import CoreGraphics
import XCTest
@testable import GlanslateCapture
@testable import GlanslateCore
@testable import GlanslateGeometry
@testable import GlanslateOverlay

final class OverlayLayoutEngineTests: XCTestCase {
    func testLongTranslationGrowsHorizontallyBeforeClipping() {
        let source = sampleSource(region: CGRect(x: 20, y: 20, width: 520, height: 360))
        let blockRect = CGRect(x: 210, y: 150, width: 80, height: 24)
        let translation = makeTranslation(
            text: "This is a much longer translated block that should need more room than the original source rect allows for a comfortable patch layout.",
            blockRect: blockRect,
            language: .en
        )

        let rendered = OverlayLayoutEngine.renderedBlock(
            for: translation,
            source: source,
            style: .cleanPatch
        )

        XCTAssertTrue(source.region.rect.contains(rendered.frame))
        XCTAssertEqual(rendered.frame.minX, blockRect.minX - 1, accuracy: 0.5)
        XCTAssertEqual(rendered.frame.minY, blockRect.minY - 1, accuracy: 0.5)
        XCTAssertGreaterThan(rendered.frame.width, blockRect.width)
        XCTAssertEqual(rendered.frame.height, blockRect.insetBy(dx: -1, dy: -1).height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(rendered.fontSize, 8)
        XCTAssertEqual(rendered.horizontalPadding, 3)
        XCTAssertEqual(rendered.verticalPadding, 2)
    }

    func testShortTranslationDoesNotProduceOversizedBox() {
        let source = sampleSource(region: CGRect(x: 0, y: 0, width: 400, height: 300))
        let blockRect = CGRect(x: 60, y: 80, width: 160, height: 28)
        let translation = makeTranslation(text: "Hi", blockRect: blockRect, language: .en)

        let rendered = OverlayLayoutEngine.renderedBlock(
            for: translation,
            source: source,
            style: .cleanPatch
        )

        // A short translation must not blow the box up to the whole selection.
        XCTAssertLessThan(rendered.frame.width, source.region.rect.width)
        XCTAssertLessThan(rendered.frame.height, source.region.rect.height)
        XCTAssertEqual(rendered.frame, blockRect.insetBy(dx: -1, dy: -1))
    }

    func testArabicUsesRightToLeftDirectionAndTrailingAlignment() {
        let source = sampleSource(region: CGRect(x: 0, y: 0, width: 220, height: 160))
        let translation = makeTranslation(
            text: "مرحبا بالعالم",
            blockRect: CGRect(x: 20, y: 30, width: 100, height: 30),
            language: .ar
        )

        let rendered = OverlayLayoutEngine.renderedBlock(
            for: translation,
            source: source,
            style: .subtitle
        )

        XCTAssertEqual(rendered.direction, .rightToLeft)
        XCTAssertEqual(rendered.textAlignment, .trailing)
    }

    func testBlockNearRightEdgeExpandsLeftWithinBounds() {
        let source = sampleSource(region: CGRect(x: 0, y: 0, width: 420, height: 240))
        let blockRect = CGRect(x: 290, y: 18, width: 90, height: 24)
        let translation = makeTranslation(
            text: "Toolbar collision case",
            blockRect: blockRect,
            language: .en
        )
        let toolbarRect = CGRect(x: 230, y: 12, width: 170, height: 58)

        let rendered = OverlayLayoutEngine.renderedBlock(
            for: translation,
            source: source,
            style: .cleanPatch,
            excludedRects: [toolbarRect]
        )

        XCTAssertTrue(source.region.rect.contains(rendered.frame))
        XCTAssertTrue(rendered.frame.contains(blockRect.insetBy(dx: -1, dy: -1)))
        XCTAssertGreaterThan(rendered.frame.width, blockRect.width)
        XCTAssertEqual(rendered.frame.maxX, source.region.rect.maxX, accuracy: 0.5)
    }

    func testMultipleTranslationsRenderOnTheirSourceBoxes() {
        let source = sampleSource(region: CGRect(x: 0, y: 0, width: 420, height: 260))
        let first = makeTranslation(
            text: "First translated line",
            blockRect: CGRect(x: 40, y: 44, width: 120, height: 22),
            language: .en
        )
        let second = makeTranslation(
            text: "Second translated line",
            blockRect: CGRect(x: 38, y: 70, width: 128, height: 22),
            language: .en
        )

        let rendered = OverlayLayoutEngine.renderedBlocks(
            translations: [second, first],
            source: source,
            style: .cleanPatch
        )

        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(rendered[0].translation.translatedText, "Second translated line")
        XCTAssertEqual(rendered[1].translation.translatedText, "First translated line")
        XCTAssertTrue(rendered[0].frame.contains(second.block.region.rect.insetBy(dx: -1, dy: -1)))
        XCTAssertTrue(rendered[1].frame.contains(first.block.region.rect.insetBy(dx: -1, dy: -1)))
        XCTAssertGreaterThan(rendered[0].frame.width, second.block.region.rect.width)
        XCTAssertGreaterThan(rendered[1].frame.width, first.block.region.rect.width)
    }

    private func makeTranslation(
        text: String,
        blockRect: CGRect,
        language: Language
    ) -> GlanslateCore.Translation {
        let block = TextBlock(
            text: "source",
            region: DisplayLocalRect(displayID: 1, rect: blockRect),
            detectedLanguage: .en,
            confidence: 1,
            source: .vision
        )
        return GlanslateCore.Translation(
            block: block,
            translatedText: text,
            targetLanguage: language,
            provider: .openAI
        )
    }

    private func sampleSource(region: CGRect) -> SourceVisualContext {
        let topology = DisplayTopologySnapshot(entries: [
            DisplayTopologyEntry(
                displayID: 1,
                appKitFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                backingScale: 2,
                pixelSize: CGSize(width: 800, height: 600),
                isMain: true
            )
        ])
        return SourceVisualContext(
            image: makeImage(width: 100, height: 100),
            region: DisplayLocalRect(displayID: 1, rect: region),
            topology: topology,
            pixelScale: 2
        )
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
