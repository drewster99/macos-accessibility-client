//
//  AXObserverWrapper.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

@preconcurrency import ApplicationServices
import Foundation
import os

/// Owns an `AXObserver` for a single target process and bridges its C callback into
/// a Swift `EventHandler`.
///
/// Every observer mutation (`AXObserverCreate`, `AXObserverAddNotification`,
/// `AXObserverRemoveNotification`) is an XPC round-trip to the AX hub. To keep our
/// process's main actor and cooperative pool free of blocking work, all of those
/// calls now run on `AXRunner`'s GCD queue, and the public API is async.
///
/// State (the subscription list and anchor-scope registry) lives behind an `NSLock`
/// because the AX queue is concurrent and multiple subscribe/teardown operations on
/// the same wrapper could otherwise race.
nonisolated final class AXObserverWrapper: @unchecked Sendable {
    /// One key/value entry from the system's user-info dictionary, stringified.
    struct UserInfoEntry: Sendable, Identifiable, Equatable {
        var id: String { key }
        let key: String
        let value: String
    }

    /// Tags an event with which subscription anchor produced it. Lets the UI tell
    /// "an event posted on the app root" apart from "an event posted on the iOS
    /// bridge node inside Simulator.app" — they often both fire for the same kind
    /// of notification but mean different things to the user.
    enum Scope: Sendable, Hashable {
        case appRoot
        case simulatorContent
    }

    /// One observed event, with everything it took to render in the UI. Equatable
    /// so SwiftUI `.onChange(of: events)` watchers can fire on each new event
    /// without paying for a body recomputation when nothing relevant changed.
    struct Event: Sendable, Identifiable, Equatable {
        let id: UUID = UUID()
        let timestamp: Date
        let notification: String
        let pid: pid_t
        let scope: Scope
        let element: AXElement
        let elementSummary: String
        let userInfo: [UserInfoEntry]
    }

    typealias EventHandler = @MainActor @Sendable (Event) -> Void

    /// Public AX notifications, exhaustive against `AXNotificationConstants.h`. Every
    /// `NSAccessibility.Notification` case and every iOS-bridged `UIAccessibility.post`
    /// flows through one of these.
    static let standardNotifications: [String] = [
        // Focus
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        // Value / state
        kAXValueChangedNotification,
        kAXSelectedTextChangedNotification,
        kAXTitleChangedNotification,
        kAXElementBusyChangedNotification,
        kAXUnitsChangedNotification,
        // Layout / geometry
        kAXLayoutChangedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
        // Windows / containers
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXSheetCreatedNotification,
        kAXDrawerCreatedNotification,
        // Tables / outlines / collections
        kAXSelectedChildrenChangedNotification,
        kAXSelectedChildrenMovedNotification,
        kAXSelectedRowsChangedNotification,
        kAXSelectedColumnsChangedNotification,
        kAXSelectedCellsChangedNotification,
        // kAXRowCountChangedNotification — disabled: noisy on row-heavy targets.
        kAXRowExpandedNotification,
        kAXRowCollapsedNotification,
        // Lifecycle
        kAXUIElementDestroyedNotification,
        kAXCreatedNotification,
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
        // Menus
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
        kAXMenuItemSelectedNotification,
        // Assistive tech
        kAXAnnouncementRequestedNotification,
        kAXHelpTagCreatedNotification
    ]

    private let observer: AXObserver
    private let pid: pid_t
    private let onEvent: EventHandler

    private let stateLock = NSLock()
    private var subscriptions: [(rawElement: AXUIElement, notification: String)] = []
    private var anchorScopes: [(rawElement: AXUIElement, scope: Scope)] = []
    private var isTornDown: Bool = false

    /// Serialises the per-event chain on the main actor. Each notification's `Task`
    /// awaits the prior one before formatting+posting, so events reach `onEvent` in
    /// arrival order even when the AX queue formats them out of order under load.
    @MainActor private var orderingChain: Task<Void, Never> = Task {}

    /// Async factory. The `AXObserverCreateWithInfoCallback` call is XPC; running it
    /// on the AX queue keeps the caller's actor free during what's typically <1ms but
    /// can stall under target stress. Run-loop source is added on the main run loop
    /// (which is thread-safe for `CFRunLoopAddSource`).
    static func make(pid: pid_t, onEvent: @escaping EventHandler) async throws -> AXObserverWrapper {
        try await AXRunner.run {
            try AXObserverWrapper(syncFor: pid, onEvent: onEvent)
        }
    }

    /// Synchronous constructor; only safe to call inside an `AXRunner.run` block or
    /// other already-off-cooperative context.
    private init(syncFor pid: pid_t, onEvent: @escaping EventHandler) throws {
        self.pid = pid
        self.onEvent = onEvent

        let createStart = CFAbsoluteTimeGetCurrent()
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
        let ms = (CFAbsoluteTimeGetCurrent() - createStart) * 1000
        AppLog.subscription.info("AXObserver created for pid \(pid, privacy: .public) — \(ms, format: .fixed(precision: 2), privacy: .public) ms")
    }

    deinit {
        // Owners *should* call `tearDown()` before letting the wrapper go so the
        // unsubscribe XPC happens off-cooperative-pool. If they didn't, we MUST do
        // it synchronously here — `AXObserverAddNotification` was given a raw
        // `Unmanaged.passUnretained(self)` context pointer; if we let `self`
        // deallocate while subscriptions are still registered, the next C callback
        // dereferences a dangling pointer (use-after-free). Sync is correctness-
        // critical here; the work is bounded (typically <100 ms total).
        stateLock.lock()
        let alreadyTornDown = isTornDown
        let subs = subscriptions
        isTornDown = true
        subscriptions.removeAll()
        stateLock.unlock()
        guard !alreadyTornDown else { return }
        let start = CFAbsoluteTimeGetCurrent()
        for sub in subs {
            AXObserverRemoveNotification(observer, sub.0, sub.1 as CFString)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        AppLog.subscription.info("AXObserver pid \(self.pid, privacy: .public) deinit-tearDown SYNC: unsubscribed \(subs.count, privacy: .public) — \(ms, format: .fixed(precision: 2), privacy: .public) ms")
    }

    /// Explicit async teardown. Prefer this over relying on `deinit` so the
    /// unsubscribe XPC stays off the cooperative pool. Idempotent — the second call
    /// is a no-op. If you skip this and let `deinit` run, cleanup happens
    /// synchronously there because the C callback context requires it (see deinit).
    func tearDown() async {
        let claim: (subs: [(AXUIElement, String)], shouldCleanUp: Bool) = withState {
            if isTornDown { return ([], false) }
            isTornDown = true
            let snapshot = subscriptions
            subscriptions.removeAll()
            return (snapshot, true)
        }
        guard claim.shouldCleanUp else { return }
        let observer = self.observer
        let pid = self.pid
        let count = claim.subs.count
        let start = CFAbsoluteTimeGetCurrent()
        await AXRunner.run {
            for sub in claim.subs {
                AXObserverRemoveNotification(observer, sub.0, sub.1 as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        AppLog.subscription.info("AXObserver pid \(pid, privacy: .public) torn down: unsubscribed \(count, privacy: .public) — \(ms, format: .fixed(precision: 2), privacy: .public) ms")
    }

    /// Subscribe a single notification on a specific element. `.notificationAlreadyRegistered`
    /// is treated as success (idempotent). XPC happens on `AXRunner`.
    func subscribe(to element: AXElement, notification: String) async throws {
        let raw = element.raw
        try await AXRunner.run { [self] in
            try self.syncSubscribe(raw: raw, notification: notification)
        }
    }

    /// Sync subscriber. Only safe inside `AXRunner.run` (or other off-cooperative)
    /// contexts. State mutation is locked because the AX queue is concurrent.
    ///
    /// We track every kernel-side registration, including ones that returned
    /// `.notificationAlreadyRegistered`, so `tearDown`/`deinit` always have
    /// everything to unsubscribe. Skipping that on a non-success-but-registered
    /// path was the bug: the kernel keeps a `passUnretained(self)` pointer in its
    /// callback record, and if we let `self` deallocate without removing it, the
    /// next callback dereferences a dangling refcon (use-after-free).
    private func syncSubscribe(raw: AXUIElement, notification: String) throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, raw, notification as CFString, context)
        switch err {
        case .success:
            withState {
                subscriptions.append((raw, notification))
            }
        case .notificationAlreadyRegistered:
            // The earlier registration was also ours (same observer, same refcon).
            // Idempotent — only track if we haven't already.
            withState {
                let alreadyTracked = subscriptions.contains { sub in
                    CFEqual(sub.rawElement, raw) && sub.notification == notification
                }
                if !alreadyTracked {
                    subscriptions.append((raw, notification))
                }
            }
        default:
            try axCheck(err, "subscribe(\(notification))")
        }
    }

    /// Subscribe the full standard set on `element`, tagged with `scope`. The whole
    /// loop runs in one `AXRunner` hop so we don't pay a hop per notification name.
    /// Per-notification failures are tolerated (a target may not support some), but
    /// they're counted and logged in aggregate so a "20/35 silent failures" regression
    /// shows up in Console.app instead of looking healthy.
    func subscribeStandardSet(on element: AXElement, scope: Scope = .appRoot) async {
        let raw = element.raw
        let total = Self.standardNotifications.count
        let label = "subscribeStandardSet [pid \(pid), \(scope)] (\(total) notifs)"
        let start = CFAbsoluteTimeGetCurrent()
        let succeeded: Int = await AXRunner.run { [self] in
            self.withState {
                self.anchorScopes.append((raw, scope))
            }
            var ok = 0
            for notification in Self.standardNotifications {
                do {
                    try self.syncSubscribe(raw: raw, notification: notification)
                    ok += 1
                } catch {
                    AppLog.subscription.debug("subscribe(\(notification, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return ok
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        AppLog.subscription.info("\(label, privacy: .public) — \(ms, format: .fixed(precision: 2), privacy: .public) ms · \(succeeded, privacy: .public)/\(total, privacy: .public) ok")
        if succeeded < total {
            AppLog.subscription.error("\(label, privacy: .public) — \(total - succeeded, privacy: .public) of \(total, privacy: .public) failed")
        }
    }

    private static let cCallback: AXObserverCallbackWithInfo = { _, element, notification, info, refcon in
        guard let refcon else { return }
        let wrapper = Unmanaged<AXObserverWrapper>.fromOpaque(refcon).takeUnretainedValue()
        let elem = AXElement(element)
        let notif = notification as String
        let entries = AXObserverWrapper.flatten(info)
        // Run-loop source is on the main run loop, so we are on the main thread.
        // Crash early and clearly if a future refactor ever moves the source.
        dispatchPrecondition(condition: .onQueue(.main))
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

    /// AX notifications fire on the exact element they were registered on, so the
    /// callback's element identifies which anchor produced the event.
    private func scope(for raw: AXUIElement) -> Scope {
        withState {
            for anchor in anchorScopes where CFEqual(anchor.rawElement, raw) {
                return anchor.scope
            }
            return .appRoot
        }
    }

    @MainActor
    private func handle(element: AXElement, notification: String, userInfo: [UserInfoEntry]) {
        let timestamp = Date.now
        let eventScope = scope(for: element.raw)
        let pid = self.pid
        let onEvent = self.onEvent
        // Build the element summary off-main via AXRunner, then post the event.
        // The timestamp is captured at arrival time so the unified log's
        // chronological sort still reflects when each event actually fired, not
        // when it finished formatting. Each task awaits its predecessor before
        // calling `onEvent`, so events reach the consumer in arrival order even
        // when AX-queue formatting completes out of order under load.
        let prior = orderingChain
        orderingChain = Task { @MainActor in
            await prior.value
            let summary = await AXRunner.run { ElementLabel.shortSync(for: element) }
            onEvent(Event(
                timestamp: timestamp,
                notification: notification,
                pid: pid,
                scope: eventScope,
                element: element,
                elementSummary: summary,
                userInfo: userInfo
            ))
        }
    }

    /// Helper for guarded state access.
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
