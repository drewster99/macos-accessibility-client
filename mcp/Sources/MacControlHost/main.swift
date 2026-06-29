//
//  main.swift
//  MacControlHost
//
//  The privileged host: vends the MCPServer over an XPC Mach service, pinning callers to
//  our team via setConnectionCodeSigningRequirement (§2). Launched on demand by launchd in
//  the product; runnable directly (or via launchctl) for testing.
//

import AppKit
import ApplicationServices
import Foundation
import HostKit

// Trigger the Accessibility consent prompt + register the host in the TCC list the first time
// it launches, so the user grants the host directly instead of hand-adding the nested helper
// .app inside the bundle. No-op once granted. (Screen Recording is prompted on first capture.)
_ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

DebugLog.event("launch", "host \(DebugLog.buildIdentity()) pid=\(ProcessInfo.processInfo.processIdentifier)")

final class HostDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        DebugLog.event("connect", "client pid=\(newConnection.processIdentifier)")
        newConnection.invalidationHandler = { DebugLog.event("disconnect", "client invalidated") }
        newConnection.interruptionHandler = { DebugLog.event("disconnect", "client interrupted") }
        // A fresh service per connection — each client gets its own MCPServer + ElementRegistry,
        // so refs are namespaced per client (the connection retains exportedObject).
        newConnection.exportedInterface = NSXPCInterface(with: MCPHostProtocol.self)
        newConnection.exportedObject = MCPHostService()
        newConnection.resume()
        return true
    }
}

let delegate = HostDelegate()
let listener = NSXPCListener(machServiceName: mcpMachServiceName)
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(mcpCallerRequirement)
listener.resume()

// Run a faceless AppKit loop, NOT dispatchMain(): a launchd agent parked in dispatchMain()
// never pumps the main run loop, so NSWorkspace.runningApplications (used by list_apps)
// freezes at launch time and keeps reporting stale/dead pids. The run loop keeps NSWorkspace
// live AND drains the main dispatch queue, so XPC delivery is unaffected. LSUIElement +
// .accessory keep it invisible (no Dock icon, no menu bar).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
