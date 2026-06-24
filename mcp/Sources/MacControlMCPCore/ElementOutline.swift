//
//  ElementOutline.swift
//  MacControlMCP
//
//  The compact, token-efficient serialization from §9 of docs/MCP_DESIGN.md. Pure
//  logic over a tree model: AXKit will populate `ElementNode` from real AXElements,
//  but the serializer (and its tests) need no Accessibility grant.
//

import CoreGraphics
import Foundation

/// Collapse newlines so a multi-line title/value/action can never break the line-based
/// outline (each element must stay on one line). Other content is returned unchanged.
private func singleLine(_ text: String) -> String {
    guard text.contains(where: { $0.isNewline }) else { return text }
    return text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
}

/// A frozen node in a UI snapshot. The `ref` is the session-scoped handle the model
/// uses to address this element in later calls.
public struct ElementNode: Equatable, Sendable {
    public let ref: String
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    public let value: String?
    public let frame: CGRect?
    public let actions: [String]
    public let settable: Bool
    public let children: [ElementNode]

    public init(
        ref: String,
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        value: String? = nil,
        frame: CGRect? = nil,
        actions: [String] = [],
        settable: Bool = false,
        children: [ElementNode] = []
    ) {
        self.ref = ref
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.frame = frame
        self.actions = actions
        self.settable = settable
        self.children = children
    }

    /// "Worth showing on its own line" — actionable, settable, or carrying a label/value.
    /// Pure decoration (unlabeled containers) is what gets collapsed under the filter.
    var isInteractable: Bool {
        !actions.isEmpty
            || settable
            || (title.map { !$0.isEmpty } ?? false)
            || (value.map { !$0.isEmpty } ?? false)
    }

    /// One-line summary used by the outline (uncollapsed) and the diff's add rows.
    public func summaryLine() -> String {
        var parts = [ref, role]
        if let subrole, !subrole.isEmpty { parts.append(subrole) }
        if let title, !title.isEmpty { parts.append("\"\(singleLine(title))\"") }
        if let frame { parts.append("[\(Int(frame.width))×\(Int(frame.height))]") }
        if !actions.isEmpty { parts.append("(" + actions.map(singleLine).joined(separator: ",") + ")") }
        if settable { parts.append("(settable)") }
        if let value, !value.isEmpty { parts.append("value:\"\(singleLine(value))\"") }
        return parts.joined(separator: " ")
    }
}

public enum ElementOutline {
    public enum Filter: Sendable { case interactable, all }

    /// Render an indented outline. Under `.interactable`, decorative subtrees with no
    /// interactable descendant collapse to `×N children…` (expandable later by ref).
    public static func render(_ root: ElementNode, filter: Filter = .interactable) -> String {
        var lines: [String] = []
        emit(root, depth: 0, filter: filter, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func emit(_ node: ElementNode, depth: Int, filter: Filter, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        let collapse = filter == .interactable
            && !node.isInteractable
            && !node.children.isEmpty
            && !hasInteractableDescendant(node)
        if collapse {
            lines.append(pad + summary(node, collapsedChildren: node.children.count))
            return
        }
        lines.append(pad + summary(node, collapsedChildren: nil))
        for child in node.children {
            emit(child, depth: depth + 1, filter: filter, into: &lines)
        }
    }

    private static func hasInteractableDescendant(_ node: ElementNode) -> Bool {
        for child in node.children {
            if child.isInteractable || hasInteractableDescendant(child) { return true }
        }
        return false
    }

    private static func summary(_ node: ElementNode, collapsedChildren: Int?) -> String {
        guard let count = collapsedChildren else { return node.summaryLine() }
        var parts = [node.ref, node.role]
        if let subrole = node.subrole, !subrole.isEmpty { parts.append(subrole) }
        if let title = node.title, !title.isEmpty { parts.append("\"\(singleLine(title))\"") }
        if let frame = node.frame {
            parts.append("[\(Int(frame.width))×\(Int(frame.height))]")
        }
        parts.append("×\(count) children…")
        return parts.joined(separator: " ")
    }
}
