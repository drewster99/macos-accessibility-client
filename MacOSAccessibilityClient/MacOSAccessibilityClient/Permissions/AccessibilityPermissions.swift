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

    /// Monotonically increases for each explicit trust check. Async work captures
    /// the generation it belongs to and discards stale results so an older `false`
    /// cannot overwrite a newer permission grant.
    @ObservationIgnored
    private var trustCheckGeneration = 0

    /// Polling task started after showing the system prompt. TCC does not reliably
    /// notify this process when the first prompt is granted, and
    /// `AXIsProcessTrustedWithOptions(prompt: true)` returns the *current* value
    /// immediately rather than waiting for the user to respond.
    @ObservationIgnored
    private var promptFollowUpTask: Task<Void, Never>?

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
        recheck()

        // TCC posts this distributed notification when accessibility trust changes,
        // including when the user flips the toggle in System Settings. It's the
        // de-facto signal — undocumented but stable for many releases.
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        })

        // Belt-and-suspenders for the case where the distributed notification is missed
        // (sandbox, missed wake, etc.) — re-evaluate whenever the user tabs back to us.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        })
    }

    /// Re-evaluates without prompting. Performs the `tccd` round-trip off the main
    /// actor so a slow daemon can't freeze the UI.
    func recheck() {
        scheduleRefresh()
    }

    /// Triggers the system Accessibility permission alert if we haven't been granted.
    /// macOS only shows the prompt once per signature; subsequent calls do nothing.
    /// `AXIsProcessTrustedWithOptions(prompt: true)` returns immediately with the
    /// current trust value; it does not wait for the user to grant permission in the
    /// prompt. Start a short follow-up poll so the banner disappears as soon as TCC
    /// records the first grant, even if no distributed notification is delivered.
    func requestAndPrompt() {
        let generation = nextTrustCheckGeneration()
        promptFollowUpTask?.cancel()

        Task { @MainActor in
            let trusted = await checkTrust(prompt: true)
            let applied = applyTrustResult(trusted, generation: generation)

            if !trusted && applied {
                startPromptFollowUpPolling(after: generation)
            }
        }
    }

    /// Opens the System Settings pane the user needs to flip the switch in.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleRefresh() {
        let generation = nextTrustCheckGeneration()
        Task { @MainActor in
            let trusted = await checkTrust(prompt: false)
            applyTrustResult(trusted, generation: generation)
        }
    }

    private func nextTrustCheckGeneration() -> Int {
        trustCheckGeneration += 1
        return trustCheckGeneration
    }

    @discardableResult
    private func applyTrustResult(_ trusted: Bool, generation: Int) -> Bool {
        // Never let an older `false` result overwrite a newer check, but do accept
        // `true` from any completed check. Trust can be granted while an earlier
        // prompt/check is still in flight, and the UI should disappear as soon as
        // any fresh TCC read observes the grant.
        guard trusted || generation == trustCheckGeneration else { return false }
        isTrusted = trusted
        if trusted {
            promptFollowUpTask?.cancel()
            promptFollowUpTask = nil
        }
        return true
    }

    private func startPromptFollowUpPolling(after promptGeneration: Int) {
        promptFollowUpTask = Task { @MainActor in
            for attempt in 1...20 {
                if Task.isCancelled { return }

                do {
                    try await Task.sleep(for: .milliseconds(250 * attempt))
                } catch {
                    return
                }

                if Task.isCancelled { return }
                let generation = nextTrustCheckGeneration()
                guard generation > promptGeneration else { return }

                let trusted = await checkTrust(prompt: false)
                guard applyTrustResult(trusted, generation: generation) else { continue }
                if trusted { return }
            }
        }
    }

    private func checkTrust(prompt: Bool) async -> Bool {
        let key = Self.trustedCheckOptionPrompt
        return await AXRunner.run {
            if prompt {
                let opts = [key: true] as CFDictionary
                return AXIsProcessTrustedWithOptions(opts)
            } else {
                return AXIsProcessTrusted()
            }
        }
    }

    deinit {
        promptFollowUpTask?.cancel()

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
