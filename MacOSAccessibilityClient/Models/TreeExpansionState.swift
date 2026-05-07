//
//  TreeExpansionState.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import Foundation
import Observation

/// Tracks which `AXElement`s in the currently-displayed tree are expanded.
/// Lifetime: one per `AppInspectionSession` (reset when the user picks a different app).
///
/// Stores `AXElement` values directly so identity is by `CFEqual`/`CFHash`.
/// Raw `AXUIElement` pointer identity is NOT stable across attribute reads —
/// `AXUIElementCopyAttributeValue(kAXChildrenAttribute)` may hand back fresh CF
/// references that compare equal but live at different addresses, so a pointer-keyed
/// set would miss matches.
@MainActor
@Observable
final class TreeExpansionState {
    private(set) var expandedElements: Set<AXElement> = []

    /// Set when something asks the tree to scroll a specific element into view. The
    /// tree clears this back to `nil` after acting on it. One-shot signal.
    var pendingReveal: AXElement?

    /// Bumping the token for an element causes its row to re-fetch `kAXChildrenAttribute`.
    /// The row key also includes the element's AX identity, so refreshes work even when
    /// the system returns fresh CF references for the same underlying AX element.
    private(set) var refreshTokens: [AXElement: UUID] = [:]

    func isExpanded(_ element: AXElement) -> Bool {
        expandedElements.contains(element)
    }

    func toggle(_ element: AXElement) {
        if expandedElements.contains(element) {
            expandedElements.remove(element)
        } else {
            expandedElements.insert(element)
        }
    }

    /// Marks the root and every descendant within `depth` rows as expanded. Depth 2
    /// means root and its children are expanded, so levels 0–2 of the tree are visible.
    func expandToDepth(_ depth: Int, from root: AXElement) {
        guard depth > 0 else { return }
        var stack: [(AXElement, Int)] = [(root, 0)]
        while let (element, level) = stack.popLast() {
            guard level < depth else { continue }
            expandedElements.insert(element)
            for child in element.children {
                stack.append((child, level + 1))
            }
        }
    }

    /// Walks the entire subtree under `root` and marks every element expanded.
    /// Synchronous and main-thread-blocking — every step is a cross-process AX call.
    /// `maxDepth` is a defensive cap against pathological cycles.
    func expandRecursively(from root: AXElement, maxDepth: Int = 50) {
        var stack: [(AXElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast() {
            guard depth < maxDepth else { continue }
            expandedElements.insert(element)
            for child in element.children {
                stack.append((child, depth + 1))
            }
        }
    }

    /// Bumps the refresh token for `element` so its row re-fetches `kAXChildrenAttribute`
    /// the next layout pass.
    func requestRefresh(for element: AXElement) {
        refreshTokens[element] = UUID()
    }

    /// The current refresh token, or nil if `requestRefresh` has never been called for
    /// this element. Combine with the element's own ID to form a stable `.task` ID.
    func refreshToken(for element: AXElement) -> UUID? {
        refreshTokens[element]
    }

    /// Expand every ancestor of `element` so the row for `element` will be visible
    /// once the tree finishes loading children. Sets `pendingReveal` so the tree view
    /// can scroll to it.
    func reveal(_ element: AXElement) {
        for ancestor in element.ancestorChain() {
            expandedElements.insert(ancestor)
        }
        pendingReveal = element
    }

    func reset() {
        expandedElements.removeAll()
        refreshTokens.removeAll()
        pendingReveal = nil
    }
}
