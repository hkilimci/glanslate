import Foundation

/// How the user wants providers chosen for a translation.
public enum ProviderChoice: Hashable, Sendable {
    /// Follow the routing policy: on-device first when possible, then preferred, then fallback.
    case automatic
    /// Use exactly this provider, with no fallback.
    case specific(TranslationProvider)
}

/// The user's provider preferences, captured when a translation starts.
public struct RoutingPolicy: Equatable, Sendable {
    public var preferred: TranslationProvider
    public var fallback: TranslationProvider?
    /// Use Apple Translation first whenever its models for the pair are installed.
    public var prefersOnDevice: Bool
    /// Cloud providers the user has agreed to send recognized text to.
    public var consented: Set<TranslationProvider>

    public init(
        preferred: TranslationProvider = .apple,
        fallback: TranslationProvider? = nil,
        prefersOnDevice: Bool = true,
        consented: Set<TranslationProvider> = []
    ) {
        self.preferred = preferred
        self.fallback = fallback
        self.prefersOnDevice = prefersOnDevice
        self.consented = consented
    }
}

public struct TranslationRequest: Sendable {
    public let texts: [String]
    public let source: SourceLanguage
    /// The language recognized from the captured text, if any.
    public let detected: DetectedLanguage?
    public let target: Language
    public let choice: ProviderChoice

    public init(texts: [String], source: SourceLanguage, detected: DetectedLanguage?, target: Language, choice: ProviderChoice) {
        self.texts = texts
        self.source = source
        self.detected = detected
        self.target = target
        self.choice = choice
    }
}

/// A finished translation.
public struct TranslationOutcome: Equatable, Sendable {
    public let provider: TranslationProvider
    public let texts: [String]
    /// The source language used or reported by the provider.
    public let source: Language?
    public let target: Language
    /// Set when the preferred provider failed and another one was used.
    public let fallback: FallbackNote?

    public init(provider: TranslationProvider, texts: [String], source: Language?, target: Language, fallback: FallbackNote?) {
        self.provider = provider
        self.texts = texts
        self.source = source
        self.target = target
        self.fallback = fallback
    }
}

public struct FallbackNote: Equatable, Sendable {
    public let skipped: TranslationProvider
    public let reason: GlanslateError

    public var message: String { "\(skipped.displayName): \(reason.title)" }
}

/// Picks providers for a request and falls back according to the user's policy.
public struct TranslationRouter: Sendable {
    /// Detected languages below this confidence are treated as unknown.
    public static let detectionThreshold = 0.5
    /// Paragraphs with fewer letters are too short to identify reliably on their own.
    static let minimumLettersPerParagraph = 8

    private let engines: [TranslationProvider: any TranslationEngine]
    private let consent: any ConsentGate
    /// Identifies single paragraphs, so a capture that mostly reads as the target
    /// language can still have its other paragraphs translated. Without one, such a
    /// capture is reported as already translated.
    private let detector: (any LanguageDetecting)?

    public init(engines: [any TranslationEngine], consent: any ConsentGate, detector: (any LanguageDetecting)? = nil) {
        var map: [TranslationProvider: any TranslationEngine] = [:]
        for engine in engines { map[engine.provider] = engine }
        self.engines = map
        self.consent = consent
        self.detector = detector
    }

    /// The source language to send to providers.
    public static func resolveSource(_ request: TranslationRequest) -> Language? {
        if let language = request.source.language { return language }
        guard let detected = request.detected, detected.confidence >= detectionThreshold else { return nil }
        return detected.language
    }

    /// The providers to try, in order. Pure, so it can be reasoned about and tested on its own.
    public static func plan(
        choice: ProviderChoice,
        policy: RoutingPolicy,
        onDeviceReady: Bool
    ) -> [TranslationProvider] {
        switch choice {
        case .specific(let provider):
            return [provider]
        case .automatic:
            var order: [TranslationProvider] = []
            if policy.prefersOnDevice, policy.preferred != .apple, onDeviceReady { order.append(.apple) }
            order.append(policy.preferred)
            if let fallback = policy.fallback { order.append(fallback) }
            var seen: Set<TranslationProvider> = []
            return order.filter { seen.insert($0).inserted }
        }
    }

    /// Splits a capture that reads as the target language overall into the paragraphs to
    /// translate and the ones already in the target language, which are kept as they are.
    /// Paragraphs too short to identify follow the rest of the capture.
    ///
    /// - Returns: The indices to translate and their source language, or `nil` when every
    ///   identifiable paragraph is already in the target language.
    static func foreignParagraphs(
        of texts: [String],
        target: Language,
        detector: any LanguageDetecting
    ) -> (indices: [Int], source: Language?)? {
        func confident(_ text: String) -> Language? {
            guard let detected = detector.detectLanguage(of: text), detected.confidence >= detectionThreshold else { return nil }
            return detected.language
        }
        let indices = texts.indices.filter { index in
            let letters = texts[index].unicodeScalars.filter(CharacterSet.letters.contains).count
            guard letters >= minimumLettersPerParagraph, let language = confident(texts[index]) else { return false }
            return language != target
        }
        guard !indices.isEmpty else { return nil }
        let source = confident(indices.map { texts[$0] }.joined(separator: "\n")).flatMap { $0 == target ? nil : $0 }
        return (indices, source)
    }

    public func translate(_ request: TranslationRequest, policy: RoutingPolicy) async throws -> TranslationOutcome {
        var source = Self.resolveSource(request)
        var indices = Array(request.texts.indices)
        if let resolved = source, resolved == request.target {
            // A chosen source equal to the target is the user's call. A detected one only
            // describes the capture's dominant language: a page's English menus shouldn't
            // stop its German article from being translated into English.
            guard case .automatic = request.source, let detector,
                  let foreign = Self.foreignParagraphs(of: request.texts, target: request.target, detector: detector) else {
                throw GlanslateError.alreadyInTargetLanguage(request.target)
            }
            indices = foreign.indices
            source = foreign.source
        }
        guard !request.texts.isEmpty else {
            return TranslationOutcome(provider: policy.preferred, texts: [], source: source, target: request.target, fallback: nil)
        }
        let texts = indices.map { request.texts[$0] }

        /// The full list of paragraphs, with the translated ones put back in place.
        func merged(_ translated: [String]) -> [String] {
            var output = request.texts
            for (index, text) in zip(indices, translated) { output[index] = text }
            return output
        }

        var onDeviceReady = false
        if case .automatic = request.choice, policy.prefersOnDevice, policy.preferred != .apple, let apple = engines[.apple] {
            onDeviceReady = await apple.readiness(source: source, target: request.target) == .ready
        }
        let order = Self.plan(choice: request.choice, policy: policy, onDeviceReady: onDeviceReady)

        var failures: [(provider: TranslationProvider, error: GlanslateError)] = []
        for provider in order {
            try Task.checkCancellation()
            do {
                let result = try await attempt(provider, texts: texts, source: source, target: request.target, policy: policy)
                let primary = failures.first { $0.provider == policy.preferred }
                let note: FallbackNote? = (request.choice == .automatic && provider != policy.preferred)
                    ? primary.map { FallbackNote(skipped: $0.provider, reason: $0.error) }
                    : nil
                return TranslationOutcome(
                    provider: provider,
                    texts: merged(result.texts),
                    source: source ?? result.detectedSource,
                    target: request.target,
                    fallback: note
                )
            } catch let error as GlanslateError {
                if error == .cancelled { throw CancellationError() }
                failures.append((provider, error))
                if !error.allowsFallback { throw error }
            }
        }

        let primary = failures.first { $0.provider == policy.preferred } ?? failures.first
        throw primary?.error ?? GlanslateError.noProviderAvailable
    }

    private func attempt(
        _ provider: TranslationProvider,
        texts: [String],
        source: Language?,
        target: Language,
        policy: RoutingPolicy
    ) async throws -> EngineResult {
        guard let engine = engines[provider] else { throw GlanslateError.noProviderAvailable }

        switch await engine.readiness(source: source, target: target) {
        case .ready: break
        case .needsSourceLanguage: throw GlanslateError.sourceLanguageUndetermined
        case .missingCredential: throw GlanslateError.missingCredential(provider)
        case .unsupportedPair: throw GlanslateError.unsupportedLanguagePair(provider, source: source, target: target)
        case .modelsNotInstalled:
            guard let source else { throw GlanslateError.sourceLanguageUndetermined }
            throw GlanslateError.languageModelsNotInstalled(source: source, target: target)
        }

        if !provider.isOnDevice {
            // `policy` is a snapshot from when the translation started. A provider consented
            // then may have been switched off since — e.g. while an earlier provider was
            // timing out — so re-check before it receives any text.
            let granted = policy.consented.contains(provider)
                ? await consent.hasConsent(for: provider)
                : await consent.requestConsent(for: provider)
            try Task.checkCancellation()
            guard granted else { throw GlanslateError.consentDeclined(provider) }
        }

        let result: EngineResult
        do {
            result = try await engine.translate(texts, source: source, target: target)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GlanslateError {
            throw error
        } catch {
            throw GlanslateError.providerFailure(provider, detail: String(describing: type(of: error)))
        }
        guard result.texts.count == texts.count else { throw GlanslateError.incompleteResponse(provider) }
        return result
    }
}
