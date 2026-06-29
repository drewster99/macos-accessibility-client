import XCTest
@testable import InputKit
import MacControlMCPCore

/// Input tools post real events, so these tests only exercise the safe paths: permission
/// gating, missing-arg validation, and key-combo parse failure. No real input is posted.
final class InputToolsTests: XCTestCase {
    private let denied: @Sendable () -> Bool = { false }
    private let granted: @Sendable () -> Bool = { true }

    func testNamesAndRequiredArgs() {
        XCTAssertEqual(ClickTool().name, "click_point")
        XCTAssertEqual(ScrollTool().name, "scroll")
        XCTAssertEqual(KeyTool().name, "key")
        let clickSchema = ClickTool().descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(clickSchema?["required"] as? [String], ["x", "y"])
    }

    func testAllGateOnPostEventAccess() {
        XCTAssertTrue(ClickTool(canPostEvents: denied).call(["x": 1, "y": 2]).contains("post_event_access_denied"))
        XCTAssertTrue(ScrollTool(canPostEvents: denied).call(["dy": 10]).contains("post_event_access_denied"))
        XCTAssertTrue(KeyTool(canPostEvents: denied).call(["keys": "cmd+s"]).contains("post_event_access_denied"))
    }

    func testMissingArgs() {
        XCTAssertTrue(ClickTool(canPostEvents: granted).call([:]).contains("missing_coordinates"))
        XCTAssertTrue(ScrollTool(canPostEvents: granted).call([:]).contains("missing_dy"))
        XCTAssertTrue(KeyTool(canPostEvents: granted).call([:]).contains("missing_keys"))
    }

    /// Granted + an unparseable combo must fail at the parse step — before any post.
    func testUnknownKeyComboDoesNotPost() {
        let out = KeyTool(canPostEvents: granted).call(["keys": "cmd+nope"])
        XCTAssertTrue(out.contains("unknown_key_combo"))
    }

    /// Every input verb must advertise the observe:"settle" + pid opt-in (act-and-settle).
    func testInputToolsAdvertiseObserveSettle() {
        func properties(_ descriptor: [String: Any]) -> [String: Any]? {
            (descriptor["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        }
        for tool in InputTools.all() {
            guard let props = properties(tool.descriptor) else {
                XCTFail("no properties for \(tool.name)"); continue
            }
            let observe = props["observe"] as? [String: Any]
            XCTAssertEqual(observe?["enum"] as? [String], ["none", "settle"], "\(tool.name) observe enum")
            XCTAssertNotNil(props["pid"], "\(tool.name) advertises pid")
        }
    }

    /// observe:"settle" + pid routes through the injected settle engine and surfaces its diff.
    /// The fake intentionally ignores `action`, so this test posts NO real event.
    func testObserveSettleRoutesThroughInjectedSettle() {
        var sawPid: pid_t = -1
        let fakeSettle: ActAndSettle = { pid, _ in
            sawPid = pid
            return (quiesced: true, settledAfterMs: 42,
                    diff: ElementDiff(added: ["e9 AXButton \"Go\""], removed: [], changed: []))
        }
        let out = ScrollTool(canPostEvents: granted, settle: fakeSettle)
            .call(["dy": -120, "observe": "settle", "pid": 4321])
        XCTAssertEqual(sawPid, 4321)
        XCTAssertTrue(out.contains("settledAfterMs"))
        XCTAssertTrue(out.contains("42"))
        XCTAssertTrue(out.contains("quiesced"))
        XCTAssertTrue(out.contains("e9 AXButton"))
    }

    func testHoverAndDragSafePaths() {
        XCTAssertEqual(HoverTool().name, "hover")
        XCTAssertEqual(DragTool().name, "drag")
        XCTAssertTrue(HoverTool(canPostEvents: denied).call(["x": 1, "y": 2]).contains("post_event_access_denied"))
        XCTAssertTrue(DragTool(canPostEvents: denied).call(["fromX": 1, "fromY": 2, "toX": 3, "toY": 4]).contains("post_event_access_denied"))
        // granted but missing coords → no event posted
        XCTAssertTrue(HoverTool(canPostEvents: granted).call([:]).contains("missing_coordinates"))
        XCTAssertTrue(DragTool(canPostEvents: granted).call([:]).contains("missing_coordinates"))
    }
}
