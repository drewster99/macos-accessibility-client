//
//  UnifiedLogEvent.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import Foundation

/// One row in the unified log timeline. Carries an entry from any of the three
/// log sources (per-app AX events, system-wide clicks, system-wide focus changes)
/// so the view can render them interleaved by timestamp.
enum UnifiedLogEvent: Identifiable, Sendable {
    case app(AXObserverWrapper.Event)
    case click(ClickTracker.ClickEvent)
    case focus(SystemFocusTracker.FocusEvent)

    var id: String {
        switch self {
        case .app(let event): return "app-\(event.id.uuidString)"
        case .click(let event): return "click-\(event.id.uuidString)"
        case .focus(let event): return "focus-\(event.id.uuidString)"
        }
    }

    var timestamp: Date {
        switch self {
        case .app(let event): return event.timestamp
        case .click(let event): return event.timestamp
        case .focus(let event): return event.timestamp
        }
    }

    /// The AX element this entry refers to, when one was successfully resolved.
    /// `nil` for clicks where `AXUIElementCopyElementAtPosition` failed.
    var element: AXElement? {
        switch self {
        case .app(let event): return event.element
        case .click(let event): return event.element
        case .focus(let event): return event.element
        }
    }

    /// PID of the process owning the element, when known. Used by the unified-log
    /// row click handler to switch the sidebar to the right app before revealing.
    var pid: pid_t? {
        switch self {
        case .app(let event): return event.pid
        case .click(let event): return event.pid
        case .focus(let event): return event.pid
        }
    }

    static func merged(
        appEvents: [AXObserverWrapper.Event],
        clickEvents: [ClickTracker.ClickEvent],
        focusEvents: [SystemFocusTracker.FocusEvent]
    ) -> [UnifiedLogEvent] {
        var entries: [UnifiedLogEvent] = []
        entries.reserveCapacity(appEvents.count + clickEvents.count + focusEvents.count)
        for event in appEvents { entries.append(.app(event)) }
        for event in clickEvents { entries.append(.click(event)) }
        for event in focusEvents { entries.append(.focus(event)) }
        // Reverse-chronological — newest at the top, matching the prior per-source views.
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
}
