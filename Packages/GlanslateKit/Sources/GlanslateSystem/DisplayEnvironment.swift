import AppKit
import GlanslateCore
import ServiceManagement

public extension NSScreen {
    /// The Core Graphics display ID backing this screen.
    var displayID: DisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var displayDescriptor: DisplayDescriptor? {
        guard let id = displayID else { return nil }
        return DisplayDescriptor(id: id, frame: frame, visibleFrame: visibleFrame, scale: backingScaleFactor, name: localizedName)
    }
}

public extension DisplayLayout {
    /// The current arrangement of connected displays.
    @MainActor
    static var current: DisplayLayout {
        DisplayLayout(displays: NSScreen.screens.compactMap(\.displayDescriptor))
    }
}

public extension DisplayDescriptor {
    @MainActor
    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }
}

/// Wraps `SMAppService` so Glanslate can start at login.
@MainActor
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether macOS is waiting for the user to approve the login item in System Settings.
    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
