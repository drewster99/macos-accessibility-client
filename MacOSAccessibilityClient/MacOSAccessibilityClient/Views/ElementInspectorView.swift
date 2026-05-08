//
//  ElementInspectorView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import SwiftUI

/// Right-hand pane: shows the selected element's role/subrole/title/frame plus the
/// full attribute, action, parameterized-attribute, and read-error lists. Action
/// rows have a Perform button that issues `AXUIElementPerformAction`; for
/// `AXMenuItem`/`AXMenuBarItem` + `AXPress` the press is routed through
/// `MenuChainWalker` when the user has the chain-walk setting enabled.
struct ElementInspectorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TreeExpansionState.self) private var expansionState

    let element: AXElement?

    @State private var snapshot: ElementSnapshot?
    @State private var lastActionResult: ActionResult?
    @State private var isPerforming: Bool = false
    @State private var actionTask: Task<Void, Never>?

    private struct ActionResult: Identifiable {
        let id = UUID()
        let action: String
        let success: Bool
        let message: String?
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if element != nil {
                    if let snapshot {
                        snapshotView(snapshot)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 8)
                    }
                } else {
                    Text("Select an element to inspect.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: element?.id) {
            actionTask?.cancel()
            actionTask = nil
            isPerforming = false
            snapshot = nil
            lastActionResult = nil
            guard let element else { return }
            let builtSnapshot = await ElementSnapshot.build(for: element)
            guard !Task.isCancelled else { return }
            snapshot = builtSnapshot
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
            isPerforming = false
        }
    }

    @ViewBuilder
    private func snapshotView(_ s: ElementSnapshot) -> some View {
        Group {
            headerSection(s)
            if !s.readErrors.isEmpty {
                readErrorsSection(s.readErrors)
            }
            attributesSection(s)
            actionsSection(s)
            parameterizedAttributesSection(s)
        }
    }

    @ViewBuilder
    private func headerSection(_ s: ElementSnapshot) -> some View {
        let family = RoleFamily.family(for: s.role)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: family.symbol)
                .font(.title)
                .foregroundStyle(family.color)
                .frame(width: 32, height: 32)
                .background(family.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(s.role)
                    .font(.title3)
                    .fontWeight(.semibold)
                if let sub = s.subrole {
                    Text("subrole: \(sub)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let title = s.title {
                    Text("title: \(title)")
                        .font(.callout)
                }
                if let frame = s.frame {
                    Text("frame: \(Formatting.frame(frame))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(family.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(family.color.opacity(0.25)))
    }

    @ViewBuilder
    private func attributesSection(_ s: ElementSnapshot) -> some View {
        section("Attributes (\(s.attributes.count))") {
            if s.attributes.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(s.attributes) { row in
                        GridRow {
                            Text(row.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                                .textSelection(.enabled)
                            Text(row.value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ s: ElementSnapshot) -> some View {
        section("Actions (\(s.actions.count))") {
            if s.actions.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(s.actions, id: \.self) { action in
                    HStack {
                        Text(action)
                            .font(.system(.body, design: .monospaced))
                        if willWalkChain(for: action) {
                            Text("(walks chain)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Perform") { performAction(action) }
                            .controlSize(.small)
                            .disabled(isPerforming)
                            .help(performHelp(for: action))
                    }
                }
                if let r = lastActionResult {
                    actionResultRow(r)
                }
            }
        }
    }

    @ViewBuilder
    private func parameterizedAttributesSection(_ s: ElementSnapshot) -> some View {
        section("Parameterized attributes (\(s.parameterizedAttributes.count))") {
            if s.parameterizedAttributes.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(s.parameterizedAttributes, id: \.self) { name in
                    Text(name).font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private func actionResultRow(_ r: ActionResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(r.success ? .green : .red)
            Text(r.action)
                .font(.system(.caption, design: .monospaced))
            if let msg = r.message {
                Text("— \(msg)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func readErrorsSection(_ errors: [ReadError]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Read errors (\(errors.count))")
                    .font(.headline)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(errors) { e in
                    GridRow {
                        Text(e.context)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                            .textSelection(.enabled)
                        Text(e.message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.orange.opacity(0.35)))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func performAction(_ action: String) {
        guard let element, !isPerforming else { return }
        if willWalkChain(for: action) {
            performMenuChainWalk(to: element)
        } else {
            actionTask?.cancel()
            isPerforming = true
            actionTask = Task { @MainActor in
                defer { isPerforming = false }
                do {
                    try await element.perform(action)
                    lastActionResult = ActionResult(action: action, success: true, message: nil)
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    lastActionResult = ActionResult(action: action, success: false, message: msg)
                }
            }
        }
    }

    /// Uses the snapshot's role (already-fetched, no extra AX hop) so the body stays
    /// off the AX bus during normal renders.
    private func willWalkChain(for action: String) -> Bool {
        guard settings.walkMenuChainOnPress, action == kAXPressAction, element != nil else { return false }
        guard let role = snapshot?.role else { return false }
        return role == kAXMenuItemRole || role == kAXMenuBarItemRole
    }

    private func performHelp(for action: String) -> String {
        if willWalkChain(for: action) {
            return "Walks the AXMenuBarItem → AXMenuItem chain, AXPressing each in order, then refreshes this element's children. Disable in View → Walk menu chain on AXPress."
        }
        return "Calls AXUIElementPerformAction(\(action))"
    }

    private func performMenuChainWalk(to leaf: AXElement) {
        let walker = MenuChainWalker(settings: settings, expansionState: expansionState)
        actionTask?.cancel()
        isPerforming = true
        let task = Task { @MainActor in
            defer { isPerforming = false }
            do {
                let count = try await walker.performAXPressWalk(to: leaf)
                guard !Task.isCancelled else { return }
                lastActionResult = ActionResult(
                    action: "AXPress (walked \(count) item\(count == 1 ? "" : "s"))",
                    success: true,
                    message: nil
                )
            } catch is CancellationError {
                lastActionResult = nil
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                lastActionResult = ActionResult(action: "AXPress (walk)", success: false, message: msg)
            }
        }
        actionTask = task
    }
}
