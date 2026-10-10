import AppKit
import Carbon.HIToolbox
import GlanslateCore

/// Registers system-wide keyboard shortcuts with the Carbon hot key API, which
/// needs no Accessibility or Input Monitoring permission.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt32
    }

    public enum RegistrationError: Error, Equatable {
        /// Another app or the system already uses this shortcut.
        case unavailable
        case failed(OSStatus)
    }

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    @discardableResult
    public func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) throws(RegistrationError) -> Token {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            Self.carbonModifiers(combo.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw status == OSStatus(eventHotKeyExistsErr) ? .unavailable : .failed(status)
        }
        references[id] = reference
        handlers[id] = action
        return Token(id: id)
    }

    public func unregister(_ token: Token) {
        if let reference = references.removeValue(forKey: token.id) {
            UnregisterEventHotKey(reference)
        }
        handlers.removeValue(forKey: token.id)
    }

    fileprivate func handle(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), glanslateHotKeyHandler, 1, &eventType, nil, &eventHandler)
    }

    /// "GLNS"
    nonisolated static let signature: OSType = 0x474C_4E53

    nonisolated public static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}

/// Carbon delivers hot key events on the main thread.
private func glanslateHotKeyHandler(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        HotKeyCenter.shared.handle(id: id)
    }
    return noErr
}

public extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

public extension KeyCombo {
    /// Builds a combo from a key event, labeling the key in the current keyboard layout.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = KeyModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        let label = KeyCombo.label(forKeyCode: event.keyCode)
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers, key: label)
    }
}

public extension RevealModifier {
    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        case .shift: return .shift
        }
    }
}
