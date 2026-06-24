#!/usr/bin/env python3
"""
Live proof of the capture / simulator / OCR tools and Electron read coverage, through the
real MacControlStdio server. Grant-free for the simulator + OCR paths; the Mac screen
capture rides this terminal's Screen-Recording grant.

Privacy: the Mac screen shot is written to a temp file and OCR'd, but only structural
counts are reported here — the screen's text content is never echoed.

Run from an Accessibility + Screen-Recording-trusted terminal.
"""
import glob
import json
import os
import subprocess
import sys
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


def is_png(path):
    try:
        with open(path, "rb") as f:
            return f.read(8) == b"\x89PNG\r\n\x1a\n"
    except OSError:
        return False


def main():
    binary = locate_binary()
    print(f"server: {binary}\n")
    s = Server(binary)
    try:
        s.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                             "clientInfo": {"name": "cap-sim", "version": "1"}})

        print("Simulator (simctl, grant-free):")
        sims = s.call("list_simulators", {})
        booted = []
        def walk(o):
            if isinstance(o, dict):
                if o.get("state") == "Booted" or o.get("udid"):
                    booted.append(o)
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        walk(sims)
        check("list_simulators returns devices", len(booted) > 0, f"{len(booted)} device entries")

        shot = s.call("screenshot", {"target": "simulator"})
        spath = shot.get("path")
        check("screenshot simulator -> valid PNG", spath and os.path.exists(spath) and is_png(spath),
              f"path={spath} bytes={os.path.getsize(spath) if spath and os.path.exists(spath) else 0}")

        check("sim statusbar override ok", s.call("sim", {"action": "statusbar"}).get("ok") is True)
        check("sim statusbar_clear ok", s.call("sim", {"action": "statusbar_clear"}).get("ok") is True)
        check("sim appearance dark ok", s.call("sim", {"action": "appearance", "value": "dark"}).get("ok") is True)
        s.call("sim", {"action": "appearance", "value": "light"})  # restore

        print("Mac screen capture + OCR (Screen-Recording grant):")
        screen = s.call("screenshot", {"target": "screen", "maxDimension": 1400})
        cpath = screen.get("path")
        longest = max(screen.get("width", 0), screen.get("height", 0))
        check("screenshot screen -> valid PNG", cpath and os.path.exists(cpath) and is_png(cpath),
              f"{screen.get('width')}x{screen.get('height')}")
        check("screenshot downscale honored (<=1400)", 0 < longest <= 1400, f"longest={longest}")
        if cpath:
            ocr = s.call("ocr", {"path": cpath})
            # report counts only — never echo the user's screen content
            n = len(ocr.get("lines", [])) if isinstance(ocr.get("lines"), list) else -1
            check("ocr returns recognized lines", n >= 0 and "lines" in ocr, f"{n} lines recognized")

        print("Electron read coverage (Chromium AX tree):")
        target = None
        for bid, name in [("com.tinyspeck.slackmacgap", "Slack"), ("com.postmanlabs.mac", "Postman"),
                          ("com.hnc.Discord", "Discord")]:
            apps = s.call("list_apps", {})
            hit = next((a for a in apps if a.get("bundleId") == bid), None)
            if not hit:
                subprocess.run(["open", "-g", "-b", bid], check=False)
                time.sleep(4.0)
                apps = s.call("list_apps", {})
                hit = next((a for a in apps if a.get("bundleId") == bid), None)
            if hit:
                target = (name, hit["pid"]); break
        if target:
            name, pid = target
            outline = s.call("ui_snapshot", {"pid": pid, "depth": 4}).get("_text", "")
            nlines = outline.count("\n")
            check(f"ui_snapshot on {name} (Electron) returns non-trivial tree", nlines >= 5,
                  f"{nlines} outline lines")
            btns = s.call("find_elements", {"pid": pid, "role": "AXButton", "limit": 50})
            check(f"find_elements finds controls in {name}", isinstance(btns, list) and len(btns) > 0,
                  f"{len(btns) if isinstance(btns, list) else 0} buttons")
        else:
            check("Electron app available", False, "no Slack/Postman/Discord found")
    finally:
        s.close()

    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
