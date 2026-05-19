import CoreGraphics
import XCTest
@testable import GlanslateCapture
@testable import GlanslateCore
@testable import GlanslateGeometry
@testable import GlanslateOverlay

final class OverlayLayoutEngineTests: XCTestCase {
    func testLongTranslationGrowsButStaysAnchoredToSourceOrigin() {
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
        // The box grows to fit the longer translation...
        XCTAssertGreaterThan(rendered.frame.height, blockRect.height)
        // ...but the box stays anchored to the source — its top-left corner does not drift.
        XCTAssertLessThanOrEqual(rendered.frame.minX, blockRect.minX + 0.5)
        XCTAssertEqual(rendered.frame.minY, blockRect.minY, accuracy: 0.5)
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
        // It stays anchored on the source block.
        XCTAssertEqual(rendered.frame.minX, blockRect.minX, accuracy: 0.5)
        XCTAssertEqual(rendered.frame.minY, blockRect.minY, accuracy: 0.5)
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

    func testExcludedToolbarRectPushesBlockAwayFromCollision() {
        let source = sampleSource(region: CGRect(x: 0, y: 0, width: 420, height: 240))
        let translation = makeTranslation(
            text: "Toolbar collision case",
            blockRect: CGRect(x: 290, y: 18, width: 90, height: 24),
            language: .en
        )
        let toolbarRect = CGRect(x: 230, y: 12, width: 170, height: 58)

        let rendered = OverlayLayoutEngine.renderedBlock(
            for: translation,
            source: source,
            style: .cleanPatch,
            excludedRects: [toolbarRect]
        )

        XCTAssertFalse(rendered.frame.intersects(toolbarRect))
        XCTAssertTrue(source.region.rect.contains(rendered.frame))
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
