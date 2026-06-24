import XCTest
import CoreGraphics
@testable import CaptureKit

final class ScreenshotToolTests: XCTestCase {
    func testDescriptorRequiresTarget() {
        let schema = ScreenshotTool().descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["target"])
    }

    func testScreenGatedWhenNoScreenRecording() {
        let tool = ScreenshotTool(hasScreenRecording: { false })
        XCTAssertTrue(tool.call(["target": "screen"]).contains("screen_recording_not_granted"))
    }

    func testUnsupportedTarget() {
        XCTAssertTrue(ScreenshotTool().call(["target": "bogus"]).contains("unsupported_target"))
    }

    func testSimulatorOutcomeIsCleanJSON() {
        // No simulator is booted here → no_booted_simulator; tolerate other valid outcomes.
        let out = ScreenshotTool().call(["target": "simulator"])
        let ok = out.contains("no_booted_simulator")
            || out.contains("\"path\"")
            || out.contains("simulator_capture_failed")
        XCTAssertTrue(ok, "unexpected output: \(out)")
    }

    func testLiveScreenCaptureWritesPNGWhenGranted() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording grant in this environment")
        let out = ScreenshotTool().call(["target": "screen", "maxDimension": 400])
        XCTAssertTrue(out.contains("\"path\""), "expected a path, got: \(out)")
    }
}
