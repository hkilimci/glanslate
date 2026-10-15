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
    private let client: any AppleTranslationClient

    public init() { client = SystemAppleTranslationClient() }

    init(client: any AppleTranslationClient) { self.client = client }

    public func readiness(source: Language?, target: Language) async -> EngineReadiness {
        guard let source else { return .needsSourceLanguage }
        switch await AppleLanguageSupport.status(source: source, target: target, client: client) {
        case .installed: return .ready
        case .downloadable: return .modelsNotInstalled
        case .unsupported: return .unsupportedPair
        }
    }

    public func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult {
        guard let source else { throw GlanslateError.sourceLanguageUndetermined }
        do {
            return try await retryMissingAppleModels {
                try await client.translate(texts, source: source, target: target)
            }
        } catch {
            throw Self.map(error, source: source, target: target)
        }
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
        if let error = error as? GlanslateError { return error }
        return GlanslateError.providerFailure(.apple, detail: String(describing: type(of: error)))
    }
}

/// Keeps framework calls replaceable in tests without downloading or removing system models.
protocol AppleTranslationClient: Sendable {
    func status(source: Language, target: Language) async -> AppleLanguageSupport.Status
    func prepare(source: Language, target: Language) async throws
    func translate(_ texts: [String], source: Language, target: Language) async throws -> EngineResult
}

private struct SystemAppleTranslationClient: AppleTranslationClient {
    func status(source: Language, target: Language) async -> AppleLanguageSupport.Status {
        let availability = LanguageAvailability()
        switch await availability.status(
            from: AppleLanguageSupport.localeLanguage(for: source),
            to: AppleLanguageSupport.localeLanguage(for: target)
        ) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func prepare(source: Language, target: Language) async throws {
        let session = TranslationSession(
            installedSource: AppleLanguageSupport.localeLanguage(for: source),
            target: AppleLanguageSupport.localeLanguage(for: target)
        )
        try await session.prepareTranslation()
    }

    func translate(_ texts: [String], source: Language, target: Language) async throws -> EngineResult {
        let session = TranslationSession(
            installedSource: AppleLanguageSupport.localeLanguage(for: source),
            target: AppleLanguageSupport.localeLanguage(for: target)
        )
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }

        let responses = try await session.translations(from: requests)
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
}

/// Model discovery can lag the first request after macOS starts its translation service.
/// Retry only a missing-model error, once, with a fresh session after a short grace period.
private func retryMissingAppleModels<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    do {
        return try await operation()
    } catch {
        guard TranslationError.notInstalled ~= error else { throw error }
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        return try await operation()
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
        await status(source: source, target: target, client: SystemAppleTranslationClient())
    }

    static func status(source: Language, target: Language, client: any AppleTranslationClient) async -> Status {
        guard source != target else { return .unsupported }
        let status = await client.status(source: source, target: target)
        guard status == .downloadable, !Task.isCancelled else { return status }
        do {
            // Availability can be stale on first use. Verify with a session that cannot
            // request downloads before telling the user to download already installed models.
            try await retryMissingAppleModels {
                try await client.prepare(source: source, target: target)
            }
            return .installed
        } catch {
            return status
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
