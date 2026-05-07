![macos-accessibility-client banner](macos_accessibility_client-banner.jpg)

# macos-accessibility-client

A small SwiftUI macOS app for exploring Apple's Accessibility (`AX*`) APIs:
inspect another app's UI element tree, watch its `AXObserver` event stream
live, follow the system-wide focused element, and drive actions on the
target via `AXUIElementPerformAction` — including a "menu chain walker"
that opens deeply-nested submenus by replaying `AXPress` on each ancestor.

Built as a hands-on reference for what's possible with the C-level
Accessibility APIs from Swift 6 — small enough to read end-to-end and
useful enough to keep on the shelf next to Apple's Accessibility Inspector.

## Features

- **Tree browser.** Live list of running GUI apps; pick one and walk its
  `AXUIElement` hierarchy. Lazy children, `AXApplication + 1 level`
  expanded by default, Option-click to expand a whole subtree.
- **Element inspector.** Every attribute, action, and parameterized
  attribute the target exposes, in a two-column key/value grid. Per-call
  `AXError`s surface in a dedicated "Read errors" section instead of
  silently rendering as empty.
- **Action invocation.** Each action gets a Perform button that calls
  `AXUIElementPerformAction`; result chip shows success or the underlying
  `AXError`.
- **Menu chain walker.** When you Perform `AXPress` on an `AXMenuItem` /
  `AXMenuBarItem`, the app activates the target and replays `AXPress` on
  every menu ancestor in root-first order so the submenu opens — clicking
  in our app would otherwise cancel the target's menu tracking. Toggle in
  **View → Walk menu chain on AXPress**; per-press / refresh delays in
  **Settings**.
- **Live event log.** `AXObserver` notifications for the inspected app
  using the `AXObserverCreateWithInfoCallback` variant — surfaces the
  system's user-info dictionary in addition to the notification name and
  element. Click any element link in the log to reveal it in the tree.
- **System-wide focused tracker.** Polls `kAXFocusedUIElementAttribute`
  on the system-wide element at 4 Hz; cross-app focus follows naturally.

## Getting started

Open `MacOSAccessibilityClient/MacOSAccessibilityClient.xcodeproj` in
Xcode 16+ and run. macOS 15 or later.

The target is **non-sandboxed** with **hardened runtime off** — both
mandatory for an Accessibility-API client that drives other apps.

On first launch the app calls `AXIsProcessTrustedWithOptions(prompt:
true)`, which shows the macOS permission alert. If you miss it, use the
in-app banner's "Open System Settings" button — it deep-links to **Privacy
& Security → Accessibility** — flip the switch, then click **Recheck**.
The grant is keyed to bundle ID + signature; a clean rebuild that re-signs
may require regranting.

## Code map

```
MacOSAccessibilityClient/
├── MacOSAccessibilityClientApp.swift     @main + Settings + View menu
├── Core/
│   ├── AXElement.swift                   value-type wrapper around AXUIElement
│   ├── AXError+ext.swift                 AXError → LocalizedError mapping
│   ├── AXObserverWrapper.swift           AXObserver lifecycle + with-info callback
│   ├── ElementSnapshot.swift             frozen view of an element for the inspector
│   └── Formatting.swift                  shared CGRect / element-label formatters
├── Models/
│   ├── AppInspectionSession.swift        per-app: root + observer + capped event log
│   ├── AppSettings.swift                 @Observable, persisted via UserDefaults
│   ├── MenuChainWalker.swift             AXPress-replay through a menu chain
│   ├── RunningAppsViewModel.swift        live NSWorkspace running-apps list
│   ├── SystemFocusTracker.swift          4 Hz system-wide focus poller
│   └── TreeExpansionState.swift          per-session expanded set + reveal/refresh
├── Permissions/
│   └── AccessibilityPermissions.swift    AXIsProcessTrusted + System Settings deeplink
└── Views/
    ├── ContentView.swift                 sidebar + center + inspector + event log
    ├── ElementInspectorView.swift        right pane — attrs/actions/errors/results
    ├── ElementTreeView.swift             middle pane — recursive AX tree
    ├── EventLogView.swift                bottom pane — observer events + user info
    ├── PermissionsBanner.swift           orange banner when AX trust is missing
    └── SystemFocusView.swift             middle pane — system-wide focus mode
```

## Notes on the API

- **Subscribe/unsubscribe is the only filter.** Notification subscriptions
  are keyed by `(observer, element, notification)` — there's no
  payload-side filter. Scope by which element you attach to (subtree) and
  which notification names you ask for; everything else is client-side.
- **`AXPress` returns success/failure, not "did the side-effect happen".**
  We surface the `AXError` in the inspector's result chip; whether the
  target actually opened a menu (or did anything else) is observed via
  `AXObserver` notifications or by re-reading state. The walker uses a
  configurable post-press delay then a `requestRefresh` on the leaf.
- **Pointer identity is not stable.** `AXUIElementCopyAttributeValue`
  may return new CF references that compare equal via `CFEqual` but live
  at different addresses. `AXElement: Hashable` uses `CFHash`/`CFEqual`,
  so sets and dictionaries keyed by `AXElement` work correctly across
  refetches; raw-pointer keys do not.

## License

See [LICENSE.md](LICENSE.md).

Copyright © 2026 Nuclear Cyborg Corp.
Written by Andrew Benson
db@nuclearcyborg.com
Twitter [@TheDrewBenson](https://x.com/TheDrewBenson)
Github [https://github.com/drewster99](https://github.com/drewster99)
