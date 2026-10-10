import AppKit
import GlanslateCore
import GlanslatePersistence
import GlanslateSystem
import Observation

/// Sections of the Settings window, in sidebar order.
public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, shortcuts, translation, appearance, saved, about

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .translation: return "Translation"
        case .appearance: return "Appearance"
        case .saved: return "Saved Translations"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .translation: return "translate"
        case .appearance: return "paintbrush"
        case .saved: return "pin"
        case .about: return "info"
        }
    }

    var tint: NSColor {
        switch self {
        case .general: return .systemGray
        case .shortcuts: return .systemIndigo
        case .translation: return .systemBlue
        case .appearance: return .systemPurple
        case .saved: return .systemOrange
        case .about: return .systemGray
        }
    }
}

struct LanguagePair: Hashable, Sendable {
    var source: Language
    var target: Language
}

/// Shared state and commands for every window, injected into SwiftUI views.
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let permissions: PermissionMonitor
    let credentials: any CredentialStoring
    let store: SavedTranslationStore?
    /// True when the on-disk store couldn't open and saved translations last only until quit.
    var isStoreTemporary = false

    var settingsSection: SettingsSection = .general
    /// A language pair Settings should offer to download, set from an overlay error.
    var pendingDownload: LanguagePair?
    /// Bumped when an API key changes so views re-read Keychain state.
    var credentialsRevision = 0
    /// The last problem registering the global shortcut, if any.
    var shortcutProblem: String?

    @ObservationIgnored var commands = Commands()

    struct Commands {
        var translateRegion: @MainActor () -> Void = {}
        var openSettings: @MainActor (SettingsSection) -> Void = { _ in }
        var openSavedTranslations: @MainActor () -> Void = {}
        var showOnboarding: @MainActor () -> Void = {}
        var finishOnboarding: @MainActor () -> Void = {}
        var applyShortcut: @MainActor () -> Void = {}
        var suspendShortcut: @MainActor () -> Void = {}
        var applyDockIcon: @MainActor () -> Void = {}
        var showAbout: @MainActor () -> Void = {}
    }

    init(settings: AppSettings, permissions: PermissionMonitor, credentials: any CredentialStoring, store: SavedTranslationStore?) {
        self.settings = settings
        self.permissions = permissions
        self.credentials = credentials
        self.store = store
    }

    func hasCredential(for provider: TranslationProvider) -> Bool {
        _ = credentialsRevision
        return !provider.requiresCredential || credentials.hasCredential(for: provider)
    }
}
