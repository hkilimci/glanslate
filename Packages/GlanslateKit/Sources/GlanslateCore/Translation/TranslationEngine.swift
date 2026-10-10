import Foundation

/// Whether an engine can take a request right now.
public enum EngineReadiness: Equatable, Sendable {
    case ready
    /// The engine can't detect languages itself and none was given.
    case needsSourceLanguage
    case missingCredential
    case unsupportedPair
    /// The pair is supported but its on-device models aren't downloaded.
    case modelsNotInstalled
}

public struct EngineResult: Equatable, Sendable {
    /// Translations aligned index-for-index with the request texts.
    public let texts: [String]
    /// The source language the engine reported, when it detected one.
    public let detectedSource: Language?

    public init(texts: [String], detectedSource: Language? = nil) {
        self.texts = texts
        self.detectedSource = detectedSource
    }
}

/// An interchangeable translation backend.
///
/// Engines translate a batch of paragraphs and must return exactly one result
/// per input, in order. They report failures as ``GlanslateError`` and let
/// `CancellationError` propagate untouched.
public protocol TranslationEngine: Sendable {
    var provider: TranslationProvider { get }
    func readiness(source: Language?, target: Language) async -> EngineReadiness
    func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult
}

/// Supplies API keys. Backed by the Keychain on macOS.
public protocol CredentialProviding: Sendable {
    func credential(for provider: TranslationProvider) -> String?
}

/// Asks the user, once per cloud provider, whether recognized text may be sent to it.
public protocol ConsentGate: Sendable {
    func requestConsent(for provider: TranslationProvider) async -> Bool
    /// Whether consent is on record right now, without asking. Checked before every
    /// cloud request, so permission revoked during a translation stops later sends.
    func hasConsent(for provider: TranslationProvider) async -> Bool
}
