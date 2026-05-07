//
//  AXError+ext.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices

/// `AXError` does not conform to `Swift.Error`; wrap it in this struct to throw
/// the result of an `AXUIElement*` call when it is anything other than `.success`.
nonisolated struct AXErrorWrapper: LocalizedError, Equatable {
    let code: AXError
    let context: String?

    init(_ code: AXError, context: String? = nil) {
        self.code = code
        self.context = context
    }

    var errorDescription: String? {
        let base = code.humanDescription
        if let context, !context.isEmpty { return "\(base) (\(context))" }
        return base
    }
}

nonisolated extension AXError {
    var humanDescription: String {
        switch self {
        case .success: "AXError.success"
        case .failure: "AXError.failure (generic failure)"
        case .illegalArgument: "AXError.illegalArgument"
        case .invalidUIElement: "AXError.invalidUIElement (element no longer valid)"
        case .invalidUIElementObserver: "AXError.invalidUIElementObserver"
        case .cannotComplete: "AXError.cannotComplete (target unresponsive or timed out)"
        case .attributeUnsupported: "AXError.attributeUnsupported"
        case .actionUnsupported: "AXError.actionUnsupported"
        case .notificationUnsupported: "AXError.notificationUnsupported"
        case .notImplemented: "AXError.notImplemented"
        case .notificationAlreadyRegistered: "AXError.notificationAlreadyRegistered"
        case .notificationNotRegistered: "AXError.notificationNotRegistered"
        case .apiDisabled: "AXError.apiDisabled (Accessibility permission missing)"
        case .noValue: "AXError.noValue"
        case .parameterizedAttributeUnsupported: "AXError.parameterizedAttributeUnsupported"
        case .notEnoughPrecision: "AXError.notEnoughPrecision"
        @unknown default: "AXError.unknown(\(self.rawValue))"
        }
    }
}

/// Throws an `AXErrorWrapper` for any non-success code.
nonisolated func axCheck(_ err: AXError, _ context: @autoclosure () -> String? = nil) throws {
    if err == .success { return }
    throw AXErrorWrapper(err, context: context())
}
