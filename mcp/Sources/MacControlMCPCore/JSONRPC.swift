//
//  JSONRPC.swift
//  MacControlMCP
//
//  Minimal newline-delimited JSON-RPC 2.0 framing for the MCP stdio transport.
//

import Foundation

/// One decoded JSON-RPC request. `id` is the raw JSON id (number / string / NSNull),
/// echoed verbatim into the response. A request with no `id` is a notification.
public struct JSONRPCRequest {
    public let id: Any?
    public let method: String
    public let params: [String: Any]
    public var isNotification: Bool { id == nil }
}

/// Helpers that never use `try?` / force-unwrap: malformed input becomes `nil`, and
/// un-encodable output falls back to a valid JSON-RPC internal error.
public enum JSONRPC {
    public static func parse(_ line: String) -> JSONRPCRequest? {
        guard let data = line.data(using: .utf8) else { return nil }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { return nil }
        guard let dict = object as? [String: Any],
              let method = dict["method"] as? String else { return nil }
        let params = (dict["params"] as? [String: Any]) ?? [:]
        return JSONRPCRequest(id: dict["id"], method: method, params: params)
    }

    public static func responseData(id: Any?, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    public static func errorData(id: Any?, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(),
                "error": ["code": code, "message": message]])
    }

    static func encode(_ object: [String: Any]) -> Data {
        do { return try JSONSerialization.data(withJSONObject: object) }
        catch {
            return Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#.utf8)
        }
    }
}
