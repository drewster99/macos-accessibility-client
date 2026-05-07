//
//  Formatting.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import CoreGraphics
import Foundation

/// Shared formatters for rendering AX-derived values consistently across the UI.
nonisolated enum Formatting {
    /// `(x, y) WxH` with whole-number coordinates rounded for readability.
    static func frame(_ rect: CGRect) -> String {
        let x = Int(rect.origin.x.rounded())
        let y = Int(rect.origin.y.rounded())
        let w = Int(rect.size.width.rounded())
        let h = Int(rect.size.height.rounded())
        return "(\(x), \(y)) \(w)×\(h)"
    }

    /// Whole-number form when the value is integral, one-decimal otherwise.
    static func dimension(_ d: CGFloat) -> String {
        d.rounded() == d ? String(Int(d)) : String(format: "%.1f", Double(d))
    }
}

/// Builds a human-readable identifier for an `AXElement`. Mirrors the strategy used
/// in the tree, inspector header, and event-log element summaries so a given element
/// reads the same way wherever it appears.
nonisolated enum ElementLabel {
    /// "AXRole — Title" / "AXRole (Subrole)" / "<RoleDescription>" / "<unidentified>".
    /// Falls through richer attributes the more sparse the element is.
    static func long(for element: AXElement) -> String {
        let role = element.role?.nonEmptyOrNil
        let subrole = element.subrole?.nonEmptyOrNil
        let title = element.title?.nonEmptyOrNil
        let roleDescription = element.roleDescription?.nonEmptyOrNil
        let identifier = (try? element.attribute("AXIdentifier", as: String.self))?.nonEmptyOrNil

        let prefix: String
        if let role {
            prefix = subrole.map { "\(role) (\($0))" } ?? role
        } else if let roleDescription {
            prefix = "<\(roleDescription)>"
        } else {
            prefix = "<unidentified>"
        }

        if let title { return "\(prefix) — \(title)" }
        if let identifier { return "\(prefix) — id:\(identifier)" }
        return prefix
    }

    /// Compact form used in event-log rows — `<AXRole "title">` / `<AXRole>`.
    static func short(for element: AXElement) -> String {
        let role = element.role ?? "<unidentified>"
        if let title = element.title?.nonEmptyOrNil {
            return "<\(role) \"\(title)\">"
        }
        return "<\(role)>"
    }
}

nonisolated extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
