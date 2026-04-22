import Foundation
import GlanslateCore

public enum AvailabilityStatus: Sendable, Hashable {
    case supported
    case needsDownload
    case unsupported
}

public protocol TranslationEngine: Sendable {
    var identifier: TranslationProvider { get }
    func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus
    func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [Translation]
}

public struct InvocationRoutingOverride: Sendable, Hashable {
    public let provider: TranslationProvider?
    public let sourceLanguage: Language?

    public init(provider: TranslationProvider? = nil, sourceLanguage: Language? = nil) {
        self.provider = provider
        self.sourceLanguage = sourceLanguage
    }
}

public protocol TranslationRouting: Sendable {
    func translate(_ blocks: [TextBlock], to target: Language, invocationOverride: InvocationRoutingOverride?) async throws -> [Translation]
}
