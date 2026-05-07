//
//  SystemFocusTracker.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import Foundation
import Observation

/// Polls the system-wide `AXUIElement` at 2 Hz to surface whatever element currently
/// holds keyboard focus across all apps. Polling (rather than per-app `AXObserver`s)
/// keeps the cross-app reach simple — one source, no per-app subscriptions to manage.
///
/// 2 Hz is a deliberate compromise: each focus change forces the inspector pane to
/// rebuild its `ElementSnapshot` (synchronous, ~20–50 cross-process AX calls), and a
/// faster cadence saturated the main thread when the focused element had a large
/// `AXValue` text body to render in the attribute Grid.
@MainActor
@Observable
final class SystemFocusTracker {
    private static let pollInterval: TimeInterval = 0.5
    private static let historyLimit = 200

    /// One row in the focus history. Each unique focus transition gets one entry,
    /// most recent first.
    struct FocusEvent: Identifiable {
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
    private var timer: Timer?

    init() {
        let element = AXElement.systemWide()
        element.setMessagingTimeout(0.5)
        self.systemWide = element
    }

    func start() {
        guard timer == nil else { return }
        isRunning = true
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        focusedElement = nil
        ancestors = []
    }

    func clearHistory() {
        history.removeAll()
    }

    private func sample() {
        let focused: AXUIElement? = try? systemWide.attribute(kAXFocusedUIElementAttribute, as: AXUIElement.self)
        guard let focused else {
            if focusedElement != nil {
                focusedElement = nil
                ancestors = []
            }
            return
        }
        let element = AXElement(focused)
        // Dedupe: assigning an equal @Observable property still fires observation.
        // The most common shape of this is the same AXElement reported on every poll
        // when nothing has changed — without this guard the inspector would rebuild
        // its snapshot twice a second for free.
        if let existing = focusedElement, existing == element {
            return
        }
        focusedElement = element
        ancestors = element.ancestorChain()
        recordHistory(element)
    }

    private func recordHistory(_ element: AXElement) {
        let event = FocusEvent(
            timestamp: .now,
            element: element,
            summary: ElementLabel.short(for: element),
            role: element.role,
            pid: element.pid
        )
        history.insert(event, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }
}
