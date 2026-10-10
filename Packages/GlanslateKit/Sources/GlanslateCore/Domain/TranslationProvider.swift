import Foundation

/// A service that turns recognized text into translated text.
public enum TranslationProvider: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case apple
    case deepL
    case google
    case openAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: return "Apple Translation"
        case .deepL: return "DeepL"
        case .google: return "Google Translate"
        case .openAI: return "OpenAI"
        }
    }

    /// Apple Translation runs entirely on this Mac. Every other provider
    /// receives the recognized text over the network.
    public var isOnDevice: Bool { self == .apple }

    public var requiresCredential: Bool { !isOnDevice }

    public var credentialName: String {
        switch self {
        case .apple: return ""
        case .deepL: return "DeepL API Key"
        case .google: return "Google Cloud API Key"
        case .openAI: return "OpenAI API Key"
        }
    }

    /// The operator that receives recognized text when this provider is used.
    public var dataRecipient: String {
        switch self {
        case .apple: return "No one — translation happens on this Mac"
        case .deepL: return "DeepL SE"
        case .google: return "Google Cloud"
        case .openAI: return "OpenAI"
        }
    }

    public var credentialHelpURL: URL? {
        switch self {
        case .apple: return nil
        case .deepL: return URL(string: "https://www.deepl.com/your-account/keys")
        case .google: return URL(string: "https://console.cloud.google.com/apis/credentials")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        }
    }

    public var privacyPolicyURL: URL? {
        switch self {
        case .apple: return nil
        case .deepL: return URL(string: "https://www.deepl.com/privacy")
        case .google: return URL(string: "https://cloud.google.com/terms/cloud-privacy-notice")
        case .openAI: return URL(string: "https://openai.com/policies/privacy-policy")
        }
    }

    public static var cloudProviders: [TranslationProvider] { allCases.filter { !$0.isOnDevice } }
}
