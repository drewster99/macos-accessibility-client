//
//  Quiescence.swift
//  MacControlMCP
//
//  The timing core of the hybrid settle from §6 of docs/MCP_DESIGN.md. After an action,
//  the host collects "something changed" timestamps from BOTH the observer journal and
//  the active structural poll; this decides when the UI has settled. Deterministic and
//  injectable (times in ms from the action), so it needs no AX grant to test.
//

import Foundation

public struct QuiescenceConfig: Sendable, Equatable {
    /// Quiet window (no structural change) that declares "settled".
    public var idleMs: Int
    /// Quiet-phase ceiling — once something changes, wait at most this long for it to go quiet
    /// (perpetual motion — spinners/video — returns here with quiesced=false).
    public var capMs: Int
    /// First-change ceiling — how long to wait for the action's effect to even BEGIN before
    /// concluding it had none. Guards slow apps (e.g. Mail opening a window) where nothing has
    /// happened yet at idleMs, which the old logic mistook for "already settled".
    public var firstChangeMs: Int

    public init(idleMs: Int = 400, capMs: Int = 3000, firstChangeMs: Int = 3000) {
        self.idleMs = idleMs
        self.capMs = capMs
        self.firstChangeMs = firstChangeMs
    }
}

public struct SettleResult: Equatable, Sendable {
    /// Milliseconds from the action at which we declared the UI settled.
    public let settledAtMs: Int
    /// True if settled by reaching a quiet window; false if it hit the cap still changing.
    public let quiesced: Bool
}

public enum Quiescence {
    /// `changes` are ms-from-action timestamps at which *anything* changed (observer
    /// notification or structural-poll delta). Returns the first quiet window of length
    /// `idleMs`, or the cap if activity never stops.
    public static func settle(changes: [Int], config: QuiescenceConfig = QuiescenceConfig()) -> SettleResult {
        let cap = config.capMs
        let idle = config.idleMs
        let sorted = changes.filter { $0 >= 0 && $0 <= cap }.sorted()

        var lastChange = 0   // t=0 is the action itself
        for time in sorted {
            // A gap of >= idle before this change means the UI was already quiet — settle
            // at the end of that quiet window and stop (later changes are "after settle").
            if time - lastChange >= idle {
                let settledAt = lastChange + idle
                return SettleResult(settledAtMs: min(settledAt, cap), quiesced: settledAt <= cap)
            }
            lastChange = time
        }

        let settledByIdle = lastChange + idle
        if settledByIdle <= cap {
            return SettleResult(settledAtMs: settledByIdle, quiesced: true)
        }
        return SettleResult(settledAtMs: cap, quiesced: false)
    }
}
