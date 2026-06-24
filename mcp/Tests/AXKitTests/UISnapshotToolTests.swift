import XCTest
import AppKit
import ApplicationServices
@testable import AXKit

final class UISnapshotToolTests: XCTestCase {
    func testDescriptorsAndRequiredArgs() {
        let session = AXSession()
        let snap = UISnapshotTool(session: session)
        XCTAssertEqual(snap.name, "ui_snapshot")
        let schema = snap.descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["pid"])
        XCTAssertEqual(ElementDetailTool(session: session).name, "element_detail")
        XCTAssertEqual(FindElementsTool(session: session).name, "find_elements")
    }

    func testPermissionGatingWhenNotTrusted() {
        let session = AXSession()
        let notTrusted: @Sendable () -> Bool = { false }
        XCTAssertTrue(UISnapshotTool(session: session, isTrusted: notTrusted).call(["pid": 1]).contains("accessibility_not_granted"))
        XCTAssertTrue(FindElementsTool(session: session, isTrusted: notTrusted).call(["pid": 1]).contains("accessibility_not_granted"))
        XCTAssertTrue(ElementDetailTool(session: session, isTrusted: notTrusted).call(["ref": "e1"]).contains("accessibility_not_granted"))
    }

    func testStaleRefWhenUnknown() {
        let session = AXSession()
        let trusted: @Sendable () -> Bool = { true }
        let out = ElementDetailTool(session: session, isTrusted: trusted).call(["ref": "nope"])
        XCTAssertTrue(out.contains("stale_ref"))
    }

    func testMissingPid() {
        let session = AXSession()
        let trusted: @Sendable () -> Bool = { true }
        XCTAssertTrue(UISnapshotTool(session: session, isTrusted: trusted).call([:]).contains("missing_pid"))
    }

    /// Live, end-to-end: snapshot a real app, take a ref, detail it via the SAME session —
    /// proving the §4 handle table resolves refs across calls. Skips without a grant.
    func testLiveSnapshotThenDetailResolvesRefAcrossCalls() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        let session = AXSession()
        let pid = Int(finder.processIdentifier)
        let outline = UISnapshotTool(session: session).call(["pid": pid, "depth": 1])
        XCTAssertTrue(outline.contains("AXApplication"))

        let firstRef = try XCTUnwrap(outline.split(separator: "\n").first?.split(separator: " ").first.map(String.init))
        let detail = ElementDetailTool(session: session).call(["ref": firstRef])
        XCTAssertTrue(detail.contains("\"role\""))
        XCTAssertFalse(detail.contains("stale_ref"))
    }
}
