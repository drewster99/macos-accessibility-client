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
/// `didSet` writes through to `UserDefaults` so settings survive relaunch. Defaults are
/// applied only when the corresponding key is missing (so a user-set value of `false`
/// for a `Bool` doesn't get overwritten by the default).
@MainActor
@Observable
final class AppSettings {
    static let walkMenuChainOnPressKey = "walkMenuChainOnPress"
    static let menuWalkPressDelayKey = "menuWalkPressDelay"
    static let menuWalkRefreshDelayKey = "menuWalkRefreshDelay"

    var walkMenuChainOnPress: Bool = true {
        didSet { UserDefaults.standard.set(walkMenuChainOnPress, forKey: Self.walkMenuChainOnPressKey) }
    }

    /// Seconds to wait after each `AXPress` in the chain before pressing the next item.
    var menuWalkPressDelay: Double = 0.15 {
        didSet { UserDefaults.standard.set(menuWalkPressDelay, forKey: Self.menuWalkPressDelayKey) }
    }

    /// Seconds to wait after the final `AXPress` before triggering a tree refresh.
    var menuWalkRefreshDelay: Double = 0.20 {
        didSet { UserDefaults.standard.set(menuWalkRefreshDelay, forKey: Self.menuWalkRefreshDelayKey) }
    }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.walkMenuChainOnPressKey) != nil {
            walkMenuChainOnPress = d.bool(forKey: Self.walkMenuChainOnPressKey)
        }
        if d.object(forKey: Self.menuWalkPressDelayKey) != nil {
            menuWalkPressDelay = d.double(forKey: Self.menuWalkPressDelayKey)
        }
        if d.object(forKey: Self.menuWalkRefreshDelayKey) != nil {
            menuWalkRefreshDelay = d.double(forKey: Self.menuWalkRefreshDelayKey)
        }
    }
}
