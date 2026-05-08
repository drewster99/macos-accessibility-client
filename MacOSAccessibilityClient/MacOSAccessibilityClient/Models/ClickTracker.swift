//
//  ClickTracker.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import ApplicationServices
import Foundation
import Observation

/// Records every left/right mouse-down anywhere on the screen and resolves the
/// AX element under the cursor at the moment of the click. iOS doesn't post AX
/// events for plain taps, so for "what did the user just click on?" inside the
/// simulator (or any other app), the only path is the OS-level mouse event +
/// `AXUIElementCopyElementAtPosition`.
///
/// Uses `NSEvent.addGlobalMonitorForEvents`, which sees clicks in *other* apps
/// (not our own). Requires the Accessibility permission this app already holds.
@MainActor
@Observable
final class ClickTracker {
    private static let historyLimit = 200

    /// One captured click. `element` may be nil if the AX hit-test failed (e.g. the
    /// click landed on a non-AX-aware surface or the target refused the query).
    struct ClickEvent: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let location: CGPoint
        let isRightClick: Bool
        let element: AXElement?
        let summary: String
        let role: String?
        let pid: pid_t?
    }

    private(set) var history: [ClickEvent] = []
    private(set) var isRunning: Bool = false

    private let systemWide: AXElement
    /// `@ObservationIgnored` + `nonisolated(unsafe)` so `deinit` can read it to
    /// remove the global event monitor even if `stop()` was never called. Only
    /// mutated on the main actor.
    @ObservationIgnored
    private nonisolated(unsafe) var monitor: Any?

    init() {
        let element = AXElement.systemWide()
        element.setMessagingTimeout(0.5)
        self.systemWide = element
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func clearHistory() {
        history.removeAll()
    }

    private func handle(_ event: NSEvent) {
        // `NSEvent.mouseLocation` is in the AppKit screen coordinate space (origin
        // bottom-left of the primary display); AX wants top-left of that same display.
        // The "primary" display is the one anchored at (0, 0); we fall back to the
        // first NSScreen if no zero-origin screen is found, which would be unusual.
        let nsLocation = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        guard let primary else { return }
        let axPoint = CGPoint(x: nsLocation.x, y: primary.frame.height - nsLocation.y)
        let timestamp = Date.now
        let isRightClick = event.type == .rightMouseDown
        // Capture the AXElement wrapper (which is `@unchecked Sendable`) rather than
        // its raw `AXUIElement`, which Swift 6 strict mode won't treat as Sendable.
        let systemWide = self.systemWide

        Task { @MainActor in
            // Hit-test the AX tree at the click position on the AX queue, then fetch
            // role + label there too so we don't bounce back and forth.
            struct Resolution: Sendable {
                let element: AXElement?
                let summary: String
                let role: String?
            }
            let resolution: Resolution = await AXRunner.run {
                var raw: AXUIElement?
                let err = AXUIElementCopyElementAtPosition(
                    systemWide.raw,
                    Float(axPoint.x),
                    Float(axPoint.y),
                    &raw
                )
                guard err == .success, let element = raw.map(AXElement.init) else {
                    return Resolution(element: nil, summary: "(no element)", role: nil)
                }
                let role = element.syncRole()
                let title = element.syncTitle()?.nonEmptyOrNil
                let summary: String
                if let title { summary = "<\(role ?? "<unidentified>") \"\(title)\">" }
                else { summary = "<\(role ?? "<unidentified>")>" }
                return Resolution(element: element, summary: summary, role: role)
            }

            let click = ClickEvent(
                timestamp: timestamp,
                location: axPoint,
                isRightClick: isRightClick,
                element: resolution.element,
                summary: resolution.summary,
                role: resolution.role,
                pid: resolution.element?.pid
            )
            self.history.insert(click, at: 0)
            if self.history.count > Self.historyLimit {
                self.history.removeLast(self.history.count - Self.historyLimit)
            }
        }
    }

    deinit {
        // Belt-and-suspenders for cases where `stop()` wasn't called before the
        // tracker is dropped — leaving the monitor live would cost us callbacks
        // on a dead object (the closure captures `[weak self]`, but the monitor
        // itself stays in AppKit's table until removed).
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
