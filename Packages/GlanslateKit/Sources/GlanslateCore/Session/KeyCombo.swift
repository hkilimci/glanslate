import Foundation

/// Modifier keys of a keyboard shortcut.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Symbols in the order macOS menus use: ⌃⌥⇧⌘.
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A global keyboard shortcut: a virtual key code plus modifiers.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// The hardware-independent virtual key code (`kVK_*`).
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// The key's label in the user's keyboard layout when it was recorded, e.g. "T" or "Space".
    public var key: String

    public init(keyCode: UInt16, modifiers: KeyModifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// ⇧⌘T
    public static let defaultTranslate = KeyCombo(keyCode: 0x11, modifiers: [.command, .shift], key: "T")

    public var displayString: String { modifiers.symbols + key }

    static let functionKeyCodes: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    public var isFunctionKey: Bool { Self.functionKeyCodes.contains(keyCode) }

    /// Global shortcuts need ⌘, ⌥, or ⌃ (Shift alone would steal typing), unless they use a function key.
    public var isValidGlobalShortcut: Bool {
        isFunctionKey || !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// A readable label for keys that don't produce a printable character.
    public static func label(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 0x31: return "Space"
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x33: return "⌫"
        case 0x75: return "⌦"
        case 0x35: return "⎋"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x73: return "↖"
        case 0x77: return "↘"
        case 0x74: return "⇞"
        case 0x79: return "⇟"
        default:
            let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
            if let index = functionKeys.firstIndex(of: keyCode) { return "F\(index + 1)" }
            return nil
        }
    }
}
