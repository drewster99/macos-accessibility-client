//
//  AXTools.swift
//  AXKit
//
//  AX-driving MCP read tools (P1). Permission is a first-class result (§3): without an
//  Accessibility grant each returns a structured `accessibility_not_granted` error. The
//  trust check is injectable so both branches are deterministically testable. All tools
//  share one AXSession (§4) so refs from a snapshot stay valid for element_detail.
//

import ApplicationServices
import CoreGraphics
import Foundation
import MacControlMCPCore

public enum AXTools {
    public static func all(
        session: AXSession,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) -> [Tool] {
        [
            UISnapshotTool(session: session, isTrusted: isTrusted),
            FindElementsTool(session: session, isTrusted: isTrusted),
            ElementDetailTool(session: session, isTrusted: isTrusted),
            FocusedElementTool(session: session, isTrusted: isTrusted),
            ElementAtTool(session: session, isTrusted: isTrusted),
            PerformActionTool(session: session, isTrusted: isTrusted),
            SetValueTool(session: session, isTrusted: isTrusted),
            SetFocusTool(session: session, isTrusted: isTrusted),
            RevealTool(session: session, isTrusted: isTrusted),
            WaitForTool(session: session, isTrusted: isTrusted),
            WindowTool(session: session, isTrusted: isTrusted),
            OpenMenuTool(session: session, isTrusted: isTrusted),
            GetChangesTool(session: session, isTrusted: isTrusted)
        ]
    }
}

private let permissionError = #"{"error":"accessibility_not_granted","howToFix":"Grant Accessibility to the host in System Settings ‣ Privacy & Security ‣ Accessibility","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"}"#

private func jsonString(_ object: Any) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch { return "null" }
}

private func frameValue(_ frame: CGRect?) -> Any {
    guard let frame else { return NSNull() }
    return ["x": Int(frame.origin.x), "y": Int(frame.origin.y), "w": Int(frame.width), "h": Int(frame.height)]
}

private func matchJSON(_ match: AXSession.Match) -> String {
    jsonString([
        "ref": match.ref,
        "role": match.role,
        "title": match.title ?? "",
        "identifier": match.identifier ?? "",
        "actions": match.actions,
        "frame": frameValue(match.frame)
    ])
}

private enum ElementResolution {
    case element(AXElement)
    case errorJSON(String)
}

/// Runs an act on an element, optionally wrapping it in act-and-settle (§6) when the caller
/// passes observe:"settle" — returning the post-action diff. Default is no settle (cheap).
private func actResult(
    _ session: AXSession,
    _ element: AXElement,
    observe: String?,
    base: [String: Any],
    perform: () -> Bool
) -> String {
    guard observe == "settle", let pid = element.pid else {
        var result = base
        result["ok"] = perform()
        return jsonString(result)
    }
    var ok = false
    let outcome = SettleEngine(session: session).actAndSettle(pid: pid) { ok = perform() }
    var result = base
    result["ok"] = ok
    result["quiesced"] = outcome.quiesced
    result["settledAfterMs"] = outcome.settledAfterMs
    result["diff"] = [
        "added": outcome.diff.added,
        "removed": outcome.diff.removed,
        "changed": outcome.diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
    ]
    return jsonString(result)
}

/// Resolve a ref to a live element, or an error-JSON string (stale_ref, with candidates
/// when ambiguous). Used by the act tools.
private func resolvedElement(_ session: AXSession, _ ref: String) -> ElementResolution {
    switch session.resolve(ref) {
    case .resolved(let element):
        return .element(element)
    case .ambiguous(let candidates):
        return .errorJSON(jsonString(["error": "stale_ref", "ref": ref, "candidates": candidates,
                                      "howToFix": "The element was rebuilt; disambiguate among the candidate refs."]))
    case .stale, .unknown:
        return .errorJSON(jsonString(["error": "stale_ref", "ref": ref,
                                      "howToFix": "Re-run ui_snapshot/find_elements to refresh refs."]))
    }
}

public struct UISnapshotTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "ui_snapshot"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Compact, depth-capped outline of an app's UI tree (interactable-filtered). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer", "description": "Target app pid (from list_apps)."],
                    "depth": ["type": "integer", "description": "Max tree depth (default 3)."],
                    "filter": ["type": "string", "enum": ["interactable", "all"]]
                ],
                "required": ["pid"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int else {
            return #"{"error":"missing_pid","howToFix":"Pass a pid from list_apps."}"#
        }
        let depth = (arguments["depth"] as? Int) ?? 3
        let filter: ElementOutline.Filter = (arguments["filter"] as? String == "all") ? .all : .interactable
        let node = session.snapshot(pid: pid_t(pidValue), maxDepth: depth)
        return ElementOutline.render(node, filter: filter)
    }
}

public struct FindElementsTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "find_elements"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Search an app's tree by role, title/value substring, exact AXIdentifier, and/or actionable-only; returns matches with refs + identifier. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "role": ["type": "string"],
                    "titleContains": ["type": "string"],
                    "identifier": ["type": "string", "description": "Exact AXIdentifier match — modern apps (e.g. Calculator) label controls here, not via title."],
                    "value": ["type": "string", "description": "Substring match on the element's AXValue."],
                    "actionable": ["type": "boolean", "description": "If true, keep only elements that advertise AX actions."],
                    "limit": ["type": "integer", "description": "Default 20."]
                ],
                "required": ["pid"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int else {
            return #"{"error":"missing_pid"}"#
        }
        let matches = session.find(
            pid: pid_t(pidValue),
            role: arguments["role"] as? String,
            titleContains: (arguments["titleContains"] as? String)?.lowercased(),
            identifier: arguments["identifier"] as? String,
            valueContains: (arguments["value"] as? String)?.lowercased(),
            actionable: arguments["actionable"] as? Bool,
            limit: (arguments["limit"] as? Int) ?? 20
        )
        let rows = matches.map { match -> [String: Any] in
            [
                "ref": match.ref,
                "role": match.role,
                "title": match.title ?? "",
                "identifier": match.identifier ?? "",
                "actions": match.actions,
                "frame": frameValue(match.frame)
            ]
        }
        return jsonString(rows)
    }
}

public struct ElementDetailTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "element_detail"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Full attributes/actions/parameterized-attributes for a ref from a prior snapshot or find. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["ref": ["type": "string"]],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String else {
            return #"{"error":"missing_ref"}"#
        }
        let element: AXElement
        switch session.resolve(ref) {
        case .resolved(let resolved):
            element = resolved
        case .ambiguous(let candidates):
            return jsonString(["error": "stale_ref", "ref": ref, "candidates": candidates,
                               "howToFix": "The element was rebuilt; disambiguate among the candidate refs."])
        case .stale, .unknown:
            return jsonString(["error": "stale_ref", "ref": ref,
                               "howToFix": "Re-run ui_snapshot/find_elements to refresh refs."])
        }
        let detail: [String: Any] = [
            "ref": ref,
            "role": element.role ?? "",
            "subrole": element.subrole ?? "",
            "identifier": element.identifier ?? "",
            "title": element.title ?? "",
            "value": element.value ?? "",
            "settable": element.isValueSettable,
            "actions": element.actions,
            "frame": frameValue(element.frame),
            "attributeNames": element.attributeNames,
            "parameterizedAttributes": element.parameterizedAttributeNames
        ]
        return jsonString(detail)
    }
}

public struct FocusedElementTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "focused_element"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "The system-wide focused UI element, with a ref. Requires Accessibility.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let match = session.focused() else { return #"{"error":"no_focused_element"}"# }
        return matchJSON(match)
    }
}

public struct ElementAtTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "element_at"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Hit-test the element at a screen point (top-left coordinates). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                "required": ["x", "y"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let x = arguments["x"] as? NSNumber, let y = arguments["y"] as? NSNumber else {
            return #"{"error":"missing_coordinates"}"#
        }
        guard let match = session.elementAt(x: x.floatValue, y: y.floatValue) else {
            return #"{"error":"no_element_at_position"}"#
        }
        return matchJSON(match)
    }
}

// MARK: - Act tools (effect-causing semantic AX; CGEvent synthetic input is a later layer)

public struct PerformActionTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "perform"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Perform an AX action (AXPress, AXShowMenu, AXIncrement, …) on a ref. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"], "action": ["type": "string"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref", "action"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String, let action = arguments["action"] as? String else {
            return #"{"error":"missing_ref_or_action"}"#
        }
        switch resolvedElement(session, ref) {
        case .element(let element):
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref, "action": action], perform: { element.perform(action) })
        case .errorJSON(let error):
            return error
        }
    }
}

public struct SetValueTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "set_value"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Set an element's AXValue (text/slider/etc.) — semantic, not keystrokes. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"], "value": ["type": "string"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref", "value"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String, let value = arguments["value"] as? String else {
            return #"{"error":"missing_ref_or_value"}"#
        }
        switch resolvedElement(session, ref) {
        case .element(let element):
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref], perform: { element.setValue(value) })
        case .errorJSON(let error):
            return error
        }
    }
}

public struct SetFocusTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "set_focus"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Make an element focused (no click). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String else { return #"{"error":"missing_ref"}"# }
        switch resolvedElement(session, ref) {
        case .element(let element):
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref], perform: { element.setFocused() })
        case .errorJSON(let error):
            return error
        }
    }
}

public struct RevealTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "reveal"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Scroll an element into view (kAXScrollToVisibleAction). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String else { return #"{"error":"missing_ref"}"# }
        switch resolvedElement(session, ref) {
        case .element(let element):
            // AXScrollToVisible is an AppKit NSAccessibility constant, not exported to
            // ApplicationServices; the underlying AX action name is the literal string.
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref], perform: { element.perform("AXScrollToVisible") })
        case .errorJSON(let error):
            return error
        }
    }
}

public struct WaitForTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "wait_for"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Actively poll an app until a condition holds (works without AX notifications). mode: idle | appears | disappears. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "mode": ["type": "string", "enum": ["idle", "appears", "disappears"]],
                    "role": ["type": "string"],
                    "titleContains": ["type": "string"],
                    "timeoutMs": ["type": "integer", "description": "Default 5000."],
                    "idleMs": ["type": "integer", "description": "Quiet window for mode=idle (default 400)."]
                ],
                "required": ["pid", "mode"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int, let mode = arguments["mode"] as? String else {
            return #"{"error":"missing_pid_or_mode"}"#
        }
        let role = arguments["role"] as? String
        let titleContains = (arguments["titleContains"] as? String)?.lowercased()
        let condition: WaitEngine.Condition
        switch mode {
        case "idle":
            condition = .idle(idleMs: (arguments["idleMs"] as? Int) ?? 400)
        case "appears":
            condition = .appears(role: role, titleContains: titleContains)
        case "disappears":
            condition = .disappears(role: role, titleContains: titleContains)
        default:
            return #"{"error":"unknown_mode"}"#
        }
        let timeout = (arguments["timeoutMs"] as? Int) ?? 5000
        let outcome = WaitEngine(session: session).wait(pid: pid_t(pidValue), condition: condition, timeoutMs: timeout)
        var result: [String: Any] = [
            "satisfied": outcome.satisfied,
            "waitedMs": outcome.waitedMs
        ]
        if let matchRef = outcome.matchRef {
            result["matchRef"] = matchRef
        } else {
            result["matchRef"] = NSNull()
        }
        return jsonString(result)
    }
}

public struct WindowTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "window"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Window management on a window ref via AX writes. action: move|resize|minimize|unminimize|raise. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "action": ["type": "string", "enum": ["move", "resize", "minimize", "unminimize", "raise"]],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "w": ["type": "number"], "h": ["type": "number"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref", "action"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String, let action = arguments["action"] as? String else {
            return #"{"error":"missing_ref_or_action"}"#
        }
        switch resolvedElement(session, ref) {
        case .element(let element):
            let op: () -> Bool
            switch action {
            case "move":
                guard let x = arguments["x"] as? NSNumber, let y = arguments["y"] as? NSNumber else {
                    return #"{"error":"missing_x_or_y"}"#
                }
                op = { element.setPosition(CGPoint(x: x.doubleValue, y: y.doubleValue)) }
            case "resize":
                guard let w = arguments["w"] as? NSNumber, let h = arguments["h"] as? NSNumber else {
                    return #"{"error":"missing_w_or_h"}"#
                }
                op = { element.setSize(CGSize(width: w.doubleValue, height: h.doubleValue)) }
            case "minimize": op = { element.setMinimized(true) }
            case "unminimize": op = { element.setMinimized(false) }
            case "raise": op = { element.raise() }
            default: return #"{"error":"unknown_action"}"#
            }
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref, "action": action], perform: op)
        case .errorJSON(let error):
            return error
        }
    }
}

public struct OpenMenuTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "open_menu"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Drive an app's menu bar by title path, e.g. [\"File\",\"Export…\",\"PDF…\"]. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "path": ["type": "array", "items": ["type": "string"]],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["pid", "path"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int, let path = arguments["path"] as? [String], !path.isEmpty else {
            return #"{"error":"missing_pid_or_path"}"#
        }
        let pid = pid_t(pidValue)
        guard arguments["observe"] as? String == "settle" else {
            let result = session.openMenu(pid: pid, path: path)
            return jsonString(["ok": result.ok, "message": result.message])
        }
        var result: (ok: Bool, message: String) = (false, "")
        let outcome = SettleEngine(session: session).actAndSettle(pid: pid) {
            result = session.openMenu(pid: pid, path: path)
        }
        return jsonString([
            "ok": result.ok,
            "message": result.message,
            "quiesced": outcome.quiesced,
            "settledAfterMs": outcome.settledAfterMs,
            "diff": [
                "added": outcome.diff.added,
                "removed": outcome.diff.removed,
                "changed": outcome.diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
            ]
        ])
    }
}

public struct GetChangesTool: Tool {
    private let session: AXSession
    private let isTrusted: @Sendable () -> Bool

    public init(session: AXSession, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "get_changes"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Diff the app's UI against the last get_changes/snapshot (added/removed/changed by ref). First call is the baseline. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["pid": ["type": "integer"], "depth": ["type": "integer"]],
                "required": ["pid"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int else { return #"{"error":"missing_pid"}"# }
        let depth = (arguments["depth"] as? Int) ?? 4
        let diff = session.getChanges(pid: pid_t(pidValue), maxDepth: depth)
        return jsonString([
            "added": diff.added,
            "removed": diff.removed,
            "changed": diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
        ])
    }
}
