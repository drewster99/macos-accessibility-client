//
//  AppInspectionSession.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import Foundation
import Observation
import os

/// One session per inspected app: holds the AX root, the live `AXObserverWrapper`,
/// and a capped event log. Replaced wholesale when the user switches apps in the sidebar.
@MainActor
@Observable
final class AppInspectionSession: Identifiable {
    let app: RunningApp
    let root: AXElement
    private(set) var events: [AXObserverWrapper.Event] = []
    private(set) var lastError: String?

    /// Called on the main actor when an event arrives whose notification is in
    /// `structuralNotifications` — i.e. the AX tree at or below `element` likely
    /// changed shape, label, or value. Consumers (the tree view) use this to
    /// invalidate cached children/labels for that element. Set after init.
    var onStructuralChange: (@MainActor (AXElement) -> Void)?

    private var observer: AXObserverWrapper?

    private static let eventBufferLimit = 500

    /// Notifications that imply a row's cached children, label, or value need to
    /// be re-fetched. We deliberately exclude focus/window/menu/announcement
    /// notifications: those don't change the tree's content at the affected
    /// element. `kAXCreatedNotification` / `kAXUIElementDestroyedNotification`
    /// fire on the new/dead element rather than its parent — for the destroyed
    /// case there's nothing valid to query, so the row-level refresh is a
    /// best-effort and we rely on `kAXLayoutChangedNotification` (typically
    /// posted on the affected container by the same UIKit transaction) to
    /// invalidate the parent.
    private static let structuralNotifications: Set<String> = [
        kAXLayoutChangedNotification,
        kAXValueChangedNotification,
        kAXTitleChangedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
        kAXRowExpandedNotification,
        kAXRowCollapsedNotification,
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification
    ]

    init(app: RunningApp, root: AXElement) {
        self.app = app
        self.root = root
        self.observer = nil
        let sessionStart = CFAbsoluteTimeGetCurrent()
        // The whole setup is async now: create the observer (XPC), subscribe the app
        // root (35 XPC calls), find iOS bridges (tree walk), subscribe those. All of
        // it goes through `AXRunner` so the calling actor isn't blocked. Session
        // creation returns immediately; the observer becomes available a few hops later.
        Task { @MainActor [weak self] in
            do {
                let wrapper = try await AXObserverWrapper.make(pid: app.pid) { [weak self] event in
                    MainActor.assumeIsolated { self?.append(event) }
                }
                await wrapper.subscribeStandardSet(on: root, scope: .appRoot)
                guard let self else {
                    await wrapper.tearDown()
                    return
                }
                self.observer = wrapper
                let bridges = await Self.findIOSContentGroups(under: root)
                for bridge in bridges {
                    await wrapper.subscribeStandardSet(on: bridge, scope: .simulatorContent)
                }
                let ms = (CFAbsoluteTimeGetCurrent() - sessionStart) * 1000
                AppLog.session.info("session(\(app.name, privacy: .public), pid \(app.pid, privacy: .public)) ready — \(ms, format: .fixed(precision: 2), privacy: .public) ms · \(bridges.count, privacy: .public) iOS bridge(s)")
            } catch {
                self?.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                let ms = (CFAbsoluteTimeGetCurrent() - sessionStart) * 1000
                AppLog.session.error("session(\(app.name, privacy: .public), pid \(app.pid, privacy: .public)) FAILED — \(ms, format: .fixed(precision: 2), privacy: .public) ms")
            }
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    private func append(_ event: AXObserverWrapper.Event) {
        events.append(event)
        if events.count > Self.eventBufferLimit {
            events.removeFirst(events.count - Self.eventBufferLimit)
        }
        if Self.structuralNotifications.contains(event.notification) {
            onStructuralChange?(event.element)
        }
    }

    /// The iOS Simulator bridges the simulated app's `UIAccessibility` tree into
    /// `Simulator.app`'s NSAccessibility hierarchy under `AXGroup` elements whose
    /// `AXIdentifier` is `"iOSContentGroup"`. There is one per booted simulator
    /// window. AX notifications posted by UIKit (layout-changed, value-changed,
    /// announcements, …) land on or under this node, so subscribing here catches
    /// them — they'd never reach a subscription on the app root.
    private static func findIOSContentGroups(under root: AXElement, maxDepth: Int = 4) async -> [AXElement] {
        await AXRunner.run {
            var results: [AXElement] = []
            // Only descend through containers that plausibly host the bridge group;
            // recursing into the bridged iOS subtree would walk thousands of nodes.
            let recursable: Set<String> = [
                kAXApplicationRole, kAXWindowRole, kAXGroupRole,
                kAXScrollAreaRole, kAXSplitGroupRole
            ]
            func visit(_ element: AXElement, _ depth: Int) {
                if depth > maxDepth { return }
                let role = element.syncRole()
                if role == kAXGroupRole {
                    let identifier: String?
                    do {
                        identifier = try element.syncAttribute("AXIdentifier", as: String.self)
                    } catch {
                        AppLog.tree.debug("findIOSContentGroups AXIdentifier read failed: \(error.localizedDescription, privacy: .public)")
                        identifier = nil
                    }
                    if identifier == "iOSContentGroup" {
                        results.append(element)
                        return
                    }
                }
                guard let role, recursable.contains(role) else { return }
                for child in element.syncChildren() {
                    visit(child, depth + 1)
                }
            }
            let start = CFAbsoluteTimeGetCurrent()
            visit(root, 0)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            AppLog.tree.info("findIOSContentGroups — \(ms, format: .fixed(precision: 2), privacy: .public) ms · \(results.count, privacy: .public) bridge node(s)")
            return results
        }
    }
}
