//
//  Screenshot.swift
//  CaptureKit
//
//  P2 screenshots (§7): ScreenCaptureKit in-process for the Mac display, `simctl` for the
//  simulator framebuffer. Screen Recording is a first-class result (§3) — Mac targets gate
//  on CGPreflightScreenCaptureAccess. The trust check is injectable for deterministic tests.
//  The async SCScreenshotManager call is bridged to the synchronous Tool.call via a
//  semaphore (acceptable for the one-request-at-a-time CLI; the host will be async).
//

import AppKit
import CoreGraphics
import Foundation
import MacControlMCPCore
import ScreenCaptureKit

public struct ScreenshotTool: Tool {
    private let hasScreenRecording: @Sendable () -> Bool

    public init(hasScreenRecording: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.hasScreenRecording = hasScreenRecording
    }

    public let name = "screenshot"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Capture a PNG and return its file path. target: screen (ScreenCaptureKit, needs Screen Recording) or simulator (simctl, no grant).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "enum": ["screen", "simulator"]],
                    "udid": ["type": "string", "description": "Simulator UDID (defaults to first booted)."],
                    "maxDimension": ["type": "integer", "description": "Downscale longest side to this many px."]
                ],
                "required": ["target"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        switch arguments["target"] as? String {
        case "simulator":
            return captureSimulator(requestedUDID: arguments["udid"] as? String)
        case "screen":
            guard hasScreenRecording() else {
                return #"{"error":"screen_recording_not_granted","howToFix":"Grant Screen Recording to the host in System Settings ‣ Privacy & Security ‣ Screen Recording","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"}"#
            }
            return captureScreen(maxDimension: arguments["maxDimension"] as? Int)
        default:
            return #"{"error":"unsupported_target","howToFix":"Use target screen or simulator."}"#
        }
    }

    // MARK: - Screen (ScreenCaptureKit)

    private func captureScreen(maxDimension: Int?) -> String {
        do {
            let image = try CaptureSupport.captureMainDisplay(maxDimension: maxDimension)
            let path = CaptureSupport.screenshotPath(prefix: "screen")
            try CaptureSupport.writePNG(image, to: path)
            return CaptureSupport.json(["path": path, "width": image.width, "height": image.height])
        } catch {
            return CaptureSupport.json(["error": "capture_failed", "detail": "\(error)"])
        }
    }

    // MARK: - Simulator (simctl)

    private func captureSimulator(requestedUDID: String?) -> String {
        let udid: String
        if let requestedUDID, !requestedUDID.isEmpty {
            udid = requestedUDID
        } else if let booted = CaptureSupport.firstBootedSimulatorUDID() {
            udid = booted
        } else {
            return #"{"error":"no_booted_simulator","howToFix":"Boot a simulator or pass udid (see list_simulators)."}"#
        }
        let path = CaptureSupport.screenshotPath(prefix: "simulator")
        let status = CaptureSupport.runProcessStatus("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", path])
        if status == 0, FileManager.default.fileExists(atPath: path) {
            return CaptureSupport.json(["path": path, "udid": udid])
        }
        return CaptureSupport.json(["error": "simulator_capture_failed", "udid": udid])
    }
}

enum CaptureError: Error { case noDisplay, captureFailed, encodeFailed }

enum CaptureSupport {
    private final class ResultBox: @unchecked Sendable {
        var image: CGImage?
        var error: Error?
    }

    static func captureMainDisplay(maxDimension: Int?) throws -> CGImage {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else { throw CaptureError.noDisplay }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let longest = max(display.width, display.height)
                if let maxDimension, maxDimension > 0, longest > maxDimension {
                    let scale = Double(maxDimension) / Double(longest)
                    config.width = Int(Double(display.width) * scale)
                    config.height = Int(Double(display.height) * scale)
                } else {
                    config.width = display.width
                    config.height = display.height
                }
                box.image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        // Bounded wait — a hung capture path must not block the host (which serializes
        // requests) indefinitely.
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            throw CaptureError.captureFailed
        }
        if let image = box.image { return image }
        throw box.error ?? CaptureError.captureFailed
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CaptureError.encodeFailed }
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func screenshotPath(prefix: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix)_\(UUID().uuidString).png")
    }

    static func firstBootedSimulatorUDID() -> String? {
        let output = shellOutput("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        guard let data = output.data(using: .utf8),
              let root = jsonObject(data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return nil }
        for (_, value) in devices {
            if let list = value as? [[String: Any]], let udid = list.first?["udid"] as? String {
                return udid
            }
        }
        return nil
    }

    static func json(_ object: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch { return "null" }
    }

    static func jsonObject(_ data: Data) -> Any? {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { return nil }
    }

    static func runProcessStatus(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        // Status-only: discard output to null devices so a full pipe can't deadlock the child.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func shellOutput(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice   // discard — undrained stderr pipe can deadlock
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
