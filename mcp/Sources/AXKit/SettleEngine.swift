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
    private let session: ElementRegistry

    public init(session: ElementRegistry) {
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
        action()

        let start = nowMs()
        let pollSeconds = Double(pollIntervalMs) / 1000.0

        // Phase 1 — wait up to firstChangeMs for the action's effect to BEGIN. Detect with a
        // value-inclusive signature so value-only effects (typing, a field update) register
        // immediately instead of waiting out the whole window.
        let changeSignature = AXSnapshot.changeSignature(of: app, maxDepth: maxDepth)
        var changed = false
        while nowMs() - start < config.firstChangeMs {
            Thread.sleep(forTimeInterval: pollSeconds)
            let signature = AXSnapshot.changeSignature(of: app, maxDepth: maxDepth)
            if signature != changeSignature { changed = true; break }
        }

        // Phase 2 — once something changed, wait up to capMs for STRUCTURAL quiet (idleMs with no
        // structural change). Structure-only here so a constantly updating value can't block it.
        var quiesced = !changed                       // nothing changed within firstChangeMs ⇒ quiet
        if changed {
            var structuralSignature = AXSnapshot.structuralSignature(of: app, maxDepth: maxDepth)
            var lastStructuralChange = nowMs()
            let phaseStart = nowMs()
            while nowMs() - phaseStart < config.capMs {
                Thread.sleep(forTimeInterval: pollSeconds)
                let signature = AXSnapshot.structuralSignature(of: app, maxDepth: maxDepth)
                if signature != structuralSignature {
                    structuralSignature = signature
                    lastStructuralChange = nowMs()
                }
                if nowMs() - lastStructuralChange >= config.idleMs { quiesced = true; break }
            }
        }

        let after = session.snapshot(pid: pid, maxDepth: maxDepth)
        return SettleOutcome(
            quiesced: quiesced,
            settledAfterMs: nowMs() - start,
            diff: Diff.compute(old: before, new: after)
        )
    }
}
