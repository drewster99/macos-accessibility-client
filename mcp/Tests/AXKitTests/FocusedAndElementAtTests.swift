import XCTest
import ApplicationServices
@testable import AXKit

final class FocusedAndElementAtTests: XCTestCase {
    func testDescriptors() {
        let session = ElementRegistry()
        XCTAssertEqual(FocusedElementTool(session: session).name, "focused_element")
        let atSchema = ElementAtTool(session: session).descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(atSchema?["required"] as? [String], ["x", "y"])
    }

    func testPermissionGating() {
        let session = ElementRegistry()
        let notTrusted: @Sendable () -> Bool = { false }
        XCTAssertTrue(FocusedElementTool(session: session, isTrusted: notTrusted).call([:]).contains("accessibility_not_granted"))
        XCTAssertTrue(ElementAtTool(session: session, isTrusted: notTrusted).call(["x": 10, "y": 10]).contains("accessibility_not_granted"))
    }

    func testElementAtMissingCoordinates() {
        let session = ElementRegistry()
        let trusted: @Sendable () -> Bool = { true }
        XCTAssertTrue(ElementAtTool(session: session, isTrusted: trusted).call([:]).contains("missing_coordinates"))
    }

    /// Live: hit-test near the top-left (menu bar area). Skips without a grant; otherwise
    /// must return either a registered element or a clean "no element" result (never crash).
    func testLiveElementAtReturnsResultOrCleanMiss() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        let session = ElementRegistry()
        let out = ElementAtTool(session: session).call(["x": 10, "y": 10])
        XCTAssertFalse(out.contains("accessibility_not_granted"))
        XCTAssertTrue(out.contains("\"ref\"") || out.contains("no_element_at_position"))
    }

    func testLiveFocusedElementReturnsResultOrCleanMiss() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        let session = ElementRegistry()
        let out = FocusedElementTool(session: session).call([:])
        XCTAssertFalse(out.contains("accessibility_not_granted"))
        XCTAssertTrue(out.contains("\"ref\"") || out.contains("no_focused_element"))
    }
}
