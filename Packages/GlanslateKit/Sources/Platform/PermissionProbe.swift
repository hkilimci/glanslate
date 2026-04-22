import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GlanslateCore
import IOKit.hid

public struct PermissionProbe: Sendable {
    public init() {}

    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func accessibilityGranted(promptIfNot: Bool = false) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let opts: CFDictionary = [
            promptKey: promptIfNot,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static func inputMonitoringGranted() -> Bool {
        // IOHIDCheckAccess available on macOS 10.15+.
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        return status == kIOHIDAccessTypeGranted
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public static func openPane(_ kind: PermissionKind) {
        let url: URL
        switch kind {
        case .screenRecording:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        }
        NSWorkspace.shared.open(url)
    }
}
