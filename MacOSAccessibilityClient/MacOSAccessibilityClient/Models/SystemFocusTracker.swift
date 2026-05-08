//
//  SystemFocusTracker.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import ApplicationServices
import Foundation
import Observation
import os

/// Tracks which UI element holds keyboard focus across all apps, by subscribing to
/// `kAXFocusedUIElementChangedNotification` on whichever app is currently frontmost
/// and re-attaching when the frontmost app changes. The focused element itself is
/// always read from the system-wide AX root, which gives us cross-app focus without
/// having to maintain N observers.
///
/// Notification-driven (not polled): `AXObserver` is keyed by PID, so we can't observe
/// the system-wide element directly, but a single observer on the frontmost process
/// catches every intra-app focus change, and `NSWorkspace.didActivateApplicationNotification`
/// catches the cross-app transitions.
@MainActor
@Observable
final class SystemFocusTracker {
    private static let historyLimit = 200

    /// One row in the focus history. Each unique focus transition gets one entry,
    /// most recent first.
    struct FocusEvent: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let element: AXElement
        let summary: String
        let role: String?
        let pid: pid_t?
    }

    private(set) var focusedElement: AXElement?
    private(set) var ancestors: [AXElement] = []
    private(set) var history: [FocusEvent] = []
    private(set) var isRunning: Bool = false

    private let systemWide: AXElement
    private var activeAppPid: pid_t?
    private var activeObserver: AXObserverWrapper?
    private var attachTask: Task<Void, Never>?
    /// At most one in-flight `sample()` task. Coalescing the firehose of focus-changed
    /// notifications stops us allocating a Task per event.
    private var sampleTask: Task<Void, Never>?
    /// Set when a focus notification arrives during an in-flight sample. The
    /// in-flight sample reads "currently focused" at its start, so a focus change
    /// that happens *after* that read but *before* the sample finishes would
    /// otherwise be lost. After the sample completes we re-run if this is set.
    private var samplePending: Bool = false
    /// Serial chain of observer-teardown tasks. Rapid app-switching used to
    /// fire-and-forget unbounded teardown tasks; chaining keeps them ordered and
    /// awaitable from `stop()`.
    private var teardownChain: Task<Void, Never> = Task {}
    /// `@ObservationIgnored` + `nonisolated(unsafe)` so `deinit` can read it to
    /// unregister the workspace tokens. Mutated only on the main actor.
    @ObservationIgnored
    private nonisolated(unsafe) var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let element = AXElement.systemWide()
        element.setMessagingTimeout(0.5)
        self.systemWide = element
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attachWorkspaceObservers()
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(to: app.processIdentifier)
        }
        coalesceSample()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        detachWorkspaceObservers()
        detach()
        sampleTask?.cancel()
        sampleTask = nil
        samplePending = false
        focusedElement = nil
        ancestors = []
    }

    func clearHistory() {
        history.removeAll()
    }

    private func attachWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let token = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let app = NSWorkspace.shared.frontmostApplication {
                    self.handleActivation(pid: app.processIdentifier)
                }
            }
        }
        workspaceObservers.append(token)
    }

    private func detachWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { nc.removeObserver(token) }
        workspaceObservers.removeAll()
    }

    private func handleActivation(pid: pid_t) {
        if pid == activeAppPid { return }
        detach()
        attach(to: pid)
        // Sample after re-attach so we catch the cross-app focus transition; the
        // new app's focused element won't generate its own change notification just
        // by virtue of becoming frontmost.
        coalesceSample()
    }

    private func attach(to pid: pid_t) {
        attachTask?.cancel()
        attachTask = Task { @MainActor [weak self] in
            do {
                let wrapper = try await AXObserverWrapper.make(pid: pid) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.coalesceSample()
                    }
                }
                guard !Task.isCancelled else {
                    await wrapper.tearDown()
                    return
                }
                let appElement = AXElement.application(pid: pid)
                appElement.setMessagingTimeout(2.0)
                try await wrapper.subscribe(to: appElement, notification: kAXFocusedUIElementChangedNotification)
                guard let self, !Task.isCancelled else {
                    await wrapper.tearDown()
                    return
                }
                self.activeObserver = wrapper
                self.activeAppPid = pid
            } catch {
                // Some processes refuse AX observation (private apps, not-yet-trusted
                // helpers, Carbon-only). Silently skip — we'll get the next activation.
            }
        }
    }

    private func detach() {
        attachTask?.cancel()
        attachTask = nil
        if let observer = activeObserver {
            // Chain teardowns instead of fire-and-forgetting — rapid detach/attach
            // would otherwise queue unbounded unawaited tasks.
            let prior = teardownChain
            teardownChain = Task {
                await prior.value
                await observer.tearDown()
            }
        }
        activeObserver = nil
        activeAppPid = nil
    }

    /// Spawn a sample if none is in flight; otherwise mark a trailing-edge re-run
    /// so the latest focus state is still picked up after the current sample
    /// completes. Without the trailing flag, a focus change that arrives after
    /// `sample()` has read its initial state would be silently dropped.
    private func coalesceSample() {
        guard sampleTask == nil else {
            samplePending = true
            return
        }
        runSample()
    }

    private func runSample() {
        sampleTask = Task { @MainActor [weak self] in
            await self?.sample()
            guard let self else { return }
            self.sampleTask = nil
            if self.samplePending {
                self.samplePending = false
                self.runSample()
            }
        }
    }

    private func sample() async {
        let fetched: AXElement?
        do {
            fetched = try await systemWide.attributeElement(kAXFocusedUIElementAttribute)
        } catch {
            AppLog.ax.debug("kAXFocusedUIElement read failed: \(error.localizedDescription, privacy: .public)")
            fetched = nil
        }
        guard let element = fetched else {
            if focusedElement != nil {
                focusedElement = nil
                ancestors = []
            }
            return
        }
        // Dedupe: assigning an equal @Observable property still fires observation,
        // and a no-op refresh would force the inspector pane to rebuild its
        // ElementSnapshot for free.
        if let existing = focusedElement, existing == element {
            return
        }
        // Fetch chain + label + role in one AX-queue hop, then update state.
        async let fetchedChain = element.ancestorChain()
        async let fetchedSummary = ElementLabel.short(for: element)
        async let fetchedRole = element.role()
        let (chain, summary, role) = await (fetchedChain, fetchedSummary, fetchedRole)

        focusedElement = element
        ancestors = chain
        let event = FocusEvent(
            timestamp: .now,
            element: element,
            summary: summary,
            role: role,
            pid: element.pid
        )
        history.insert(event, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    deinit {
        // workspace tokens were registered against `.main` queue from the same
        // notification center we read here; safe to remove from a nonisolated deinit.
        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            nc.removeObserver(token)
        }
    }
}
