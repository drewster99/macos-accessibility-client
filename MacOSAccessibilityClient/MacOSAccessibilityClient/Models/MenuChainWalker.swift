//
//  MenuChainWalker.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import ApplicationServices
import Foundation

/// Drives a deeply-nested menu open by replaying `AXPress` on each `AXMenuBarItem` /
/// `AXMenuItem` ancestor in order, with a configurable delay between presses. macOS
/// only populates a submenu's accessibility children when the submenu has been opened
/// in the target app's UI; clicking around in *our* app collapses the target's menus,
/// so we drive the opening programmatically instead of asking the user to do it.
///
/// `AXPress` returns success/failure (we check), but doesn't tell us whether the menu
/// actually opened. The post-walk refresh on the leaf is how we surface the result.
@MainActor
struct MenuChainWalker {
    enum WalkError: Error, LocalizedError {
        case pressFailed(element: AXElement, underlying: Error)
        case noChain

        var errorDescription: String? {
            switch self {
            case .pressFailed(let element, let underlying):
                let underlyingMsg = (underlying as? LocalizedError)?.errorDescription ?? "\(underlying)"
                return "AXPress on \(ElementLabel.short(for: element)) failed: \(underlyingMsg)"
            case .noChain:
                return "Element has no AXMenuItem/AXMenuBarItem ancestors."
            }
        }
    }

    let settings: AppSettings
    let expansionState: TreeExpansionState

    /// Build `[root → … → leaf]` of just the menu-related ancestors (`AXMenuBarItem` and
    /// `AXMenuItem`). Excludes the `AXMenu` containers between them — those aren't pressable.
    static func collectMenuChain(to leaf: AXElement, maxDepth: Int = 80) -> [AXElement] {
        var chain: [AXElement] = []
        var current: AXElement? = leaf
        var visited: Set<AXElement> = []
        var depth = 0
        while let element = current, depth < maxDepth, !visited.contains(element) {
            visited.insert(element)
            if let role = element.role,
               role == kAXMenuItemRole || role == kAXMenuBarItemRole {
                chain.append(element)
            }
            current = element.parent
            depth += 1
        }
        return chain.reversed()
    }

    /// Activate the target app, then `AXPress` each link in the chain in root-first order
    /// with the configured inter-press delay. Refreshes the leaf's children after the
    /// configured refresh delay so the now-populated submenu becomes visible in the tree.
    /// Returns the count of presses issued (== chain length).
    func performAXPressWalk(to leaf: AXElement) async throws -> Int {
        let chain = Self.collectMenuChain(to: leaf)
        guard !chain.isEmpty else { throw WalkError.noChain }

        if let pid = leaf.pid,
           let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate()
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(80))
        }

        let pressDelay = max(0, settings.menuWalkPressDelay)
        let refreshDelay = max(0, settings.menuWalkRefreshDelay)

        for (index, item) in chain.enumerated() {
            try Task.checkCancellation()
            do {
                try item.perform(kAXPressAction)
            } catch {
                throw WalkError.pressFailed(element: item, underlying: error)
            }
            if index < chain.count - 1, pressDelay > 0 {
                try await Task.sleep(for: .seconds(pressDelay))
            }
        }

        if refreshDelay > 0 {
            try await Task.sleep(for: .seconds(refreshDelay))
        }
        try Task.checkCancellation()
        expansionState.requestRefresh(for: leaf)

        return chain.count
    }
}
