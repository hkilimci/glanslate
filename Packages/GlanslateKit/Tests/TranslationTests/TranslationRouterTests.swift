import Foundation
import XCTest
@testable import GlanslateCore
@testable import GlanslatePlatform
@testable import GlanslateSettings
@testable import GlanslateTranslation

private struct StubEngine: TranslationEngine {
    let identifier: TranslationProvider
    let availability: AvailabilityStatus
    let resultText: String

    func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus {
        availability
    }

    func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [GlanslateCore.Translation] {
        blocks.map {
            GlanslateCore.Translation(
                block: $0,
                translatedText: resultText,
                targetLanguage: to,
                provider: identifier
            )
        }
    }
}

private actor RecordingEngine: TranslationEngine {
    nonisolated let identifier: TranslationProvider
    private(set) var lastFrom: Language?

    init(identifier: TranslationProvider) {
        self.identifier = identifier
    }

    func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus {
        .supported
    }

    func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [GlanslateCore.Translation] {
        lastFrom = from
        return blocks.map {
            GlanslateCore.Translation(
                block: $0,
                translatedText: "ok",
                targetLanguage: to,
                provider: identifier
            )
        }
    }
}

final class TranslationRouterTests: XCTestCase {
    @MainActor
    func testRouterFallsBackWhenPreferredUnsupported() async throws {
        let defaults = UserDefaults(suiteName: "TranslationRouterTests-\(UUID().uuidString)")!
        let keychain = KeychainStore(service: "TranslationRouterTests-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        settings.preferredProvider = .apple
        settings.fallbackProvider = .openAI
        settings.acceptDisclosure(for: .openAI)

        let router = TranslationRouter(
            engines: [
                .apple: StubEngine(identifier: .apple, availability: .unsupported, resultText: "unused"),
                .openAI: StubEngine(identifier: .openAI, availability: .supported, resultText: "fallback")
            ],
            settings: settings,
            keychain: keychain
        )

        let block = TextBlock(
            text: "hello",
            region: DisplayLocalRect(displayID: 1, rect: .init(x: 0, y: 0, width: 10, height: 10)),
            detectedLanguage: .en,
            confidence: 1,
            source: .vision
        )

        let translations = try await router.translate([block], to: .tr)
        XCTAssertEqual(translations.map(\.provider), [.openAI])
        XCTAssertEqual(translations.map(\.translatedText), ["fallback"])
    }

    @MainActor
    func testExplicitProviderOverrideDoesNotFallback() async throws {
        let defaults = UserDefaults(suiteName: "TranslationRouterExplicit-\(UUID().uuidString)")!
        let keychain = KeychainStore(service: "TranslationRouterExplicit-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        settings.preferredProvider = .apple
        settings.fallbackProvider = .openAI
        settings.acceptDisclosure(for: .deepL)
        settings.acceptDisclosure(for: .openAI)

        let router = TranslationRouter(
            engines: [
                .deepL: StubEngine(identifier: .deepL, availability: .unsupported, resultText: "unused"),
                .openAI: StubEngine(identifier: .openAI, availability: .supported, resultText: "fallback")
            ],
            settings: settings,
            keychain: keychain
        )

        let block = TextBlock(
            text: "hello",
            region: DisplayLocalRect(displayID: 1, rect: .init(x: 0, y: 0, width: 10, height: 10)),
            detectedLanguage: .en,
            confidence: 1,
            source: .vision
        )

        do {
            _ = try await router.translate(
                [block],
                to: .tr,
                invocationOverride: InvocationRoutingOverride(provider: .deepL)
            )
            XCTFail("Expected explicit provider override to fail without fallback")
        } catch let error as GlanslateError {
            XCTAssertEqual(error, .unsupportedPair(.deepL, from: .en, to: .tr))
        }
    }

    @MainActor
    func testRouterDetectsSourceLanguageFromTextWhenBlocksLackDetectedLanguage() async throws {
        let defaults = UserDefaults(suiteName: "TranslationRouterDetect-\(UUID().uuidString)")!
        let keychain = KeychainStore(service: "TranslationRouterDetect-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        settings.preferredProvider = .openAI
        settings.fallbackProvider = .openAI
        settings.acceptDisclosure(for: .openAI)

        let engine = RecordingEngine(identifier: .openAI)
        let router = TranslationRouter(
            engines: [.openAI: engine],
            settings: settings,
            keychain: keychain
        )

        // No per-block detected language — the router must fall back to combined-text detection.
        let block = TextBlock(
            text: "The quick brown fox jumps over the lazy dog near the riverbank.",
            region: DisplayLocalRect(displayID: 1, rect: .init(x: 0, y: 0, width: 10, height: 10)),
            detectedLanguage: nil,
            confidence: 1,
            source: .vision
        )

        _ = try await router.translate([block], to: .tr)

        let recorded = await engine.lastFrom
        XCTAssertEqual(recorded, .en)
    }
}
