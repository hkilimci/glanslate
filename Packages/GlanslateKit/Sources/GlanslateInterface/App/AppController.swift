import AppKit
import GlanslateCore
import GlanslatePersistence
import GlanslateSystem
import OSLog

/// The application's composition root: owns settings, services, windows, the
/// menu bar item, the global shortcut, and the translation workflow.
@MainActor
public final class AppController: NSObject {
    private static let log = Logger(subsystem: "app.glanslate", category: "app")

    let environment: AppEnvironment
    private let windows: WindowRouter
    private var glance: GlanceController!
    private var statusMenu: StatusMenuController?
    private var shortcutToken: HotKeyCenter.Token?

    override public init() {
        let settings = AppSettings()
        let store: SavedTranslationStore?
        do {
            store = try SavedTranslationStore()
        } catch {
            Self.log.error("Saved translations unavailable: \(String(describing: type(of: error)), privacy: .public)")
            store = try? SavedTranslationStore(inMemory: true)
        }
        environment = AppEnvironment(
            settings: settings,
            permissions: PermissionMonitor(),
            credentials: KeychainCredentialStore(),
            store: store
        )
        windows = WindowRouter(environment: environment)
        super.init()
        glance = GlanceController(
            settings: settings,
            store: store,
            credentials: environment.credentials,
            navigation: .init(
                showPermissions: { [weak self] in self?.showOnboarding() },
                openSettings: { [weak self] section in self?.openSettings(section) },
                downloadLanguages: { [weak self] source, target in
                    self?.environment.pendingDownload = LanguagePair(source: source, target: target)
                    self?.openSettings(.translation)
                }
            )
        )
        environment.commands = .init(
            translateRegion: { [weak self] in self?.translateRegion() },
            openSettings: { [weak self] section in self?.openSettings(section) },
            openSavedTranslations: { [weak self] in self?.openSavedTranslations() },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            finishOnboarding: { [weak self] in self?.finishOnboarding() },
            applyShortcut: { [weak self] in self?.registerShortcut() },
            suspendShortcut: { [weak self] in self?.unregisterShortcut() },
            applyDockIcon: { [weak self] in self?.windows.updateActivationPolicy() },
            showAbout: { [weak self] in self?.showAbout() }
        )
    }

    /// Call from `applicationDidFinishLaunching`.
    public func start() {
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu(target: self)
        statusMenu = StatusMenuController(environment: environment)
        windows.updateActivationPolicy()
        registerShortcut()
        if !environment.settings.hasCompletedOnboarding || !Permission.screenRecording.isGranted {
            showOnboarding()
        }
    }

    /// Call from `applicationShouldTerminate`; dismisses temporary windows cleanly.
    public func prepareForTermination() {
        glance.cancelAll()
        if let shortcutToken { HotKeyCenter.shared.unregister(shortcutToken) }
    }

    /// Dock icon clicks open Settings when no window is visible.
    public func handleReopen() {
        openSettings(environment.settingsSection)
    }

    // MARK: Commands

    func translateRegion() {
        glance.translateRegion()
    }

    func openSettings(_ section: SettingsSection) {
        environment.settingsSection = section
        windows.show(.settings)
    }

    func openSavedTranslations() {
        windows.show(.savedTranslations)
    }

    func showOnboarding() {
        environment.permissions.refresh()
        windows.show(.onboarding)
    }

    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Translate text anywhere on your screen.\nCapture and text recognition stay on your Mac.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }

    private func finishOnboarding() {
        environment.settings.hasCompletedOnboarding = true
        windows.close(.onboarding)
    }

    private func unregisterShortcut() {
        if let shortcutToken {
            HotKeyCenter.shared.unregister(shortcutToken)
            self.shortcutToken = nil
        }
    }

    private func registerShortcut() {
        unregisterShortcut()
        environment.shortcutProblem = nil
        guard let combo = environment.settings.translateShortcut else { return }
        do {
            shortcutToken = try HotKeyCenter.shared.register(combo) { [weak self] in
                self?.translateRegion()
            }
        } catch .unavailable {
            environment.shortcutProblem = "\(combo.displayString) is already used by another app. Choose a different shortcut."
        } catch {
            environment.shortcutProblem = "\(combo.displayString) couldn’t be registered. Choose a different shortcut."
        }
    }

    // MARK: Main menu actions

    @objc func translateRegionAction(_ sender: Any?) { translateRegion() }
    @objc func openSettingsAction(_ sender: Any?) { openSettings(environment.settingsSection) }
    @objc func openSavedAction(_ sender: Any?) { openSavedTranslations() }
    @objc func aboutAction(_ sender: Any?) { showAbout() }
}
