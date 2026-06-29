//
//  DebugLog.swift
//  HostKit
//
//  Append-only debug log shared by the relay and host processes (the two ends of the XPC
//  pipe). One unified file so a single timeline shows launch / connect / disconnect plus every
//  request and response in their entirety; each entry is tagged with the writing process + pid,
//  and an advisory lock (flock) around each write keeps the two processes from interleaving a
//  single entry. Logging never throws into the caller — IO failures are swallowed, since a
//  broken log must not break the relay or host.
//
//  Always on. `MACCONTROL_LOG=0` disables it; `MACCONTROL_LOG_PATH=/abs/file` redirects it.
//

import Foundation

public enum DebugLog {
    private static let queue = DispatchQueue(label: "com.nuclearcyborg.maccontrol.debuglog")

    /// 64 MiB, after which the current file is rotated to `…/maccontrol.log.1` (one generation).
    private static let capBytes: UInt64 = 64 * 1024 * 1024

    private static let enabled: Bool = ProcessInfo.processInfo.environment["MACCONTROL_LOG"] != "0"

    private static let tag: String =
        "\(ProcessInfo.processInfo.processName):\(ProcessInfo.processInfo.processIdentifier)"

    private static let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["MACCONTROL_LOG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacControlMCP", isDirectory: true)
            .appendingPathComponent("maccontrol.log")
    }()

    // Only ever touched inside `queue.sync`, so the shared (non-Sendable) formatter never races.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A one-line build identity for the *current* process: marketing version, build number, and
    /// the running executable's modification time. The binary mtime is the reliable discriminator —
    /// it changes on every recompile/re-sign — so a `launch` line tells you exactly which build came
    /// up (e.g. confirming a restarted host is the new one, not a stale on-demand instance).
    public static func buildIdentity() -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        var binaryBuilt = "unknown"
        if let path = Bundle.main.executablePath {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                if let modified = attributes[.modificationDate] as? Date {
                    binaryBuilt = formatter.string(from: modified)
                }
            } catch {
                // Executable mtime unavailable — leave "unknown".
            }
        }
        return "v\(version) build \(build) binary \(binaryBuilt)"
    }

    /// A lifecycle event: `launch`, `connect`, `disconnect`, … `message` is an optional detail line.
    public static func event(_ category: String, _ message: String = "") {
        write(kind: category.uppercased(), body: message)
    }

    /// A full inbound JSON-RPC request line, verbatim.
    public static func request(_ line: String) {
        write(kind: "REQUEST", body: line)
    }

    /// A full outbound JSON-RPC response, verbatim (`<nil>` when the host returned nothing).
    public static func response(_ line: String?) {
        write(kind: "RESPONSE", body: line ?? "<nil>")
    }

    private static func write(kind: String, body: String) {
        guard enabled else { return }
        queue.sync {
            let header = "==== \(timestampFormatter.string(from: Date())) [\(tag)] \(kind) ====\n"
            let entry = body.isEmpty ? header : header + body + "\n"
            append(Data(entry.utf8))
        }
    }

    /// Create-if-needed, rotate-if-large, then append under an exclusive advisory lock.
    private static func append(_ data: Data) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            rotateIfNeeded(fileManager)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { do { try handle.close() } catch { /* nothing actionable */ } }
            let descriptor = handle.fileDescriptor
            flock(descriptor, LOCK_EX)
            defer { flock(descriptor, LOCK_UN) }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // A logging failure must never disrupt the relay/host; drop the entry.
        }
    }

    private static func rotateIfNeeded(_ fileManager: FileManager) {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? UInt64, size > capBytes else { return }
            let rotated = fileURL.appendingPathExtension("1")
            if fileManager.fileExists(atPath: rotated.path) {
                try fileManager.removeItem(at: rotated)
            }
            try fileManager.moveItem(at: fileURL, to: rotated)
        } catch {
            // File absent or unrotatable — just keep appending to the current file.
        }
    }
}
