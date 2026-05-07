//
//  SystemFocusView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import SwiftUI

/// Center pane shown when the user picks "System-wide focused element" in the sidebar.
/// Renders whatever currently has keyboard focus across all apps plus its ancestor
/// chain, driven by `SystemFocusTracker`'s polling of `kAXFocusedUIElementAttribute`
/// on the system-wide element. Every row is clickable; clicking sets the inspector's
/// element to that ancestor / focused element.
struct SystemFocusView: View {
    @Environment(SystemFocusTracker.self) private var focus
    @Binding var inspected: AXElement?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let focused = focus.focusedElement {
                    focusedCard(focused)
                    if !focus.ancestors.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ancestor chain")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(Array(focus.ancestors.enumerated()), id: \.element.id) { idx, ancestor in
                                ancestorRow(ancestor, depth: idx + 1)
                            }
                        }
                    }
                } else {
                    Text("No element currently has keyboard focus.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: focus.focusedElement) { _, new in
            inspected = new
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LiveDot(active: focus.isRunning)
            VStack(alignment: .leading, spacing: 1) {
                Text(focus.isRunning ? "Tracking system-wide focus" : "Idle")
                    .font(.headline)
                Text("Polling \(Int(1.0 / 0.5)) Hz · \(focus.history.count) focus changes captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Big, role-tinted card for the currently-focused element. Mirrors the inspector
    /// header style so the eye carries the same visual identity across panes.
    private func focusedCard(_ element: AXElement) -> some View {
        let family = RoleFamily.family(for: element.role)
        return Button(action: { inspected = element }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: family.symbol)
                    .font(.title)
                    .foregroundStyle(family.color)
                    .frame(width: 36, height: 36)
                    .background(family.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Focused")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text(ElementLabel.long(for: element))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let frame = element.frame {
                        Text("frame: \(Formatting.frame(frame))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(family.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(family.color.opacity(0.3)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Click to inspect")
    }

    /// Compact, clickable row for one ancestor. Lighter typography than the focused
    /// card so the chain reads as supporting context, not as the primary thing.
    private func ancestorRow(_ element: AXElement, depth: Int) -> some View {
        let family = RoleFamily.family(for: element.role)
        return Button(action: { inspected = element }) {
            HStack(alignment: .center, spacing: 10) {
                Text("↑\(depth)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .leading)
                Image(systemName: family.symbol)
                    .foregroundStyle(family.color)
                    .font(.system(size: 12))
                    .frame(width: 16, height: 16)
                Text(ElementLabel.long(for: element))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(family.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(family.color.opacity(0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Click to inspect")
    }
}
