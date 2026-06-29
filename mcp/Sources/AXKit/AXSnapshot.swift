//
//  AXSnapshot.swift
//  AXKit
//
//  The AX → ElementNode bridge: walks a live AXElement subtree (depth-capped) into the
//  Sendable snapshot model that MacControlMCPCore's outline/diff/locator consume, and
//  returns the ref→AXElement handle map the host keeps for later reads/actions (§4).
//  Call inside AXRunner.run — every property read here is a cross-process AX call.
//

import ApplicationServices
import Foundation
import MacControlMCPCore

/// Allocates session-scoped refs ("e1", "e2", …).
public final class RefAllocator {
    private var counter = 0
    public init() {}
    public func next() -> String {
        counter += 1
        return "e\(counter)"
    }
}

public enum AXSnapshot {
    /// Walk a subtree into an ElementNode tree. `refFor` assigns a ref to each element —
    /// callers pass an identity-stable provider (ElementRegistry) so the same element keeps its
    /// ref across snapshots, which is what makes the diff meaningful.
    public static func build(
        _ root: AXElement,
        maxDepth: Int = 3,
        refFor: (AXElement) -> String
    ) -> ElementNode {
        func visit(_ element: AXElement, depth: Int) -> ElementNode {
            let ref = refFor(element)
            let children: [ElementNode] = depth < maxDepth
                ? element.children.map { visit($0, depth: depth + 1) }
                : []
            return ElementNode(
                ref: ref,
                role: element.role ?? "AXUnknown",
                subrole: element.subrole,
                identifier: element.identifier,
                title: element.title,
                value: element.value,
                frame: element.frame,
                actions: element.actions,
                settable: element.isValueSettable,
                children: children
            )
        }

        return visit(root, depth: 0)
    }

    /// A cheap structural fingerprint (roles + child counts to depth) used by the settle
    /// poll to detect change without allocating refs. Stable within a process run.
    public static func structuralSignature(of root: AXElement, maxDepth: Int) -> Int {
        var hasher = Hasher()
        func visit(_ element: AXElement, depth: Int) {
            hasher.combine(element.role ?? "")
            let children = element.children
            hasher.combine(children.count)
            if depth < maxDepth {
                for child in children { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return hasher.finalize()
    }

    /// Like `structuralSignature` but also folds in each element's value, so it detects value-only
    /// changes (typing, a field update) that don't alter structure. Used to spot the *first* effect
    /// of an action quickly; quiescence still keys off the structure-only signature so a constantly
    /// changing value (clock/progress) can't prevent settling.
    public static func changeSignature(of root: AXElement, maxDepth: Int) -> Int {
        var hasher = Hasher()
        func visit(_ element: AXElement, depth: Int) {
            hasher.combine(element.role ?? "")
            hasher.combine(element.value ?? "")
            let children = element.children
            hasher.combine(children.count)
            if depth < maxDepth {
                for child in children { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return hasher.finalize()
    }
}
