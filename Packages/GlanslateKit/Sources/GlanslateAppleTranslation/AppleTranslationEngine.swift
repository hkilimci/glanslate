import Foundation
import GlanslateCore
@preconcurrency import Translation

/// On-device translation with Apple's Translation framework.
///
/// Uses `TranslationSession(installedSource:target:)` (macOS 26), which works
/// without a SwiftUI view but can only use language models that are already
/// downloaded. Missing models are reported so the user can download them from
/// Settings, where a SwiftUI-hosted session is allowed to request downloads.
public struct AppleTranslationEngine: TranslationEngine {
    public let provider = TranslationProvider.apple

    public init() {}

    public func readiness(source: Language?, target: Language) async -> EngineReadiness {
        guard let source else { return .needsSourceLanguage }
        switch await AppleLanguageSupport.status(source: source, target: target) {
        case .installed: return .ready
        case .downloadable: return .modelsNotInstalled
        case .unsupported: return .unsupportedPair
        }
    }

    public func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult {
        guard let source else { throw GlanslateError.sourceLanguageUndetermined }
        let session = TranslationSession(
            installedSource: AppleLanguageSupport.localeLanguage(for: source),
            target: AppleLanguageSupport.localeLanguage(for: target)
        )
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }

        let responses: [TranslationSession.Response]
        do {
            responses = try await session.translations(from: requests)
        } catch {
            throw Self.map(error, source: source, target: target)
        }
        try Task.checkCancellation()

        var byIndex: [Int: String] = [:]
        for response in responses {
            if let identifier = response.clientIdentifier, let index = Int(identifier) {
                byIndex[index] = response.targetText
            }
        }
        let ordered = texts.indices.compactMap { byIndex[$0] }
        guard ordered.count == texts.count else { throw GlanslateError.incompleteResponse(.apple) }
        return EngineResult(texts: ordered, detectedSource: source)
    }

    static func map(_ error: any Error, source: Language, target: Language) -> any Error {
        if error is CancellationError || TranslationError.alreadyCancelled ~= error { return CancellationError() }
        if TranslationError.notInstalled ~= error {
            return GlanslateError.languageModelsNotInstalled(source: source, target: target)
        }
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return GlanslateError.unsupportedLanguagePair(.apple, source: source, target: target)
        }
        if TranslationError.unableToIdentifyLanguage ~= error { return GlanslateError.sourceLanguageUndetermined }
        if TranslationError.nothingToTranslate ~= error { return GlanslateError.noTextFound }
        return GlanslateError.providerFailure(.apple, detail: String(describing: type(of: error)))
    }
}

/// Availability of Apple's on-device language models.
public enum AppleLanguageSupport {
    public enum Status: Equatable, Sendable {
        case installed
        case downloadable
        case unsupported
    }

    public static func status(source: Language, target: Language) async -> Status {
        guard source != target else { return .unsupported }
        let availability = LanguageAvailability()
        switch await availability.status(from: localeLanguage(for: source), to: localeLanguage(for: target)) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Catalog languages Apple Translation can work with on this Mac.
    public static func supportedLanguages() async -> Set<Language> {
        let languages = await LanguageAvailability().supportedLanguages
        return Set(languages.compactMap { language in
            guard let code = language.languageCode?.identifier else { return nil }
            let script = language.script?.identifier
            return Language(script.map { "\(code)-\($0)" } ?? code)
        })
    }

    /// Apple identifies some languages by region (Brazilian Portuguese, US English).
    public static func localeLanguage(for language: Language) -> Locale.Language {
        switch language.code {
        case "pt": return Locale.Language(identifier: "pt-BR")
        case "en": return Locale.Language(identifier: "en-US")
        default: return Locale.Language(identifier: language.code)
        }
    }
}
