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
    private let updateToast = ToastPresenter()

    override public init() {
        let settings = AppSettings()
        let store: SavedTranslationStore?
        do {
            store = try SavedTranslationStore()
        } catch {
            // No in-memory stand-in: pins that look saved but vanish at quit are worse than
            // pinning being visibly unavailable until the next launch.
            Self.log.error("Saved translations unavailable: \(String(describing: type(of: error)), privacy: .public)")
            store = nil
        }
        environment = AppEnvironment(
            settings: settings,
            permissions: PermissionMonitor(),
            credentials: KeychainCredentialStore(),
            store: store,
            updates: Self.makeUpdateController(settings: settings)
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
            showAbout: { [weak self] in self?.showAbout() },
            checkForUpdates: { [weak self] in self?.checkForUpdates() }
        )
        environment.updates?.onUpdateFound = { [weak self] update in self?.announce(update) }
    }

    /// Updates come from the GitHub repository named in Info.plist; builds without one don't check.
    private static func makeUpdateController(settings: AppSettings) -> UpdateController? {
        let info = Bundle.main.infoDictionary
        guard let repository = info?["GlanslateUpdateRepository"] as? String,
              let versionString = info?["CFBundleShortVersionString"] as? String,
              let version = AppVersion(versionString),
              let feed = GitHubReleaseFeed(repository: repository, appVersion: versionString)
        else { return nil }
        return UpdateController(currentVersion: version, settings: settings, checker: feed, installer: UpdateInstaller())
    }

    /// Call from `applicationDidFinishLaunching`.
    public func start() {
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu(target: self)
        statusMenu = StatusMenuController(environment: environment)
        windows.updateActivationPolicy()
        registerShortcut()
        environment.updates?.startSchedule()
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

    func checkForUpdates() {
        openSettings(.about)
        environment.updates?.checkNow()
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

    private func announce(_ update: AvailableUpdate) {
        guard let current = environment.updates?.currentVersion else { return }
        updateToast.show(
            title: "Glanslate \(update.version) is available",
            message: "You have version \(current). See what’s new, then install it in a click.",
            symbol: "arrow.down.circle.fill",
            tint: .accentColor,
            action: (title: "Update…", handler: { [weak self] in self?.openSettings(.about) })
        )
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
        } catch HotKeyCenter.RegistrationError.unavailable {
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
    @objc func checkForUpdatesAction(_ sender: Any?) { checkForUpdates() }
}
