//
//  UnifiedLogView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import SwiftUI

/// Bottom pane: a single timeline merging the currently-inspected app's events,
/// global clicks, and system-wide focus changes. Each row has four cells —
/// timestamp, app event, click, focus — and only the cell matching the entry's
/// source is populated, so a glance at a column shows the activity flow from
/// that source. Click any row to reveal that element in the tree (auto-switching
/// the sidebar to the owning app if necessary).
struct UnifiedLogView: View {
    let entries: [UnifiedLogEvent]
    let appColumnTitle: String
    let appColumnSubscriptionError: String?

    @Binding var clicksEnabled: Bool
    @Binding var focusEnabled: Bool

    let onClear: () -> Void
    let onElementClick: (UnifiedLogEvent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let appColumnSubscriptionError {
                subscriptionErrorBanner(appColumnSubscriptionError)
            }
            Divider()
            // GeometryReader measures the panel's width so the column header and
            // every row use the same App / Clicks / Focus column widths. App is
            // ~10% narrower than equal-thirds and Clicks is ~15% wider, with the
            // remainder going to Focus.
            GeometryReader { geo in
                let widths = ColumnWidths.from(totalWidth: geo.size.width)
                VStack(spacing: 0) {
                    columnHeaderRow(widths: widths)
                    Divider()
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            if entries.isEmpty {
                                Text("No activity yet. Pick an app to see its events, or enable click / focus tracking above.")
                                    .foregroundStyle(.secondary)
                                    .padding(12)
                            } else {
                                ForEach(entries) { entry in
                                    UnifiedLogRow(entry: entry, widths: widths, onElementClick: onElementClick)
                                    Divider()
                                }
                            }
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Events (\(entries.count))")
                .font(.headline)
            Spacer()
            Toggle(isOn: $clicksEnabled) {
                Label("Capture clicks", systemImage: "cursorarrow.click")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Toggle(isOn: $focusEnabled) {
                Label("Track focus", systemImage: "scope")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Button("Clear", action: onClear)
                .controlSize(.small)
                .disabled(entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func subscriptionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Subscription failed: \(message)")
                .font(.caption)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15))
    }

    private func columnHeaderRow(widths: ColumnWidths) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Time")
                .frame(width: UnifiedLogRow.timestampColumnWidth, alignment: .leading)
            Text(appColumnTitle)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: widths.app, alignment: .leading)
            Text("Clicks")
                .lineLimit(1).truncationMode(.tail)
                .frame(width: widths.click, alignment: .leading)
            Text("Focus")
                .lineLimit(1).truncationMode(.tail)
                .frame(width: widths.focus, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

/// Computed widths for the App / Clicks / Focus columns. The proportions are
/// 0.30 / 0.38 / 0.32 of the space remaining after the fixed timestamp column,
/// horizontal padding, and inter-cell spacing.
private struct ColumnWidths: Equatable, Sendable {
    let app: CGFloat
    let click: CGFloat
    let focus: CGFloat

    static func from(totalWidth: CGFloat) -> ColumnWidths {
        // 90 (timestamp) + 24 (horizontal padding 12 × 2) + 24 (3 × 8 inter-cell spacing)
        let leftover = max(0, totalWidth - 90 - 24 - 24)
        return ColumnWidths(
            app: leftover * 0.30,
            click: leftover * 0.38,
            focus: leftover * 0.32
        )
    }
}

private struct UnifiedLogRow: View {
    static let timestampColumnWidth: CGFloat = 90

    let entry: UnifiedLogEvent
    let widths: ColumnWidths
    let onElementClick: (UnifiedLogEvent) -> Void

    var body: some View {
        Button(action: { onElementClick(entry) }) {
            HStack(alignment: .top, spacing: 8) {
                Text(timestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.timestampColumnWidth, alignment: .leading)
                AppCell(entry: entry)
                    .frame(width: widths.app, alignment: .leading)
                ClickCell(entry: entry)
                    .frame(width: widths.click, alignment: .leading)
                FocusCell(entry: entry)
                    .frame(width: widths.focus, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.element == nil ? "No element resolved for this entry" : "Reveal in tree")
        .disabled(entry.element == nil)
    }

    private var timestamp: String {
        Formatting.timestamp.string(from: entry.timestamp)
    }
}

private struct AppCell: View {
    let entry: UnifiedLogEvent

    var body: some View {
        if case .app(let event) = entry {
            let family = NotificationFamily.family(for: event.notification)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(family.color)
                        .frame(width: 7, height: 7)
                    Text(event.notification)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if event.scope == .simulatorContent {
                        Text("iOS sim")
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .foregroundStyle(Theme.iOSBridge)
                            .background(Theme.iOSBridge.opacity(0.18), in: Capsule())
                            .overlay(Capsule().stroke(Theme.iOSBridge.opacity(0.45), lineWidth: 0.5))
                    }
                }
                Text(event.elementSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

private struct ClickCell: View {
    let entry: UnifiedLogEvent

    var body: some View {
        if case .click(let event) = entry {
            let family = RoleFamily.family(for: event.role)
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: event.isRightClick ? "cursorarrow.click.badge.clock" : "cursorarrow.click")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                    .frame(width: 14)
                Image(systemName: family.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(family.color)
                    .frame(width: 14)
                Text(event.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(coords(event.location))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func coords(_ point: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", point.x, point.y)
    }
}

private struct FocusCell: View {
    let entry: UnifiedLogEvent

    var body: some View {
        if case .focus(let event) = entry {
            let family = RoleFamily.family(for: event.role)
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: family.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(family.color)
                    .frame(width: 14)
                Text(event.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let pid = event.pid {
                    Text("pid \(pid)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
