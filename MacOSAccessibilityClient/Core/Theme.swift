//
//  Theme.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import ApplicationServices
import SwiftUI

/// Groups AX roles into visual families so tree rows, inspector headers, and any
/// other element-presenting UI can render with consistent color + symbol coding.
enum RoleFamily {
    case container    // AXApplication, AXWindow, AXGroup, AXMenu, AXMenuBar, …
    case interactive  // AXButton, AXMenuItem, AXMenuBarItem, AXLink, AXCheckBox, …
    case text         // AXStaticText, AXTextField, AXTextArea
    case visual       // AXImage, AXProgressIndicator, AXLevelIndicator
    case unknown

    static func family(for role: String?) -> RoleFamily {
        guard let role else { return .unknown }
        if Self.containerRoles.contains(role) { return .container }
        if Self.interactiveRoles.contains(role) { return .interactive }
        if Self.textRoles.contains(role) { return .text }
        if Self.visualRoles.contains(role) { return .visual }
        return .unknown
    }

    private static let containerRoles: Set<String> = [
        kAXApplicationRole, kAXWindowRole, kAXGroupRole, kAXMenuRole, kAXMenuBarRole,
        kAXScrollAreaRole, kAXSplitGroupRole, kAXOutlineRole, kAXTableRole,
        kAXListRole, kAXBrowserRole, kAXTabGroupRole, kAXLayoutAreaRole,
        kAXSplitterRole, kAXMatteRole, kAXDrawerRole, kAXSheetRole,
        kAXSystemWideRole, kAXToolbarRole, kAXRowRole, kAXCellRole, kAXColumnRole
    ]

    /// `AXLink` and a few other interactive roles aren't always exposed as public
    /// `kAX…Role` constants depending on SDK; we use literal strings to avoid
    /// build-time surprises.
    private static let interactiveRoles: Set<String> = [
        kAXButtonRole, kAXMenuItemRole, kAXMenuBarItemRole,
        kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXSliderRole,
        kAXValueIndicatorRole, kAXDisclosureTriangleRole, kAXIncrementorRole,
        kAXComboBoxRole, kAXRadioGroupRole,
        "AXLink", "AXSwitch", "AXSegmentedControl", "AXStepper"
    ]

    private static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole
    ]

    private static let visualRoles: Set<String> = [
        kAXImageRole, kAXProgressIndicatorRole, kAXLevelIndicatorRole,
        kAXRelevanceIndicatorRole, kAXBusyIndicatorRole
    ]

    var color: Color {
        switch self {
        case .container: .indigo
        case .interactive: .green
        case .text: .blue
        case .visual: .orange
        case .unknown: .gray
        }
    }

    /// SF Symbol used to mark elements of this family in the tree and inspector header.
    var symbol: String {
        switch self {
        case .container: "rectangle.3.group"
        case .interactive: "cursorarrow.click.2"
        case .text: "text.alignleft"
        case .visual: "photo"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Groups AX notifications into families for the event log's color dots.
enum NotificationFamily {
    case focus
    case value
    case menu
    case window
    case lifecycle
    case other

    static func family(for notification: String) -> NotificationFamily {
        switch notification {
        case kAXFocusedUIElementChangedNotification,
             kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            return .focus
        case kAXValueChangedNotification,
             kAXSelectedTextChangedNotification,
             kAXSelectedRowsChangedNotification,
             kAXSelectedColumnsChangedNotification,
             kAXSelectedCellsChangedNotification,
             kAXSelectedChildrenChangedNotification,
             kAXTitleChangedNotification:
            return .value
        case kAXMenuOpenedNotification,
             kAXMenuClosedNotification,
             kAXMenuItemSelectedNotification:
            return .menu
        case kAXWindowCreatedNotification,
             kAXWindowMovedNotification,
             kAXWindowResizedNotification,
             kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification:
            return .window
        case kAXUIElementDestroyedNotification,
             kAXCreatedNotification,
             kAXApplicationActivatedNotification,
             kAXApplicationDeactivatedNotification,
             kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            return .lifecycle
        default:
            return .other
        }
    }

    var color: Color {
        switch self {
        case .focus: .blue
        case .value: .green
        case .menu: .indigo
        case .window: .cyan
        case .lifecycle: .orange
        case .other: .gray
        }
    }
}
