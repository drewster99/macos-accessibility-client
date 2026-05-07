//
//  ContentView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import SwiftUI

enum SidebarSelection: Hashable {
    case app(pid_t)
    case systemFocus
}

struct ContentView: View {
    @Environment(AccessibilityPermissions.self) private var permissions
    @Environment(RunningAppsViewModel.self) private var runningApps
    @Environment(SystemFocusTracker.self) private var focus

    @State private var selection: SidebarSelection?
    @State private var session: AppInspectionSession?
    @State private var inspected: AXElement?
    @State private var expansionState = TreeExpansionState()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
            detail
                .frame(minWidth: 600)
        }
        .frame(minWidth: 1100, minHeight: 700)
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
                            .tag(SidebarSelection.app(app.pid))
                    }
                }
                Section("System") {
                    Label("System-wide focused element", systemImage: "scope")
                        .tag(SidebarSelection.systemFocus)
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
            bottomPanel
                .frame(minHeight: 140, idealHeight: 200)
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch selection {
        case .systemFocus:
            FocusHistoryView(
                history: focus.history,
                isRunning: focus.isRunning,
                onClear: { focus.clearHistory() },
                onElementClick: { element in
                    inspected = element
                }
            )
        case .app, .none:
            EventLogView(
                events: session?.events ?? [],
                subscriptionError: session?.lastError,
                onClear: { session?.clearEvents() },
                onElementClick: { element in
                    inspected = element
                    expansionState.reveal(element)
                }
            )
        }
    }

    @ViewBuilder
    private var middle: some View {
        switch selection {
        case .app:
            if let session {
                ElementTreeView(root: session.root, selection: $inspected)
                    .id(session.app.pid)
            } else {
                placeholder("Pick an app from the sidebar.")
            }
        case .systemFocus:
            SystemFocusView(inspected: $inspected)
        case .none:
            placeholder("Pick an app or System-wide focused element from the sidebar.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSelectionChange(_ new: SidebarSelection?) {
        inspected = nil
        expansionState.reset()
        switch new {
        case .app(let pid):
            guard let app = runningApps.apps.first(where: { $0.pid == pid }) else {
                session = nil
                return
            }
            let newSession = AppInspectionSession(app: app, root: runningApps.element(for: app))
            session = newSession
            expansionState.expandToDepth(2, from: newSession.root)
            focus.stop()
        case .systemFocus:
            session = nil
            focus.start()
        case .none:
            session = nil
            focus.stop()
        }
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
