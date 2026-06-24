//
//  Sim.swift
//  MacControlMCPCore
//
//  The simulator device suite (§5/§8 P5) via `xcrun simctl`. No TCC grant. `udid` defaults
//  to the booted device. Each action returns { ok, output } or { ok:false, error }.
//

import Foundation

public struct SimTool: Tool {
    public init() {}

    public let name = "sim"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Drive a simulator via simctl: openurl/appearance/statusbar/statusbar_clear/launch/terminate/pbpaste. udid defaults to the booted device. No grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["openurl", "appearance", "statusbar", "statusbar_clear", "launch", "terminate", "pbpaste"]],
                    "udid": ["type": "string", "description": "Defaults to the booted device."],
                    "url": ["type": "string"],
                    "value": ["type": "string", "description": "dark|light for appearance."],
                    "bundleId": ["type": "string"]
                ],
                "required": ["action"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard let action = arguments["action"] as? String else {
            return JSONText.from(["error": "missing_action"])
        }
        let udid = (arguments["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "booted"

        let simctlArgs: [String]
        switch action {
        case "openurl":
            guard let url = arguments["url"] as? String else { return JSONText.from(["error": "missing_url"]) }
            simctlArgs = ["simctl", "openurl", udid, url]
        case "appearance":
            guard let value = arguments["value"] as? String else { return JSONText.from(["error": "missing_value"]) }
            simctlArgs = ["simctl", "ui", udid, "appearance", value]
        case "statusbar":
            simctlArgs = ["simctl", "status_bar", udid, "override",
                          "--time", "9:41", "--batteryState", "charged",
                          "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"]
        case "statusbar_clear":
            simctlArgs = ["simctl", "status_bar", udid, "clear"]
        case "launch":
            guard let bundleId = arguments["bundleId"] as? String else { return JSONText.from(["error": "missing_bundleId"]) }
            simctlArgs = ["simctl", "launch", udid, bundleId]
        case "terminate":
            guard let bundleId = arguments["bundleId"] as? String else { return JSONText.from(["error": "missing_bundleId"]) }
            simctlArgs = ["simctl", "terminate", udid, bundleId]
        case "pbpaste":
            simctlArgs = ["simctl", "pbpaste", udid]
        default:
            return JSONText.from(["error": "unknown_action", "action": action])
        }

        let result = Shell.runFull("/usr/bin/xcrun", simctlArgs)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0 {
            return JSONText.from(["ok": true, "action": action, "output": output])
        }
        return JSONText.from(["ok": false, "action": action, "error": output])
    }
}
