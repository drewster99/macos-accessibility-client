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

    /// Whether `attribute` is writable on this element (`AXUIElementIsAttributeSettable`).
    public func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(raw, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// The selected text range (a zero-length range is the insertion caret). `nil` if the element
    /// doesn't expose a CFRange-typed `AXSelectedTextRange`.
    public var selectedTextRange: CFRange? {
        guard let value = copyAttribute(kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Whether this app element exposes a window yet. Checks `AXChildren` (which lists windows and
    /// populates promptly on launch) as well as `AXWindows` (which can lag empty for seconds after
    /// an app launches) — so launch readiness isn't stalled waiting on `AXWindows`.
    public var hasWindow: Bool {
        if children.contains(where: { $0.role == kAXWindowRole as String }) { return true }
        return !windows.isEmpty
    }

    /// Total character count (`AXNumberOfCharacters`), for sanity-checking a target range.
    public var numberOfCharacters: Int? {
        (copyAttribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }

    /// Replace the current selection (or insert at the caret, when the selection is zero-length)
    /// with `text` — the same effect as typing, via the settable `AXSelectedText` attribute. No
    /// keystrokes, no clipboard, no focus needed. Caller must confirm `isSettable` first.
    @discardableResult
    public func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(raw, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Move the selection/caret to `range` (`AXSelectedTextRange`).
    @discardableResult
    public func setSelectedRange(_ range: CFRange) -> Bool {
        var value = range
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
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

    /// The element's parent in the AX tree (`kAXParentAttribute`), or `nil` at the root.
    public var parent: AXElement? {
        guard let value = copyAttribute(kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// The window containing this element (`kAXWindowAttribute`), or `nil`. Raising this to be the
    /// key/main window is required before synthetic keystrokes will reach the element — keys go to
    /// the frontmost app's *key window*, so a focused element in a background window won't receive
    /// them.
    public var window: AXElement? {
        guard let value = copyAttribute(kAXWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// Whether the element currently holds keyboard focus (`kAXFocusedAttribute` is true) — the
    /// read-back used to confirm a `setFocused()` actually took (some elements accept the set call
    /// but never become first responder).
    public var isFocused: Bool {
        guard let value = copyAttribute(kAXFocusedAttribute),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
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

// MARK: - control_app enrichment (labels, values, ranges, links, generic booleans, collections)

public extension AXElement {
    /// Numeric attribute reader (NSNumber-backed AX values).
    func numberAttribute(_ name: String) -> Double? {
        (copyAttribute(name) as? NSNumber)?.doubleValue
    }

    /// Array-of-elements attribute reader (rows/cells/etc.).
    func elementArrayAttribute(_ name: String) -> [AXElement]? {
        guard let array = copyAttribute(name) as? [AXUIElement] else { return nil }
        return array.map(AXElement.init)
    }

    /// Accessibility description / help — the 2nd and 3rd label fallbacks after AXTitle (§7).
    var axDescription: String? { stringAttribute("AXDescription") }
    var help: String? { stringAttribute("AXHelp") }

    /// AXValue as a number when the control's value is numeric (slider/scrollbar/stepper).
    var numericValue: Double? { (copyAttribute(kAXValueAttribute) as? NSNumber)?.doubleValue }
    var valueIsNumeric: Bool { numericValue != nil }

    var minValue: Double? { numberAttribute("AXMinValue") }
    var maxValue: Double? { numberAttribute("AXMaxValue") }
    var valueDescription: String? { stringAttribute("AXValueDescription") }
    var placeholderValue: String? { stringAttribute("AXPlaceholderValue") }

    /// AXURL destination as an absolute string (links, web areas, some images).
    var url: String? { (copyAttribute("AXURL") as? NSURL)?.absoluteString }

    /// Every boolean-typed attribute, name → value. The generic state source (§8); the
    /// renderer surfaces the true ones (with AXEnabled inverted to `disabled`).
    var booleanAttributes: [String: Bool] {
        var result: [String: Bool] = [:]
        for name in attributeNames {
            guard let value = copyAttribute(name), CFGetTypeID(value) == CFBooleanGetTypeID() else { continue }
            result[name] = CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        return result
    }

    /// Raw (uncleaned) action names — the exact strings `AXUIElementPerformAction` needs (§9).
    var rawActionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Immediate-child count — one cheap read for the `[N hidden]` marker (§5). `nil` when the
    /// read fails (→ `[more hidden]`).
    var childCount: Int? {
        guard let array = copyAttribute(kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return array.count
    }

    // Disclosure (outline rows)
    var disclosureLevel: Int? { numberAttribute("AXDisclosureLevel").map { Int($0) } }
    var isDisclosing: Bool? {
        guard let value = copyAttribute("AXDisclosing"), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
    var isDisclosingSettable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(raw, "AXDisclosing" as CFString, &settable) == .success && settable.boolValue
    }
    @discardableResult
    func setDisclosing(_ flag: Bool) -> Bool {
        AXUIElementSetAttributeValue(raw, "AXDisclosing" as CFString, flag ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    // Collections (table/grid/outline) — efficient subset attributes (§10)
    var rowCount: Int? { numberAttribute("AXRowCount").map { Int($0) } }
    var columnCount: Int? { numberAttribute("AXColumnCount").map { Int($0) } }
    var columnTitles: [String]? { copyAttribute("AXColumnTitles") as? [String] }
    var visibleRows: [AXElement]? { elementArrayAttribute("AXVisibleRows") }
    var selectedRows: [AXElement]? { elementArrayAttribute("AXSelectedRows") }
    var visibleCells: [AXElement]? { elementArrayAttribute("AXVisibleCells") }
    var selectedCells: [AXElement]? { elementArrayAttribute("AXSelectedCells") }

    /// The app element's windows in `AXWindows` order (native / best-effort z-order, §4).
    var windows: [AXElement] { elementArrayAttribute("AXWindows") ?? [] }

    /// The point AX recommends for activating this element (`AXActivationPoint`), in top-left
    /// screen coordinates — the right place to synthesize a click for `activate`.
    var activationPoint: CGPoint? {
        guard let value = copyAttribute("AXActivationPoint"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
    }

    /// Numeric value setter (slider/scrollbar) — writes a `CFNumber`, guarded by settability.
    @discardableResult
    func setValue(number: Double) -> Bool {
        guard isValueSettable else { return false }
        return AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, NSNumber(value: number)) == .success
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
