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
import os

/// Lightweight Swift wrapper around `AXUIElement`. Reference-semantic underneath
/// (the `AXUIElement` is a CFTypeRef) but this struct is a value type.
///
/// Read methods are **async** — they hop to `AXRunner`'s GCD queue so the cross-process
/// XPC blocking happens off Swift's cooperative thread pool and off the main actor.
/// Sync helpers (`syncRole()`, `syncAttribute(_:)`, …) exist for use *inside*
/// `AXRunner.run` closures or other already-off-cooperative contexts; calling them
/// from main actor or a default-actor task re-introduces the blocking we're avoiding.
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

    /// Local call (no XPC) so it stays sync.
    var pid: pid_t? {
        var pid: pid_t = 0
        if AXUIElementGetPid(raw, &pid) == .success { return pid }
        return nil
    }

    /// Sync XPC, but typically <1 ms. Set on the application element to apply to its
    /// whole subtree. Called once at session start; not in any hot path. Logs (rather
    /// than throws) on failure: a stale timeout just means subsequent reads use the
    /// 6 s default, which is recoverable, and the alternative is forcing every caller
    /// to handle a near-impossible error.
    func setMessagingTimeout(_ seconds: Float) {
        let err = AXUIElementSetMessagingTimeout(raw, seconds)
        if err != .success {
            AppLog.ax.error("AXUIElementSetMessagingTimeout failed: \(err.humanDescription, privacy: .public)")
        }
    }
}

// MARK: - Async public API (off-cooperative-pool via AXRunner)

nonisolated extension AXElement {
    /// Read an attribute. Returns `nil` (not throws) when the attribute exists but
    /// has no value or isn't supported on this element — common, not failures.
    func attribute(_ name: String) async throws -> AXAttributeValue? {
        try await AXRunner.run { [self] in try self.syncAttribute(name) }
    }

    /// Typed convenience. Returns `nil` if missing or the cast fails.
    func attribute<T: Sendable>(_ name: String, as: T.Type = T.self) async throws -> T? {
        try await AXRunner.run { [self] in
            try self.syncAttribute(name)?.raw as? T
        }
    }

    /// AX-element-typed attribute reader. Bridges the raw `AXUIElement` (which Swift 6
    /// strict mode won't treat as `Sendable`) into our `@unchecked Sendable` wrapper
    /// before crossing the AX-queue → caller boundary.
    func attributeElement(_ name: String) async throws -> AXElement? {
        try await AXRunner.run { [self] in
            guard let raw = try self.syncAttribute(name)?.raw,
                  CFGetTypeID(raw) == AXUIElementGetTypeID()
            else { return nil }
            return AXElement(unsafeDowncast(raw, to: AXUIElement.self))
        }
    }

    func attributeNames() async throws -> [String] {
        try await AXRunner.run { [self] in try self.syncAttributeNames() }
    }

    func actionNames() async throws -> [String] {
        try await AXRunner.run { [self] in try self.syncActionNames() }
    }

    func parameterizedAttributeNames() async throws -> [String] {
        try await AXRunner.run { [self] in try self.syncParameterizedAttributeNames() }
    }

    /// Issue an action against the target. Side effects (menu opens, etc.) are not
    /// reported — observe notifications or re-read state to verify.
    func perform(_ action: String) async throws {
        try await AXRunner.run { [self] in
            try axCheck(
                AXUIElementPerformAction(self.raw, action as CFString),
                "perform(\(action))"
            )
        }
    }

    func role() async -> String? {
        await AXRunner.run { [self] in self.syncRole() }
    }

    func subrole() async -> String? {
        await AXRunner.run { [self] in self.syncSubrole() }
    }

    func title() async -> String? {
        await AXRunner.run { [self] in self.syncTitle() }
    }

    func roleDescription() async -> String? {
        await AXRunner.run { [self] in self.syncRoleDescription() }
    }

    func valueDescription() async -> String? {
        await AXRunner.run { [self] in self.syncValueDescription() }
    }

    func frame() async -> CGRect? {
        await AXRunner.run { [self] in self.syncFrame() }
    }

    func children() async -> [AXElement] {
        await AXRunner.run { [self] in self.syncChildren() }
    }

    func parent() async -> AXElement? {
        await AXRunner.run { [self] in self.syncParent() }
    }

    /// Walks `kAXParentAttribute` until it runs out, returning closest-first. The
    /// whole walk happens in a single hop to the AX queue so we don't pay
    /// hop-per-ancestor overhead.
    func ancestorChain(maxDepth: Int = 80) async -> [AXElement] {
        await AXRunner.run { [self] in self.syncAncestorChain(maxDepth: maxDepth) }
    }
}

// MARK: - Sync helpers (only safe inside AXRunner.run / already-off-main contexts)

nonisolated extension AXElement {
    func syncAttribute(_ name: String) throws -> AXAttributeValue? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, name as CFString, &value)
        if err == .noValue || err == .attributeUnsupported { return nil }
        try axCheck(err, "attribute(\(name))")
        return value.map(AXAttributeValue.init)
    }

    func syncAttribute<T: Sendable>(_ name: String, as: T.Type = T.self) throws -> T? {
        try syncAttribute(name)?.raw as? T
    }

    func syncAttributeNames() throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyAttributeNames(raw, &names)
        if err == .noValue || err == .attributeUnsupported { return [] }
        try axCheck(err, "attributeNames")
        return (names as? [String]) ?? []
    }

    func syncActionNames() throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(raw, &names)
        if err == .noValue || err == .actionUnsupported { return [] }
        try axCheck(err, "actionNames")
        return (names as? [String]) ?? []
    }

    func syncParameterizedAttributeNames() throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyParameterizedAttributeNames(raw, &names)
        if err == .noValue || err == .parameterizedAttributeUnsupported { return [] }
        try axCheck(err, "parameterizedAttributeNames")
        return (names as? [String]) ?? []
    }

    /// Convenience reader for a string-typed attribute. Returns `nil` for both
    /// "attribute not present" and genuine read failures, but logs the latter at
    /// debug level so they're recoverable in Console.app rather than silently lost.
    private func loggedString(_ attribute: String) -> String? {
        do {
            return try syncAttribute(attribute, as: String.self)
        } catch {
            AppLog.ax.debug("\(attribute, privacy: .public) read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Convenience reader for a CFTypeRef-typed attribute. Same semantics as
    /// `loggedString`: nil for missing-or-unsupported plus logged-then-nil on real
    /// failures so the caller stays simple.
    private func loggedRaw(_ attribute: String) -> CFTypeRef? {
        do {
            return try syncAttribute(attribute)?.raw
        } catch {
            AppLog.ax.debug("\(attribute, privacy: .public) read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func syncRole() -> String? { loggedString(kAXRoleAttribute) }
    func syncSubrole() -> String? { loggedString(kAXSubroleAttribute) }
    func syncTitle() -> String? { loggedString(kAXTitleAttribute) }
    func syncRoleDescription() -> String? { loggedString(kAXRoleDescriptionAttribute) }

    func syncValueDescription() -> String? {
        guard let raw = loggedRaw(kAXValueAttribute) else { return nil }
        return AXValueFormatter.describe(raw)
    }

    func syncFrame() -> CGRect? {
        guard let posVal = loggedRaw(kAXPositionAttribute),
              let sizeVal = loggedRaw(kAXSizeAttribute),
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let posOk = AXValueGetValue(unsafeDowncast(posVal, to: AXValue.self), .cgPoint, &origin)
        let sizeOk = AXValueGetValue(unsafeDowncast(sizeVal, to: AXValue.self), .cgSize, &size)
        guard posOk, sizeOk else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func syncChildren() -> [AXElement] {
        guard let arr = loggedRaw(kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return arr.map(AXElement.init)
    }

    func syncParent() -> AXElement? {
        guard let raw = loggedRaw(kAXParentAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(raw, to: AXUIElement.self))
    }

    func syncAncestorChain(maxDepth: Int = 80) -> [AXElement] {
        var chain: [AXElement] = []
        var current = syncParent()
        var visited: Set<AXElement> = []
        var depth = 0
        while let next = current, depth < maxDepth, !visited.contains(next) {
            visited.insert(next)
            chain.append(next)
            current = next.syncParent()
            depth += 1
        }
        return chain
    }
}

// MARK: - Identity

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

// MARK: - Sendable wrap for opaque CF values returned from reads

/// `CFTypeRef` is `Any`, which Swift can't statically prove `Sendable`. AX values
/// are bridged from Core Foundation types whose reference semantics are immutable
/// for our read-only use, so we wrap them here for boundary crossing back to the
/// caller from the AX queue.
nonisolated struct AXAttributeValue: @unchecked Sendable {
    let raw: CFTypeRef
}

// MARK: - Stringification

/// Stringifies whatever Accessibility hands us. AX values can be `String`, `NSNumber`,
/// `AXValue` (CGPoint/CGSize/CGRect/CFRange), arrays of children, or another `AXUIElement`.
///
/// Always called from an already-off-cooperative context (inside `AXRunner.run` or
/// the AX-observer notification callback, which is on main but only stringifies
/// short-lived user-info dictionaries). Element-typed values do their own inline
/// sync read of role/title; that nested read is tolerated because we're already
/// off the cooperative pool.
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
            let element = AXElement(unsafeDowncast(value, to: AXUIElement.self))
            let role = element.syncRole() ?? "<unidentified>"
            if let title = element.syncTitle(), !title.isEmpty {
                return "<\(role) \"\(title)\">"
            }
            return "<\(role)>"
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

    static func describe(_ value: AXAttributeValue) -> String {
        describe(value.raw)
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
