#if DEBUG
import Foundation
import GlanslateCore
import GlanslatePersistence
import GlanslateSystem
import SwiftUI

/// Keys held in memory, so previews never touch the Keychain.
final class PreviewCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TranslationProvider: String] = [:]

    func credential(for provider: TranslationProvider) -> String? { lock.withLock { values[provider] } }
    func hasCredential(for provider: TranslationProvider) -> Bool { credential(for: provider) != nil }
    func setCredential(_ value: String, for provider: TranslationProvider) throws { lock.withLock { values[provider] = value } }
    func removeCredential(for provider: TranslationProvider) throws { _ = lock.withLock { values.removeValue(forKey: provider) } }
}

extension AppEnvironment {
    /// An environment with throwaway preferences and an in-memory store.
    @MainActor
    static func preview(savedSamples: Bool = false) -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "glanslate.preview.\(UUID().uuidString)")!
        let store = try? SavedTranslationStore(inMemory: true)
        if savedSamples, let store {
            try? store.save(SavedTranslationDraft(
                id: UUID(),
                originalText: "Les cafés du quartier ouvrent tôt et ferment tard.",
                translatedText: "The neighborhood cafés open early and close late.",
                sourceLanguage: .french,
                targetLanguage: .english,
                provider: .apple,
                thumbnail: nil
            ))
            try? store.save(SavedTranslationDraft(
                id: UUID(),
                createdAt: Date().addingTimeInterval(-3_600),
                originalText: "Bitte halten Sie Ihre Fahrkarte bereit.",
                translatedText: "Please have your ticket ready.",
                sourceLanguage: .german,
                targetLanguage: .english,
                provider: .deepL,
                thumbnail: nil
            ))
        }
        return AppEnvironment(
            settings: AppSettings(defaults: defaults),
            permissions: PermissionMonitor(),
            credentials: PreviewCredentialStore(),
            store: store
        )
    }
}

#Preview("Settings — Translation") {
    let environment = AppEnvironment.preview()
    environment.settingsSection = .translation
    return SettingsView().environment(environment).frame(width: 760, height: 580)
}

#Preview("Settings — Appearance, Dark") {
    let environment = AppEnvironment.preview()
    environment.settingsSection = .appearance
    return SettingsView().environment(environment).frame(width: 760, height: 580).preferredColorScheme(.dark)
}

#Preview("Onboarding — Permissions") {
    OnboardingView(initialStep: .permissions).environment(AppEnvironment.preview())
}

#Preview("Saved Translations") {
    SavedTranslationsView().environment(AppEnvironment.preview(savedSamples: true)).frame(width: 880, height: 560)
}

#Preview("Overlay Styles") {
    VStack(spacing: 12) {
        ForEach(OverlayStyle.allCases) { style in
            OverlayPreview(style: style, subtitle: .default, textScale: 1, isDark: style == .subtitle)
        }
    }
    .padding()
}
#endif
