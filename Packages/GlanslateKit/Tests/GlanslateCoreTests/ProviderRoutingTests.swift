import Foundation
import Testing
@testable import GlanslateCore

/// An engine whose readiness and behavior are scripted per test.
private final class ScriptedEngine: TranslationEngine, @unchecked Sendable {
    let provider: TranslationProvider
    var readinessValue: EngineReadiness
    var failure: (any Error)?
    var delay: Duration?
    /// Runs while the request is in flight, before it completes or fails.
    var onTranslate: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var _calls = 0
    private var _sources: [Language?] = []
    private var _texts: [[String]] = []

    init(_ provider: TranslationProvider, readiness: EngineReadiness = .ready, failure: (any Error)? = nil, delay: Duration? = nil) {
        self.provider = provider
        self.readinessValue = readiness
        self.failure = failure
        self.delay = delay
    }

    var calls: Int { lock.withLock { _calls } }
    var sources: [Language?] { lock.withLock { _sources } }
    var texts: [[String]] { lock.withLock { _texts } }

    func readiness(source: Language?, target: Language) async -> EngineReadiness {
        if provider == .apple, source == nil, readinessValue == .ready { return .needsSourceLanguage }
        return readinessValue
    }

    func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult {
        lock.withLock {
            _calls += 1
            _sources.append(source)
            _texts.append(texts)
        }
        await onTranslate?()
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return EngineResult(texts: texts.map { "[\(provider.rawValue)] \($0)" })
    }
}

private actor RecordingConsent: ConsentGate {
    var asked: [TranslationProvider] = []
    /// Providers switched off since the routing policy was captured.
    var revoked: Set<TranslationProvider> = []
    let answer: Bool
    init(answer: Bool) { self.answer = answer }
    func requestConsent(for provider: TranslationProvider) async -> Bool {
        asked.append(provider)
        return answer
    }
    func hasConsent(for provider: TranslationProvider) async -> Bool {
        !revoked.contains(provider)
    }
    func revoke(_ provider: TranslationProvider) {
        revoked.insert(provider)
    }
}

/// Reports scripted languages for exact texts, and nothing for anything else.
private struct ScriptedDetector: LanguageDetecting {
    let languages: [String: DetectedLanguage]
    func detectLanguage(of text: String) -> DetectedLanguage? { languages[text] }
}

private func request(
    source: SourceLanguage = .automatic,
    detected: DetectedLanguage? = DetectedLanguage(language: .french, confidence: 0.9),
    target: Language = .english,
    choice: ProviderChoice = .automatic
) -> TranslationRequest {
    TranslationRequest(texts: ["Bonjour", "Merci"], source: source, detected: detected, target: target, choice: choice)
}

@Suite("Provider routing")
struct ProviderRoutingTests {
    @Test func planPrefersOnDeviceWhenModelsAreInstalled() {
        let policy = RoutingPolicy(preferred: .deepL, fallback: .google, prefersOnDevice: true)
        #expect(TranslationRouter.plan(choice: .automatic, policy: policy, onDeviceReady: true) == [.apple, .deepL, .google])
        #expect(TranslationRouter.plan(choice: .automatic, policy: policy, onDeviceReady: false) == [.deepL, .google])
    }

    @Test func planHonorsExplicitChoiceAndDeduplicates() {
        let policy = RoutingPolicy(preferred: .apple, fallback: .apple)
        #expect(TranslationRouter.plan(choice: .automatic, policy: policy, onDeviceReady: true) == [.apple])
        #expect(TranslationRouter.plan(choice: .specific(.openAI), policy: policy, onDeviceReady: true) == [.openAI])
    }

    @Test func appleTranslatesWhenPreferredAndInstalled() async throws {
        let apple = ScriptedEngine(.apple)
        let router = TranslationRouter(engines: [apple, ScriptedEngine(.deepL)], consent: RecordingConsent(answer: true))
        let outcome = try await router.translate(request(), policy: RoutingPolicy(preferred: .apple))
        #expect(outcome.provider == .apple)
        #expect(outcome.texts == ["[apple] Bonjour", "[apple] Merci"])
        #expect(outcome.source == .french)
        #expect(outcome.fallback == nil)
    }

    @Test func onDeviceIsUsedBeforeACloudPreferenceWithoutAskingConsent() async throws {
        let consent = RecordingConsent(answer: true)
        let deepL = ScriptedEngine(.deepL)
        let router = TranslationRouter(engines: [ScriptedEngine(.apple), deepL], consent: consent)
        let outcome = try await router.translate(request(), policy: RoutingPolicy(preferred: .deepL, prefersOnDevice: true))
        #expect(outcome.provider == .apple)
        #expect(deepL.calls == 0)
        #expect(await consent.asked.isEmpty)
    }

    @Test func missingModelsFallBackToConsentedCloudProvider() async throws {
        let apple = ScriptedEngine(.apple, readiness: .modelsNotInstalled)
        let router = TranslationRouter(engines: [apple, ScriptedEngine(.deepL)], consent: RecordingConsent(answer: false))
        let policy = RoutingPolicy(preferred: .apple, fallback: .deepL, consented: [.deepL])
        let outcome = try await router.translate(request(), policy: policy)
        #expect(outcome.provider == .deepL)
        #expect(outcome.fallback == FallbackNote(skipped: .apple, reason: .languageModelsNotInstalled(source: .french, target: .english)))
    }

    @Test func fallbackAsksForConsentFirstAndRespectsRefusal() async {
        let consent = RecordingConsent(answer: false)
        let google = ScriptedEngine(.google)
        let router = TranslationRouter(engines: [ScriptedEngine(.apple, readiness: .unsupportedPair), google], consent: consent)
        let policy = RoutingPolicy(preferred: .apple, fallback: .google)
        await #expect(throws: GlanslateError.unsupportedLanguagePair(.apple, source: .french, target: .english)) {
            try await router.translate(request(), policy: policy)
        }
        #expect(await consent.asked == [.google])
        #expect(google.calls == 0, "Declined providers never receive text")
    }

    @Test func noFallbackConfiguredReportsThePreferredFailure() async {
        let router = TranslationRouter(engines: [ScriptedEngine(.deepL, readiness: .missingCredential)], consent: RecordingConsent(answer: true))
        await #expect(throws: GlanslateError.missingCredential(.deepL)) {
            try await router.translate(request(), policy: RoutingPolicy(preferred: .deepL, consented: [.deepL]))
        }
    }

    @Test func networkFailureFallsBack() async throws {
        let deepL = ScriptedEngine(.deepL, failure: GlanslateError.network(.deepL, .timedOut))
        let openAI = ScriptedEngine(.openAI)
        let router = TranslationRouter(engines: [deepL, openAI], consent: RecordingConsent(answer: true))
        let outcome = try await router.translate(request(), policy: RoutingPolicy(preferred: .deepL, fallback: .openAI, consented: [.deepL, .openAI]))
        #expect(outcome.provider == .openAI)
        #expect(outcome.fallback?.skipped == .deepL)
    }

    @Test func explicitChoiceNeverFallsBack() async {
        let google = ScriptedEngine(.google)
        let router = TranslationRouter(
            engines: [ScriptedEngine(.deepL, failure: GlanslateError.rateLimited(.deepL, retryAfter: 2)), google],
            consent: RecordingConsent(answer: true)
        )
        let policy = RoutingPolicy(preferred: .apple, fallback: .google, consented: [.deepL, .google])
        await #expect(throws: GlanslateError.rateLimited(.deepL, retryAfter: 2)) {
            try await router.translate(request(choice: .specific(.deepL)), policy: policy)
        }
        #expect(google.calls == 0)
    }

    @Test func undetectedSourceSkipsAppleButCloudCanDetect() async throws {
        let apple = ScriptedEngine(.apple)
        let google = ScriptedEngine(.google)
        let router = TranslationRouter(engines: [apple, google], consent: RecordingConsent(answer: true))
        let lowConfidence = DetectedLanguage(language: .french, confidence: 0.2)
        let outcome = try await router.translate(
            request(detected: lowConfidence),
            policy: RoutingPolicy(preferred: .apple, fallback: .google, consented: [.google])
        )
        #expect(outcome.provider == .google)
        #expect(google.sources == [nil])
        #expect(apple.calls == 0)
    }

    @Test func undetectedSourceWithOnlyAppleAsksForASourceLanguage() async {
        let router = TranslationRouter(engines: [ScriptedEngine(.apple)], consent: RecordingConsent(answer: true))
        await #expect(throws: GlanslateError.sourceLanguageUndetermined) {
            try await router.translate(request(detected: nil), policy: RoutingPolicy(preferred: .apple))
        }
    }

    @Test func explicitSourceOverridesDetection() async throws {
        let apple = ScriptedEngine(.apple)
        let router = TranslationRouter(engines: [apple], consent: RecordingConsent(answer: true))
        _ = try await router.translate(request(source: .specific(.italian)), policy: RoutingPolicy(preferred: .apple))
        #expect(apple.sources == [.italian])
    }

    @Test func textAlreadyInTheTargetLanguageIsReported() async {
        let router = TranslationRouter(engines: [ScriptedEngine(.apple)], consent: RecordingConsent(answer: true))
        await #expect(throws: GlanslateError.alreadyInTargetLanguage(.english)) {
            try await router.translate(request(detected: DetectedLanguage(language: .english, confidence: 0.95)), policy: RoutingPolicy())
        }
    }

    @Test func mixedCapturesTranslateOnlyTheForeignParagraphs() async throws {
        let menu = "Settings and preferences"
        let article = "Ein ganzer Absatz auf Deutsch"
        let detector = ScriptedDetector(languages: [
            menu: DetectedLanguage(language: .english, confidence: 0.9),
            article: DetectedLanguage(language: .german, confidence: 0.95),
        ])
        let apple = ScriptedEngine(.apple)
        let router = TranslationRouter(engines: [apple], consent: RecordingConsent(answer: true), detector: detector)
        // The capture reads as English overall; "Home" is too short to identify on its own.
        let mixed = TranslationRequest(
            texts: ["Home", menu, article],
            source: .automatic,
            detected: DetectedLanguage(language: .english, confidence: 0.95),
            target: .english,
            choice: .automatic
        )
        let outcome = try await router.translate(mixed, policy: RoutingPolicy(preferred: .apple))
        #expect(apple.texts == [[article]], "Paragraphs already in English aren't sent")
        #expect(apple.sources == [.german])
        #expect(outcome.texts == ["Home", menu, "[apple] \(article)"])
        #expect(outcome.source == .german)
    }

    @Test func capturesEntirelyInTheTargetLanguageAreStillReported() async {
        let detector = ScriptedDetector(languages: ["Settings and preferences": DetectedLanguage(language: .english, confidence: 0.9)])
        let apple = ScriptedEngine(.apple)
        let router = TranslationRouter(engines: [apple], consent: RecordingConsent(answer: true), detector: detector)
        let english = TranslationRequest(
            texts: ["Home", "Settings and preferences", "12:30"],
            source: .automatic,
            detected: DetectedLanguage(language: .english, confidence: 0.95),
            target: .english,
            choice: .automatic
        )
        await #expect(throws: GlanslateError.alreadyInTargetLanguage(.english)) {
            try await router.translate(english, policy: RoutingPolicy(preferred: .apple))
        }
        #expect(apple.calls == 0)
    }

    @Test func aChosenSourceEqualToTheTargetIsReportedEvenWhenMixed() async {
        let detector = ScriptedDetector(languages: ["Ein ganzer Absatz auf Deutsch": DetectedLanguage(language: .german, confidence: 0.95)])
        let router = TranslationRouter(engines: [ScriptedEngine(.apple)], consent: RecordingConsent(answer: true), detector: detector)
        let chosen = TranslationRequest(
            texts: ["Ein ganzer Absatz auf Deutsch"],
            source: .specific(.english),
            detected: nil,
            target: .english,
            choice: .automatic
        )
        await #expect(throws: GlanslateError.alreadyInTargetLanguage(.english)) {
            try await router.translate(chosen, policy: RoutingPolicy(preferred: .apple))
        }
    }

    @Test func consentRevokedDuringATranslationBlocksTheFallback() async {
        let consent = RecordingConsent(answer: true)
        let deepL = ScriptedEngine(.deepL, failure: GlanslateError.network(.deepL, .timedOut))
        // The user switches Google off in Settings while DeepL is still timing out.
        deepL.onTranslate = { await consent.revoke(.google) }
        let google = ScriptedEngine(.google)
        let router = TranslationRouter(engines: [deepL, google], consent: consent)
        let policy = RoutingPolicy(preferred: .deepL, fallback: .google, consented: [.deepL, .google])
        await #expect(throws: GlanslateError.network(.deepL, .timedOut)) {
            try await router.translate(request(), policy: policy)
        }
        #expect(google.calls == 0, "Revoked providers never receive text")
        #expect(await consent.asked.isEmpty, "Consent recorded at the start isn't asked for again")
    }

    @Test func cancellationStopsRoutingWithoutFallback() async {
        let deepL = ScriptedEngine(.deepL, delay: .seconds(5))
        let google = ScriptedEngine(.google)
        let router = TranslationRouter(engines: [deepL, google], consent: RecordingConsent(answer: true))
        let policy = RoutingPolicy(preferred: .deepL, fallback: .google, consented: [.deepL, .google])
        let task = Task { try await router.translate(request(), policy: policy) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(google.calls == 0)
    }

    @Test func mismatchedResultCountIsIncomplete() async {
        struct ShortEngine: TranslationEngine {
            let provider = TranslationProvider.apple
            func readiness(source: Language?, target: Language) async -> EngineReadiness { .ready }
            func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult {
                EngineResult(texts: [texts[0]])
            }
        }
        let router = TranslationRouter(engines: [ShortEngine()], consent: RecordingConsent(answer: true))
        await #expect(throws: GlanslateError.incompleteResponse(.apple)) {
            try await router.translate(request(), policy: RoutingPolicy(preferred: .apple))
        }
    }
}
