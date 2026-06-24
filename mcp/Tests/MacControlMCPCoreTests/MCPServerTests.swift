import XCTest
@testable import MacControlMCPCore

final class MCPServerTests: XCTestCase {
    private func resultObject(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }

    func testInitializeEchoesProtocolVersion() throws {
        let server = MCPServer()
        let line = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        let object = try resultObject(server.handleLine(line))
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "mac-control-mcp")
    }

    func testToolsListExposesGrantFreeTools() throws {
        let server = MCPServer()
        let object = try resultObject(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#))
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("list_apps"))
        XCTAssertTrue(names.contains("list_simulators"))
    }

    func testListAppsReturnsTextContent() throws {
        let server = MCPServer()
        let line = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}"#
        let object = try resultObject(server.handleLine(line))
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        // list_apps returns a JSON array (this test process is itself a running app).
        XCTAssertTrue(text.hasPrefix("["))
    }

    func testUnknownToolErrors() throws {
        let server = MCPServer()
        let line = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#
        let object = try resultObject(server.handleLine(line))
        XCTAssertNotNil(object["error"])
    }

    func testUnknownMethodErrors() throws {
        let server = MCPServer()
        let object = try resultObject(server.handleLine(#"{"jsonrpc":"2.0","id":5,"method":"bogus","params":{}}"#))
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testNotificationProducesNoResponse() {
        let server = MCPServer()
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testMalformedLineProducesParseError() {
        let server = MCPServer()
        let data = server.handleLine("not json")
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(text.contains("-32700"), "non-empty unparseable line → parse error")
        XCTAssertNil(server.handleLine("   "), "blank line is ignored")
    }

    func testRequestMethodSentAsNotificationGetsNoResponse() {
        // Even a request-style method, sent without an id, is a notification → no response.
        let server = MCPServer()
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","method":"initialize","params":{}}"#))
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","method":"tools/list"}"#))
    }
}
