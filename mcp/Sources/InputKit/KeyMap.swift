//
//  KeyMap.swift
//  InputKit
//
//  Parses key-combo specs like "cmd+shift+s" into a (CGKeyCode, CGEventFlags) chord for
//  synthetic keyboard events (§5/§8). Pure logic — fully unit-testable, no event posting.
//  Key codes are the US ANSI virtual key codes (kVK_ANSI_*).
//

import CoreGraphics
import Foundation

public struct KeyChord: Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags
    public init(keyCode: CGKeyCode, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }
}

public enum KeyMap {
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
        "fn": .maskSecondaryFn
    ]

    /// "cmd+shift+s" → chord. The last token is the key; earlier tokens are modifiers.
    /// Returns nil for an unknown key or modifier (never a silent wrong chord).
    public static func parse(_ spec: String) -> KeyChord? {
        let tokens = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyName = tokens.last, let keyCode = keyCodes[keyName] else { return nil }

        var flags: CGEventFlags = []
        for modifier in tokens.dropLast() {
            guard let flag = modifiers[modifier] else { return nil }
            flags.insert(flag)
        }
        return KeyChord(keyCode: keyCode, flags: flags)
    }
}
