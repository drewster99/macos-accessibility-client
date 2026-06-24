#!/usr/bin/env python3
"""
Verify the INSTALLED app's on-demand launchd + XPC path end-to-end — the one thing the
in-process harnesses can't prove because it requires the real signed bundle, the registered
LaunchAgent, and a TCC grant on the host.

Run this AFTER you have:
  1. moved MacControlMCP.app to /Applications (or kept it in mcp/dist/),
  2. launched it once and clicked "Register" (registers the SMAppService LaunchAgent),
  3. granted the HOST Accessibility (+ Screen Recording) in System Settings.

It drives the bundled `MacControlRelay` exactly as an MCP client would: writes newline-
delimited JSON-RPC to the relay's stdin and reads responses. The relay forwards over XPC to
the on-demand host (launched by launchd), so a correct response proves relay → launchd → host
→ back, plus the code-signing-pinned XPC admission.

  python3 integration/verify_installed_relay.py
"""
import json
import os
import select
import subprocess
import sys
import time


def locate_relay():
    candidates = [
        "/Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist",
                     "MacControlMCP.app", "Contents", "Helpers", "MacControlRelay"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return os.path.abspath(c)
    sys.exit("MacControlRelay not found — install MacControlMCP.app to /Applications "
             "(or build dist/ via notarize-app.sh) first.")


def main():
    relay = locate_relay()
    print(f"relay: {relay}\n")
    p = subprocess.Popen([relay], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, bufsize=1, text=True)

    def rpc(obj, timeout=20):
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()
        # The relay may need to cold-launch the host on the first call. Bounded reads via
        # select() so a host that never launches reports a timeout instead of hanging.
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([p.stdout], [], [], max(0.0, deadline - time.time()))
            if not ready:
                return None
            line = p.stdout.readline()
            if line == "":   # EOF — relay exited
                return None
            if line.strip():
                return json.loads(line)
        return None

    ok = True
    try:
        init = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                               "clientInfo": {"name": "verify-relay", "version": "1"}}})
        if init and "result" in init:
            print("  [PASS] initialize via relay->XPC->host")
        else:
            ok = False
            print(f"  [FAIL] initialize via relay — {init}")

        resp = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": {"name": "list_apps", "arguments": {}}})
        try:
            apps = json.loads(resp["result"]["content"][0]["text"])
            print(f"  [PASS] list_apps via relay -> {len(apps)} apps (host is alive)")
        except Exception:
            ok = False
            print(f"  [FAIL] list_apps via relay — {resp}")

        # Confirm the host actually holds the Accessibility grant (so AX tools will work).
        resp = rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": {"name": "focused_element", "arguments": {}}})
        text = (resp or {}).get("result", {}).get("content", [{}])[0].get("text", "") if resp else ""
        if "accessibility_not_granted" in text:
            ok = False
            print("  [FAIL] host lacks Accessibility — grant the HOST (not the relay) in "
                  "System Settings ‣ Privacy & Security ‣ Accessibility")
        else:
            print("  [PASS] host holds Accessibility (focused_element did not report a grant error)")
    finally:
        try:
            p.stdin.close()
        except Exception:
            pass
        err = p.stderr.read() if p.stderr else ""
        p.terminate()
        if err.strip():
            print(f"\nrelay stderr:\n{err.strip()}")

    print("\n" + ("ALL GOOD — the installed launchd/XPC path works end-to-end."
                  if ok else "INCOMPLETE — see FAIL lines above."))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
