//
//  ContentView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AccessibilityPermissions.self) private var permissions
    @Environment(RunningAppsViewModel.self) private var runningApps
    @Environment(SystemFocusTracker.self) private var focus
    @Environment(ClickTracker.self) private var clicks

    @State private var selection: pid_t?
    @State private var session: AppInspectionSession?
    @State private var inspected: AXElement?
    @State private var expansionState = TreeExpansionState()
    @State private var clicksEnabled: Bool = false
    @State private var focusEnabled: Bool = false

    /// Cached merged log. Recomputed only when one of the three sources changes
    /// (via `.onChange` below); avoids re-merging ~900 entries on every parent
    /// state invalidation.
    @State private var unifiedEntries: [UnifiedLogEvent] = []

    /// Tracks the currently in-flight expansion / reveal work so a fast app-switch
    /// can cancel the prior task before launching the next one. Without this,
    /// rapid sidebar selection queues redundant tree walks for sessions the user
    /// has already left.
    @State private var expandTask: Task<Void, Never>?

    var body: some View {
        rootSplit
            .modifier(LogSourceWatcher(
                appEvents: session?.events ?? [],
                clickEvents: clicks.history,
                focusEvents: focus.history,
                onChange: rebuildUnifiedEntries
            ))
            .onChange(of: clicksEnabled) { _, on in
                if on { clicks.start() } else { clicks.stop() }
            }
            .onChange(of: focusEnabled) { _, on in
                if on { focus.start() } else { focus.stop() }
            }
            .onDisappear {
                expandTask?.cancel()
                expandTask = nil
            }
    }

    @ViewBuilder
    private var rootSplit: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
            detail
                .frame(minWidth: 600)
        }
        .frame(minWidth: AppLayout.minWindowWidth, minHeight: AppLayout.minWindowHeight)
        .environment(expansionState)
        .toolbar { toolbarContent }
        .navigationTitle("MacOS Accessibility Client")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let session {
                TargetChip(app: session.app)
                    .transition(.opacity)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: refreshSession) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(session == nil)
            .help("Refresh this session's tree")
        }
    }

    private func refreshSession() {
        guard let session else { return }
        expansionState.requestRefresh(for: session.root)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            if !permissions.isTrusted {
                PermissionsBanner()
                    .padding()
            }
            List(selection: $selection) {
                Section("Running Apps") {
                    ForEach(runningApps.apps) { app in
                        AppRow(app: app)
                            .tag(app.pid)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: selection) { _, new in
            handleSelectionChange(new)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VSplitView {
            HSplitView {
                middle
                    .frame(minWidth: 320)
                ElementInspectorView(element: inspected)
                    .frame(minWidth: 360)
            }
            .frame(minHeight: 360)
            UnifiedLogView(
                entries: unifiedEntries,
                appColumnTitle: appColumnTitle,
                appColumnSubscriptionError: session?.lastError,
                clicksEnabled: $clicksEnabled,
                focusEnabled: $focusEnabled,
                onClear: clearAllLogs,
                onElementClick: handleLogElementClick
            )
            .frame(minHeight: 160, idealHeight: 240)
        }
    }

    private func rebuildUnifiedEntries() {
        unifiedEntries = UnifiedLogEvent.merged(
            appEvents: session?.events ?? [],
            clickEvents: clicks.history,
            focusEvents: focus.history
        )
    }

    private var appColumnTitle: String {
        if let session { return session.app.name } else { return "App (no selection)" }
    }

    private func clearAllLogs() {
        session?.clearEvents()
        clicks.clearHistory()
        focus.clearHistory()
    }

    @ViewBuilder
    private var middle: some View {
        if let session {
            ElementTreeView(root: session.root, selection: $inspected)
                .id(session.app.pid)
        } else {
            placeholder("Pick an app from the sidebar to see its accessibility tree.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSelectionChange(_ new: pid_t?) {
        // No-op when the selection moves to an app we already have a session for —
        // `handleLogElementClick` sets the session up directly before nudging
        // `selection`, and we don't want to trample its expansion-state work.
        if let session, let new, session.app.pid == new { return }
        inspected = nil
        expansionState.reset()
        guard let pid = new,
              let app = runningApps.apps.first(where: { $0.pid == pid })
        else {
            session = nil
            expandTask?.cancel()
            expandTask = nil
            return
        }
        startSession(for: app)
    }

    /// Click on a row in the unified log: reveal the element in the tree, switching
    /// the sidebar to the owning app first if the click came from a different process.
    private func handleLogElementClick(_ entry: UnifiedLogEvent) {
        guard let element = entry.element else { return }
        let targetPid = entry.pid ?? element.pid

        if let targetPid,
           selection != targetPid,
           let app = runningApps.apps.first(where: { $0.pid == targetPid }) {
            // Set up the new session synchronously here so the `.onChange`-triggered
            // `handleSelectionChange` sees a matching session and is a no-op. This
            // avoids a race where the change handler resets the expansion state
            // *after* our reveal additions land.
            expansionState.reset()
            inspected = element
            selection = targetPid
            startSession(for: app, revealing: element)
            return
        }

        inspected = element
        expandTask?.cancel()
        expandTask = Task { @MainActor in
            await expansionState.reveal(element)
        }
    }

    /// Single source of truth for "user picked an app to inspect": creates the
    /// session, replaces any in-flight expansion work, and optionally reveals an
    /// element once the initial expansion finishes.
    private func startSession(for app: RunningApp, revealing element: AXElement? = nil) {
        let newSession = AppInspectionSession(app: app, root: runningApps.element(for: app))
        let state = expansionState
        newSession.onStructuralChange = { element in
            state.requestRefresh(for: element)
        }
        session = newSession
        expandTask?.cancel()
        expandTask = Task { @MainActor in
            await expansionState.expandToDepth(2, from: newSession.root)
            if Task.isCancelled { return }
            if let element {
                await expansionState.reveal(element)
            }
        }
    }
}

/// Pulled out so the parent body's modifier chain doesn't blow Swift's type-check
/// budget. Watches the three log sources and calls `onChange` whenever any of
/// them changes; the parent uses that to rebuild its merged @State entries array.
private struct LogSourceWatcher: ViewModifier {
    let appEvents: [AXObserverWrapper.Event]
    let clickEvents: [ClickTracker.ClickEvent]
    let focusEvents: [SystemFocusTracker.FocusEvent]
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appEvents) { _, _ in onChange() }
            .onChange(of: clickEvents) { _, _ in onChange() }
            .onChange(of: focusEvents) { _, _ in onChange() }
            .onAppear { onChange() }
    }
}

private struct AppRow: View {
    let app: RunningApp

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(pid: app.pid, fallbackSystemImage: "app.dashed")
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .lineLimit(1)
                Text("pid \(app.pid)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Capsule chip used in the toolbar to show the currently-inspected target.
private struct TargetChip: View {
    let app: RunningApp

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(pid: app.pid, fallbackSystemImage: "app")
                .frame(width: 16, height: 16)
            Text(app.name)
                .font(.subheadline)
            Text("pid \(app.pid)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35)))
    }
}

/// Renders an `NSRunningApplication.icon` as a SwiftUI image, falling back to a
/// system symbol if the icon isn't available (e.g. process exited).
private struct AppIconView: View {
    let pid: pid_t
    let fallbackSystemImage: String

    var body: some View {
        if let nsImage = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: fallbackSystemImage)
                .foregroundStyle(.secondary)
        }
    }
}
