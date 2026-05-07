//
//  AXObserverWrapper.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import Foundation

/// Owns an `AXObserver` for a single target process and bridges its C callback into
/// a Swift `EventHandler`. Removes its run-loop source and all subscriptions on `deinit`,
/// so a notification scheduled mid-tear-down can't dereference a dead wrapper.
///
/// Uses the *with-info* callback variant so we get the system-provided user-info
/// dictionary when the target app populates one.
nonisolated final class AXObserverWrapper: @unchecked Sendable {
    /// One key/value entry from the system's user-info dictionary, stringified.
    struct UserInfoEntry: Sendable, Identifiable {
        var id: String { key }
        let key: String
        let value: String
    }

    /// One observed event, with everything it took to render in the UI.
    struct Event: Sendable, Identifiable {
        let id: UUID = UUID()
        let timestamp: Date
        let notification: String
        let pid: pid_t
        let element: AXElement
        let elementSummary: String
        let userInfo: [UserInfoEntry]
    }

    typealias EventHandler = @MainActor @Sendable (Event) -> Void

    /// Standard set of notifications worth subscribing on an app's root element. Some
    /// (e.g. window-resized) only fire once individual windows are subscribed too;
    /// for the inspector, the app-root subscription captures the bulk of activity.
    static let standardNotifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXValueChangedNotification,
        kAXSelectedTextChangedNotification,
        kAXTitleChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification,
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
        kAXMenuItemSelectedNotification,
        kAXCreatedNotification
    ]

    private let observer: AXObserver
    private let pid: pid_t
    private var subscriptions: [(rawElement: AXUIElement, notification: String)] = []
    private let onEvent: EventHandler

    init(pid: pid_t, onEvent: @escaping EventHandler) throws {
        self.pid = pid
        self.onEvent = onEvent

        var observer: AXObserver?
        try axCheck(
            AXObserverCreateWithInfoCallback(pid, Self.cCallback, &observer),
            "AXObserverCreateWithInfoCallback(pid: \(pid))"
        )
        guard let observer else {
            throw AXErrorWrapper(.failure, context: "AXObserverCreateWithInfoCallback returned nil")
        }
        self.observer = observer

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    deinit {
        for sub in subscriptions {
            AXObserverRemoveNotification(observer, sub.rawElement, sub.notification as CFString)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    /// Subscribe a single notification on a specific element. `.notificationAlreadyRegistered`
    /// is treated as success (idempotent).
    func subscribe(to element: AXElement, notification: String) throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, element.raw, notification as CFString, context)
        if err == .notificationAlreadyRegistered { return }
        try axCheck(err, "subscribe(\(notification))")
        subscriptions.append((element.raw, notification))
    }

    /// Subscribe the full standard set on the given app element. Failures are silently
    /// dropped per-notification (some apps don't support all notifications, and that's not
    /// an error worth surfacing to the user).
    func subscribeStandardSet(on appElement: AXElement) {
        for notification in Self.standardNotifications {
            try? subscribe(to: appElement, notification: notification)
        }
    }

    private static let cCallback: AXObserverCallbackWithInfo = { _, element, notification, info, refcon in
        guard let refcon else { return }
        let wrapper = Unmanaged<AXObserverWrapper>.fromOpaque(refcon).takeUnretainedValue()
        let elem = AXElement(element)
        let notif = notification as String
        let entries = AXObserverWrapper.flatten(info)
        // Run-loop source is on the main run loop, so we are on the main thread.
        MainActor.assumeIsolated {
            wrapper.handle(element: elem, notification: notif, userInfo: entries)
        }
    }

    /// Flatten a CFDictionary user-info payload into stable, Sendable rows. Values are
    /// stringified through `AXValueFormatter` so AXValue/AXUIElement embedded values
    /// render the same way they do in the inspector.
    private static func flatten(_ info: CFDictionary) -> [UserInfoEntry] {
        let dict = info as NSDictionary
        var entries: [UserInfoEntry] = []
        entries.reserveCapacity(dict.count)
        for (rawKey, rawValue) in dict {
            entries.append(UserInfoEntry(
                key: "\(rawKey)",
                value: AXValueFormatter.describe(rawValue as CFTypeRef)
            ))
        }
        return entries.sorted { $0.key < $1.key }
    }

    @MainActor
    private func handle(element: AXElement, notification: String, userInfo: [UserInfoEntry]) {
        onEvent(Event(
            timestamp: .now,
            notification: notification,
            pid: pid,
            element: element,
            elementSummary: ElementLabel.short(for: element),
            userInfo: userInfo
        ))
    }
}
