//
//  PermissionsBanner.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import SwiftUI

struct PermissionsBanner: View {
    @Environment(AccessibilityPermissions.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Accessibility permission required")
                    .font(.headline)
            }
            Text("This app needs Accessibility access to read other apps' UI. Click below to request it, or open System Settings to grant it manually.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Request Permission") {
                    permissions.requestAndPrompt()
                }
                Button("Open System Settings") {
                    permissions.openSystemSettings()
                }
                Button("Recheck") {
                    permissions.recheck()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.4)))
    }
}
