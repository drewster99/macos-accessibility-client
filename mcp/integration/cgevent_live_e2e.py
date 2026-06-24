#!/usr/bin/env python3
"""
Live proof of the 6 GLOBAL-INPUT CGEvent verbs (click / scroll / key / type_text / hover /
drag) through the real MacControlStdio server.

UNLIKE the AX verbs, these post SYSTEM-WIDE events that land on whatever is frontmost — so
this harness foregrounds throwaway targets (Calculator, TextEdit) and asks the operator to
stay hands-off while it runs. Run it ATTENDED. It verifies effects by reading state back:

  type_text -> the focused TextEdit field's value
  key       -> ⌘A then a replacement keystroke collapses the field to one char
  click     -> clicking a Calculator button's frame updates the display
  drag      -> dragging the title bar moves the window (frame read-back)
  scroll    -> best-effort (scroll offset isn't exposed by the tools): asserts it posts ok
  hover     -> best-effort (cursor position isn't exposed): asserts it posts ok

Run from an Accessibility-trusted terminal (synthetic input rides that grant).
"""
import glob
import json
import os
import subprocess
import sys
import tempfile
import time


def locate_binary():
    env = os.environ.get("MACCONTROL_STDIO")
    if env and os.path.exists(env):
        return env
    hits = sorted(glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/MacControlMCP-*/Build/Products/*/MacControlStdio")),
        key=os.path.getmtime, reverse=True)
    if not hits:
        sys.exit("MacControlStdio not found — build the 'All' scheme first.")
    return hits[0]


class Server:
    def __init__(self, b):
        self.p = subprocess.Popen([b], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, bufsize=1, text=True)
        self._id = 0

    def rpc(self, method, params=None):
        self._id += 1
        req = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            req["params"] = params
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def call(self, name, arguments):
        text = self.rpc("tools/call", {"name": name, "arguments": arguments})["result"]["content"][0]["text"]
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {"_text": text}

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        self.p.terminate()


results = []
def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


def activate(app_name):
    subprocess.run(["osascript", "-e", f'tell application "{app_name}" to activate'], check=False)
    time.sleep(1.0)


def app_pid(s, bundle_id, timeout=12.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for a in s.call("list_apps", {}):
            if a.get("bundleId") == bundle_id:
                return a["pid"]
        time.sleep(0.4)
    return None


def find_one(s, pid, **kw):
    kw["pid"] = pid
    r = s.call("find_elements", kw)
    return r[0] if isinstance(r, list) and r else None


def window_frame(s, pid):
    w = find_one(s, pid, role="AXWindow", limit=1)
    return s.call("element_detail", {"ref": w["ref"]}).get("frame", {}) if w else {}


def test_typing(s):
    print("TextEdit — type_text + key (focused-field read-back):")
    tmp = os.path.join(tempfile.gettempdir(), f"cg_scratch_{os.getpid()}.txt")
    with open(tmp, "w") as f:
        f.write("seed\n")
    subprocess.run(["open", "-a", "TextEdit", tmp], check=False)
    pid = app_pid(s, "com.apple.TextEdit")
    if not pid:
        check("TextEdit running", False); return
    time.sleep(1.0)
    activate("TextEdit")
    area = find_one(s, pid, role="AXTextArea", limit=5)
    if not area:
        check("TextEdit text area", False); return
    ref = area["ref"]
    s.call("set_value", {"ref": ref, "value": ""})
    s.call("set_focus", {"ref": ref})
    time.sleep(0.3)

    r = s.call("type_text", {"text": "hello cgevent", "via": "keys"})
    time.sleep(0.6)  # keystrokes process a beat after posting — read after a settle delay
    val = s.call("element_detail", {"ref": ref}).get("value") or ""
    check("type_text(keys) lands in focused field", "ok" in r and "hello cgevent" in val, f"value={val!r}")

    # ⌘A selects all, delete removes the selection -> empty field. Proves a modifier combo
    # AND a plain keystroke both land (with settle delays for the post→process lag).
    s.call("key", {"keys": "cmd+a"})
    time.sleep(0.5)
    s.call("key", {"keys": "delete"})
    time.sleep(0.6)
    val2 = (s.call("element_detail", {"ref": ref}).get("value") or "").strip()
    check("key ⌘A select-all + delete -> empty field", val2 == "", f"value={val2!r}")

    # observe:"settle" on a CGEvent verb (the gap this session closed): type with settle posts,
    # waits for the app to quiesce, and returns the diff — no separate read-after-wait needed.
    s.call("set_value", {"ref": ref, "value": ""})
    s.call("set_focus", {"ref": ref})
    time.sleep(0.3)
    rs = s.call("type_text", {"text": "settle me", "via": "keys", "observe": "settle", "pid": pid})
    landed = s.call("element_detail", {"ref": ref}).get("value") or ""
    check("type_text observe:settle -> diff + text lands",
          isinstance(rs, dict) and "settledAfterMs" in rs and "diff" in rs and "settle me" in landed,
          f"settledAfterMs={rs.get('settledAfterMs')} value={landed!r}")

    # scroll: needs content taller than the view; assert it posts without error (offset unreadable).
    s.call("set_value", {"ref": ref, "value": "\n".join(f"line {i}" for i in range(200))})
    s.call("set_focus", {"ref": ref})
    time.sleep(0.2)
    rs = s.call("scroll", {"dx": 0, "dy": -400})
    check("scroll posts ok (best-effort)", isinstance(rs, dict) and rs.get("ok") is not False
          and "error" not in rs, str(rs)[:80])

    # hover: move cursor over the window; assert it posts (cursor pos unreadable via tools).
    fr = window_frame(s, pid)
    if fr:
        rh = s.call("hover", {"x": fr["x"] + fr["w"] // 2, "y": fr["y"] + fr["h"] // 2})
        check("hover posts ok (best-effort)", isinstance(rh, dict) and "error" not in rh, str(rh)[:80])

    # drag the window by its title bar (a few px below the frame top); verify via frame read-back.
    before = window_frame(s, pid)
    if before:
        tb_x, tb_y = before["x"] + before["w"] // 2, before["y"] + 6
        s.call("drag", {"fromX": tb_x, "fromY": tb_y, "toX": tb_x + 140, "toY": tb_y})
        time.sleep(0.6)
        after = window_frame(s, pid)
        moved = after.get("x", -999) - before.get("x", 0)
        check("drag title bar -> window moves right ~140", 110 <= moved <= 180,
              f"x {before.get('x')} -> {after.get('x')} (Δ{moved})")


def test_click(s):
    print("Calculator — click (display read-back):")
    subprocess.run(["open", "-a", "Calculator"], check=False)
    pid = app_pid(s, "com.apple.calculator")
    if not pid:
        check("Calculator running", False); return
    activate("Calculator")

    # Park the window at a known spot so button screen-coords are stable and unoccluded.
    win = find_one(s, pid, role="AXWindow", limit=1)
    s.call("window", {"ref": win["ref"], "action": "move", "x": 220, "y": 220})
    s.call("window", {"ref": win["ref"], "action": "raise"})
    time.sleep(0.6)

    def ref_for(*idents):
        for i in idents:
            e = find_one(s, pid, identifier=i)
            if e:
                return e
        return None

    ac = ref_for("AllClear", "Clear")
    if ac:
        s.call("click", {"x": ac["frame"]["x"] + ac["frame"]["w"] // 2,
                         "y": ac["frame"]["y"] + ac["frame"]["h"] // 2})
        time.sleep(0.3)

    five = ref_for("Five")
    fr = five["frame"]
    s.call("click", {"x": fr["x"] + fr["w"] // 2, "y": fr["y"] + fr["h"] // 2})
    time.sleep(0.4)
    disp = None
    for e in s.call("find_elements", {"pid": pid, "role": "AXStaticText", "limit": 40}) or []:
        v = s.call("element_detail", {"ref": e["ref"]}).get("value") or ""
        if any(c.isdigit() for c in v):
            disp = v
    check("click on '5' button -> display shows 5",
          disp is not None and disp.replace("‎", "").strip().endswith("5"), f"display={disp!r}")


def main():
    binary = locate_binary()
    print(f"server: {binary}")
    print("ATTENDED RUN — please don't touch the keyboard/mouse for ~30s.\n")
    s = Server(binary)
    try:
        s.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                             "clientInfo": {"name": "cgevent-e2e", "version": "1"}})
        # Confirm synthetic-input access before firing (gates on CGPreflightPostEventAccess).
        probe = s.call("hover", {"x": 12, "y": 12})
        if isinstance(probe, dict) and "error" in probe and "post" in json.dumps(probe).lower():
            check("synthetic-input access granted", False, str(probe))
            return
        test_typing(s)
        test_click(s)
    finally:
        s.close()

    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
