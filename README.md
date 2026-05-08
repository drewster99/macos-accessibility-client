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
- **Unified timeline.** A single bottom-pane log interleaves three
  sources by timestamp — the inspected app's `AXObserver` notifications
  (via `AXObserverCreateWithInfoCallback`, including the system-supplied
  user-info dictionary), system-wide clicks, and system-wide focus
  changes. Each row is rendered in its source column so the activity
  flow is legible at a glance; click any row to reveal that element in
  the tree, auto-switching the sidebar to the owning app if needed.
- **System-wide focus tracker.** Notification-driven, not polled. A
  single `AXObserver` rides the frontmost app's
  `kAXFocusedUIElementChangedNotification`, and
  `NSWorkspace.didActivateApplicationNotification` re-anchors the
  observer on app switches. The focused element is read from the
  system-wide AX root, so cross-app focus is captured without needing
  one observer per process.
- **Global click capture.** `NSEvent.addGlobalMonitorForEvents` sees
  left/right mouse-downs in *other* apps; for each click, the AX
  element under the cursor is resolved via
  `AXUIElementCopyElementAtPosition` so the unified log can show
  what was clicked, not just where.

## Getting started

Open `MacOSAccessibilityClient/MacOSAccessibilityClient.xcodeproj` in
Xcode 16+ and run. macOS 15 or later.

The target is **non-sandboxed** so it can inspect and drive other apps via Accessibility APIs. Release builds are signed with the hardened runtime enabled for Developer ID notarization.

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
│   ├── AXRunner.swift                    GCD bridge so blocking AX XPC stays
│   │                                     off the main actor and cooperative pool
│   ├── ElementSnapshot.swift             frozen view of an element for the inspector
│   ├── Formatting.swift                  shared CGRect / element-label formatters
│   ├── Logging.swift                     centralised os.Logger subsystems + timing helper
│   └── Theme.swift                       role / notification family colours + symbols
├── Models/
│   ├── AppInspectionSession.swift        per-app: root + observer + capped event log
│   ├── AppSettings.swift                 @Observable, persisted via UserDefaults
│   ├── ClickTracker.swift                global mouse-down monitor + AX hit-test
│   ├── MenuChainWalker.swift             AXPress-replay through a menu chain
│   ├── RunningAppsViewModel.swift        live NSWorkspace running-apps list
│   ├── SystemFocusTracker.swift          notification-driven focus tracker
│   ├── TreeExpansionState.swift          per-session expanded set + reveal/refresh
│   └── UnifiedLogEvent.swift             enum merging app/click/focus events for the timeline
├── Permissions/
│   └── AccessibilityPermissions.swift    AXIsProcessTrusted + System Settings deeplink
└── Views/
    ├── ContentView.swift                 sidebar + center + inspector + unified log
    ├── ElementInspectorView.swift        right pane — attrs/actions/errors/results
    ├── ElementTreeView.swift             middle pane — recursive AX tree
    ├── PermissionsBanner.swift           orange banner when AX trust is missing
    └── UnifiedLogView.swift              bottom pane — interleaved app/click/focus log
```

## Release automation

This repo includes `release.sh`, a one-command macOS release builder/publisher.

```bash
./release.sh              # bump patch/build, sign, notarize, staple, DMG, publish GitHub release
./release.sh --dry-run    # local build + DMG visual test only; no signing/notarization/git/GitHub
./release.sh --notarize-dry-run --notary-profile macos-accessibility-client
./release.sh --version 1.1.0
```

The script automatically increments `MARKETING_VERSION` patch numbers (`1.0.0` → `1.0.1`) and increments `CURRENT_PROJECT_VERSION` each release. Use `--version X.Y.Z` when you want to manually move to a new minor or major version; the build number still increments.

Release output is written under `build/release/`. The DMG uses the standard macOS drag-to-Applications layout with an Applications symlink and visual arrow guidance. The generated background includes a high-contrast glass tile behind the Applications symlink and an arrowhead aligned to the Bezier curve's endpoint tangent so the installer remains legible on the dark theme.

### Signing and notarization prerequisites

Published releases are fully automated end-to-end and require Developer ID signing plus Apple notarization credentials before running `./release.sh`:

1. Install a valid **Developer ID Application** certificate in the login keychain. The script auto-detects the identity when exactly one is available, or you can pass it explicitly:

   ```bash
   ./release.sh --signing-identity "Developer ID Application: Nuclear Cyborg Corp (P8MA38JTXY)"
   # or
   SIGNING_IDENTITY="Developer ID Application: Nuclear Cyborg Corp (P8MA38JTXY)" ./release.sh
   ```

2. Configure `xcrun notarytool` credentials. The recommended approach is a keychain profile, which keeps credentials out of shell history:

   ```bash
   xcrun notarytool store-credentials macos-accessibility-client \
     --apple-id "you@example.com" \
     --team-id "TEAMID" \
     --password "app-specific-password"

   NOTARY_PROFILE=macos-accessibility-client ./release.sh
   # or
   ./release.sh --notary-profile macos-accessibility-client
   ```

   The script also supports App Store Connect API key environment variables:
   `NOTARY_KEY`, `NOTARY_KEY_ID`, and optional `NOTARY_ISSUER`; or Apple ID variables:
   `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, and `NOTARY_TEAM_ID`.

3. For a normal publish, run `./release.sh` (optionally with `--yes`). The default published workflow is:
   - build the Release `.app` with Xcode,
   - sign the `.app` with `codesign --options runtime --timestamp`,
   - create a temporary ZIP of the `.app` with `ditto --keepParent` for Apple notarization upload,
   - submit with `xcrun notarytool submit --wait` and fail with the notary log if Apple rejects it,
   - staple and validate the `.app`,
   - build the drag-to-Applications DMG from the stapled app,
   - sign the DMG,
   - notarize the DMG directly,
   - staple and validate the DMG,
   - publish the signed/notarized/stapled DMG to GitHub and verify the asset.

Apple's stapler supports UDIF disk images, code-signed executable bundles, and signed flat installer packages, so the release asset stays a DMG; the ZIP is only a temporary upload wrapper for app notarization.

Use `--dry-run` for quick local build/DMG visual checks without Apple credentials. Use `--notarize-dry-run` when you want to test the full signing/notarization/stapling path without committing, tagging, pushing, or creating a GitHub release.

Note on build numbers: perpetually increasing `CFBundleVersion` is required for App Store uploads and is a safe convention for direct GitHub distribution, so the script increments it on every release.

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
