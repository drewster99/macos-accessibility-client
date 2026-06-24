# Live integration harnesses

These scripts drive the **real `MacControlStdio` MCP server** over stdio (the same
`HostKit.makeFullServer()` the XPC host uses) against live apps, proving the tools work
end-to-end — not just at the unit level. They must run from a terminal that is
**Accessibility-** and **Screen-Recording-trusted**, because the server inherits the
caller's TCC identity. That's why these are scripts, not XCTest cases: the `xcodebuild`
test runner isn't a trusted responsible process, so AX-dependent live tests skip there.

The binary is auto-located from DerivedData (build the `All` scheme first), or point
`MACCONTROL_STDIO` at it.

## Scripts

| Script | Proves | Targets | Attended? |
|---|---|---|---|
| `ax_live_e2e.py` | read (`ui_snapshot`, `find_elements` incl. identifier/actionable filters, `element_detail`, `element_at`, `focused_element`), AX **act** (`perform`/AXPress, `set_value`, `set_focus`, `reveal`, `window` move, `open_menu`), `observe:"settle"`, `wait_for`, `get_changes` value-diff | Calculator (native AppKit), TextEdit | no — background, element-targeted |
| `capture_sim_electron_e2e.py` | `screenshot` (screen + simulator), downscale, `ocr` (Vision), `sim` (statusbar/appearance), `list_simulators`, Electron read coverage | Booted simulator, screen, Slack/Postman/Discord | no |
| `cgevent_live_e2e.py` | the 6 **global-input** verbs — `click`, `scroll`, `key`, `type_text`, `hover`, `drag` — with read-back where observable (typed text, ⌘A+delete→empty, click→display, drag→window frame), plus `type_text` with `observe:"settle"` returning a diff | Calculator + TextEdit (foregrounded) | **YES** — posts system-wide events |

Run:

```sh
python3 integration/ax_live_e2e.py
python3 integration/capture_sim_electron_e2e.py
python3 integration/cgevent_live_e2e.py   # ATTENDED — don't touch keyboard/mouse for ~30s
```

Each prints per-check PASS/FAIL and exits non-zero if any check fails. The first two only
touch apps they launch in the background (`open -g`) with element-targeted AX calls, so they
don't disturb the foreground session. `cgevent_live_e2e.py` foregrounds its targets and fires
**real keyboard/mouse events** — run it attended.

Note: CGEvent keystrokes/clicks process a beat *after* `post()` returns, so the harness reads
state back after a short settle delay (an immediate read can miss the just-posted key).

## What these do NOT cover (deliberately)

- **The installed-app XPC/launchd on-demand path** — these scripts exercise the in-process
  server directly (the same `makeFullServer()` the XPC host uses). The relay→launchd→host XPC
  path is proven separately by the P0a spike and needs the notarized `dist/MacControlMCP.app`
  installed + granted to verify at runtime.

## Known real-world AX limitations surfaced here

- **Calculator's SwiftUI result display** isn't carried as a `value` on an identity-stable
  snapshot node, so its display changes don't show up in `get_changes`. `set_value` /
  `get_changes` value-diff is therefore asserted against TextEdit's standard `AXTextArea`.
  Modern controls also frequently have **no `AXTitle`** (their label is in `AXIdentifier` —
  e.g. Calculator's `"Seven"`), which is why `find_elements` matches identifier/value and
  exposes `identifier` in results.
