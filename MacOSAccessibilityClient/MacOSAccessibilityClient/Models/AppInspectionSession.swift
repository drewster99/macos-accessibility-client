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

/// One session per inspected app: holds the AX root, the live `AXObserverWrapper`,
/// and a capped event log. Replaced wholesale when the user switches apps in the sidebar.
@MainActor
@Observable
final class AppInspectionSession: Identifiable {
    let app: RunningApp
    let root: AXElement
    private(set) var events: [AXObserverWrapper.Event] = []
    private(set) var lastError: String?

    private var observer: AXObserverWrapper?

    private static let eventBufferLimit = 500

    init(app: RunningApp, root: AXElement) {
        self.app = app
        self.root = root
        self.observer = nil
        do {
            let wrapper = try AXObserverWrapper(pid: app.pid) { [weak self] event in
                MainActor.assumeIsolated { self?.append(event) }
            }
            wrapper.subscribeStandardSet(on: root)
            self.observer = wrapper
        } catch {
            self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
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
    }
}
