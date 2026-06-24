//
//  main.swift
//  MacControlRelay
//
//  The stdio relay MCP clients launch: forwards newline-delimited JSON-RPC to the host
//  over XPC and writes replies back. Its one piece of logic is transparent reconnect —
//  if the host re-execs (e.g. to apply a Screen-Recording grant), it reconnects and
//  retries the in-flight line once instead of surfacing a broken pipe (§2).
//

import Foundation
import HostKit

func makeConnection() -> NSXPCConnection {
    let connection = NSXPCConnection(machServiceName: mcpMachServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: MCPHostProtocol.self)
    connection.setCodeSigningRequirement(mcpHostRequirement)
    connection.resume()
    return connection
}

let stdout = FileHandle.standardOutput
var connection = makeConnection()

// Tools with side effects — never re-fire these on reconnect (we have no idempotency token).
let mutatingTools: Set<String> = [
    "click", "scroll", "key", "type_text", "drag", "hover",
    "perform", "set_value", "set_focus", "reveal", "window", "open_menu", "sim"
]

func isMutating(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8) else { return false }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch { return false }
    guard let dict = object as? [String: Any],
          (dict["method"] as? String) == "tools/call",
          let params = dict["params"] as? [String: Any],
          let name = params["name"] as? String else { return false }
    return mutatingTools.contains(name)
}

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }

    var responded = false
    for attempt in 0..<2 {
        let semaphore = DispatchSemaphore(value: 0)
        var response: String?
        var failed = false

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            failed = true
            semaphore.signal()
        } as? MCPHostProtocol

        if let proxy {
            proxy.handle(line: line) { reply in
                response = reply
                semaphore.signal()
            }
            semaphore.wait()
        } else {
            failed = true
        }

        if !failed {
            if let response {
                stdout.write(Data((response + "\n").utf8))
            }
            responded = true
            break
        }

        // Never re-fire a mutating call (no idempotency token) — surface the failure instead.
        if isMutating(line) { break }
        // Otherwise reconnect once and retry (host may have re-exec'd for a grant).
        connection.invalidate()
        connection = makeConnection()
        _ = attempt
    }

    if !responded {
        stdout.write(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"host unavailable"}}"# .utf8))
        stdout.write(Data("\n".utf8))
    }
}
