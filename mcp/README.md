# MacControlMCP

An MCP server for inspecting, observing, and driving **macOS apps and iOS Simulator
content**, plus taking screenshots — built on this repo's Accessibility code. See
[`../docs/MCP_DESIGN.md`](../docs/MCP_DESIGN.md) for the full design and
[`../docs/GOAL.md`](../docs/GOAL.md) for the definition of done.

## Architecture

A privileged background **host** owns all Accessibility / ScreenCaptureKit / CGEvent /
`simctl` work and vends the MCP server over an XPC Mach service; a dumb **stdio relay**
is what MCP clients launch; an SMAppService **registrar** installs the host as an
on-demand `LaunchAgent`. Only the host holds TCC grants.

```
MacControlMCP.app/
  Contents/MacOS/MacControlRegistrar        registers the host LaunchAgent (SMAppService)
  Contents/Helpers/MacControlHost           the privileged XPC host (the only TCC identity)
  Contents/Helpers/MacControlRelay          stdio↔XPC relay — what MCP clients launch
  Contents/Library/LaunchAgents/com.nuclearcyborg.maccontrol.host.plist
```

Caller identity is pinned: the host's `NSXPCListener` enforces a code-signing
requirement so only our signed relay/GUI can connect.

## Build & test (via xcode-mcp-server)

This is a native Xcode project generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate            # regenerate MacControlMCP.xcodeproj after editing project.yml
```

Build and test through **xcode-mcp-server** (scheme `All`) — never `xcodebuild` directly:
`build_project` / `run_project_tests` against `MacControlMCP.xcodeproj`.

> Live AX/Screen-Recording tests `XCTSkip` unless the test-runner process is itself
> AX-granted, so they skip under the `xcodebuild` runner and run under a granted terminal.

## Package & notarize

Build the **`Release`** scheme via xcode-mcp-server, then:

```sh
./notarize-app.sh   # sign (Developer ID + hardened runtime, inside-out) → notarytool --wait → staple → spctl
```

It signs the Xcode-built `MacControlMCP.app` (relay → nested `MacControlHost.app` → app) using the
`ncc-cli-notarytool` keychain profile (or `$NOTARY_PROFILE`). The result is notarized, stapled, and
Gatekeeper-accepted (`source=Notarized Developer ID`). (`package.sh` is the older SwiftPM CLI-assembly path.)

## Install & grant

1. Copy `dist/MacControlMCP.app` to `/Applications`.
2. Run the registrar once to install the LaunchAgent and approve it in **System Settings ▸
   General ▸ Login Items**:
   `/Applications/MacControlMCP.app/Contents/MacOS/MacControlRegistrar`
3. Grant the **host** Accessibility (and Screen Recording for screenshots) in **System
   Settings ▸ Privacy & Security**. AX-driving tools return a structured
   `accessibility_not_granted` error until granted.

## MCP client configuration

Point your MCP client at the **relay**:

```json
{
  "mcpServers": {
    "mac-control": {
      "command": "/Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay"
    }
  }
}
```

The relay connects to the host over XPC (launched on demand by launchd) and forwards
JSON-RPC. No URL/port — standard stdio.

## Tools

| Group | Tools |
|---|---|
| Discovery | `list_apps`, `list_simulators` |
| Query (refs) | `ui_snapshot`, `find_elements`, `element_detail`, `element_at`, `focused_element` |
| Act (AX) | `perform`, `set_value`, `set_focus`, `reveal`, `window`, `open_menu` |
| Act (synthetic input) | `click`, `scroll`, `key`, `type_text`, `drag`, `hover` |
| Observe | `wait_for`, `get_changes` (and act-and-settle diffs via `SettleEngine`) |
| Capture | `screenshot` (screen via ScreenCaptureKit, simulator via simctl), `ocr` (Vision) |
| Simulator | `sim` (openurl / appearance / statusbar / launch / terminate / pbpaste) |

Element refs are stable across snapshots (assigned by AX element identity), so diffs are
meaningful and a dead ref is re-resolved via its locator — returning candidates rather
than guessing when ambiguous.

> `Package.swift` is retained only as the release-build backend for `package.sh`; the
> Xcode project has native targets and does **not** reference it.
