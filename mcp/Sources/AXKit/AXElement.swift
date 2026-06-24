//
//  AXElement.swift
//  AXKit
//
//  Lean value wrapper around AXUIElement for the server's read path. Sync readers run
//  off the main thread via AXRunner — each is a cross-process XPC call. (Adapted from the
//  proven patterns in the app's Core/AXElement.swift, minus the inspector-only formatting.)
//

import ApplicationServices
import CoreGraphics
import Foundation

public struct AXElement: @unchecked Sendable {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    public static func systemWide() -> AXElement {
        AXElement(AXUIElementCreateSystemWide())
    }

    /// Applies to the whole subtree; set once at session start so a hung target can't
    /// block reads indefinitely.
    public func setMessagingTimeout(_ seconds: Float) {
        _ = AXUIElementSetMessagingTimeout(raw, seconds)
    }

    /// Owning process — local call, no XPC.
    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
    }

    public func copyAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success ? value : nil
    }

    public func stringAttribute(_ name: String) -> String? {
        copyAttribute(name) as? String
    }

    public var role: String? { stringAttribute(kAXRoleAttribute) }
    public var subrole: String? { stringAttribute(kAXSubroleAttribute) }
    public var title: String? { stringAttribute(kAXTitleAttribute) }
    public var identifier: String? { stringAttribute("AXIdentifier") }

    /// String form of AXValue — handles the common String and NSNumber cases.
    public var value: String? {
        guard let value = copyAttribute(kAXValueAttribute) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    public var isValueSettable: Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(raw, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    public var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return ((names as? [String]) ?? []).map { Self.cleanActionName($0) }
    }

    /// AX action names are single-line tokens ("AXPress"). Some apps leak the *description* of
    /// an NSAccessibilityCustomAction into the names array instead — a multi-line
    /// "Name:Move next\nTarget:0x0\nSelector:(null)" blob whose newlines would break the
    /// line-based snapshot. Reduce such an entry to its display name; collapse any other stray
    /// newlines so a single action can never span lines.
    static func cleanActionName(_ name: String) -> String {
        guard name.contains(where: { $0.isNewline }) else { return name }
        let lines = name.split(whereSeparator: { $0.isNewline })
        if name.hasPrefix("Name:"), let first = lines.first {
            return String(first.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    public var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public var parameterizedAttributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public var children: [AXElement] {
        guard let array = copyAttribute(kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    public var frame: CGRect? {
        guard let positionValue = copyAttribute(kAXPositionAttribute),
              let sizeValue = copyAttribute(kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let position = unsafeDowncast(positionValue, to: AXValue.self)
        let dimensions = unsafeDowncast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The element this (system-wide or app) element reports as focused.
    public var focusedElement: AXElement? {
        guard let value = copyAttribute(kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// Hit-test: the element at a screen point (AX top-left coordinates).
    public func elementAtPosition(x: Float, y: Float) -> AXElement? {
        var out: AXUIElement?
        guard AXUIElementCopyElementAtPosition(raw, x, y, &out) == .success, let element = out else { return nil }
        return AXElement(element)
    }

    /// False only when the element has been destroyed (`kAXErrorInvalidUIElement`).
    /// Other errors/success count as alive — we only want to detect a dead reference.
    public var isAlive: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    // MARK: - Mutators (effect-causing — semantic AX, no synthetic events)

    @discardableResult
    public func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }

    @discardableResult
    public func setValue(_ value: String) -> Bool {
        // Guard settability — writing a CFString to a non-settable or non-string value
        // (slider/checkbox/numeric) would fail or misbehave. (Typed conversion per
        // attribute is a future refinement; today this is the string-value path.)
        guard isValueSettable else { return false }
        return AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, value as CFString) == .success
    }

    @discardableResult
    public func setFocused() -> Bool {
        AXUIElementSetAttributeValue(raw, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    // MARK: - Window management (AX writes on a window element)

    @discardableResult
    public func setPosition(_ point: CGPoint) -> Bool {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXPositionAttribute as CFString, axValue) == .success
    }

    @discardableResult
    public func setSize(_ size: CGSize) -> Bool {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, axValue) == .success
    }

    @discardableResult
    public func setMinimized(_ minimized: Bool) -> Bool {
        let flag: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(raw, kAXMinimizedAttribute as CFString, flag) == .success
    }

    @discardableResult
    public func raise() -> Bool {
        AXUIElementPerformAction(raw, kAXRaiseAction as CFString) == .success
    }

    /// The app element's menu bar (for menu-path driving).
    public var menuBar: AXElement? {
        guard let value = copyAttribute(kAXMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }
}

// AX guarantees two AXUIElementRefs to the same element are CFEqual — this is what lets
// the session assign a STABLE ref to an element across snapshots (so diffs are meaningful).
extension AXElement: Hashable {
    public static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.raw, rhs.raw)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(raw))
    }
}
