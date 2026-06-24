// P0a spike — the faceless host. Launched on demand by launchd when the relay looks up
// the Mach service. Vends an XPC listener with a code-signing requirement and reports
// its own AX-trust status so we can confirm TCC attribution lands here.

import Foundation
import ApplicationServices

func hostLog(_ s: String) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let line = "[host pid=\(pid)] \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let path = ("~/Library/Logs/p0a-host.log" as NSString).expandingTildeInPath
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        try? fh.close()
    }
}

final class HostService: NSObject, P0AHostProtocol {
    func probe(withReply reply: @escaping (String) -> Void) {
        let trusted = AXIsProcessTrusted()
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "(none)"
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "?"
        let json = "{\"role\":\"host\",\"pid\":\(pid),\"bundleID\":\"\(bundleID)\",\"executable\":\"\(exe)\",\"axTrusted\":\(trusted)}"
        hostLog("probe replied: \(json)")
        reply(json)
    }
}

final class HostDelegate: NSObject, NSXPCListenerDelegate {
    let service = HostService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: P0AHostProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        hostLog("accepted connection from pid \(newConnection.processIdentifier)")
        return true
    }
}

@main
struct HostMain {
    static func main() {
        hostLog("starting; AXIsProcessTrusted=\(AXIsProcessTrusted())")
        // Auto-register in the Accessibility list so granting is a one-toggle action
        // (no "+" path-hunting). Harmless once already trusted.
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            hostLog("not trusted — requested Accessibility prompt; 'p0a-host' should now appear (disabled) in System Settings ‣ Privacy & Security ‣ Accessibility")
        }
        let hostDelegate = HostDelegate()
        let listener = NSXPCListener(machServiceName: p0aMachServiceName)
        listener.delegate = hostDelegate
        // System-enforced admission: only callers satisfying our team requirement get through.
        listener.setConnectionCodeSigningRequirement(p0aTeamRequirement)
        listener.resume()
        hostLog("listening on \(p0aMachServiceName) with code-signing requirement")
        dispatchMain()
    }
}
