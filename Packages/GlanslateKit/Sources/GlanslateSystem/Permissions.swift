import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// The privacy permissions Glanslate uses.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    /// Required: lets ScreenCaptureKit read the pixels of the selected region.
    case screenRecording
    /// Optional: lets Glanslate read exact text from apps that expose it.
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    public var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        }
    }

    public var isRequired: Bool { self == .screenRecording }

    public var explanation: String {
        switch self {
        case .screenRecording:
            return "Lets Glanslate capture the area you select so it can read the text. Nothing is recorded continuously, and captures never leave your Mac."
        case .accessibility:
            return "Optional. Lets Glanslate read exact text from apps that expose it, which improves accuracy. Without it, Glanslate reads text from the screen image."
        }
    }

    /// The Privacy & Security pane for this permission.
    var settingsURL: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    public var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// Registers Glanslate in the relevant System Settings list (prompting once if
    /// macOS allows) and opens the pane so the user can switch it on.
    @MainActor
    public func requestAndOpenSettings() {
        switch self {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            // Equivalent to kAXTrustedCheckOptionPrompt; the literal avoids a mutable C global.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        openSettings()
    }

    @MainActor
    public func openSettings() {
        if !NSWorkspace.shared.open(settingsURL) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
        }
    }
}

/// Publishes live permission status and refreshes whenever Glanslate becomes
/// active again — typically right after the user returns from System Settings.
@MainActor
@Observable
public final class PermissionMonitor {
    public private(set) var screenRecording: Bool
    public private(set) var accessibility: Bool

    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    public init() {
        screenRecording = Permission.screenRecording.isGranted
        accessibility = Permission.accessibility.isGranted
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        }
    }

    public func refresh() {
        let screen = Permission.screenRecording.isGranted
        let ax = Permission.accessibility.isGranted
        if screen != screenRecording { screenRecording = screen }
        if ax != accessibility { accessibility = ax }
    }

    /// Polls while a permission screen is visible, since macOS doesn't notify
    /// apps when the user flips a switch in System Settings.
    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                // Stop once the monitor is gone; otherwise the loop would spin on forever.
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// Restarts Glanslate. macOS often applies a new Screen Recording grant only after relaunch.
@MainActor
public enum Relauncher {
    public static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Starts the copy now installed and quits only once it has launched, calling
    /// `willQuit` first. If it can't start, calls `failed` and keeps running.
    public static func relaunch(willQuit: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
            let launched = application != nil && error == nil
            DispatchQueue.main.async {
                if launched {
                    willQuit()
                    NSApp.terminate(nil)
                } else {
                    failed()
                }
            }
        }
    }
}
