//
//  MCPServer.swift
//  MacControlMCP
//
//  Per-connection MCP method dispatch. Pure request→response; the transport (stdio
//  here, XPC-relayed later) only feeds it lines and writes back the returned bytes.
//

import Foundation

public final class MCPServer {
    /// MCP protocol revision we default to when the client doesn't pin one.
    static let defaultProtocolVersion = "2024-11-05"

    private let tools: [Tool]

    public init(tools: [Tool] = MCPServer.defaultTools()) {
        self.tools = tools
    }

    public static func defaultTools() -> [Tool] {
        [ListAppsTool(), ListSimulatorsTool(), SimTool()]
    }

    /// Handle one JSON-RPC line. Returns the response bytes to write, or `nil` for
    /// notifications and unparseable input (nothing to send back).
    public func handleLine(_ line: String) -> Data? {
        guard let request = JSONRPC.parse(line) else {
            // Per JSON-RPC, a non-empty unparseable line is a parse error (id: null); a blank
            // line is transport whitespace we ignore.
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return JSONRPC.errorData(id: NSNull(), code: -32700, message: "parse error")
        }
        return handle(request)
    }

    func handle(_ request: JSONRPCRequest) -> Data? {
        // JSON-RPC notifications (no `id`) must never receive a response — including for
        // request-style methods a client might send without an id.
        if request.isNotification { return nil }
        switch request.method {
        case "initialize":
            let version = (request.params["protocolVersion"] as? String) ?? Self.defaultProtocolVersion
            return JSONRPC.responseData(id: request.id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "mac-control-mcp", "version": "0.0.1"]
            ])

        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "tools/list":
            return JSONRPC.responseData(id: request.id, result: ["tools": tools.map(\.descriptor)])

        case "tools/call":
            return handleToolCall(request)

        case "ping":
            return JSONRPC.responseData(id: request.id, result: [:])

        default:
            if request.isNotification { return nil }
            return JSONRPC.errorData(id: request.id, code: -32601, message: "method not found: \(request.method)")
        }
    }

    private func handleToolCall(_ request: JSONRPCRequest) -> Data? {
        guard let name = request.params["name"] as? String else {
            return JSONRPC.errorData(id: request.id, code: -32602, message: "missing tool name")
        }
        let arguments = (request.params["arguments"] as? [String: Any]) ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            return JSONRPC.errorData(id: request.id, code: -32602, message: "unknown tool: \(name)")
        }
        let text = tool.call(arguments)
        return JSONRPC.responseData(id: request.id, result: [
            "content": [["type": "text", "text": text]]
        ])
    }
}
