import XCTest
import AppKit
import ApplicationServices
import MacControlMCPCore
@testable import AXKit

final class SettleEngineTests: XCTestCase {
    /// Live: a no-op "action" against a stable app must settle (quiesce) well under the
    /// cap and return a computed diff — proving the snapshot→poll→diff pipeline works
    /// end-to-end without depending on AX notifications. Read-only, no side effects.
    func testLiveNoOpSettleQuiescesQuickly() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        let engine = SettleEngine(session: ElementRegistry())
        let outcome = engine.actAndSettle(pid: finder.processIdentifier, maxDepth: 1) { /* no-op */ }

        XCTAssertTrue(outcome.quiesced, "a stable app + no-op should quiesce, not hit the cap")
        XCTAssertLessThanOrEqual(outcome.settledAfterMs, 3000)
    }

    /// Proves the identity-stable-ref fix: two snapshots of an unchanged app share refs,
    /// so the diff is empty (without identity stability this would be all-removed+all-added).
    func testLiveStableRefsYieldEmptyDiffOnNoChange() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        let session = ElementRegistry()
        let pid = finder.processIdentifier
        let before = session.snapshot(pid: pid, maxDepth: 1)
        let after = session.snapshot(pid: pid, maxDepth: 1)
        let diff = Diff.compute(old: before, new: after)
        XCTAssertTrue(diff.isEmpty, "stable refs + no change must yield an empty diff, got \(diff)")
    }

    func testLiveGetChangesBaselineThenEmpty() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        let session = ElementRegistry()
        let pid = finder.processIdentifier
        XCTAssertTrue(session.getChanges(pid: pid, maxDepth: 1).isEmpty, "first call is the baseline → empty")
        XCTAssertTrue(session.getChanges(pid: pid, maxDepth: 1).isEmpty, "no change → empty diff")
    }

    func testCustomCapIsRespected() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        let engine = SettleEngine(session: ElementRegistry())
        let config = QuiescenceConfig(idleMs: 200, capMs: 1000)
        let outcome = engine.actAndSettle(pid: finder.processIdentifier, maxDepth: 1, config: config) { }
        XCTAssertLessThanOrEqual(outcome.settledAfterMs, 1000)
    }
}
