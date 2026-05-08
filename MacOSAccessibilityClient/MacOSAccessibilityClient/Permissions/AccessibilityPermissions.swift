//
//  AccessibilityPermissions.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import ApplicationServices
import Observation

/// Tracks whether the running process has been granted Accessibility permission.
/// AX permission is grant-once, system-wide, scoped to bundle ID + signature; if the
/// signature changes (e.g. a clean dev build re-signs), the user has to re-grant.
@MainActor
@Observable
final class AccessibilityPermissions {
    /// The dictionary key for prompting the user — the literal string instead of
    /// `kAXTrustedCheckOptionPrompt`, which Swift 6 strict concurrency rejects as
    /// a non-Sendable `Unmanaged<CFString>` global.
    private static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

    private(set) var isTrusted: Bool = false

    /// `@ObservationIgnored` because nothing observes these tokens; combined with
    /// `nonisolated(unsafe)` so `deinit` can read them to unregister. Safe because
    /// the array is mutated only during `init` on the main actor and read only
    /// during deinit, when no other reference to `self` exists.
    @ObservationIgnored
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init() {
        // AXIsProcessTrusted() is a synchronous XPC round-trip to tccd. Under signature
        // mismatch / cache-revalidation conditions it can stall for seconds, so we never
        // want it on the main thread — including at launch.
        Task { await refresh() }

        // TCC posts this distributed notification when accessibility trust changes,
        // including when the user flips the toggle in System Settings. It's the
        // de-facto signal — undocumented but stable for many releases.
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })

        // Belt-and-suspenders for the case where the distributed notification is missed
        // (sandbox, missed wake, etc.) — re-evaluate whenever the user tabs back to us.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })
    }

    /// Re-evaluates without prompting. Performs the `tccd` round-trip on a detached
    /// task so a slow daemon can't freeze the UI.
    func recheck() {
        Task { await refresh() }
    }

    /// Triggers the system Accessibility permission alert if we haven't been granted.
    /// macOS only shows the prompt once per signature; subsequent calls do nothing
    /// other than refresh the trust status. See `trustedCheckOptionPrompt` for the
    /// Swift 6 reason behind the literal key.
    func requestAndPrompt() {
        Task {
            let key = Self.trustedCheckOptionPrompt
            let trusted = await Task.detached(priority: .userInitiated) {
                let opts = [key: true] as CFDictionary
                return AXIsProcessTrustedWithOptions(opts)
            }.value
            self.isTrusted = trusted
        }
    }

    /// Opens the System Settings pane the user needs to flip the switch in.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh() async {
        let trusted = await Task.detached(priority: .userInitiated) {
            AXIsProcessTrusted()
        }.value
        self.isTrusted = trusted
    }

    deinit {
        // Tokens come from two centers — a distributed one (TCC trust changes) and
        // a normal one (NSApplication.didBecomeActive). Hand them back to whichever
        // center vended them. The instance is `@MainActor` and so is `init`, so we
        // know we were registered on `.main` and can use the normal API safely.
        let dnc = DistributedNotificationCenter.default()
        let nc = NotificationCenter.default
        for token in observers {
            dnc.removeObserver(token)
            nc.removeObserver(token)
        }
    }
}
