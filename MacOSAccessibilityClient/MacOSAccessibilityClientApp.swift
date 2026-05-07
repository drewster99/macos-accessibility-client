//
//  MacOSAccessibilityClientApp.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import SwiftUI

@main
struct MacOSAccessibilityClientApp: App {
    @State private var permissions = AccessibilityPermissions()
    @State private var runningApps = RunningAppsViewModel()
    @State private var focus = SystemFocusTracker()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(permissions)
                .environment(runningApps)
                .environment(focus)
                .environment(settings)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("View") {
                ViewMenuItems(settings: settings)
            }
        }

        Settings {
            SettingsView(settings: settings)
        }
    }
}

private struct ViewMenuItems: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle("Walk menu chain on AXPress", isOn: $settings.walkMenuChainOnPress)
            .keyboardShortcut("M", modifiers: [.command, .shift])
    }
}

private struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Menu chain walker") {
                Toggle("Walk menu chain on AXPress", isOn: $settings.walkMenuChainOnPress)
                    .help("When AXPressing an AXMenuItem or AXMenuBarItem, replay AXPress on each ancestor in turn so the target's submenu actually opens.")

                LabeledContent("Delay between presses") {
                    HStack {
                        Slider(value: $settings.menuWalkPressDelay, in: 0.0...1.0)
                            .frame(maxWidth: 220)
                        Text(format(settings.menuWalkPressDelay))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("Delay before refreshing tree") {
                    HStack {
                        Slider(value: $settings.menuWalkRefreshDelay, in: 0.0...1.0)
                            .frame(maxWidth: 220)
                        Text(format(settings.menuWalkRefreshDelay))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 280)
    }

    private func format(_ d: Double) -> String {
        String(format: "%.2fs", d)
    }
}
