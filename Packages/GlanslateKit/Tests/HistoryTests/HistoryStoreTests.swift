import CoreGraphics
import XCTest
@testable import GlanslateCore
@testable import GlanslateHistory

final class HistoryStoreTests: XCTestCase {
    @MainActor
    func testPinListDeleteRoundTrip() async throws {
        let store = try SwiftDataHistoryStore(inMemory: true)
        let translation = GlanslateCore.Translation(
            block: TextBlock(
                text: "hello",
                region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                detectedLanguage: .en,
                confidence: 1,
                source: .vision
            ),
            translatedText: "merhaba",
            targetLanguage: .tr,
            provider: .openAI
        )

        try await store.pin(translation, thumbnail: Data([1, 2, 3]))
        let items = try await store.list()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].translatedText, "merhaba")

        try await store.delete(translation.id)
        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testDeleteAllClearsPinnedTranslations() async throws {
        let store = try SwiftDataHistoryStore(inMemory: true)
        let translations = [
            translation(id: UUID(), source: "hello", translated: "merhaba"),
            translation(id: UUID(), source: "world", translated: "dunya"),
        ]

        for translation in translations {
            try await store.pin(translation, thumbnail: nil)
        }
        let pinned = try await store.list()
        XCTAssertEqual(pinned.count, 2)

        try await store.deleteAll()

        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
    }

    private func translation(id: UUID, source: String, translated: String) -> GlanslateCore.Translation {
        GlanslateCore.Translation(
            id: id,
            block: TextBlock(
                text: source,
                region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                detectedLanguage: .en,
                confidence: 1,
                source: .vision
            ),
            translatedText: translated,
            targetLanguage: .tr,
            provider: .openAI
        )
    }
}
