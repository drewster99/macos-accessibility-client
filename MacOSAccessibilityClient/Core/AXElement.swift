//
//  AXElement.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import CoreGraphics
import Foundation

/// Lightweight Swift wrapper around `AXUIElement`. Reference-semantic underneath
/// (the `AXUIElement` is a CFTypeRef) but this struct is a value type.
///
/// All calls cross-process to the target app and are synchronous; pair the application
/// element with `setMessagingTimeout(_:)` so an unresponsive target can't lock the caller.
nonisolated struct AXElement: @unchecked Sendable {
    let raw: AXUIElement

    init(_ raw: AXUIElement) {
        self.raw = raw
    }

    static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    static func systemWide() -> AXElement {
        AXElement(AXUIElementCreateSystemWide())
    }

    // MARK: Discovery

    /// All attribute names the target app exposes for this element. Returns an empty
    /// array (not throws) when the element legitimately has none.
    func attributeNames() throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyAttributeNames(raw, &names)
        if err == .noValue || err == .attributeUnsupported { return [] }
        try axCheck(err, "attributeNames")
        return (names as? [String]) ?? []
    }

    /// All actions (`AXPress`, `AXShowMenu`, etc.) the target supports on this element.
    func actionNames() throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(raw, &names)
        if err == .noValue || err == .actionUnsupported { return [] }
        try axCheck(err, "actionNames")
        return (names as? [String]) ?? []
    }

    /// All parameterized-attribute names. Read these via the underlying C call —
    /// the wrapper doesn't yet expose a typed parameterized read.
    func parameterizedAttributeNames() throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyParameterizedAttributeNames(raw, &names)
        if err == .noValue || err == .parameterizedAttributeUnsupported { return [] }
        try axCheck(err, "parameterizedAttributeNames")
        return (names as? [String]) ?? []
    }

    // MARK: Reads / writes

    /// Read an attribute and return whatever CFType the system handed back. The caller
    /// is responsible for downcasting. Returns `nil` (not throws) when the attribute
    /// exists but has no value, or is unsupported on this element — those are common
    /// and not failures.
    func attribute(_ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, name as CFString, &value)
        if err == .noValue || err == .attributeUnsupported { return nil }
        try axCheck(err, "attribute(\(name))")
        return value
    }

    /// Typed convenience. Returns `nil` when the attribute is missing or the cast fails.
    func attribute<T>(_ name: String, as: T.Type = T.self) throws -> T? {
        try attribute(name) as? T
    }

    func setAttribute(_ name: String, value: CFTypeRef) throws {
        try axCheck(
            AXUIElementSetAttributeValue(raw, name as CFString, value),
            "setAttribute(\(name))"
        )
    }

    /// Issue an action against the target app. Success/failure is reported via the
    /// thrown `AXErrorWrapper`; whether the action's *side effect* happened (e.g. a
    /// menu opened) is not — observe notifications or re-read state to verify that.
    func perform(_ action: String) throws {
        try axCheck(
            AXUIElementPerformAction(raw, action as CFString),
            "perform(\(action))"
        )
    }

    /// Default is ~6 seconds for the app element; bring it down so a hung target can't
    /// freeze the inspector. Set on the application element to apply to its whole subtree.
    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(raw, seconds)
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        if AXUIElementGetPid(raw, &pid) == .success { return pid }
        return nil
    }

    // MARK: Convenience

    var role: String? { (try? attribute(kAXRoleAttribute)) as? String }
    var subrole: String? { (try? attribute(kAXSubroleAttribute)) as? String }
    var title: String? { (try? attribute(kAXTitleAttribute)) as? String }
    var roleDescription: String? { (try? attribute(kAXRoleDescriptionAttribute)) as? String }

    /// `kAXValueAttribute` may be a String, Number, AXValue, etc. Stringify whatever we get.
    var valueDescription: String? {
        guard let raw = try? attribute(kAXValueAttribute) else { return nil }
        return AXValueFormatter.describe(raw)
    }

    /// Combines `kAXPositionAttribute` (CGPoint) and `kAXSizeAttribute` (CGSize) into a CGRect.
    var frame: CGRect? {
        let posVal = try? attribute(kAXPositionAttribute)
        let sizeVal = try? attribute(kAXSizeAttribute)
        guard let posVal, let sizeVal else { return nil }
        guard CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let posOk = AXValueGetValue(unsafeDowncast(posVal, to: AXValue.self), .cgPoint, &origin)
        let sizeOk = AXValueGetValue(unsafeDowncast(sizeVal, to: AXValue.self), .cgSize, &size)
        guard posOk, sizeOk else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var children: [AXElement] {
        guard let raw = try? attribute(kAXChildrenAttribute) else { return [] }
        guard let array = raw as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    var parent: AXElement? {
        guard let raw = try? attribute(kAXParentAttribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(raw, to: AXUIElement.self))
    }

    /// Walks `kAXParentAttribute` until it runs out, returning closest-first.
    func ancestorChain(maxDepth: Int = 80) -> [AXElement] {
        var chain: [AXElement] = []
        var current = self.parent
        var visited: Set<AXElement> = []
        var depth = 0
        while let next = current, depth < maxDepth, !visited.contains(next) {
            visited.insert(next)
            chain.append(next)
            current = next.parent
            depth += 1
        }
        return chain
    }
}

nonisolated extension AXElement: Equatable, Hashable, Identifiable {
    static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.raw, rhs.raw)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(raw))
    }

    /// Stable element identity for SwiftUI diffing and scroll targets.
    var id: AXElement { self }
}

/// Stringifies whatever Accessibility hands us. AX values can be `String`, `NSNumber`,
/// `AXValue` (CGPoint/CGSize/CGRect/CFRange), arrays of children, or another `AXUIElement`.
nonisolated enum AXValueFormatter {
    /// Cap string-typed values at this many characters when rendering. AX text-field
    /// values can be the entire document; un-truncated, CoreText/Grid layout will
    /// peg the main thread when one of those lands in the inspector.
    static let stringTruncationLimit = 500

    static func describe(_ value: CFTypeRef) -> String {
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            let str = unsafeDowncast(value, to: CFString.self) as String
            if str.count > Self.stringTruncationLimit {
                let prefix = str.prefix(Self.stringTruncationLimit)
                return "\"\(prefix)…\" (\(str.count) chars)"
            }
            return "\"\(str)\""
        }
        if typeID == CFNumberGetTypeID() {
            return "\(unsafeDowncast(value, to: NSNumber.self))"
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)) ? "true" : "false"
        }
        if typeID == AXUIElementGetTypeID() {
            return ElementLabel.short(for: AXElement(unsafeDowncast(value, to: AXUIElement.self)))
        }
        if typeID == CFArrayGetTypeID() {
            let count = CFArrayGetCount(unsafeDowncast(value, to: CFArray.self))
            return "[\(count) item\(count == 1 ? "" : "s")]"
        }
        if typeID == AXValueGetTypeID() {
            return describeAXValue(unsafeDowncast(value, to: AXValue.self))
        }
        return String(describing: value)
    }

    private static func describeAXValue(_ axValue: AXValue) -> String {
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var p = CGPoint.zero
            AXValueGetValue(axValue, .cgPoint, &p)
            return "(\(Formatting.dimension(p.x)), \(Formatting.dimension(p.y)))"
        case .cgSize:
            var s = CGSize.zero
            AXValueGetValue(axValue, .cgSize, &s)
            return "\(Formatting.dimension(s.width)) × \(Formatting.dimension(s.height))"
        case .cgRect:
            var r = CGRect.zero
            AXValueGetValue(axValue, .cgRect, &r)
            return Formatting.frame(r)
        case .cfRange:
            var range = CFRange(location: 0, length: 0)
            AXValueGetValue(axValue, .cfRange, &range)
            return "{\(range.location), \(range.length)}"
        case .axError:
            var e = AXError.success
            AXValueGetValue(axValue, .axError, &e)
            return e.humanDescription
        case .illegal:
            return "<illegal>"
        @unknown default:
            return "<axvalue>"
        }
    }
}
