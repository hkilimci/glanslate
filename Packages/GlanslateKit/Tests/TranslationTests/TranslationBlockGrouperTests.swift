import CoreGraphics
import XCTest
@testable import GlanslateCore
@testable import GlanslateTranslation

final class TranslationBlockGrouperTests: XCTestCase {
    func testMergesWrappedParagraphLinesAndKeepsParagraphBreaks() {
        let blocks = [
            block("Thanks for your comment. You have a point.", y: 0),
            block("I would also behave like you in terms of security.", y: 16),
            block("It is an open-source app so you can check the code.", y: 32),
            block("You can also fork the project.", y: 70),
        ]

        let grouped = TranslationBlockGrouper.groupedForContext(blocks)

        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(
            grouped[0].text,
            "Thanks for your comment. You have a point.\nI would also behave like you in terms of security.\nIt is an open-source app so you can check the code."
        )
        XCTAssertEqual(grouped[0].region.rect, CGRect(x: 10, y: 0, width: 300, height: 44))
        XCTAssertEqual(grouped[1].text, "You can also fork the project.")
    }

    func testDoesNotMergeSeparateColumns() {
        let blocks = [
            block("Left column line one", x: 10, y: 0, width: 120),
            block("Right column line one", x: 220, y: 2, width: 140),
            block("Left column line two", x: 10, y: 16, width: 120),
        ]

        let grouped = TranslationBlockGrouper.groupedForContext(blocks)

        XCTAssertEqual(grouped.map(\.text), [
            "Left column line one",
            "Right column line one",
            "Left column line two",
        ])
    }

    private func block(
        _ text: String,
        x: CGFloat = 10,
        y: CGFloat,
        width: CGFloat = 300
    ) -> TextBlock {
        TextBlock(
            text: text,
            region: DisplayLocalRect(displayID: 1, rect: CGRect(x: x, y: y, width: width, height: 12)),
            detectedLanguage: .en,
            confidence: 1,
            source: .vision
        )
    }
}
