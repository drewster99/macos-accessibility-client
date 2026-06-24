//
//  SettleEngine.swift
//  AXKit
//
//  The §6 hybrid settle, live: snapshot → act → poll a depth-limited structural signature
//  until it stabilizes (observer-independent, so it works for Electron/web/simulator) →
//  re-snapshot and diff. Reuses the unit-tested Quiescence + Diff. The action closure is
//  caller-supplied; for read-only "settle on nothing" it's a no-op.
//

import ApplicationServices
import Foundation
import MacControlMCPCore

public final class SettleEngine {
    private let session: AXSession

    public init(session: AXSession) {
        self.session = session
    }

    public struct SettleOutcome: Sendable {
        public let quiesced: Bool
        public let settledAfterMs: Int
        public let diff: ElementDiff
    }

    private func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    public func actAndSettle(
        pid: pid_t,
        maxDepth: Int = 4,
        config: QuiescenceConfig = QuiescenceConfig(),
        pollIntervalMs: Int = 100,
        action: () -> Void
    ) -> SettleOutcome {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)

        let before = session.snapshot(pid: pid, maxDepth: maxDepth)
        var lastSignature = AXSnapshot.structuralSignature(of: app, maxDepth: maxDepth)

        action()

        var changeTimes: [Int] = []
        let start = nowMs()
        var elapsed = 0
        while elapsed < config.capMs {
            Thread.sleep(forTimeInterval: Double(pollIntervalMs) / 1000.0)
            elapsed = nowMs() - start
            let signature = AXSnapshot.structuralSignature(of: app, maxDepth: maxDepth)
            if signature != lastSignature {
                changeTimes.append(elapsed)
                lastSignature = signature
            }
            let lastChange = changeTimes.last ?? 0
            if elapsed - lastChange >= config.idleMs { break }
        }

        let after = session.snapshot(pid: pid, maxDepth: maxDepth)
        let settle = Quiescence.settle(changes: changeTimes, config: config)
        return SettleOutcome(
            quiesced: settle.quiesced,
            settledAfterMs: min(elapsed, config.capMs),
            diff: Diff.compute(old: before, new: after)
        )
    }
}
