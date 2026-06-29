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
    DebugLog.event("connect", "xpc \(mcpMachServiceName)")
    return connection
}

// Tools with side effects — never re-fire these on reconnect (we have no idempotency token).
let mutatingTools: Set<String> = [
    "click", "click_point", "scroll", "key", "type", "drag", "hover",
    "set_value", "focus_keyboard", "reveal", "window", "menu_pick", "sim",
    "action", "change_text", "change_value", "launch_app", "kill"
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

/// Resolve the enclosing app bundle (`…/MacControlMCP.app`) from the relay's own path
/// (`…/Contents/Helpers/MacControlRelay`), or `nil` if we're not inside one.
func enclosingAppBundle() -> URL? {
    let relay = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = relay.deletingLastPathComponent()   // Helpers
        .deletingLastPathComponent()               // Contents
        .deletingLastPathComponent()               // MacControlMCP.app
    return app.pathExtension == "app" ? app : nil
}

/// Cold-start self-bootstrap: launch the app hidden in `--register-and-exit` mode so it registers
/// the host LaunchAgent (and boots any stale host), then return. The caller waits briefly and
/// reconnects. Without this, a fresh install requires the user to open the app once before any
/// MCP call works — this makes the first MCP call bring the whole stack up by itself.
func bootstrapHost() {
    guard let app = enclosingAppBundle() else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", app.path, "--args", "--register-and-exit"]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        // Best-effort; if launching the app fails we fall through to "host unavailable".
    }
}

/// The relay loop runs in a `nonisolated` function — NOT `main.swift` top-level code, which
/// Swift 6 runs on the MainActor. Top-level isolation would make the NSXPC reply/error closures
/// `@MainActor`, and XPC invokes them on its own background queue → `swift_task_checkIsolated`
/// trap (crash) on every callback, plus a main-thread deadlock against the semaphore wait below.
/// A nonisolated context keeps those closures non-isolated, so XPC can call them off-main safely.
func runRelay() {
    DebugLog.event("launch", "relay \(DebugLog.buildIdentity()) argv=\(CommandLine.arguments.joined(separator: " "))")
    let stdout = FileHandle.standardOutput
    var connection = makeConnection()
    var bootstrapped = false

    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        DebugLog.request(line)

        var responded = false
        for attempt in 0..<3 {
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
                DebugLog.response(response)
                responded = true
                break
            }

            connection.invalidate()
            let mutating = isMutating(line)

            // Cold start: if a plain reconnect didn't help (attempt ≥ 1), or this is a mutating
            // call we won't retry, bring the host up once by launching the app to register the
            // LaunchAgent. A registered host that merely re-exec'd (e.g. for a grant) recovers on
            // the first plain reconnect without this.
            if !bootstrapped && (attempt >= 1 || mutating) {
                bootstrapped = true
                bootstrapHost()
                Thread.sleep(forTimeInterval: 1.5)
            }
            connection = makeConnection()

            // Never re-fire a mutating call (no idempotency token) — surface the failure; the
            // bootstrap above means the model's retry reaches the now-running host.
            if mutating { break }
        }

        if !responded {
            let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"host unavailable"}}"#
            stdout.write(Data((fallback + "\n").utf8))
            DebugLog.response(fallback)
        }
    }

    DebugLog.event("disconnect", "stdin closed")
}

runRelay()
