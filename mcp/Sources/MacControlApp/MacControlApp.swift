//
//  MacControlApp.swift
//  MacControlApp
//
//  The product Mac app (MacControlMCP.app). It bundles the host (nested .app) and the
//  stdio relay as helpers, registers the host as an on-demand LaunchAgent via SMAppService,
//  and guides the user through the Accessibility / Screen-Recording grants and MCP-client
//  setup. The host does all the privileged work; this app is its unprivileged face (§2).
//

import AppKit
import ServiceManagement
import SwiftUI

@main
struct MacControlApp: App {
    var body: some Scene {
        WindowGroup("MacControlMCP") {
            ContentView()
                .frame(minWidth: 500, minHeight: 460)
                .padding(20)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var agentStatus = "—"
    @Published var lastMessage = ""

    /// SMAppService only registers a LaunchAgent for a SIGNED app in a stable location. The
    /// unsigned Xcode/DerivedData build fails to register (silently, before this fix) — so warn
    /// when we're not the notarized build in /Applications.
    var runningFromApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    private let agent = SMAppService.agent(plistName: "com.nuclearcyborg.maccontrol.host.plist")

    var relayPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MacControlRelay")
            .path
    }

    var configJSON: String {
        """
        {
          "mcpServers": {
            "mac-control": { "command": "\(relayPath)" }
          }
        }
        """
    }

    func refresh() {
        agentStatus = statusName(agent.status)
    }

    func register() {
        do {
            try agent.register()
            lastMessage = runningFromApplications ? "" :
                "Registered, but this isn't the /Applications build — registration may not stick. Use the notarized app in /Applications."
        } catch {
            lastMessage = "Register failed: \(error.localizedDescription) — the app must be the signed/notarized build running from /Applications."
        }
        refresh()
    }

    func unregister() {
        do {
            try agent.unregister()
            lastMessage = ""
        } catch {
            lastMessage = "Unregister failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func copyConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configJSON, forType: .string)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled ✓"
        case .requiresApproval: return "Requires approval — click “Login Items…”, then enable MacControlMCP under “Allow in the Background”"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MacControlMCP")
                .font(.largeTitle).bold()
            Text("An MCP server for driving macOS apps and the iOS Simulator.")
                .foregroundStyle(.secondary)

            GroupBox("1 · Host agent") {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.runningFromApplications {
                        Text("⚠︎ Run the notarized build from /Applications — an unsigned dev build can't register the host agent.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("Status: \(model.agentStatus)")
                    if !model.lastMessage.isEmpty {
                        Text(model.lastMessage).font(.callout).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Register") { model.register() }
                        Button("Unregister") { model.unregister() }
                        Button("Login Items…") { model.openLoginItems() }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("2 · Grant the host permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Grant the host **Accessibility** (to drive apps) and **Screen Recording** (for screenshots).")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open Accessibility…") { model.openAccessibilitySettings() }
                        Button("Open Screen Recording…") { model.openScreenRecordingSettings() }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("3 · Point your MCP client at the relay") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.relayPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy config JSON") { model.copyConfig() }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
            Button("Refresh") { model.refresh() }
        }
        .onAppear { model.refresh() }
    }
}
