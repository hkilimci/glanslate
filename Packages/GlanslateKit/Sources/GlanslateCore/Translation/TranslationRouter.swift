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

    private let engines: [TranslationProvider: any TranslationEngine]
    private let consent: any ConsentGate

    public init(engines: [any TranslationEngine], consent: any ConsentGate) {
        var map: [TranslationProvider: any TranslationEngine] = [:]
        for engine in engines { map[engine.provider] = engine }
        self.engines = map
        self.consent = consent
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

    public func translate(_ request: TranslationRequest, policy: RoutingPolicy) async throws -> TranslationOutcome {
        let source = Self.resolveSource(request)
        if let source, source == request.target {
            throw GlanslateError.alreadyInTargetLanguage(request.target)
        }
        guard !request.texts.isEmpty else {
            return TranslationOutcome(provider: policy.preferred, texts: [], source: source, target: request.target, fallback: nil)
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
                let result = try await attempt(provider, request: request, source: source, policy: policy)
                let primary = failures.first { $0.provider == policy.preferred }
                let note: FallbackNote? = (request.choice == .automatic && provider != policy.preferred)
                    ? primary.map { FallbackNote(skipped: $0.provider, reason: $0.error) }
                    : nil
                return TranslationOutcome(
                    provider: provider,
                    texts: result.texts,
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
        request: TranslationRequest,
        source: Language?,
        policy: RoutingPolicy
    ) async throws -> EngineResult {
        guard let engine = engines[provider] else { throw GlanslateError.noProviderAvailable }

        switch await engine.readiness(source: source, target: request.target) {
        case .ready: break
        case .needsSourceLanguage: throw GlanslateError.sourceLanguageUndetermined
        case .missingCredential: throw GlanslateError.missingCredential(provider)
        case .unsupportedPair: throw GlanslateError.unsupportedLanguagePair(provider, source: source, target: request.target)
        case .modelsNotInstalled:
            guard let source else { throw GlanslateError.sourceLanguageUndetermined }
            throw GlanslateError.languageModelsNotInstalled(source: source, target: request.target)
        }

        if !provider.isOnDevice, !policy.consented.contains(provider) {
            let granted = await consent.requestConsent(for: provider)
            try Task.checkCancellation()
            guard granted else { throw GlanslateError.consentDeclined(provider) }
        }

        let result: EngineResult
        do {
            result = try await engine.translate(request.texts, source: source, target: request.target)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GlanslateError {
            throw error
        } catch {
            throw GlanslateError.providerFailure(provider, detail: String(describing: type(of: error)))
        }
        guard result.texts.count == request.texts.count else { throw GlanslateError.incompleteResponse(provider) }
        return result
    }
}
