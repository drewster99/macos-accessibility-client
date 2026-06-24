//
//  Locator.swift
//  MacControlMCP
//
//  The re-resolvable locator from §4 of docs/MCP_DESIGN.md. When a `ref`'s underlying
//  element is destroyed/rebuilt, the host re-resolves it from this signature — but
//  NEVER silently guesses: a confident unique match resolves, anything ambiguous returns
//  candidates so the caller surfaces `stale_ref`. Pure logic over ElementNode trees.
//

import Foundation

public struct Locator: Equatable, Sendable {
    public let role: String
    public let identifier: String?
    public let title: String?
    /// Index among same-role siblings under the parent.
    public let siblingIndex: Int
    /// Roles from the root down to (and excluding) this element.
    public let parentRoles: [String]

    public init(role: String, identifier: String?, title: String?, siblingIndex: Int, parentRoles: [String]) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.siblingIndex = siblingIndex
        self.parentRoles = parentRoles
    }
}

public enum LocatorCapture {
    /// Build a locator for every node in the tree, keyed by ref.
    public static func all(in root: ElementNode) -> [String: Locator] {
        var result: [String: Locator] = [:]
        func visit(_ node: ElementNode, parentRoles: [String], siblingIndex: Int) {
            result[node.ref] = Locator(
                role: node.role,
                identifier: node.identifier,
                title: node.title,
                siblingIndex: siblingIndex,
                parentRoles: parentRoles
            )
            let childParentRoles = parentRoles + [node.role]
            var perRoleCount: [String: Int] = [:]
            for child in node.children {
                let index = perRoleCount[child.role, default: 0]
                perRoleCount[child.role] = index + 1
                visit(child, parentRoles: childParentRoles, siblingIndex: index)
            }
        }
        visit(root, parentRoles: [], siblingIndex: 0)
        return result
    }
}

public enum LocatorMatch: Equatable, Sendable {
    case resolved(String)        // a single confident ref
    case ambiguous([String])     // multiple plausible refs — caller must disambiguate
    case gone                    // no plausible match
}

public enum LocatorMatcher {
    public static func resolve(_ target: Locator, in root: ElementNode) -> LocatorMatch {
        let locators = LocatorCapture.all(in: root)

        // 1. Strongest signal: AXIdentifier (when present).
        if let identifier = target.identifier, !identifier.isEmpty {
            let matches = locators.filter { $0.value.role == target.role && $0.value.identifier == identifier }
            if matches.count == 1, let ref = matches.keys.first { return .resolved(ref) }
            if matches.count > 1 { return .ambiguous(matches.keys.sorted()) }
            // none by identifier → fall through to structural matching
        }

        let sameRole = locators.filter { $0.value.role == target.role }
        if sameRole.isEmpty { return .gone }

        // 2. Exact structural match: title + parent-chain + sibling index.
        let exact = sameRole.filter {
            $0.value.title == target.title
                && $0.value.parentRoles == target.parentRoles
                && $0.value.siblingIndex == target.siblingIndex
        }
        if exact.count == 1, let ref = exact.keys.first { return .resolved(ref) }
        if exact.count > 1 { return .ambiguous(exact.keys.sorted()) }

        // 3. Title-only fallback — resolve if unique, otherwise fail loud.
        if let title = target.title {
            let byTitle = sameRole.filter { $0.value.title == title }
            if byTitle.count == 1, let ref = byTitle.keys.first { return .resolved(ref) }
            if byTitle.count > 1 { return .ambiguous(byTitle.keys.sorted()) }
        }

        return .gone
    }
}
