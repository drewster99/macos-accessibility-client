// P0a spike — the control app. Registers the host as an on-demand LaunchAgent via
// SMAppService. Stands in for the real GUI/installer. Run once after install.

import Foundation
import ServiceManagement

func statusName(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}

let agent = SMAppService.agent(plistName: "com.nuclearcyborg.p0a.host.plist")
print("agent status before: \(statusName(agent.status))")
do {
    try agent.register()
    print("register: ok; status=\(statusName(agent.status))")
    if agent.status == .requiresApproval {
        print(">> Approve in System Settings ▸ General ▸ Login Items (then re-run if needed).")
        SMAppService.openSystemSettingsLoginItems()
    }
} catch {
    print("register: FAILED: \(error)")
}
