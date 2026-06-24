# MCP Server Design — Mac & Simulator Control

**Status:** Draft — revised after two independent review passes
**Date:** 2026-06-23
**Scope:** An MCP server, built on this project's Accessibility code, that lets an
agent inspect, observe, and drive macOS apps and iOS Simulator content, and
capture screenshots of the screen, a window, an app, an element, or a simulator.

---

## 1. Goals & non-goals

### Goals
- **Drive** Mac apps and iOS-Simulator content: read structure, invoke actions,
  click/scroll/drag/type, manage windows, set values/focus/selection.
- **Observe** change: know what happened after an action (or after the user did
  something), efficiently, without re-dumping the world.
- **Capture** screenshots: whole screen, a display, an app, a window, a single
  element (cropped), or a booted simulator.
- **Be efficient and highly performant**: one round trip per act, small payloads,
  warm sessions, all AX I/O off the cooperative pool.
- **Install as one app bundle**; let any MCP client launch a stdio server trivially;
  let the app see all connected clients and own permissions/settings/notifications;
  the app need not be visible or open.

### Non-goals (v1)
- Building/running Xcode projects — that's `xcode-mcp-server`'s job; this server
  complements it.
- True multi-touch gestures (pinch/rotate) — a single synthetic pointer can't do
  them reliably.
- Reading another process's internal state beyond what AX, pixels/OCR, or the
  clipboard expose.
- Apple Events / AppleScript automation and global keystroke *monitoring* — both
  deliberately avoided (see §3).

---

## 2. Architecture

A privileged **background agent** owns everything; a disposable **stdio relay**
is what MCP clients launch; an optional **GUI** is a face on the agent. All three
ship in one signed bundle and talk over **XPC**.

```
MacControlMCP.app/                         ← single signed bundle, single TCC identity
  Contents/
    MacOS/MacControlMCP                    GUI front-end  — unprivileged, XPC client
    Helpers/
      MacControlHost.app                   ★ THE AGENT — a nested helper *app*
        Contents/MacOS/mac-control-host      (own bundle id, Info.plist, LSUIElement,
                                             icon → friendly, stable TCC identity).
                                             Owns AX + ScreenCaptureKit, AXObservers,
                                             sessions/handle tables, settings,
                                             notifications, client registry; vends the
                                             Mach service. The ONE TCC identity.
      mac-control-mcp                       stdio relay — unprivileged, ~no logic
    Library/LaunchAgents/
      com.nuclearcyborg.maccontrol.host.plist   on-demand launch (SMAppService;
                                             BundleProgram → the helper app; MachServices)
```

### Roles
- **`mac-control-host` (the agent).** A faceless `LaunchAgent`, packaged as a nested
  helper **.app** with its own bundle id + Info.plist + `LSUIElement` + icon. *All*
  Accessibility, Screen Recording, CGEvent, ScreenCaptureKit, and `simctl` work lives
  here and nowhere else, so there is exactly **one TCC identity** to manage — note that
  identity is the **helper app's** designated requirement, *distinct* from the GUI's
  bundle id; "single TCC identity" means the user grants the helper, not the enclosing
  bundle. Vends a Mach XPC service, holds warm per-target sessions + the
  `ref → AXUIElement` handle tables, runs the `AXObserver`s + change journal, and keeps
  a **registry of every connected relay** (so the app "sees all stdio clients"). Runs
  the MCP server logic per connection.
- **`mac-control-mcp` (the stdio relay).** What MCP clients put in their config as
  `command`. Opens an `NSXPCConnection` to the host's Mach service and is a
  transparent pipe: stdin JSON-RPC → XPC → host → XPC → stdout. Holds **no AX
  permission and no protocol logic.** Disposable, one per client. Its *one* piece of
  logic: **transparent reconnect** — on XPC interruption/invalidation (e.g., the host
  re-execs to apply a Screen-Recording grant), it re-establishes the connection and
  retries the in-flight request instead of surfacing a broken pipe. Mutating calls carry
  an idempotency token so a retry across a host restart can't double-fire.
- **GUI (`MacControlMCP`).** Touches **zero AX directly**; it's an XPC client that
  renders the live activity the host streams to it (the project's existing
  observer/inspector UI, now sourced over XPC). Closing the window leaves the host
  running.

### Cold-start flow (app not running, not visible)
1. An MCP client (Claude Code, Claude Desktop) launches `mac-control-mcp` per its config.
2. The relay opens `NSXPCConnection(machServiceName: …host)` and sends `initialize`.
   Creating the connection launches nothing — the **first message** does.
3. That first message makes **launchd start the host helper on demand** (registered
   via `SMAppService.agent`). No GUI, no Dock icon, nothing visible.
4. The host registers the relay as a client and services MCP tool calls.
5. The user can *optionally* open the GUI later; it attaches to the already-running
   host. Quitting the window leaves the host and all sessions alive.

### Why launchd-launch is load-bearing
TCC checks the **process that calls the API** and attributes it to a *responsible
process*. If the relay forked the host (or the host were an `XPCService` sub-bundle
of the relay), TCC could attribute AX/Screen-Recording requests to the **ancestor**
(the terminal / the MCP client) — the classic "my CLI needs Accessibility but the
grant has to go to iTerm" trap. By having the relay look up a **Mach service** and
letting **launchd** start the host, the host is its **own responsible process**;
its grant attaches to *it*, independent of who spawned the relay. The relay only
ever speaks XPC, so its being unprivileged is irrelevant — the host calls AX
in-process with its own grant.

> **Load-bearing — prototype before building on it.** TCC's responsible-process
> attribution is *not* a documented public contract. Prior art (SMAppService agents
> that hold Accessibility) makes this very likely, but **P0a** must confirm with a
> signed-helper spike that attribution lands on the host — not Terminal / the MCP
> client / the relay — before anything depends on it.

### XPC admission — who may connect

A launchd `MachServices` name lives in the user's bootstrap namespace, so **any
process running as the same user can look it up and connect.** Same-UID is *not*
authorization — without a check, any local process could drive our TCC-trusted host
(a confused-deputy / privilege-escalation hole). There is **no built-in "same app
only" restriction** for a launchd Mach service. (An `XPCService` bundle *is*
implicitly app-private, but it's unreachable by our independently-launched relay and
would adopt the GUI's TCC responsibility — disqualified on both counts.)

So the host **pins caller identity** with a code-signing requirement the system
enforces before our delegate even runs:
- **`NSXPCListener.setConnectionCodeSigningRequirement:`** (macOS 13+) — or C-level
  `xpc_listener_set_peer_code_signing_requirement` — set to a requirement pinned to our
  Team ID **and** the relay/GUI bundle ids (their designated requirements).
- Belt-and-suspenders in `shouldAcceptNewConnection:`: validate the peer's audit token
  via `SecCodeCreateWithXPCMessage` + `SecCodeCheckValidity` against a `SecRequirement`.

Connections that don't satisfy the requirement are rejected. (SDK-confirmed in macOS 15:
`setConnectionCodeSigningRequirement:`, `xpc_listener_set_peer_code_signing_requirement`,
and `SecCodeCreateWithXPCMessage` all present.)

> **Local dev:** ad-hoc/unsigned debug builds have no Team ID, so the requirement would
> reject them. Under `#if DEBUG`, relax it to match the bundle id (or a dev cert) so
> debugging isn't blocked; enforce the full Team-ID requirement only in Release.

### Decided sub-points
- **Relay = dumb pipe; host = MCP server.** All protocol logic in one place; the
  relay never version-skews.
- **Host lifecycle.** Resident while ≥1 client is connected; idle-timeout exit after
  the last disconnect (keeps warm observers alive during a working session, frees
  resources after).
- **Ref namespacing.** Per-client ref namespace over **shared** warm sessions —
  clients can't collide on each other's handles, but the expensive
  session/observer/root is built once per target pid.
- **Transport.** XPC Mach service (native, launchd-supervised on-demand launch).
  Caveat: Mach lookup needs the relay in the user's GUI bootstrap namespace (true
  for local desktop MCP clients; would fail over a bare ssh session). A Unix-domain
  socket at a known path is the fallback if ever needed.
- **Agent, never Daemon.** It must be a per-user `LaunchAgent` in the Aqua/GUI
  session — AX, ScreenCaptureKit, and permission prompts all require it. A
  `LaunchDaemon` (system, pre-login) would have none of that.

---

## 3. Permissions (TCC)

The host needs exactly **two** grants; everything else needs none.

| Capability | Grant | Notes |
|---|---|---|
| `AXUIElement` read/write/actions | **Accessibility** | the whole AX surface |
| Synthetic input — `CGEvent.post` click/scroll/drag/keys | **Accessibility** (post-event access) | check `CGPreflightPostEventAccess()`, not just `AXIsProcessTrusted()` |
| Screenshots via ScreenCaptureKit | **Screen Recording** | one-time grant; see relaunch note |
| Simulator screenshots / device ops via `xcrun simctl` | none | CoreSimulator, runs as the user |
| App lifecycle, open URLs, pasteboard | none | `NSWorkspace` / `NSPasteboard` |

A faceless agent **can** hold both grants — keyboard remappers, window managers, and
screen tools do exactly this. We deliberately **avoid**:
- **Apple Events / Automation** — we drive via AX + CGEvent, never AppleScript.
- **Input Monitoring** (`kTCCServiceListenEvent`) — we *post* keystrokes (Accessibility),
  we never *listen* globally. (Mouse monitoring is covered by Accessibility; keyboard
  monitoring would need Input Monitoring — so we observe text changes via AX instead.)

### Gotchas to design around
1. **Give the host its own bundle + Info.plist** (`CFBundleName`, icon, `LSUIElement`)
   so System Settings shows a friendly name, not `mac-control-host`.
2. **Screen Recording may need a relaunch after granting** — after the grant flips, run
   a preflight **and a tiny capture probe**; only enter `granted_but_pending_restart`
   (and re-exec) if the probe still fails, so we don't needlessly tear down warm
   sessions. This behavior is version-fragile — probe, don't assume.
3. **Accessibility has no in-prompt "Allow"** — always a manual toggle. The GUI
   orchestrates the UX (the existing `PermissionsBanner`/deep-link), but the **host**
   must call `AXIsProcessTrustedWithOptions(prompt:true)` and self-check so attribution
   lands on it. GUI → XPC → "host, trigger your prompt."
4. **Grant is keyed to the host's designated requirement** (Team ID + bundle id +
   signature). Developer-ID-signed + notarized = stable; re-signed dev builds re-prompt
   (same caveat the README already documents).
5. **Permission-not-granted is a first-class result** — AX/screenshot/input tools return
   a structured `{ error: "accessibility_not_granted" | "screen_recording_not_granted" |
   "post_event_access_denied", deepLink, howToFix }` so the agent and user know exactly
   what to do.
6. **Posting events has its own access check.** Use `CGPreflightPostEventAccess()` /
   `CGRequestPostEventAccess()` for synthetic input rather than inferring it from
   `AXIsProcessTrusted()`. It's surfaced to users under Accessibility, but it's a
   distinct preflight — model it explicitly.

---

## 4. Element addressing — handles + locators

`AXUIElement`s are opaque, process-local `CFTypeRef`s; they cannot be serialized to
the model. The model needs stable, cheap references.

- **`ref`** — a short opaque handle (e.g. `"e7f3"`), valid within a **session** (one
  per target pid). The host holds the `ref → AXElement` table. The model passes just
  the `ref` back to read or act — no re-sending descriptors, no re-walking.
- **locator** — each `ref` is backed by a richer signature: `{ pid, window id+title,
  parent-chain role/identifier signature, sibling index, role, title, AXIdentifier,
  frame, snapshot generation }`. When a handle goes stale (element destroyed/rebuilt),
  the host attempts **best-effort** re-resolution from the locator — but **never
  silently guesses.** Role paths shift, titles duplicate, and `AXIdentifier` is often
  absent, so a high-confidence match proceeds while anything ambiguous returns a
  `stale_ref` error **with candidate refs** for the agent to disambiguate. (A
  transparent *wrong* re-resolution means clicking the wrong thing — worse than a clean
  failure.)
- **warm sessions** — cached root, `AXObserver`, change journal, and a
  messaging-timeout set once; repeated calls stay hot.
- **per-client namespacing** — refs are namespaced per relay connection over a shared
  session, so two clients driving the same app don't collide.

This is the foundation the diff model (§6) builds on: unchanged elements keep their
refs, new ones get new refs, destroyed refs are reported removed — so diffs are
expressed in the vocabulary the model already holds.

---

## 5. Capability surface

The four obvious verbs (read structure, AXPress, synthetic click, synthetic keys)
are the *narrow* slice. The full menu, by mechanism:

### Accessibility (rides the Accessibility grant)
- **Read** — role/subrole/title/value/frame/enabled/selected/attributes/actions, tree
  walk, hit-test (`AXUIElementCopyElementAtPosition`). *Reuse `AXElement` / `ElementSnapshot`.*
- **Actions** — generic `perform(action)`: `AXPress`, `AXShowMenu`, `AXIncrement`/
  `AXDecrement`, `AXPick`, `AXConfirm`/`AXCancel`, `AXRaise`. *Reuse.*
- **Writes** (unused today; the inspector is read-only) — `AXUIElementSetAttributeValue`
  on settable attrs (guard with `AXUIElementIsAttributeSettable`):
  - **focus** (`kAXFocusedAttribute`) — focus without clicking
  - **selection** (`kAXSelectedTextRange`, `kAXSelectedRows`, `kAXSelected`)
  - **window management** (`kAXPosition`/`kAXSize`/`kAXMinimized`/`kAXMain`)
  - **value** (text, sliders, checkboxes), **expand/collapse**, **scroll-to-range**
- **Parameterized attributes** (names read today, never queried) — `kAXBoundsForRange`
  (screen rect of a word/line), `kAXStringForRange`, `kAXAttributedStringForRange`,
  `kAXRangeForPosition` (char index at a point).
- **Menus** — drive `kAXMenuBar` + the menu-chain walker (`File ▸ Export ▸ PDF…`),
  no coordinates. *Reuse `MenuChainWalker`.*
- **Observe** — `AXObserver` standard set incl. announcements and sheet/alert appearance.
  *Reuse `AXObserverWrapper` / `AppInspectionSession`.*

### Synthetic input (CGEvent — rides the Accessibility grant)
- **click** (left/right/other, single/double/triple, modifier-held), **scroll**
  (the reliable way to scroll anything), **drag** (= **swipe** in the simulator),
  **hover/move**, **keys** (Unicode via `CGEventKeyboardSetUnicodeString`; shortcuts
  via keycode + flags). *All new — zero CGEvent in the app today.*
- Requires the target focused/unobscured (HID-level events). Prefer AX actions/writes
  when available; fall back to CGEvent for the simulator and non-AX surfaces.

### Clipboard
- `NSPasteboard` read/write (Mac) and `simctl pbcopy/pbpaste` (simulator). Doubles as
  the **most reliable text-injection path** (write + ⌘V) for surfaces that mangle
  keystrokes, and a **text-extraction fallback** (⌘C + read). No TCC.

### Visual (rides Screen Recording)
- **Screenshots** — ScreenCaptureKit in-process (Mac) + `simctl io screenshot` (sim). §7.
- **Vision OCR** — `VNRecognizeTextRequest` on a capture reads text the AX tree doesn't
  expose (games/canvas/AX-poor web). In-process, no extra grant.
- **Pixel/color pick** — visual assertions when AX can't report state.
- **Video** — ScreenCaptureKit stream mode, if the GUI ever wants a live mirror.

### App & system (no TCC)
- App lifecycle (launch/activate/hide/quit — *reuse `RunningAppsViewModel`*), open
  URLs/files/deep links (`NSWorkspace`), frontmost read/set.

### Simulator device (`simctl` — no TCC, subprocess)
- `openurl`, `push`, `location`, `status_bar override`, `ui appearance dark/light`,
  `privacy grant/revoke`, `install`/`launch`/`terminate`, `pbcopy`/`pbpaste`,
  `recordVideo`, `addmedia`, log streaming.

> **The simulator boundary.** UI *inspection and control* of running simulator content
> is in-process via the `iOSContentGroup` AX bridge + CGEvent taps. Only **pixel
> capture and device management** shell out to `simctl` — there is no public in-process
> API for the device framebuffer (private `CoreSimulator`/`SimulatorKit` would be
> version-fragile, and capturing the Simulator *window* via ScreenCaptureKit includes
> chrome and breaks when occluded). **AX set-value on bridged iOS text fields is
> unreliable**: UIKit's `accessibilityValue` is app-writable, but the *bridged external*
> AX surface commonly exposes `AXValue` as **non-settable** and offers no public
> external set-text action. Treat bridged iOS `AXValue` as read-mostly (check
> `AXUIElementIsAttributeSettable`); for text entry use CGEvent (hardware keyboard) or
> `simctl pbcopy` + ⌘V.

---

## 6. Interaction model — observe & diff

### The core mismatch
AX is **push** (AXObservers fire asynchronously, in bursts). The MCP+LLM loop is
**pull** (the model calls a tool, gets a result, reasons). The model does **not**
react to a server push mid-turn. So change-detection cannot depend on pushing events
at the model. The bridge:
1. an **always-on change journal** per target — observer signals plus a settle-time
   structural poll — so an action's effects are captured even when the app under-reports,
2. **fold observation into the action** (one call acts *and* returns what changed),
3. return a **diff**, never a re-dump.

This is also the performance thesis: `tap` + "settle and return the diff" is **one
round trip and a tiny payload**, versus "tap, then separately re-snapshot the whole
tree" (two calls + a huge tree).

### Session + journal
Per target pid: a **warm session** with `AXObserver` registrations + an active
structural poll feeding a **change journal** (`{ seq, time, ref, source:
notification|poll, oldValue?, newValue? }`, coalesced, capped, with a **monotonic cursor
token** so any tool can say "give me everything since `t-10472`").

**Observation is coarse, and many apps under-report — so we don't trust it for deep
precision.** `AXObserver` registers per *(element, notification)* pair (not a recursive
feed), and worse, Electron/Chromium and WebKit content (VS Code, Slack, Discord,
browsers) frequently post *no* notifications for deep tree changes — observer-idle alone
would return an empty diff before such a UI has actually updated. So observers do only
what they're cheap and reliable at, and a poll does the rest:
- **Static, coarse observers** (always-on): app root + windows + focused element, for
  focus changes, window/sheet lifecycle, and announcements; plus the `iOSContentGroup`
  anchor — the existing `AppInspectionSession` already subscribes it successfully. We do
  **not** dynamically register per-materialized-container: that floods `axserver` with
  blocking IPC and still wouldn't help uncooperative apps.
- **Active structural poll during settle** (§Quiescence): a depth-limited structural
  signature (roles + child counts + key attributes) of the active window, sampled at
  intervals, catches the deep changes observers miss — Electron/web and deep
  bridged-simulator nodes alike.

### Quiescence ("keep refreshing until changes stop")
- **Bracket the action with the cursor:** record the cursor *before* posting, post,
  then collect events with `seq ≥ start`.
- **Hybrid settle = observer-quiet AND structure-stable:** during the settle window,
  sample a depth-limited structural signature of the active window every ~**100 ms**.
  Declare settled when the observer journal has been idle **and** the structural
  signature has stopped changing for ~**400 ms**; hard cap ~**3 s** (all per-call
  overridable). The structural poll is what makes settle work for Electron/web and
  bridged-simulator content where observers are silent; the cap + `quiesced: false`
  handles perpetual motion (spinners/video).
- **Re-read the changed region**, diff against the cached snapshot, return the diff.

### Diff shape (ref vocabulary)
```jsonc
click(ref:"e12", observe:"settle") →
{
  hit:      { ref:"e12", role:"AXButton", title:"Compose" },   // hit-test confirms the target
  quiesced: true, settledAfterMs: 420,
  diff: {
    added:      [ "e88 AXSheet \"New Message\" [600×400]", "e90 AXTextField \"To:\"" ],
    removed:    [ "e12" ],
    changed:    [ { ref:"e30", was:"value:\"\"", now:"value:\"Draft\"" } ],
    focusMoved: "e90"
  },
  changeToken: "t-10472"
}
```
- **Nothing changed** → `diff:{}`, `quiesced:true` — a useful signal (no-op tap /
  disabled control / missed); `hit` says what was actually under the point.
- **Structural reset** (whole screen replaced / navigation) → `{ reset:true,
  snapshot:<fresh compact outline> }` instead of a diff.

### Data-flow lifecycle (we never dump all screen contents)
1. **Orient** — `list_apps` / `list_simulators` (names, windows, frontmost). No deep trees.
2. **Pick + read** — `ui_snapshot(target)` → compact, depth-capped, ref-bearing outline
   (collapsed subtrees as `×N children…`, expand-by-ref). Warms the session; returns
   the first `changeToken`.
3. **Act + settle** — `click`/`scroll`/`type`/`perform` with `observe:"settle"` →
   returns the diff.
4. **Async / late changes** — `wait_for(condition, timeout)` **actively polls** for an
   expected result, so it works even in apps that don't post notifications;
   `get_changes(since:changeToken)` drains whatever the passive journal captured since.
   The journal is only as complete as the app's notifications *between* settles — for
   silent apps (Electron/web), prefer `wait_for`.

Named cases: **window changes** → window created/moved/resized notifications surface as
`added`/`changed` or via `wait_for(appears:…)`. **Tap → what changed** → the act-and-settle
diff. **Scroll** → `scroll(observe:"settle")` returns the delta of newly-revealed rows,
not the whole list.

### Diff-builder caveats
- `created/destroyed` fire on the new/dead element; `layout-changed` usually on the
  container — the builder re-reads flagged containers and the parents of created/destroyed
  nodes, with a full-subtree re-snapshot fallback when the change set is incoherent.
- Notification floods (giant tables) → coalesce per element+type, cap the journal, prefer
  the reset-snapshot path when the delta exceeds a threshold.

### Push as a secondary channel
Expose the journal as **MCP resources** (`ui://<target>/snapshot`, `ui://<target>/changes`)
with `resources/subscribe`, and emit **progress notifications** during a long settle.
Clients that support subscriptions and the **host GUI** (over XPC) get live push for
visualization — but correctness never depends on it.

---

## 7. Screenshots

| Target | Mechanism |
|---|---|
| `screen` / display | ScreenCaptureKit `SCContentFilter(display:)` |
| `window` (by CGWindowID) | `SCContentFilter(desktopIndependentWindow:)` (`SCWindow.windowID` maps the CGWindowID) |
| `app` | filter to one `SCRunningApplication`'s windows (up to N) |
| `element` (by ref) | full-window capture, then crop to the AX frame |
| `simulator` | `xcrun simctl io <udid> screenshot` (clean device framebuffer, no chrome, no Screen-Recording grant) |

In-process via `SCScreenshotManager.captureImage` — **no subprocess, no temp file**,
**downscale at capture time** (`SCStreamConfiguration.width/height`) to protect the
token budget, and **exclude our own overlay/cursor** via content-filter exclusion. This
strictly beats the `screencapture`/`swift`-interpreter shell-outs `xcode-mcp-server`
uses on the Mac side; for the simulator we converge on `simctl`.

`SCScreenshotManager.captureImage` is macOS 14+ (our floor is 15, so always available).
`SCContentFilter` app/window capture is **display-scoped**: an app whose windows span
two displays needs one capture per display, then compose or return multiple images.

**Return modes:** default a **file path** (token-cheap, like `xcode-mcp-server`,
written to a pruned per-user cache dir); **inline base64** on request (we can downscale
in-memory first); optional `highlight: ref` draws a box around an element's frame.

---

## 8. Tool catalog

Conventions: `target` = `{ app | pid | udid | "screen" }`. Action tools take
`observe: "none" | "settle" | "hittest"` (default `"settle"`) and return a diff per §6.
Coordinates are **global display points** unless a `ref` is given (then the host uses
the element's frame). Synthetic-input tools default `ensureFront: true` (activate +
raise + wait-unobscured before posting) and are **cancelable**; long `wait_for`/settles
honor cancellation. Paste-based `type_text` **saves and restores the user's clipboard**
around the injection.

### Discovery
- `list_apps()` → `[{ pid, name, bundleId, frontmost, windows:[{ id, title, frame, focused, minimized }] }]`
- `list_simulators()` → `[{ udid, name, os, state }]`
- `screen_overview()` → displays + frontmost app + window list (no deep trees)

### Query (returns refs)
- `ui_snapshot({ target, root?, depth=3, filter="interactable"|"all", max=200 })`
  → `{ outline, refs, changeToken }`
- `find_elements({ target, role?, titleContains?, identifier?, value?, actionable?, limit=20 })`
  → `[{ ref, role, title, frame, actions }]`
- `element_detail({ ref })` → full attributes/actions/parameterizedAttributes/settable/frame/readErrors
- `element_at({ target, x, y })` → `{ ref, role, title, frame }`
- `focused_element({ target? })` → `{ ref, … }`
- `query_text({ ref, range? })` → parameterized text reads (`stringForRange`, `boundsForRange`)

### Control — Accessibility
- `perform({ ref, action, openMenuChain?=true })` → result (auto menu-walk for menu items)
- `set_attribute({ ref, attribute, value })` → guarded by `IsAttributeSettable`
- `set_value({ ref, value })` / `set_focus({ ref })` → convenience wrappers
- `reveal({ ref })` → `kAXScrollToVisibleAction` — scroll an element into view (reliable AX scroll vs. guessing coordinates)
- `open_menu({ app, path:[…] })` → menu-chain walker
- `window({ ref|target, action:"move"|"resize"|"minimize"|"raise"|"main", x?, y?, w?, h? })`

### Control — synthetic input (CGEvent)
- `click({ target, ref?|x,y, button="left", count=1, modifiers?, observe? })`
- `scroll({ target, ref?|x,y, dx=0, dy, observe? })`
- `drag({ target, from:{ref|x,y}, to:{ref|x,y}, observe? })`  ·  `hover({ target, ref?|x,y })`
- `type_text({ text, target?, via="keys"|"paste", observe? })`
- `key({ keys:"cmd+s", target?, observe? })`

### Clipboard
- `clipboard_read({ simulator?=false })` → `{ text, types }`
- `clipboard_write({ text, simulator?=false })`

### App & system
- `activate({ target })` → launch if needed + bring frontmost/raise (precondition for reliable CGEvent)
- `open_url({ url, target? })` → `NSWorkspace.open` (Mac) / `simctl openurl` (simulator)

### Screenshots
- `screenshot({ target:"screen"|"app"|"window"|"element"|"simulator", id?, display?, udid?, ref?, maxDimension?, format="png"|"jpeg", return="path"|"inline", highlight?, excludeOurUI=true })`

### Observation
- `wait_for({ target, condition:{ appears?|disappears?|valueChanges?|idle?|notification? }, timeout=5000 })`
- `get_changes({ target, since:changeToken })` → events + diff
- Resources: `ui://<target>/snapshot`, `ui://<target>/changes` (subscribable)

### Simulator device (`simctl`)
- `sim({ udid?, action:"openurl"|"push"|"location"|"statusbar"|"appearance"|"privacy"|"install"|"launch"|"terminate"|"recordVideo"|"addmedia"|"log", … })`

### Permissions
- `permissions_status()` → `{ accessibility, screenRecording, pendingRestart }`
- `request_permission({ which:"accessibility"|"screenRecording" })`

> Most of the AX column comes "for free" from three **generic verbs** —
> `perform(any action)`, `set_attribute(any settable)`, `query_text(any parameterized)` —
> so we don't hand-build 40 tools. The CGEvent verb set, clipboard, OCR, screenshots,
> and the `simctl` suite round it out.

---

## 9. Serialization formats

**Compact outline** (interactable-filtered, depth-capped, ref-bearing):
```
e1  AXWindow "Inbox — Mail" [1440×900]
  e2  AXButton "Reload" (AXPress)
  e3  AXTextField "Search" value:"" (settable)
  e4  AXGroup ×12 children…        ← collapsed; expand with ui_snapshot(root:e4)
```
One element per line, indentation = depth, decorative/unlabeled containers collapse to
`×N children…`. Never auto-descends the bridged iOS subtree unless it's the explicit target.

**Diff** — see §6.

---

## 10. Performance strategy

- Warm per-target sessions; all AX I/O through `AXRunner` (off the cooperative pool),
  batched one hop per element (`ElementSnapshot`).
- Interactable-filter + depth-cap + ref-based incremental expansion → small payloads.
- Refs avoid resending descriptors; locators give best-effort stale-handle recovery
  (fail-loud on ambiguity, never a silent wrong match — §4).
- **Act-and-settle = one round trip + a diff**, not act-then-redump (the settle-time
  poll is host-internal — it adds no client round trips).
- Settle detects change from coarse observer signals plus a depth-limited structural
  poll bounded to the active window, then re-reads only the changed region.
- Screenshots in-process, downscaled, file-path by default.
- Never auto-walk the bridged iOS subtree (thousands of nodes) unless targeted.

---

## 11. Reuse map (existing → AXKit)

Extract `Core/` + `Models/` (SwiftUI-free) into a shared **`AXKit`** package the host links:

| Existing | Role in the server |
|---|---|
| `AXElement` + `AXRunner` | AX read/action primitives, off-pool execution |
| `ElementSnapshot` | one-hop batched element read → `element_detail` |
| `MenuChainWalker` | `open_menu` / `perform(AXPress)` on menu items |
| `ClickTracker` | hit-test (`element_at`) + user-tap observation (`wait_for` user click) |
| `AppInspectionSession` + `AXObserverWrapper` | warm session + change journal |
| `RunningAppsViewModel` | `list_apps`, activate/lifecycle |
| `SystemFocusTracker` | `focused_element` |
| `AccessibilityPermissions` | `permissions_status` / `request_permission` (driven host-side) |

**New code:** AX writes (`set_attribute`), parameterized-attribute reads, the CGEvent
verb set, clipboard, ScreenCaptureKit capture + Vision OCR, the `simctl` suite, the
change-journal/quiescence/diff layer, the XPC interface + relay, and the MCP server
(official `modelcontextprotocol/swift-sdk`).

---

## 12. Open decisions

1. **Control surface** — assumed **AX actions + synthetic CGEvent input** (the
   simulator and non-AX surfaces require it). Confirm.
2. **Quiescence defaults** — 400 ms idle / 3 s cap. Tune after first real runs.
3. **Screenshot inline vs. path default** — assumed **path default**, inline on request.
4. **Bundle/product names** — placeholders (`MacControlMCP`, `mac-control-host`,
   `mac-control-mcp`, `com.nuclearcyborg.maccontrol.host`).
5. **One `simctl` mega-tool vs. split** — assumed a single `sim` tool with an `action`
   discriminator; could split the high-value ones (openurl/push/appearance) into
   first-class tools.

### Resolved by the review pass
6. **XPC admission** — pin connections to our Team ID + relay/GUI designated requirements
   via `setConnectionCodeSigningRequirement:` (§2). No automatic same-app restriction
   exists for a launchd Mach service.
7. **Observation precision** — *static* coarse observers (root/windows/focused/bridge) +
   an active depth-limited **structural poll** during settle (§6). Two reviews conflicted
   here (one urged more observers, one warned they're costly and still blind to
   Electron/web); the poll-hybrid resolves both — it doesn't depend on apps posting AX
   notifications.
8. **Locator safety** — best-effort re-resolution that fails loud (`stale_ref` +
   candidates) rather than guessing (§4).
9. **Load-bearing assumptions to spike first** — TCC responsible-process attribution and
   the Screen-Recording relaunch behavior are version-fragile; both validated in P0a
   before being built on.

---

## 13. Suggested phasing

- **P0a — De-risk spikes (do first).** (1) Signed-helper **TCC attribution** test: relay
  launched from Terminal/Claude → launchd starts the host → host preflights AX +
  ScreenCaptureKit and confirms System Settings/TCC attributes the **host**, not the
  client. (2) **XPC admission**: confirm `setConnectionCodeSigningRequirement:` rejects an
  unsigned/mismatched caller. (3) **Observation coverage**: measure what root/window
  observers actually deliver on a native app, a sample **Electron app (VS Code/Slack)**,
  and **bridged-simulator nodes** — confirming the structural-poll fallback is needed.
  (4) **Screen-Recording relaunch**: probe whether a fresh grant works without re-exec.
  (5) **Relay reconnect**: host re-exec mid-call → relay transparently reconnects and retries.
- **P0b — Skeleton.** AXKit extraction; host helper **app** + Mach service + `SMAppService`
  registration + connection code-signing requirement; stdio relay; MCP `initialize`;
  `permissions_status`/`request_permission`; `list_apps`/`list_simulators`.
- **P1 — Read.** `ui_snapshot` (compact outline + refs), `find_elements`,
  `element_detail`, `element_at`, `focused_element`. Handle/locator table.
- **P2 — Screenshots.** ScreenCaptureKit (`screen`/`window`/`app`/`element`) + `simctl`
  (`simulator`); downscale; path/inline.
- **P3 — Act.** `perform`, `set_attribute`/`set_value`/`set_focus`, `open_menu`,
  `window`; CGEvent `click`/`scroll`/`drag`/`hover`/`type_text`/`key`; clipboard.
- **P4 — Observe.** Change journal + quiescence + diff; `observe:"settle"` on actions;
  `wait_for`/`get_changes`; resource subscriptions.
- **P5 — Simulator & polish.** `sim` suite; Vision OCR; GUI live-activity over XPC.
