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
    private(set) var isTrusted: Bool

    init() {
        self.isTrusted = AXIsProcessTrusted()
    }

    /// Re-evaluates without prompting. Call after the user toggles the switch in
    /// System Settings and returns to the app.
    func recheck() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Triggers the system Accessibility permission alert if we haven't been granted.
    /// macOS only shows the prompt once per signature; subsequent calls do nothing
    /// other than refresh the trust status.
    ///
    /// We use the literal key `"AXTrustedCheckOptionPrompt"` instead of the framework
    /// constant `kAXTrustedCheckOptionPrompt` because the latter is a non-Sendable
    /// global `Unmanaged<CFString>` that triggers a Swift 6 strict-concurrency error.
    func requestAndPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the System Settings pane the user needs to flip the switch in.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
