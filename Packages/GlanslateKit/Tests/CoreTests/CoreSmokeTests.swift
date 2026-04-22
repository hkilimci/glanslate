import CoreGraphics
import XCTest
@testable import GlanslateCore

final class CoreSmokeTests: XCTestCase {
    func testLanguageCodableRoundTripsAllCases() throws {
        for language in Language.allCases {
            let encoded = try JSONEncoder().encode(language)
            let decoded = try JSONDecoder().decode(Language.self, from: encoded)
            XCTAssertEqual(decoded, language)
        }
    }

    func testDisplayLocalRectEqualityIncludesDisplayID() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let left = DisplayLocalRect(displayID: 1, rect: rect)
        let right = DisplayLocalRect(displayID: 2, rect: rect)

        XCTAssertNotEqual(left, right)
    }

    func testGlanslateErrorLocalizedDescriptionIsNonEmpty() {
        let error = GlanslateError.translation(provider: .openAI, reason: "boom")
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
}
