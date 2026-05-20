import Foundation

public enum TranslationProvider: String, Sendable, Codable, Hashable, CaseIterable {
    case apple
    case deepL
    case google
    case openAI

    public var displayName: String {
        switch self {
        case .apple: return "Apple Translation"
        case .deepL: return "DeepL"
        case .google: return "Google Translate"
        case .openAI: return "OpenAI"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .deepL, .openAI:
            return true
        case .apple, .google:
            return false
        }
    }

    public var sendsTextOffDevice: Bool { self != .apple }
}

public struct Translation: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let block: TextBlock
    public let translatedText: String
    public let targetLanguage: Language
    public let provider: TranslationProvider

    public init(
        id: UUID = UUID(),
        block: TextBlock,
        translatedText: String,
        targetLanguage: Language,
        provider: TranslationProvider
    ) {
        self.id = id
        self.block = block
        self.translatedText = translatedText
        self.targetLanguage = targetLanguage
        self.provider = provider
    }
}
