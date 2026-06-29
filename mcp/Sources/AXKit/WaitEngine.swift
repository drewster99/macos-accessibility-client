//
//  WaitEngine.swift
//  AXKit
//
//  wait_for (§6/§8): actively polls for an expected condition, so it works even in apps
//  that don't post AX notifications (Electron/web). Read-only — pure observation, no side
//  effects — which is why it can be live-tested.
//

import ApplicationServices
import Foundation

public final class WaitEngine {
    private let session: ElementRegistry

    public init(session: ElementRegistry) {
        self.session = session
    }

    public enum Condition: Sendable {
        case idle(idleMs: Int)
        case appears(role: String?, titleContains: String?)
        case disappears(role: String?, titleContains: String?)
    }

    public struct Outcome: Sendable {
        public let satisfied: Bool
        public let waitedMs: Int
        public let matchRef: String?
    }

    private func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    public func wait(pid: pid_t, condition: Condition, timeoutMs: Int, pollMs: Int = 150, maxDepth: Int = 8) -> Outcome {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        let start = nowMs()

        switch condition {
        case .idle(let idleMs):
            var lastSignature = AXSnapshot.structuralSignature(of: app, maxDepth: maxDepth)
            var lastChange = 0
            while nowMs() - start < timeoutMs {
                Thread.sleep(forTimeInterval: Double(pollMs) / 1000.0)
                let elapsed = nowMs() - start
                let signature = AXSnapshot.structuralSignature(of: app, maxDepth: maxDepth)
                if signature != lastSignature {
                    lastSignature = signature
                    lastChange = elapsed
                }
                if elapsed - lastChange >= idleMs {
                    return Outcome(satisfied: true, waitedMs: elapsed, matchRef: nil)
                }
            }
            return Outcome(satisfied: false, waitedMs: nowMs() - start, matchRef: nil)

        case .appears(let role, let titleContains):
            while nowMs() - start < timeoutMs {
                if let first = session.find(pid: pid, role: role, titleContains: titleContains, limit: 1, maxDepth: maxDepth).first {
                    return Outcome(satisfied: true, waitedMs: nowMs() - start, matchRef: first.ref)
                }
                Thread.sleep(forTimeInterval: Double(pollMs) / 1000.0)
            }
            return Outcome(satisfied: false, waitedMs: nowMs() - start, matchRef: nil)

        case .disappears(let role, let titleContains):
            while nowMs() - start < timeoutMs {
                if session.find(pid: pid, role: role, titleContains: titleContains, limit: 1, maxDepth: maxDepth).isEmpty {
                    return Outcome(satisfied: true, waitedMs: nowMs() - start, matchRef: nil)
                }
                Thread.sleep(forTimeInterval: Double(pollMs) / 1000.0)
            }
            return Outcome(satisfied: false, waitedMs: nowMs() - start, matchRef: nil)
        }
    }
}
