//
//  main.swift
//  MacControlRegistrar
//
//  The bundle's main executable: registers the host as an on-demand LaunchAgent via
//  SMAppService (§2). Run once after install; `--unregister` to remove. LSUIElement so it
//  doesn't show a Dock icon.
//

import Foundation
import ServiceManagement

func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

let agent = SMAppService.agent(plistName: "com.nuclearcyborg.maccontrol.host.plist")
print("agent status: \(statusName(agent.status))")

if CommandLine.arguments.dropFirst().contains("--unregister") {
    do {
        try agent.unregister()
        print("unregistered")
    } catch {
        print("unregister failed: \(error)")
    }
} else {
    do {
        try agent.register()
        print("registered; status=\(statusName(agent.status))")
        if agent.status == .requiresApproval {
            print(">> Approve in System Settings ▸ General ▸ Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
    } catch {
        print("register failed: \(error)")
    }
}
