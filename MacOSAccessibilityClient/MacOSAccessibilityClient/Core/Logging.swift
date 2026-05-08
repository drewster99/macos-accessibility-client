//
//  Logging.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import Foundation
import os

/// Centralised `Logger` instances per subsystem area so the Console.app subsystem
/// filter (`com.nuclearcyborg.MacOSAccessibilityClient`) and Xcode's category column
/// give a clean breakdown of where each line came from.
///
/// Levels in use:
/// - `.info`  — instrumentation timings, subscribe/unsubscribe counts.
/// - `.notice` — slow operations crossing a threshold worth eyeballing.
/// - `.error` — failed AX calls that meant "we couldn't read what we expected."
nonisolated enum AppLog {
    static let subsystem = "com.nuclearcyborg.MacOSAccessibilityClient"

    static let session = Logger(subsystem: subsystem, category: "session")
    static let subscription = Logger(subsystem: subsystem, category: "subscription")
    static let snapshot = Logger(subsystem: subsystem, category: "snapshot")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let tree = Logger(subsystem: subsystem, category: "tree")
}

/// Times a synchronous block and logs the duration. Returns whatever the block
/// returned. The label is interpolated as public so it's actually visible in
/// Console.app rather than being redacted.
@discardableResult
nonisolated func timed<T>(_ label: String, on logger: Logger, body: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try body()
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    logger.info("\(label, privacy: .public) — \(ms, format: .fixed(precision: 2), privacy: .public) ms")
    return result
}

/// Same as `timed` but for async bodies.
@discardableResult
nonisolated func timed<T>(_ label: String, on logger: Logger, body: () async throws -> T) async rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try await body()
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    logger.info("\(label, privacy: .public) — \(ms, format: .fixed(precision: 2), privacy: .public) ms")
    return result
}
