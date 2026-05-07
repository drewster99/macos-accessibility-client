//
//  RunningAppsViewModel.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import ApplicationServices
import Observation

/// Tracks the set of regular (foreground) running applications and exposes them as
/// `Identifiable` rows so SwiftUI can render a live list. Filters out background
/// daemons (`.prohibited`, `.accessory`) since they don't have user-facing UI.
@MainActor
@Observable
final class RunningAppsViewModel {
    private(set) var apps: [RunningApp] = []

    private var notificationObservers: [NSObjectProtocol] = []
    private var policyObservations: [pid_t: NSKeyValueObservation] = [:]

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        let terminate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        notificationObservers = [launch, terminate]
        rebuild()
    }

    /// Builds an `AXElement` for the app and applies a 2.0s messaging timeout so a
    /// hung target can't lock up the inspector.
    func element(for app: RunningApp) -> AXElement {
        let element = AXElement.application(pid: app.pid)
        element.setMessagingTimeout(2.0)
        return element
    }

    private func rebuild() {
        let running = NSWorkspace.shared.runningApplications
        syncPolicyObservations(for: running)
        apps = running
            .filter { $0.activationPolicy == .regular }
            .compactMap { RunningApp($0) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Watch every running app's `activationPolicy` so an app that promotes from
    /// `.accessory`/`.prohibited` to `.regular` (or vice versa) triggers a rebuild —
    /// launch/terminate notifications alone miss those mid-life transitions.
    private func syncPolicyObservations(for running: [NSRunningApplication]) {
        let currentPids = Set(running.map(\.processIdentifier))
        policyObservations = policyObservations.filter { currentPids.contains($0.key) }
        for app in running where policyObservations[app.processIdentifier] == nil {
            policyObservations[app.processIdentifier] = app.observe(\.activationPolicy, options: []) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.rebuild() }
            }
        }
    }
}

struct RunningApp: Identifiable, Hashable, Sendable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?

    var pid: pid_t { id }

    init?(_ app: NSRunningApplication) {
        guard let name = app.localizedName else { return nil }
        self.id = app.processIdentifier
        self.name = name
        self.bundleIdentifier = app.bundleIdentifier
    }
}
