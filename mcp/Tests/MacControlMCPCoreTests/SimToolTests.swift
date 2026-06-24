import XCTest
@testable import MacControlMCPCore

final class SimToolTests: XCTestCase {
    func testDescriptorRequiresAction() {
        let schema = SimTool().descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["action"])
    }

    func testMissingAndUnknownAction() {
        XCTAssertTrue(SimTool().call([:]).contains("missing_action"))
        XCTAssertTrue(SimTool().call(["action": "bogus"]).contains("unknown_action"))
    }

    func testMissingActionArguments() {
        XCTAssertTrue(SimTool().call(["action": "openurl"]).contains("missing_url"))
        XCTAssertTrue(SimTool().call(["action": "appearance"]).contains("missing_value"))
        XCTAssertTrue(SimTool().call(["action": "launch"]).contains("missing_bundleId"))
    }

    /// Uses an invalid UDID so simctl fails cleanly with no side effect regardless of what
    /// is booted — proving the tool runs simctl and surfaces failure as ok:false.
    func testInvalidUDIDFailsCleanly() {
        let out = SimTool().call([
            "action": "openurl",
            "udid": "00000000-0000-0000-0000-000000000000",
            "url": "https://example.com"
        ])
        XCTAssertTrue(out.contains("\"ok\""))
        XCTAssertTrue(out.contains("false") || out.contains("\"error\""), "expected a clean failure, got: \(out)")
    }

    func testSimToolIsRegistered() {
        let names = MCPServer.defaultTools().map(\.name)
        XCTAssertTrue(names.contains("sim"))
    }
}
