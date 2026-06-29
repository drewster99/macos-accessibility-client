//
//  ControlWalker.swift
//  AXKit
//
//  Builds a render-ready `ControlNode` tree from live AX, global breadth-first across the
//  whole subtree, bounded by a wall-clock deadline (docs/CONTROL_APP_DESIGN.md §5). Whatever
//  the budget doesn't reach is left as a frontier with a `[N hidden]`/`[more hidden]` marker.
//  Collections render visible∪selected only; the rest is hidden (§10).
//

import ApplicationServices
import Foundation
import MacControlMCPCore

public enum ControlWalker {
    static let collectionRoles: Set<String> = ["AXTable", "AXOutline", "AXGrid", "AXList"]

    /// Mutable build node used during BFS; frozen to an immutable `ControlNode` at the end.
    private final class Build {
        let element: AXElement
        let ref: String
        let role: String
        let subrole: String?
        let label: String?
        let identifier: String?
        let textValue: String?
        let numericValue: Double?
        let minValue: Double?
        let maxValue: Double?
        let valueDescription: String?
        let url: String?
        let placeholder: String?
        let states: [String]
        let actions: [String]
        let disclosureLevel: Int?
        let rowCount: Int?
        let columnCount: Int?
        let columnTitles: [String]?
        var children: [Build] = []
        var hidden: HiddenCount = .none

        init(element: AXElement, ref: String, role: String, subrole: String?, label: String?,
             identifier: String?, textValue: String?, numericValue: Double?, minValue: Double?,
             maxValue: Double?, valueDescription: String?, url: String?, placeholder: String?,
             states: [String], actions: [String], disclosureLevel: Int?,
             rowCount: Int?, columnCount: Int?, columnTitles: [String]?) {
            self.element = element; self.ref = ref; self.role = role; self.subrole = subrole
            self.label = label; self.identifier = identifier; self.textValue = textValue
            self.numericValue = numericValue; self.minValue = minValue; self.maxValue = maxValue
            self.valueDescription = valueDescription; self.url = url; self.placeholder = placeholder
            self.states = states; self.actions = actions; self.disclosureLevel = disclosureLevel
            self.rowCount = rowCount; self.columnCount = columnCount; self.columnTitles = columnTitles
        }
    }

    /// Read one element's metadata + mint its ref. This is the heavy per-node AX cost (§8).
    private static func draft(_ element: AXElement, registry: ElementRegistry, pid: pid_t?) -> Build {
        let role = element.role ?? "AXUnknown"
        let subrole = element.subrole
        let label = [element.title, element.axDescription, element.help]
            .compactMap { $0 }.first(where: { !$0.isEmpty })
        let numeric = element.numericValue
        let textValue = numeric == nil ? element.value : nil

        var seen = Set<String>()
        var actions = element.rawActionNames
            .map { ActionVocab.displayLabel(forRaw: $0) }
            .filter { seen.insert($0).inserted }
        // Outline disclosure as a capability, not a state (§10) — only for actual rows (some
        // non-row elements spuriously expose AXDisclosing), and only when it's actually
        // performable: AXDisclosing is settable, or there's a disclosure-triangle child to press.
        let rowLike = role == "AXRow" || role == "AXOutlineRow" || subrole == "AXOutlineRow"
        if rowLike, let disclosing = element.isDisclosing,
           element.isDisclosingSettable || element.children.contains(where: { $0.role == "AXDisclosureTriangle" }) {
            actions.append(disclosing ? "collapse" : "disclose")
        }

        let isCollection = collectionRoles.contains(role)

        // {editable}: a settable *text* value — the signal that change_text / type(ref) has a real
        // target here. Gated on a present text value so we don't pay an extra settability IPC on the
        // (vast) majority of elements that carry no value; numeric range controls are already
        // self-evident via [min–max] + change_value, so they're deliberately not marked.
        var states = StateNames.render(element.booleanAttributes)
        if textValue != nil, element.isValueSettable { states.append("editable") }

        return Build(
            element: element,
            ref: registry.handle(for: element, pid: pid),
            role: role,
            subrole: subrole,
            label: label,
            identifier: element.identifier,
            textValue: textValue,
            numericValue: numeric,
            // Only real range controls (numeric AXValue) carry min/max — many Catalyst/bridged
            // elements spuriously expose AXMinValue/AXMaxValue=0, which would spam `[0–0]`.
            minValue: numeric != nil ? element.minValue : nil,
            maxValue: numeric != nil ? element.maxValue : nil,
            valueDescription: element.valueDescription,
            url: element.url,
            placeholder: element.placeholderValue,
            states: states,
            actions: actions,
            disclosureLevel: element.disclosureLevel,
            rowCount: isCollection ? element.rowCount : nil,
            columnCount: isCollection ? element.columnCount : nil,
            columnTitles: isCollection ? element.columnTitles : nil
        )
    }

    /// Hidden-count for a node we didn't expand: one cheap child-count read (§5).
    private static func frontierHidden(_ element: AXElement) -> HiddenCount {
        guard let count = element.childCount else { return .unknown }
        return count > 0 ? .known(count) : .none
    }

    /// The children to actually walk, plus the hidden-count this node should advertise.
    /// Collections yield visible∪selected with the remainder hidden; everything else yields
    /// its full `AXChildren` (root optionally filtered to one window).
    private static func childrenToWalk(
        _ node: Build, isRoot: Bool, windowFilter: String?
    ) -> ([AXElement], HiddenCount) {
        let element = node.element
        if collectionRoles.contains(node.role) {
            let visible = element.visibleRows ?? element.visibleCells ?? []
            let selected = element.selectedRows ?? element.selectedCells ?? []
            if !visible.isEmpty || !selected.isEmpty || element.rowCount != nil {
                var seen = Set<AXElement>()
                let union = (visible + selected).filter { seen.insert($0).inserted }
                let hidden: HiddenCount
                if let total = element.rowCount {
                    let remaining = total - union.count
                    hidden = remaining > 0 ? .known(remaining) : .none
                } else {
                    hidden = .unknown
                }
                return (union, hidden)
            }
            // No row/cell info — treat as an ordinary container.
        }
        let kids = element.children
        if isRoot, let windowFilter {
            // Keep the selected window + non-window children (e.g. the menu bar); drop other windows.
            return (kids.filter { $0.role != "AXWindow" || $0.title == windowFilter }, .none)
        }
        return (kids, .none)
    }

    private static func freeze(_ build: Build) -> ControlNode {
        ControlNode(
            ref: build.ref,
            type: RoleNames.humanize(role: build.role, subrole: build.subrole),
            label: build.label,
            identifier: build.identifier,
            textValue: build.textValue,
            numericValue: build.numericValue,
            minValue: build.minValue,
            maxValue: build.maxValue,
            valueDescription: build.valueDescription,
            url: build.url,
            placeholder: build.placeholder,
            states: build.states,
            actions: build.actions,
            disclosureLevel: build.disclosureLevel,
            rowCount: build.rowCount,
            columnCount: build.columnCount,
            columnTitles: build.columnTitles,
            hidden: build.hidden,
            children: build.children.map(freeze)
        )
    }

    /// Walk `root` to a `ControlNode` tree, global-BFS, bounded by `deadline`.
    public static func build(
        root: AXElement, registry: ElementRegistry, pid: pid_t?,
        deadline: Date, windowFilter: String? = nil
    ) -> ControlNode {
        let rootBuild = draft(root, registry: registry, pid: pid)
        // Guard against malformed AX trees (cycles / an element re-listed under multiple parents):
        // each element is walked at most once, so the queue can't inflate and burn the budget.
        var visited: Set<AXElement> = [root]
        var queue: [Build] = [rootBuild]
        var index = 0
        while index < queue.count {
            if Date() >= deadline { break }
            let node = queue[index]
            index += 1
            let (childElements, hidden) = childrenToWalk(node, isRoot: node === rootBuild, windowFilter: windowFilter)
            node.hidden = hidden
            for childElement in childElements where visited.insert(childElement).inserted {
                let child = draft(childElement, registry: registry, pid: pid)
                node.children.append(child)
                queue.append(child)
            }
        }
        // Everything still queued was never expanded → frontier; advertise its child count.
        for position in index..<queue.count {
            let node = queue[position]
            if case .none = node.hidden { node.hidden = frontierHidden(node.element) }
        }
        return freeze(rootBuild)
    }
}
