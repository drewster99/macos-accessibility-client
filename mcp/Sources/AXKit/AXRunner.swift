//
//  AXRunner.swift
//  AXKit
//
//  Runs blocking Accessibility XPC off Swift's cooperative pool (same rationale as the
//  app's Core/AXRunner). Every AXUIElementCopy… is a cross-process round-trip that can
//  stall, so we hop to a GCD global queue and bridge back via a continuation.
//

import Dispatch

public enum AXRunner {
    private static let queue = DispatchQueue.global(qos: .userInitiated)

    public static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
