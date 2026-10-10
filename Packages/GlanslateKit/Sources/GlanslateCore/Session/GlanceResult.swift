import Foundation

/// A recognized capture paired with its current translation.
public struct GlanceResult: Equatable, Sendable {
    public let recognized: RecognizedText
    public let outcome: TranslationOutcome

    public init(recognized: RecognizedText, outcome: TranslationOutcome) {
        self.recognized = recognized
        self.outcome = outcome
    }

    public struct Pair: Equatable, Sendable, Identifiable {
        public let block: TextBlock
        public let translation: String
        public var id: UUID { block.id }
    }

    /// Each block with its translation, in reading order.
    public var pairs: [Pair] {
        zip(recognized.blocks, outcome.texts).map { Pair(block: $0, translation: $1) }
    }

    /// The translation as plain text, one paragraph per block.
    public var translatedText: String {
        outcome.texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    public var originalText: String { recognized.fullText }
}

/// Everything needed to persist a pinned translation.
public struct SavedTranslationDraft: Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let originalText: String
    public let translatedText: String
    public let sourceLanguage: Language?
    public let targetLanguage: Language
    public let provider: TranslationProvider
    /// A downscaled image of the captured region (JPEG), if available.
    public let thumbnail: Data?

    public init(
        id: UUID,
        createdAt: Date = Date(),
        originalText: String,
        translatedText: String,
        sourceLanguage: Language?,
        targetLanguage: Language,
        provider: TranslationProvider,
        thumbnail: Data?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.thumbnail = thumbnail
    }

    public init(id: UUID, result: GlanceResult, thumbnail: Data?, createdAt: Date = Date()) {
        self.init(
            id: id,
            createdAt: createdAt,
            originalText: result.originalText,
            translatedText: result.translatedText,
            sourceLanguage: result.outcome.source,
            targetLanguage: result.outcome.target,
            provider: result.outcome.provider,
            thumbnail: thumbnail
        )
    }
}
