//
//  ElementSnapshot.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import CoreGraphics
import Foundation
import os

/// One row in the inspector's attribute table.
nonisolated struct AttributeRow: Identifiable, Sendable {
    let id: String
    let name: String
    let value: String

    init(name: String, value: String) {
        self.id = name
        self.name = name
        self.value = value
    }
}

/// Records a non-success `AXError` from a single AX call so the inspector can show
/// it instead of silently rendering the call as "no value".
nonisolated struct ReadError: Identifiable, Sendable {
    let id = UUID()
    let context: String
    let message: String
}

/// Frozen view of one `AXElement` for rendering. Building this is what triggers all
/// the cross-process AX reads — the view layer should never call AX itself.
nonisolated struct ElementSnapshot: Sendable {
    let role: String
    let subrole: String?
    let title: String?
    let frame: CGRect?
    let attributes: [AttributeRow]
    let actions: [String]
    let parameterizedAttributes: [String]
    let readErrors: [ReadError]

    /// Build a snapshot off the cooperative pool. Single hop to `AXRunner` does
    /// every read for this element back-to-back; the caller awaits and gets a
    /// finished `Sendable` value.
    static func build(for element: AXElement) async -> ElementSnapshot {
        await AXRunner.run { ElementSnapshot(syncFor: element) }
    }

    /// Synchronous builder. Only safe to call from inside an `AXRunner.run` block
    /// or another already-off-cooperative context.
    init(syncFor element: AXElement) {
        let snapshotStart = CFAbsoluteTimeGetCurrent()
        let resolvedRole = element.syncRole() ?? "<unidentified>"
        self.role = resolvedRole
        self.subrole = element.syncSubrole()?.nonEmptyOrNil
        self.title = element.syncTitle()?.nonEmptyOrNil
        self.frame = element.syncFrame()

        var errors: [ReadError] = []

        let attrNames: [String]
        do {
            attrNames = try element.syncAttributeNames()
        } catch {
            attrNames = []
            errors.append(ReadError(
                context: "AXUIElementCopyAttributeNames",
                message: Self.message(for: error)
            ))
        }

        var rows: [AttributeRow] = []
        rows.reserveCapacity(attrNames.count)
        for name in attrNames {
            let attrStart = CFAbsoluteTimeGetCurrent()
            do {
                if let raw = try element.syncAttribute(name) {
                    rows.append(AttributeRow(name: name, value: AXValueFormatter.describe(raw)))
                } else {
                    rows.append(AttributeRow(name: name, value: "—"))
                }
            } catch {
                rows.append(AttributeRow(name: name, value: "<error>"))
                errors.append(ReadError(
                    context: "attribute(\(name))",
                    message: Self.message(for: error)
                ))
            }
            let attrMs = (CFAbsoluteTimeGetCurrent() - attrStart) * 1000
            if attrMs > 50 {
                AppLog.ax.notice("slow read \(resolvedRole, privacy: .public).\(name, privacy: .public) — \(attrMs, format: .fixed(precision: 2), privacy: .public) ms")
            }
        }
        self.attributes = rows

        do {
            self.actions = try element.syncActionNames()
        } catch {
            self.actions = []
            errors.append(ReadError(
                context: "AXUIElementCopyActionNames",
                message: Self.message(for: error)
            ))
        }

        do {
            self.parameterizedAttributes = try element.syncParameterizedAttributeNames()
        } catch {
            self.parameterizedAttributes = []
            errors.append(ReadError(
                context: "AXUIElementCopyParameterizedAttributeNames",
                message: Self.message(for: error)
            ))
        }

        self.readErrors = errors

        let totalMs = (CFAbsoluteTimeGetCurrent() - snapshotStart) * 1000
        AppLog.snapshot.info("snapshot(\(resolvedRole, privacy: .public)) — \(totalMs, format: .fixed(precision: 2), privacy: .public) ms · \(rows.count, privacy: .public) attrs · \(errors.count, privacy: .public) errors")
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
