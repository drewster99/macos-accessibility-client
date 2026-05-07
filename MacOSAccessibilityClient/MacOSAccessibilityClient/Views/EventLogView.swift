//
//  EventLogView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import SwiftUI

/// Bottom pane: a reverse-chronological log of `AXObserver` notifications for the
/// currently-inspected app, plus a one-shot subscription-error banner. Each event row
/// shows the notification name, a clickable summary of the originating element
/// (clicking reveals it in the tree above), and the system's user-info dictionary
/// (when populated by the target).
struct EventLogView: View {
    let events: [AXObserverWrapper.Event]
    let subscriptionError: String?
    let onClear: () -> Void
    let onElementClick: (AXElement) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Events (\(events.count))")
                    .font(.headline)
                Spacer()
                Button("Clear", action: onClear)
                    .controlSize(.small)
                    .disabled(events.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            if let subscriptionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Subscription failed: \(subscriptionError)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.15))
            }
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if events.isEmpty {
                        Text("No events yet. Subscribe by selecting an app in the sidebar; then interact with that app to see notifications.")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        ForEach(events.reversed()) { event in
                            EventRow(event: event, onElementClick: onElementClick)
                            Divider()
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct EventRow: View {
    let event: AXObserverWrapper.Event
    let onElementClick: (AXElement) -> Void

    var body: some View {
        let family = NotificationFamily.family(for: event.notification)
        HStack(alignment: .top, spacing: 8) {
            Text(timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(family.color)
                        .frame(width: 7, height: 7)
                    Text(event.notification)
                        .font(.system(.caption, design: .monospaced))
                }
                Button(action: { onElementClick(event.element) }) {
                    Text(event.elementSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tint)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Reveal in tree")
                if !event.userInfo.isEmpty {
                    userInfoTable
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var userInfoTable: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 1) {
            ForEach(event.userInfo) { entry in
                GridRow {
                    Text(entry.key)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.leading)
                    Text(entry.value)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
        .padding(.leading, 8)
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: event.timestamp)
    }
}
