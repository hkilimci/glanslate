import GlanslateCore
import Testing
@preconcurrency import Translation
@testable import GlanslateAppleTranslation

private actor ScriptedAppleClient: AppleTranslationClient {
    let availability: AppleLanguageSupport.Status
    var preparationFailures: [any Error]
    var translationFailures: [any Error]
    private(set) var preparations = 0
    private(set) var translations = 0

    init(
        availability: AppleLanguageSupport.Status = .installed,
        preparationFailures: [any Error] = [],
        translationFailures: [any Error] = []
    ) {
        self.availability = availability
        self.preparationFailures = preparationFailures
        self.translationFailures = translationFailures
    }

    func status(source: Language, target: Language) async -> AppleLanguageSupport.Status { availability }

    func prepare(source: Language, target: Language) async throws {
        preparations += 1
        if !preparationFailures.isEmpty { throw preparationFailures.removeFirst() }
    }

    func translate(_ texts: [String], source: Language, target: Language) async throws -> EngineResult {
        translations += 1
        if !translationFailures.isEmpty { throw translationFailures.removeFirst() }
        return EngineResult(texts: texts.map { "Translated: \($0)" }, detectedSource: source)
    }
}

private struct NoCloudConsent: ConsentGate {
    func requestConsent(for provider: TranslationProvider) async -> Bool { false }
    func hasConsent(for provider: TranslationProvider) async -> Bool { false }
}

@Suite("Apple translation model discovery")
struct AppleTranslationEngineTests {
    private let request = TranslationRequest(
        texts: ["Bonjour", "Merci"], source: .specific(.french), detected: nil,
        target: .english, choice: .automatic
    )

    @Test func firstTranslationRecoversFromStaleAvailabilityAndColdModels() async throws {
        let client = ScriptedAppleClient(
            availability: .downloadable, preparationFailures: [TranslationError.notInstalled]
        )
        let router = TranslationRouter(engines: [AppleTranslationEngine(client: client)], consent: NoCloudConsent())
        let outcome = try await router.translate(request, policy: RoutingPolicy())
        #expect(outcome.texts == ["Translated: Bonjour", "Translated: Merci"])
        #expect(outcome.provider == .apple)
        #expect(await client.preparations == 2)
        #expect(await client.translations == 1)
    }

    @Test func staleAvailabilityStillPrefersInstalledModelsOverCloud() async throws {
        let client = ScriptedAppleClient(availability: .downloadable)
        let router = TranslationRouter(engines: [AppleTranslationEngine(client: client)], consent: NoCloudConsent())
        let outcome = try await router.translate(request, policy: RoutingPolicy(preferred: .deepL))
        #expect(outcome.provider == .apple)
    }

    @Test func installedAvailabilityDoesNotNeedExtraPreparation() async {
        let client = ScriptedAppleClient()
        #expect(await AppleTranslationEngine(client: client).readiness(source: .french, target: .english) == .ready)
        #expect(await client.preparations == 0)
    }

    @Test func genuinelyMissingModelsStillOfferDownloadAfterOneRetry() async {
        let client = ScriptedAppleClient(
            availability: .downloadable,
            preparationFailures: [TranslationError.notInstalled, TranslationError.notInstalled]
        )
        let router = TranslationRouter(engines: [AppleTranslationEngine(client: client)], consent: NoCloudConsent())
        await #expect(throws: GlanslateError.languageModelsNotInstalled(source: .french, target: .english)) {
            try await router.translate(request, policy: RoutingPolicy())
        }
        #expect(await client.preparations == 2)
        #expect(await client.translations == 0)
    }

    @Test func unsupportedPairsAreNotProbedOrRetried() async {
        let client = ScriptedAppleClient(availability: .unsupported)
        #expect(await AppleTranslationEngine(client: client).readiness(source: .french, target: .english) == .unsupportedPair)
        #expect(await client.preparations == 0)
    }

    @Test func firstSessionMissingModelErrorIsRetriedWithinTheSameRequest() async throws {
        let client = ScriptedAppleClient(translationFailures: [TranslationError.notInstalled])
        let router = TranslationRouter(engines: [AppleTranslationEngine(client: client)], consent: NoCloudConsent())
        let outcome = try await router.translate(request, policy: RoutingPolicy())
        #expect(outcome.texts == ["Translated: Bonjour", "Translated: Merci"])
        #expect(await client.translations == 2)
    }

    @Test func persistentSessionFailureStopsAfterOneRetry() async {
        let client = ScriptedAppleClient(translationFailures: [TranslationError.notInstalled, TranslationError.notInstalled])
        let engine = AppleTranslationEngine(client: client)
        await #expect(throws: GlanslateError.languageModelsNotInstalled(source: .french, target: .english)) {
            try await engine.translate(request.texts, source: .french, target: .english)
        }
        #expect(await client.translations == 2)
    }

    @Test func unrelatedTranslationErrorsAreNotRetried() async {
        let client = ScriptedAppleClient(translationFailures: [TranslationError.unsupportedLanguagePairing])
        let engine = AppleTranslationEngine(client: client)
        await #expect(throws: GlanslateError.unsupportedLanguagePair(.apple, source: .french, target: .english)) {
            try await engine.translate(request.texts, source: .french, target: .english)
        }
        #expect(await client.translations == 1)
    }

    @Test func cancellationDuringModelDiscoveryStopsTheRequest() async {
        let client = ScriptedAppleClient(availability: .downloadable, preparationFailures: [TranslationError.notInstalled])
        let router = TranslationRouter(engines: [AppleTranslationEngine(client: client)], consent: NoCloudConsent())
        let task = Task { try await router.translate(request, policy: RoutingPolicy()) }
        while await client.preparations == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await client.preparations == 1)
        #expect(await client.translations == 0)
    }
}
