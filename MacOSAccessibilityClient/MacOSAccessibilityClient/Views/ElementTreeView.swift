//
//  ElementTreeView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import SwiftUI
import os

/// Center pane: a recursively-rendered AX tree starting at `root`. Each row pre-fetches
/// its role + label + children asynchronously via `AXRunner` (off cooperative pool, off
/// main) so view body evaluations don't trigger XPC calls. Expanded state lives in the
/// shared `TreeExpansionState` so the whole tree can be expanded/collapsed/refreshed by
/// code outside this view.
struct ElementTreeView: View {
    @Environment(TreeExpansionState.self) private var expansionState
    @State private var revealTask: Task<Void, Never>?

    /// Wait one beat after a `pendingReveal` before scrolling. The first frame
    /// instantiates ancestor rows; their `.task` fires loading children; only the
    /// frame after that contains the deep target row in the SwiftUI tree.
    private static let revealScrollDelay: Duration = .milliseconds(120)

    let root: AXElement
    @Binding var selection: AXElement?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ElementTreeRow(element: root, level: 0, selection: $selection)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: expansionState.pendingReveal) { _, target in
                guard let target else { return }
                revealTask?.cancel()
                revealTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: Self.revealScrollDelay)
                    } catch is CancellationError {
                        return
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    withAnimation { proxy.scrollTo(target.id, anchor: .center) }
                    if expansionState.pendingReveal == target {
                        expansionState.pendingReveal = nil
                    }
                }
            }
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
            }
        }
    }
}

private struct ElementTreeRow: View {
    @Environment(TreeExpansionState.self) private var expansionState
    let element: AXElement
    let level: Int
    @Binding var selection: AXElement?

    @State private var role: String?
    @State private var label: String = "…"
    @State private var children: [AXElement] = []
    @State private var loaded = false

    var body: some View {
        let family = RoleFamily.family(for: role)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: handleClick) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .frame(width: 12)
                        .opacity(loaded && children.isEmpty ? 0 : 0.7)
                    Image(systemName: family.symbol)
                        .font(.system(size: 11))
                        .frame(width: 14)
                        .foregroundStyle(family.color)
                    Text(label)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(level) * 14)
                .padding(.vertical, 1)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor.opacity(0.25) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(element.id)

            if isExpanded {
                ForEach(children) { child in
                    ElementTreeRow(element: child, level: level + 1, selection: $selection)
                }
            }
        }
        .task(id: refreshKey) {
            let start = CFAbsoluteTimeGetCurrent()
            // Fetch role + label + children together so visible-row populate is one
            // synchronous run on the AX queue rather than three round-trips.
            async let fetchedRole = element.role()
            async let fetchedLabel = ElementLabel.long(for: element)
            async let fetchedChildren = element.children()
            let (r, l, c) = await (fetchedRole, fetchedLabel, fetchedChildren)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if ms > 25 {
                AppLog.tree.notice("tree row populate(\(r ?? "?", privacy: .public)) — \(ms, format: .fixed(precision: 2), privacy: .public) ms · \(c.count, privacy: .public) children")
            }
            role = r
            label = l
            children = c
            loaded = true
        }
    }

    /// Combines the element's AX identity with the per-element refresh token so a
    /// `requestRefresh` on an ancestor re-fires this row's `.task`.
    private struct RefreshKey: Hashable {
        let element: AXElement
        let token: UUID?
    }

    private var refreshKey: RefreshKey {
        RefreshKey(element: element, token: expansionState.refreshToken(for: element))
    }

    private var isExpanded: Bool {
        expansionState.isExpanded(element)
    }

    private var isSelected: Bool {
        guard let selection else { return false }
        return selection == element
    }

    private func handleClick() {
        let optionDown = NSEvent.modifierFlags.contains(.option)
        selection = element
        if optionDown {
            Task { @MainActor in
                await expansionState.expandRecursively(from: element)
            }
        } else if loaded && !children.isEmpty {
            expansionState.toggle(element)
        }
    }
}
