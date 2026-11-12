import Foundation

/// Hardware virtual key codes; no keyboard events are generated in this module.
public struct ButtonShortcut: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var keyLabel: String
    public init(keyCode: UInt16, modifiers: UInt64 = 0, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    public static let modifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
    public var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.modifierMask == 0 && !keyLabel.isEmpty &&
        ![54, 55, 56, 57, 58, 59, 60, 61, 62].contains(keyCode) && (keyCode != 63 || modifiers == 0)
    }
    public var title: String {
        [(18, "⌃"), (19, "⌥"), (17, "⇧"), (20, "⌘")].reduce("") {
            $0 + (modifiers & (1 << $1.0) != 0 ? $1.1 : "")
        } + keyLabel
    }
    public static let returnKey = Self(keyCode: 36, keyLabel: "↩")
    public static let functionKey = Self(keyCode: 63, keyLabel: "fn")
}

public struct ButtonShortcutSettings: Codable, Equatable {
    public var bindings: [String: ButtonShortcut] = [:]
    public init() {}
}

/// Per-session duplicate suppression, separate for each physical control.
public struct ButtonShortcutGate {
    private var last: [String: (UInt16, TimeInterval)] = [:]
    public init() {}
    public mutating func accept(button: String, sequence: UInt16, time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        if let (oldSequence, oldTime) = last[button] {
            let delta = sequence &- oldSequence
            guard delta > 0, delta < 0x8000, time >= oldTime, time - oldTime >= 0.15 else { return false }
        }
        last[button] = (sequence, time)
        return true
    }
}
