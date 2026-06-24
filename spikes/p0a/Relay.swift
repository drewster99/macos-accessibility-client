// P0a spike — the relay. Stands in for the stdio MCP relay launched by a client.
// Connecting triggers launchd to start the host on demand; we print the host's reply.

import Foundation

func relayLog(_ s: String) {
    let pid = ProcessInfo.processInfo.processIdentifier
    FileHandle.standardError.write(Data("[relay pid=\(pid)] \(s)\n".utf8))
}

@main
struct RelayMain {
    static func main() {
        let conn = NSXPCConnection(machServiceName: p0aMachServiceName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: P0AHostProtocol.self)
        // Pin the host's identity too (mutual auth): reject a host that isn't our team.
        conn.setCodeSigningRequirement(p0aTeamRequirement)
        conn.invalidationHandler = { relayLog("connection invalidated") }
        conn.interruptionHandler = { relayLog("connection interrupted") }
        conn.resume()

        let sema = DispatchSemaphore(value: 0)
        relayLog("connecting to \(p0aMachServiceName)")
        let proxy = conn.remoteObjectProxyWithErrorHandler { err in
            print("{\"role\":\"relay\",\"error\":\"\(err.localizedDescription)\"}")
            relayLog("proxy error: \(err)")
            sema.signal()
        }
        if let host = proxy as? P0AHostProtocol {
            host.probe { reply in
                print(reply)
                relayLog("host reply: \(reply)")
                sema.signal()
            }
        } else {
            print("{\"role\":\"relay\",\"error\":\"could not obtain proxy\"}")
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 10)
        conn.invalidate()
    }
}
