import AppKit
import GlanslateSystem
import SwiftUI

/// Opens and reuses Glanslate's standard windows. While any of them is open
/// the app is a regular app (Dock icon, ⌘-Tab), so windows always come to the
/// front even when Glanslate otherwise lives only in the menu bar.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    enum Kind: Hashable {
        case settings, savedTranslations, onboarding
    }

    private let environment: AppEnvironment
    private var windows: [Kind: NSWindow] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show(_ kind: Kind) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        updateActivationPolicy(windowOpening: true)
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: Kind) {
        windows[kind]?.performClose(nil)
    }

    func isVisible(_ kind: Kind) -> Bool {
        windows[kind]?.isVisible ?? false
    }

    func updateActivationPolicy(windowOpening: Bool = false) {
        let hasOpenWindow = windowOpening || windows.values.contains { $0.isVisible }
        let policy: NSApplication.ActivationPolicy = environment.settings.showsDockIcon || hasOpenWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Let the window finish closing before deciding whether to hide the Dock icon.
        Task { @MainActor [weak self] in
            self?.updateActivationPolicy()
        }
    }

    private func makeWindow(_ kind: Kind) -> NSWindow {
        let window: NSWindow
        switch kind {
        case .settings:
            window = makeWindow(
                SettingsView().environment(environment),
                size: CGSize(width: 760, height: 580),
                minSize: CGSize(width: 680, height: 460),
                title: "Settings",
                autosave: "GlanslateSettings"
            )
        case .savedTranslations:
            window = makeWindow(
                SavedTranslationsView().environment(environment),
                size: CGSize(width: 880, height: 580),
                minSize: CGSize(width: 640, height: 400),
                title: "Saved Translations",
                autosave: "GlanslateSavedTranslations"
            )
        case .onboarding:
            window = makeWindow(
                OnboardingView().environment(environment),
                size: CGSize(width: 620, height: 600),
                minSize: CGSize(width: 620, height: 600),
                title: "Welcome to Glanslate",
                autosave: nil
            )
            window.styleMask.remove(.resizable)
            window.styleMask.remove(.miniaturizable)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
        window.delegate = self
        return window
    }

    private func makeWindow(_ root: some View, size: CGSize, minSize: CGSize, title: String, autosave: String?) -> NSWindow {
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = title
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenNone)
        if let autosave {
            window.setFrameAutosaveName(autosave)
        }
        return window
    }
}
