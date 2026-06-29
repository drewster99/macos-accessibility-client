//
//  Tools.swift
//  MacControlMCP
//
//  P0b grant-free tools: list_running_apps (NSWorkspace) and list_simulators (simctl).
//  Neither needs an Accessibility/Screen-Recording grant, so they're testable now.
//

import Foundation
import AppKit

public protocol Tool {
    var name: String { get }
    /// MCP tool descriptor: { name, description, inputSchema }.
    var descriptor: [String: Any] { get }
    /// Run the tool and return a text payload (JSON string for these two).
    func call(_ arguments: [String: Any]) -> String
}

/// JSON helpers that avoid `try?` — failures degrade to a benign literal.
enum JSONText {
    static func from(_ object: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch { return "null" }
    }

    static func object(_ data: Data) -> Any? {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { return nil }
    }
}

/// Minimal subprocess runner for `simctl`. Returns stdout (empty on failure).
enum Shell {
    static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice   // discard — an undrained stderr pipe can deadlock the child
        do { try process.run() } catch { return "" }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a subprocess, returning exit status and combined stdout+stderr.
    static func runFull(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public struct ListAppsTool: Tool {
    public init() {}
    public let name = "list_running_apps"
    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "List running GUI apps (regular activation policy): pid, name, bundleId, frontmost.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        let rows = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { app -> [String: Any] in
                [
                    "pid": Int(app.processIdentifier),
                    "name": app.localizedName ?? "(unknown)",
                    "bundleId": app.bundleIdentifier ?? "",
                    "frontmost": app.isActive
                ]
            }
        return JSONText.from(rows)
    }
}

public struct ListSimulatorsTool: Tool {
    public init() {}
    public let name = "list_simulators"
    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "List booted simulators via simctl: udid, name, os, state.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        let output = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        guard let data = output.data(using: .utf8),
              let root = JSONText.object(data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return "[]" }

        var rows: [[String: Any]] = []
        for (runtime, value) in devices {
            guard let list = value as? [[String: Any]] else { continue }
            let os = runtime.components(separatedBy: "SimRuntime.").last?
                .replacingOccurrences(of: "-", with: " ") ?? runtime
            for device in list {
                rows.append([
                    "udid": device["udid"] as? String ?? "",
                    "name": device["name"] as? String ?? "",
                    "os": os,
                    "state": device["state"] as? String ?? ""
                ])
            }
        }
        return JSONText.from(rows)
    }
}
