//
//  Formatting.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import CoreGraphics
import Foundation
import os

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

    /// Single shared `HH:mm:ss.SSS` formatter used by every log row in the UI.
    /// `DateFormatter` is heavyweight enough that allocating one per row body
    /// re-evaluation shows up under scroll; cache it once.
    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Builds a human-readable identifier for an `AXElement`. Both forms are async —
/// they hop to `AXRunner` so the multi-attribute read happens off-main and
/// off-cooperative-pool, then format and return the string. Each call costs
/// exactly one hop (all the reads run back-to-back on the AX queue).
nonisolated enum ElementLabel {
    /// "AXRole — Title" / "AXRole (Subrole)" / "<RoleDescription>" / "<unidentified>".
    /// Falls through richer attributes the more sparse the element is.
    static func long(for element: AXElement) async -> String {
        await AXRunner.run { Self.longSync(for: element) }
    }

    /// Sync form for callers that are already on `AXRunner.run` or another
    /// off-cooperative-pool context (e.g. inside an AX-observer notification
    /// callback that has hopped onto the AX queue itself).
    static func longSync(for element: AXElement) -> String {
        let role = element.syncRole()?.nonEmptyOrNil
        let subrole = element.syncSubrole()?.nonEmptyOrNil
        let title = element.syncTitle()?.nonEmptyOrNil
        let roleDescription = element.syncRoleDescription()?.nonEmptyOrNil
        let identifier: String? = {
            do {
                return try element.syncAttribute("AXIdentifier", as: String.self)?.nonEmptyOrNil
            } catch {
                AppLog.ax.debug("AXIdentifier read failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }()

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
    static func short(for element: AXElement) async -> String {
        await AXRunner.run { Self.shortSync(for: element) }
    }

    /// Sync sibling of `short`; safe inside an `AXRunner.run` block.
    static func shortSync(for element: AXElement) -> String {
        let role = element.syncRole() ?? "<unidentified>"
        if let title = element.syncTitle()?.nonEmptyOrNil {
            return "<\(role) \"\(title)\">"
        }
        return "<\(role)>"
    }
}

nonisolated extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
