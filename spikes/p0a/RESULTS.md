# P0a spike #1 — results

Validates the load-bearing TCC/XPC assumptions in `docs/MCP_DESIGN.md` §2 before the
real build. Throwaway harness (built with `swiftc` via `build.sh`; the product builds via
xcode-mcp-server).

## ✅ Validated autonomously (no TCC grant needed)

Run: `./build.sh && ./test-admission.sh`

1. **On-demand launchd launch.** The host is not running; a relay connecting to the Mach
   service `P8MA38JTXY.com.nuclearcyborg.p0a.host` causes launchd to start it on demand.
   Evidence (host log): fresh `pid` logs `starting … listening … accepted connection`.

2. **XPC admission (closes the same-user confused-deputy hole).**
   - Team-signed relay → **ACCEPTED** (host logs "accepted connection from pid N", replies).
   - Ad-hoc relay → **REJECTED**: `NSCocoaErrorDomain Code=4097` + interruption, and the host
     log shows **no "accepted"** for it — the system rejected it before our delegate ran.
   - Mechanism: `NSXPCListener.setConnectionCodeSigningRequirement(_:)` pinned to our Team ID.

3. **Design note confirmed.** The bare-executable host reports `bundleID:"(none)"` → it would
   appear under an unfriendly name in System Settings. ⇒ the real host must be a nested `.app`
   with its own bundle id (as the design already specifies).

## ⏳ Pending — requires a manual grant (TCC is human-gated by design)

**TCC responsible-process attribution** — the single most load-bearing claim. Procedure:

1. `./build.sh && ./verify-tcc.sh` — it (re)launches the host and prints the host binary path.
2. **System Settings ▸ Privacy & Security ▸ Accessibility ▸ "+"**, add the printed host path:
   `…/spikes/p0a/build/P0AControl.app/Contents/Helpers/p0a-host`, and enable it.
3. Re-run `./verify-tcc.sh`. **Pass = the relay prints `"axTrusted":true`** — proving the
   grant attached to the *host* (launched by launchd), not Terminal / the client / the relay.

(Also still human-gated: the real SMAppService registration needs the Control app run + a
Login-Items approval. This spike used `launchctl` to register the Mach service directly.)

## P0a remaining (separate spikes)

- Observation coverage on a real Electron app + simulator (also needs a grant for the probe).
- Screen-Recording relaunch behavior (needs the SR grant).
- Relay reconnect across host re-exec (autonomous; relay reconnect is a P0b feature).
