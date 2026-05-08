//
//  AppSettings.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import Foundation
import Observation

/// User-tunable behavior persisted in `UserDefaults`.
///
/// `didSet` writes through on user changes. Defaults are loaded into the
/// inline initializers via the `loadBool` / `loadDouble` helpers, so the
/// stored property starts at the persisted value (or the supplied default
/// if no key is set) and `didSet` does not fire during initialisation.
@MainActor
@Observable
final class AppSettings {
    static let walkMenuChainOnPressKey = "walkMenuChainOnPress"
    static let menuWalkPressDelayKey = "menuWalkPressDelay"
    static let menuWalkRefreshDelayKey = "menuWalkRefreshDelay"

    var walkMenuChainOnPress: Bool = AppSettings.loadBool(AppSettings.walkMenuChainOnPressKey, default: true) {
        didSet { UserDefaults.standard.set(walkMenuChainOnPress, forKey: Self.walkMenuChainOnPressKey) }
    }

    /// Seconds to wait after each `AXPress` in the chain before pressing the next item.
    var menuWalkPressDelay: Double = AppSettings.loadDouble(AppSettings.menuWalkPressDelayKey, default: 0.15) {
        didSet { UserDefaults.standard.set(menuWalkPressDelay, forKey: Self.menuWalkPressDelayKey) }
    }

    /// Seconds to wait after the final `AXPress` before triggering a tree refresh.
    var menuWalkRefreshDelay: Double = AppSettings.loadDouble(AppSettings.menuWalkRefreshDelayKey, default: 0.20) {
        didSet { UserDefaults.standard.set(menuWalkRefreshDelay, forKey: Self.menuWalkRefreshDelayKey) }
    }

    nonisolated private static func loadBool(_ key: String, default defaultValue: Bool) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) != nil ? d.bool(forKey: key) : defaultValue
    }

    nonisolated private static func loadDouble(_ key: String, default defaultValue: Double) -> Double {
        let d = UserDefaults.standard
        return d.object(forKey: key) != nil ? d.double(forKey: key) : defaultValue
    }
}
