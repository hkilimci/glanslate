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
}
