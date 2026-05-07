//
//  FocusHistoryView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import SwiftUI

/// Bottom panel shown when the user is on the System-wide focus mode. Replaces the
/// per-app event log with a chronological list of focus transitions captured by
/// `SystemFocusTracker`. Each row is clickable and reveals that element in the
/// inspector.
struct FocusHistoryView: View {
    let history: [SystemFocusTracker.FocusEvent]
    let isRunning: Bool
    let onClear: () -> Void
    let onElementClick: (AXElement) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                LiveDot(active: isRunning)
                Text("Focus history (\(history.count))")
                    .font(.headline)
                Spacer()
                Button("Clear", action: onClear)
                    .controlSize(.small)
                    .disabled(history.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if history.isEmpty {
                        Text("No focus changes yet. Move the keyboard focus across apps to populate this list.")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        ForEach(history) { event in
                            FocusHistoryRow(event: event, onClick: { onElementClick(event.element) })
                            Divider()
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct FocusHistoryRow: View {
    let event: SystemFocusTracker.FocusEvent
    let onClick: () -> Void

    var body: some View {
        let family = RoleFamily.family(for: event.role)
        Button(action: onClick) {
            HStack(alignment: .center, spacing: 10) {
                Text(timestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Image(systemName: family.symbol)
                    .foregroundStyle(family.color)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(event.summary)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let pid = event.pid {
                    Text("pid \(pid)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to inspect this element")
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: event.timestamp)
    }
}

/// Pulsing accent dot used wherever a "this is live" indicator is wanted.
struct LiveDot: View {
    let active: Bool
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(active ? Color.accentColor.opacity(pulse ? 0.0 : 0.35) : .gray.opacity(0.2))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.4 : 1.0)
            Circle()
                .fill(active ? Color.accentColor : .gray)
                .frame(width: 8, height: 8)
        }
        .onAppear { startPulse() }
        .onChange(of: active) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard active else { pulse = false; return }
        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
