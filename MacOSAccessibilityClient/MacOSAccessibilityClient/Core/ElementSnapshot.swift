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

    init(_ element: AXElement) {
        self.role = element.role ?? "<unidentified>"
        self.subrole = element.subrole?.nonEmptyOrNil
        self.title = element.title?.nonEmptyOrNil
        self.frame = element.frame

        var errors: [ReadError] = []

        let attrNames: [String]
        do {
            attrNames = try element.attributeNames()
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
            do {
                if let raw = try element.attribute(name) {
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
        }
        self.attributes = rows

        do {
            self.actions = try element.actionNames()
        } catch {
            self.actions = []
            errors.append(ReadError(
                context: "AXUIElementCopyActionNames",
                message: Self.message(for: error)
            ))
        }

        do {
            self.parameterizedAttributes = try element.parameterizedAttributeNames()
        } catch {
            self.parameterizedAttributes = []
            errors.append(ReadError(
                context: "AXUIElementCopyParameterizedAttributeNames",
                message: Self.message(for: error)
            ))
        }

        self.readErrors = errors
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// Serializes expensive cross-process AX reads off the main actor.
actor ElementSnapshotBuilder {
    func snapshot(for element: AXElement) -> ElementSnapshot {
        ElementSnapshot(element)
    }
}
