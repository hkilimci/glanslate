import Foundation
import Observation
import GlanslateCore
import GlanslatePlatform

public enum PeekModifier: String, Sendable, Codable, CaseIterable {
    case option, control, command, shift

    public var displayName: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        }
    }
}

@MainActor
@Observable
public final class SettingsStore {
    // Translation
    public var preferredProvider: TranslationProvider
    public var fallbackProvider: TranslationProvider
    public var defaultTargetLanguage: Language
    public var acceptedCloudDisclosureProviders: Set<TranslationProvider>
    public var openAIModel: String

    // Overlay
    public var overlayStyle: OverlayStyle
    public var overlayOpacity: Double
    public var peekModifier: PeekModifier
    public var subtitleShowBorder: Bool
    public var subtitleTextColorHex: String          // #RRGGBB
    public var subtitleOutlineColorHex: String

    // Onboarding
    public var didShowOnboarding: Bool

    // Non-persisted: keychain for keys.
    public let keychain: KeychainStore

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        self.preferredProvider = defaults.decode("preferredProvider", default: .apple)
        self.fallbackProvider  = defaults.decode("fallbackProvider", default: .openAI)
        self.defaultTargetLanguage = defaults.decode("defaultTargetLanguage", default: .en)
        self.acceptedCloudDisclosureProviders =
            Set(defaults.decode("acceptedCloudDisclosureProviders", default: Array<TranslationProvider>()))
        self.openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-5.4-mini"
        self.overlayStyle = defaults.decode("overlayStyle", default: .cleanPatch)
        self.overlayOpacity = defaults.object(forKey: "overlayOpacity") as? Double ?? 1.0
        self.peekModifier = defaults.decode("peekModifier", default: .option)
        self.subtitleShowBorder = defaults.object(forKey: "subtitleShowBorder") as? Bool ?? false
        self.subtitleTextColorHex = defaults.string(forKey: "subtitleTextColorHex") ?? "#FFFFFF"
        self.subtitleOutlineColorHex = defaults.string(forKey: "subtitleOutlineColorHex") ?? "#000000"
        self.didShowOnboarding = defaults.bool(forKey: "didShowOnboarding")
    }

    public func persist() {
        defaults.encode(preferredProvider, key: "preferredProvider")
        defaults.encode(fallbackProvider, key: "fallbackProvider")
        defaults.encode(defaultTargetLanguage, key: "defaultTargetLanguage")
        defaults.encode(Array(acceptedCloudDisclosureProviders), key: "acceptedCloudDisclosureProviders")
        defaults.set(openAIModel, forKey: "openAIModel")
        defaults.encode(overlayStyle, key: "overlayStyle")
        defaults.set(overlayOpacity, forKey: "overlayOpacity")
        defaults.encode(peekModifier, key: "peekModifier")
        defaults.set(subtitleShowBorder, forKey: "subtitleShowBorder")
        defaults.set(subtitleTextColorHex, forKey: "subtitleTextColorHex")
        defaults.set(subtitleOutlineColorHex, forKey: "subtitleOutlineColorHex")
        defaults.set(didShowOnboarding, forKey: "didShowOnboarding")
    }

    public func acceptDisclosure(for provider: TranslationProvider) {
        acceptedCloudDisclosureProviders.insert(provider)
        persist()
    }

    public func hasAcceptedDisclosure(for provider: TranslationProvider) -> Bool {
        !provider.sendsTextOffDevice || acceptedCloudDisclosureProviders.contains(provider)
    }
}

extension UserDefaults {
    func decode<T: Codable>(_ key: String, default value: T) -> T {
        guard let data = data(forKey: key) else { return value }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? value
    }

    func encode<T: Codable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            set(data, forKey: key)
        }
    }
}
