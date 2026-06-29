import XCTest
import AppKit
import ApplicationServices
@testable import AXKit

final class WaitForToolTests: XCTestCase {
    func testDescriptorAndGating() {
        let session = ElementRegistry()
        let tool = WaitForTool(session: session)
        XCTAssertEqual(tool.name, "wait_for")
        let schema = tool.descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["pid", "mode"])
        XCTAssertTrue(WaitForTool(session: session, isTrusted: { false }).call(["pid": 1, "mode": "idle"]).contains("accessibility_not_granted"))
    }

    func testMissingArgsAndUnknownMode() {
        let session = ElementRegistry()
        let trusted: @Sendable () -> Bool = { true }
        XCTAssertTrue(WaitForTool(session: session, isTrusted: trusted).call(["pid": 1]).contains("missing_pid_or_mode"))
        XCTAssertTrue(WaitForTool(session: session, isTrusted: trusted).call(["pid": 1, "mode": "bogus"]).contains("unknown_mode"))
    }

    private func finderPID() throws -> pid_t {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        return finder.processIdentifier
    }

    /// Live, read-only: a stable app goes idle quickly.
    func testLiveIdleSatisfiedQuickly() throws {
        let pid = try finderPID()
        let outcome = WaitEngine(session: ElementRegistry()).wait(pid: pid, condition: .idle(idleMs: 300), timeoutMs: 3000)
        XCTAssertTrue(outcome.satisfied)
        XCTAssertLessThan(outcome.waitedMs, 3000)
    }

    /// Live, read-only: Finder has a window, so appears(AXWindow) is satisfied immediately.
    func testLiveAppearsWindowSatisfied() throws {
        let pid = try finderPID()
        let outcome = WaitEngine(session: ElementRegistry()).wait(pid: pid, condition: .appears(role: "AXWindow", titleContains: nil), timeoutMs: 3000)
        XCTAssertTrue(outcome.satisfied)
        XCTAssertNotNil(outcome.matchRef)
    }

    /// Live, read-only: a nonsense title never appears → times out, returns not-satisfied.
    func testLiveAppearsTimesOutForNonexistent() throws {
        let pid = try finderPID()
        let outcome = WaitEngine(session: ElementRegistry()).wait(pid: pid, condition: .appears(role: nil, titleContains: "zzz-nonexistent-zzz"), timeoutMs: 500)
        XCTAssertFalse(outcome.satisfied)
    }
}
