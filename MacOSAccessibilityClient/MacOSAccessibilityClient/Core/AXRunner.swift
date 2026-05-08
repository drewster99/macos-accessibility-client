//
//  AXRunner.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import Dispatch
import Foundation

/// Runs synchronous Accessibility API calls off Swift's cooperative thread pool.
///
/// Every `AXUIElementCopy…` call is a cross-process XPC round-trip to the target
/// app. They can block for seconds when the target is paused, swamped, or simply
/// has a large response (e.g. enumerating an iOS-bridged subtree). Running that
/// kind of blocking work on the cooperative thread pool starves other Tasks; on
/// the main actor it freezes the UI. Both are bad.
///
/// GCD's global concurrent queues are the right place for blocking work — they
/// grow threads as needed and don't compete with the cooperative pool. We hop
/// onto a `userInitiated` global queue and bridge the result back via
/// `withCheckedThrowingContinuation`.
///
/// Cutoff that drove this design: anything ≳5 ms of blocking work shouldn't be
/// on the cooperative pool. AX reads routinely cross that bar.
nonisolated enum AXRunner {
    /// Concurrent global queue. Many AX reads can be in-flight to the same target
    /// at once; the kernel-side AX hub serialises per-target where it matters.
    private static let queue = DispatchQueue.global(qos: .userInitiated)

    /// Run a throwing synchronous AX block on the AX queue. Returns when the block
    /// completes. The caller's actor is suspended for the duration (good — no main
    /// thread blocking) but the cooperative pool isn't tied up doing the wait.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try body())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Non-throwing variant.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            queue.async {
                cont.resume(returning: body())
            }
        }
    }
}
