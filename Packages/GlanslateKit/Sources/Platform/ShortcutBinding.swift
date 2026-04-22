import AppKit
import Foundation
import GlanslateCore
import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    static let translateRegion = Self(
        "translateRegion",
        default: .init(.t, modifiers: [.command, .shift])
    )
}

public struct ShortcutBinding {
    public static func onTriggerTranslate(_ handler: @escaping @Sendable () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .translateRegion, action: handler)
    }

    public static func removeAllHandlers() {
        KeyboardShortcuts.removeAllHandlers()
    }
}
