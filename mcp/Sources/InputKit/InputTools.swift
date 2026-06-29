//
//  InputTools.swift
//  InputKit
//
//  Synthetic-input MCP tools (§8). Gate on CGPreflightPostEventAccess (post-event access,
//  surfaced as Accessibility — §3) via an injectable check so gating is testable without
//  posting. The actual posting fires only on a real call with access granted.
//

import CoreGraphics
import Foundation
import MacControlMCPCore

public enum InputTools {
    public static func all(
        canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
        settle: ActAndSettle? = nil
    ) -> [Tool] {
        [
            ClickTool(canPostEvents: canPostEvents, settle: settle),
            ScrollTool(canPostEvents: canPostEvents, settle: settle),
            KeyTool(canPostEvents: canPostEvents, settle: settle),
            HoverTool(canPostEvents: canPostEvents, settle: settle),
            DragTool(canPostEvents: canPostEvents, settle: settle)
        ]
    }
}

private let postEventError = #"{"error":"post_event_access_denied","howToFix":"Grant Accessibility to the host in System Settings ‣ Privacy & Security ‣ Accessibility (synthetic input rides this grant).","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"}"#

/// Schema fragments shared by every input tool so a caller can opt into act-and-settle (§6).
/// Functions (not global lets) to stay clear of Swift 6's shared-mutable-global rule for the
/// non-Sendable [String: Any] dictionaries.
private func observeProp() -> [String: Any] {
    ["type": "string", "enum": ["none", "settle"],
     "description": "settle = after posting, wait for `pid`'s UI to quiesce and return the diff (§6). Synthetic input lands a beat after posting, so prefer this over an immediate re-read."]
}
private func pidProp() -> [String: Any] {
    ["type": "integer", "description": "App to observe when observe=settle (its UI tree is diffed)."]
}

private func okJSON(_ extra: [String: Any]) -> String {
    var dict: [String: Any] = ["ok": true]
    for (key, value) in extra { dict[key] = value }
    do {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch { return #"{"ok":true}"# }
}

/// Posts an event, optionally wrapping it in act-and-settle (§6) when the caller passes
/// observe:"settle" + a target `pid` and the host injected a settle engine — returning the
/// post-action diff, mirroring the AX act verbs. Otherwise it's post-and-return (unchanged).
private func settledResult(_ settle: ActAndSettle?, _ arguments: [String: Any],
                           base: [String: Any], post: () -> Void) -> String {
    guard (arguments["observe"] as? String) == "settle",
          let settle, let pidValue = arguments["pid"] as? Int else {
        post()
        return okJSON(base)
    }
    let outcome = settle(pid_t(pidValue)) { post() }
    var dict: [String: Any] = ["ok": true]
    for (key, value) in base { dict[key] = value }
    dict["quiesced"] = outcome.quiesced
    dict["settledAfterMs"] = outcome.settledAfterMs
    dict["diff"] = [
        "added": outcome.diff.added,
        "removed": outcome.diff.removed,
        "changed": outcome.diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch { return okJSON(base) }
}

public struct ClickTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "click_point"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Synthetic mouse click at raw screen coordinates (global top-left). AVOID unless you have an explicit coordinate to hit — to click a UI element, use `click(ref)`, which targets the element and brings its app frontmost. Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "x": ["type": "number"], "y": ["type": "number"],
                    "button": ["type": "string", "enum": ["left", "right"]],
                    "count": ["type": "integer", "description": "1=single, 2=double, 3=triple."],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["x", "y"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let x = arguments["x"] as? NSNumber, let y = arguments["y"] as? NSNumber else {
            return #"{"error":"missing_coordinates"}"#
        }
        let rightButton = (arguments["button"] as? String) == "right"
        let count = (arguments["count"] as? Int) ?? 1
        return settledResult(settle, arguments, base: ["x": x.intValue, "y": y.intValue], post: {
            SyntheticInput.click(x: x.doubleValue, y: y.doubleValue, rightButton: rightButton, clickCount: count)
        })
    }
}

public struct ScrollTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "scroll"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Synthetic scroll wheel by pixel deltas (dy negative scrolls down). Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "dx": ["type": "integer"], "dy": ["type": "integer"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["dy"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let dy = arguments["dy"] as? Int else { return #"{"error":"missing_dy"}"# }
        let dx = (arguments["dx"] as? Int) ?? 0
        return settledResult(settle, arguments, base: ["dx": dx, "dy": dy], post: {
            SyntheticInput.scroll(dx: dx, dy: dy)
        })
    }
}

public struct KeyTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "key"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Synthetic key combo, e.g. \"cmd+s\", \"cmd+shift+z\", \"return\". Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "keys": ["type": "string"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["keys"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let keys = arguments["keys"] as? String else { return #"{"error":"missing_keys"}"# }
        guard let chord = KeyMap.parse(keys) else {
            return okJSON(["ok": false, "error": "unknown_key_combo", "keys": keys])
        }
        return settledResult(settle, arguments, base: ["keys": keys], post: {
            SyntheticInput.post(chord)
        })
    }
}

public struct HoverTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "hover"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Move the cursor to a screen point (triggers hover/tooltips) without clicking. Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "x": ["type": "number"], "y": ["type": "number"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["x", "y"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let x = arguments["x"] as? NSNumber, let y = arguments["y"] as? NSNumber else {
            return #"{"error":"missing_coordinates"}"#
        }
        return settledResult(settle, arguments, base: ["x": x.intValue, "y": y.intValue], post: {
            SyntheticInput.move(x: x.doubleValue, y: y.doubleValue)
        })
    }
}

public struct DragTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "drag"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Drag from one screen point to another (a swipe in the simulator). Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "fromX": ["type": "number"], "fromY": ["type": "number"],
                    "toX": ["type": "number"], "toY": ["type": "number"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["fromX", "fromY", "toX", "toY"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let fromX = arguments["fromX"] as? NSNumber, let fromY = arguments["fromY"] as? NSNumber,
              let toX = arguments["toX"] as? NSNumber, let toY = arguments["toY"] as? NSNumber else {
            return #"{"error":"missing_coordinates"}"#
        }
        return settledResult(settle, arguments, base: [:], post: {
            SyntheticInput.drag(fromX: fromX.doubleValue, fromY: fromY.doubleValue,
                                toX: toX.doubleValue, toY: toY.doubleValue)
        })
    }
}
