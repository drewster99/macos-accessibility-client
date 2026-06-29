//
//  ElementRegistry.swift
//  AXKit
//
//  The §4 handle table. Refs are assigned by ELEMENT IDENTITY (CFEqual) so the same
//  element keeps its ref across snapshots — that stability is what makes the §6 diff
//  meaningful (unchanged elements compare equal by ref). Each ref also stores a Locator +
//  pid so a dead ref can be re-resolved against a fresh snapshot (best-effort, fail-loud).
//

import ApplicationServices
import CoreGraphics
import Foundation
import MacControlMCPCore

public final class ElementRegistry {
    private struct Stored {
        var element: AXElement
        var locator: Locator?
        var pid: pid_t?
    }

    private let allocator = RefAllocator()
    private var storage: [String: Stored] = [:]
    private var elementToRef: [AXElement: String] = [:]
    private var lastSnapshots: [pid_t: ElementNode] = [:]

    // control_app state (§ tree persistence): the last walked tree per app, and child→parent
    // ref links that power parent-climb stale recovery and incremental expand.
    private var controlTrees: [pid_t: ControlNode] = [:]
    private var controlParents: [String: String] = [:]

    public init() {}

    public struct Match: Sendable {
        public let ref: String
        public let role: String
        public let title: String?
        public let identifier: String?
        public let frame: CGRect?
        public let actions: [String]
    }

    public enum RefResolution {
        case resolved(AXElement)
        case ambiguous([String])   // candidate refs in a fresh snapshot
        case stale                 // issued but unrecoverable
        case unknown               // never issued
    }

    /// Identity-stable ref: the same element (CFEqual) always returns the same ref.
    private func ref(for element: AXElement, pid: pid_t?) -> String {
        if let existing = elementToRef[element] {
            storage[existing]?.element = element
            if let pid { storage[existing]?.pid = pid }
            return existing
        }
        let ref = allocator.next()
        elementToRef[element] = ref
        storage[ref] = Stored(element: element, locator: nil, pid: pid)
        return ref
    }

    /// Bound memory growth for long-lived sessions: when the handle table gets large, drop
    /// dead elements + their identity-map entries, and snapshots for exited pids. The
    /// (expensive) isAlive sweep is only paid once the table is actually large.
    private func pruneDeadHandlesIfLarge() {
        guard storage.count > 4000 else { return }
        // Iterate a SNAPSHOT (filter makes a new dictionary) so we never mutate `storage`
        // while iterating it.
        for (ref, stored) in storage.filter({ !$0.value.element.isAlive }) {
            elementToRef[stored.element] = nil
            controlParents[ref] = nil
            storage[ref] = nil
        }
        lastSnapshots = lastSnapshots.filter { kill($0.key, 0) == 0 }
        controlTrees = controlTrees.filter { kill($0.key, 0) == 0 }
    }

    private func match(_ ref: String, _ element: AXElement) -> Match {
        Match(ref: ref, role: element.role ?? "AXUnknown", title: element.title,
              identifier: element.identifier, frame: element.frame, actions: element.actions)
    }

    /// Pure match predicate for find_elements (§8), extracted so it's deterministically
    /// unit-testable without a live AX tree. `titleContains`/`valueContains` match
    /// case-insensitively and are expected pre-lowercased by the caller; `identifierFilter`
    /// matches `AXIdentifier` EXACTLY (modern apps — e.g. Calculator — label controls there,
    /// not via AXTitle); `actionable` (when true) keeps only elements that advertise actions.
    static func elementMatches(
        role: String?, title: String?, identifier: String?, value: String?, actions: [String],
        roleFilter: String?, titleContains: String?, identifierFilter: String?,
        valueContains: String?, actionable: Bool?
    ) -> Bool {
        if let roleFilter, role != roleFilter { return false }
        if let titleContains, !(title?.lowercased().contains(titleContains) ?? false) { return false }
        if let identifierFilter, identifier != identifierFilter { return false }
        if let valueContains, !(value?.lowercased().contains(valueContains) ?? false) { return false }
        if actionable == true, actions.isEmpty { return false }
        return true
    }

    /// Snapshot an app subtree with identity-stable refs, then attach each ref's locator.
    public func snapshot(pid: pid_t, maxDepth: Int) -> ElementNode {
        pruneDeadHandlesIfLarge()
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        let node = AXSnapshot.build(app, maxDepth: maxDepth) { self.ref(for: $0, pid: pid) }
        for (ref, locator) in LocatorCapture.all(in: node) where storage[ref] != nil {
            storage[ref]?.locator = locator
        }
        return node
    }

    /// Poll-based change feed: diff a fresh snapshot against the last one this session
    /// returned for the pid. The first call establishes the baseline (empty diff). Works
    /// without AX notifications, and the stable refs make the diff meaningful (§6).
    public func getChanges(pid: pid_t, maxDepth: Int) -> ElementDiff {
        let fresh = snapshot(pid: pid, maxDepth: maxDepth)
        let diff = lastSnapshots[pid].map { Diff.compute(old: $0, new: fresh) } ?? ElementDiff()
        lastSnapshots[pid] = fresh
        return diff
    }

    /// Register a single element (find/focused/at), identity-stable.
    @discardableResult
    public func register(_ element: AXElement) -> Match {
        match(ref(for: element, pid: element.pid), element)
    }

    public func element(for ref: String) -> AXElement? { storage[ref]?.element }

    /// Mint (or reuse) an identity-stable ref for an element — the control_app walk's entry
    /// point into the handle table. Same element (CFEqual) always returns the same ref.
    @discardableResult
    public func handle(for element: AXElement, pid: pid_t?) -> String {
        ref(for: element, pid: pid)
    }

    // MARK: - control_app tree persistence

    /// Store the freshly-walked tree for a pid and merge its parent links.
    public func storeControlTree(_ tree: ControlNode, pid: pid_t) {
        controlTrees[pid] = tree
        for (child, parent) in ControlTree.parentLinks(of: tree) { controlParents[child] = parent }
    }

    /// The persisted node for a ref (from its app's stored tree), if any.
    public func controlNode(for ref: String) -> ControlNode? {
        guard let pid = storage[ref]?.pid, let tree = controlTrees[pid] else { return nil }
        return ControlTree.find(ref, in: tree)
    }

    /// Splice an updated subtree for `ref` back into its app's stored tree.
    public func updateControlTree(ref: String, subtree: ControlNode) {
        guard let pid = storage[ref]?.pid, let tree = controlTrees[pid] else { return }
        controlTrees[pid] = ControlTree.replacingSubtree(ref, in: tree, with: subtree)
        for (child, parent) in ControlTree.parentLinks(of: subtree) { controlParents[child] = parent }
    }

    /// Nearest live element at or above `ref`, climbing persisted parent links (§ stale
    /// recovery). Returns the element and the ref it was found at (== `ref` when alive).
    public func liveAncestor(of ref: String) -> (element: AXElement, ref: String)? {
        var current: String? = ref
        while let r = current {
            if let element = storage[r]?.element, element.isAlive { return (element, r) }
            current = controlParents[r]
        }
        return nil
    }

    /// The parent ref of `ref` in the persisted tree, if known.
    public func parentRef(of ref: String) -> String? { controlParents[ref] }

    /// Nearest window/dialog/sheet ancestor of `ref` (for a post-navigation `refresh:"window"`),
    /// or nil if `ref` isn't under one in a stored tree.
    public func windowAncestor(of ref: String) -> String? {
        let windowTypes: Set<String> = ["window", "dialog", "sheet"]
        var current: String? = ref
        while let r = current {
            if let node = controlNode(for: r), windowTypes.contains(node.type) { return r }
            current = controlParents[r]
        }
        return nil
    }

    /// Evict trees/handles for apps that have exited — junk data once the pid is gone.
    public func evictDeadApps() {
        let deadPids = Set(controlTrees.keys.filter { kill($0, 0) != 0 })
        guard !deadPids.isEmpty else { return }
        for pid in deadPids {
            controlTrees[pid] = nil
            lastSnapshots[pid] = nil
        }
        // Iterate a SNAPSHOT (filter makes a new dictionary) so we never mutate `storage` while
        // iterating it (same hazard guarded against in pruneDeadHandlesIfLarge).
        for (ref, stored) in storage.filter({ deadPids.contains($0.value.pid ?? -1) }) {
            elementToRef[stored.element] = nil
            controlParents[ref] = nil
            storage[ref] = nil
        }
    }

    /// Resolve a ref to a live element, re-resolving via its locator if the element died.
    public func resolve(_ ref: String) -> RefResolution {
        guard let stored = storage[ref] else { return .unknown }
        if stored.element.isAlive { return .resolved(stored.element) }
        guard let locator = stored.locator, let pid = stored.pid else { return .stale }

        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        var fresh: [String: AXElement] = [:]
        let freshTree = AXSnapshot.build(app, maxDepth: 8) { element in
            let tempRef = "t\(fresh.count)"
            fresh[tempRef] = element
            return tempRef
        }
        switch LocatorMatcher.resolve(locator, in: freshTree) {
        case .resolved(let tempRef):
            guard let element = fresh[tempRef] else { return .stale }
            // Re-bind the ORIGINAL ref to the live element so future calls hit the cache,
            // instead of allocating a fresh ref and re-resolving (slow) on every call. Drop the
            // dead element's identity-map entry first, or it leaks (it's no longer in storage,
            // so neither prune sweep can ever reach it).
            elementToRef[stored.element] = nil
            storage[ref] = Stored(element: element, locator: locator, pid: pid)
            elementToRef[element] = ref
            return .resolved(element)
        case .ambiguous(let tempRefs):
            let candidates = tempRefs.compactMap { fresh[$0] }.map { register($0).ref }
            return .ambiguous(candidates)
        case .gone:
            return .stale
        }
    }

    public func find(pid: pid_t, role: String?, titleContains: String?,
                     identifier: String? = nil, valueContains: String? = nil, actionable: Bool? = nil,
                     limit: Int, maxDepth: Int = 12) -> [Match] {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        var results: [Match] = []

        func matches(_ element: AXElement) -> Bool {
            ElementRegistry.elementMatches(
                role: element.role, title: element.title, identifier: element.identifier,
                value: element.value, actions: element.actions,
                roleFilter: role, titleContains: titleContains, identifierFilter: identifier,
                valueContains: valueContains, actionable: actionable)
        }

        func visit(_ element: AXElement, depth: Int) {
            if results.count >= limit { return }
            if matches(element) {
                results.append(match(ref(for: element, pid: pid), element))
            }
            if depth < maxDepth {
                for child in element.children {
                    if results.count >= limit { return }
                    visit(child, depth: depth + 1)
                }
            }
        }

        visit(app, depth: 0)
        return results
    }

    public func focused() -> Match? {
        let systemWide = AXElement.systemWide()
        systemWide.setMessagingTimeout(1)
        guard let element = systemWide.focusedElement else { return nil }
        return register(element)
    }

    public func elementAt(x: Float, y: Float) -> Match? {
        let systemWide = AXElement.systemWide()
        systemWide.setMessagingTimeout(1)
        guard let element = systemWide.elementAtPosition(x: x, y: y) else { return nil }
        return register(element)
    }

    /// Drive an app's menu bar by title path ("File" → "Export…" → "PDF…"), pressing each
    /// level so lazy submenus populate before descending.
    public func openMenu(pid: pid_t, path: [String]) -> (ok: Bool, message: String) {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        guard let menuBar = app.menuBar else { return (false, "no menu bar") }
        var current = menuBar
        for title in path {
            guard let match = Self.findMenuChild(in: current, title: title) else {
                return (false, "menu item not found: \(title)")
            }
            if !match.perform("AXPress") { return (false, "AXPress failed on: \(title)") }
            Thread.sleep(forTimeInterval: 0.15)
            current = match
        }
        return (true, "opened: \(path.joined(separator: " > "))")
    }

    /// Finds a child menu item by title — handles both the menu bar (AXMenuBarItem children)
    /// and a submenu (an AXMenu child whose children are AXMenuItems).
    private static func findMenuChild(in element: AXElement, title: String) -> AXElement? {
        for child in element.children {
            guard let role = child.role else { continue }
            if (role == "AXMenuBarItem" || role == "AXMenuItem"), child.title == title {
                return child
            }
            if role == "AXMenu" {
                for item in child.children where item.title == title { return item }
            }
        }
        return nil
    }
}
