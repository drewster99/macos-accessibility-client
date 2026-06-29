import XCTest
@testable import HostKit

/// Verifies the XPC host service wraps the *full* MCPServer (every tool layer) and
/// forwards JSON-RPC correctly. The XPC transport itself is proven by spikes/p0a; this
/// tests the host's request handling at the logic level.
final class MCPHostServiceTests: XCTestCase {
    func testHandleForwardsInitialize() {
        let service = MCPHostService()
        let expectation = expectation(description: "reply")
        service.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#) { reply in
            XCTAssertTrue(reply?.contains("serverInfo") ?? false)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testToolsListIncludesEveryLayer() {
        let service = MCPHostService()
        let expectation = expectation(description: "reply")
        service.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#) { reply in
            let text = reply ?? ""
            for tool in ["list_apps", "control_app", "element_detail", "screenshot", "action", "click", "key", "type"] {
                XCTAssertTrue(text.contains(tool), "tools/list missing \(tool)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testNotificationRepliesNil() {
        let service = MCPHostService()
        let expectation = expectation(description: "reply")
        service.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) { reply in
            XCTAssertNil(reply)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testMakeFullServerWiresManyTools() {
        let data = makeFullServer().handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        // 16 tools across all layers — spot-check the count is in the right ballpark.
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "\"name\"").count - 1, 16)
    }
}
