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
}
