import Foundation
import GlanslateCore
import Observation

/// Ordinary preferences, stored in `UserDefaults`. Credentials live in the Keychain instead.
@MainActor
@Observable
public final class AppSettings {
    // MARK: Translation

    public var targetLanguage: Language { didSet { store(targetLanguage, .targetLanguage) } }
    public var sourceLanguage: SourceLanguage { didSet { store(sourceLanguage, .sourceLanguage) } }
    public var preferredProvider: TranslationProvider { didSet { store(preferredProvider, .preferredProvider) } }
    /// `nil` means no fallback.
    public var fallbackProvider: TranslationProvider? { didSet { store(fallbackProvider, .fallbackProvider) } }
    public var prefersOnDevice: Bool { didSet { defaults.set(prefersOnDevice, forKey: Key.prefersOnDevice.rawValue) } }
    /// Cloud providers the user agreed to send recognized text to.
    public private(set) var consentedProviders: Set<TranslationProvider> {
        didSet { store(consentedProviders.map(\.rawValue).sorted(), .consentedProviders) }
    }
    public var openAIModel: String { didSet { defaults.set(openAIModel, forKey: Key.openAIModel.rawValue) } }
    public var usesAccessibilityText: Bool { didSet { defaults.set(usesAccessibilityText, forKey: Key.usesAccessibilityText.rawValue) } }

    // MARK: Appearance

    public var overlayStyle: OverlayStyle { didSet { store(overlayStyle, .overlayStyle) } }
    /// Multiplier applied to the estimated font size (0.85...1.3).
    public var textScale: Double { didSet { defaults.set(textScale, forKey: Key.textScale.rawValue) } }
    public var subtitle: SubtitleAppearance { didSet { store(subtitle, .subtitle) } }

    // MARK: Shortcuts

    /// `nil` disables the global shortcut.
    public var translateShortcut: KeyCombo? { didSet { store(translateShortcut, .translateShortcut) } }
    public var revealModifier: RevealModifier { didSet { store(revealModifier, .revealModifier) } }

    // MARK: General

    public var showsDockIcon: Bool { didSet { defaults.set(showsDockIcon, forKey: Key.showsDockIcon.rawValue) } }
    public var savesThumbnails: Bool { didSet { defaults.set(savesThumbnails, forKey: Key.savesThumbnails.rawValue) } }
    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding.rawValue) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        targetLanguage = Self.load(Language.self, .targetLanguage, from: defaults) ?? Language.preferredTarget()
        sourceLanguage = Self.load(SourceLanguage.self, .sourceLanguage, from: defaults) ?? .automatic
        preferredProvider = Self.load(TranslationProvider.self, .preferredProvider, from: defaults) ?? .apple
        fallbackProvider = Self.load(TranslationProvider?.self, .fallbackProvider, from: defaults) ?? nil
        prefersOnDevice = defaults.object(forKey: Key.prefersOnDevice.rawValue) as? Bool ?? true
        consentedProviders = Set((Self.load([String].self, .consentedProviders, from: defaults) ?? []).compactMap(TranslationProvider.init(rawValue:)))
        openAIModel = defaults.string(forKey: Key.openAIModel.rawValue) ?? OpenAIEngine.defaultModel
        usesAccessibilityText = defaults.object(forKey: Key.usesAccessibilityText.rawValue) as? Bool ?? true
        overlayStyle = Self.load(OverlayStyle.self, .overlayStyle, from: defaults) ?? .liquidGlass
        textScale = defaults.object(forKey: Key.textScale.rawValue) as? Double ?? 1
        subtitle = Self.load(SubtitleAppearance.self, .subtitle, from: defaults) ?? .default
        translateShortcut = defaults.object(forKey: Key.translateShortcut.rawValue) == nil
            ? .defaultTranslate
            : Self.load(KeyCombo?.self, .translateShortcut, from: defaults) ?? nil
        revealModifier = Self.load(RevealModifier.self, .revealModifier, from: defaults) ?? .option
        showsDockIcon = defaults.object(forKey: Key.showsDockIcon.rawValue) as? Bool ?? false
        savesThumbnails = defaults.object(forKey: Key.savesThumbnails.rawValue) as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding.rawValue)
    }

    /// The preferences the router needs, captured at the start of a translation.
    public var routingPolicy: RoutingPolicy {
        RoutingPolicy(
            preferred: preferredProvider,
            fallback: fallbackProvider == preferredProvider ? nil : fallbackProvider,
            prefersOnDevice: prefersOnDevice,
            consented: consentedProviders
        )
    }

    public func hasConsent(for provider: TranslationProvider) -> Bool {
        provider.isOnDevice || consentedProviders.contains(provider)
    }

    public func setConsent(_ granted: Bool, for provider: TranslationProvider) {
        guard !provider.isOnDevice else { return }
        if granted { consentedProviders.insert(provider) } else { consentedProviders.remove(provider) }
    }

    public func resetAppearance() {
        overlayStyle = .liquidGlass
        textScale = 1
        subtitle = .default
    }

    // MARK: Storage

    enum Key: String {
        case targetLanguage, sourceLanguage, preferredProvider, fallbackProvider, prefersOnDevice
        case consentedProviders, openAIModel, usesAccessibilityText
        case overlayStyle, textScale, subtitle
        case translateShortcut, revealModifier
        case showsDockIcon, savesThumbnails, hasCompletedOnboarding
    }

    private func store<Value: Encodable>(_ value: Value, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: Key, from defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
