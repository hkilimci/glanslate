import Foundation
import Testing
@testable import GlanslateCore

@Suite("Overlay layout")
struct OverlayLayoutTests {
    let engine = OverlayLayoutEngine()
    let measurer = ApproximateMeasurer()
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

    private func input(_ text: String, frame: CGRect, lines: Int = 1, lineHeight: CGFloat = 20) -> OverlayLayoutInput {
        OverlayLayoutInput(id: UUID(), sourceFrame: frame, lineHeight: lineHeight, lineCount: lines, text: text)
    }

    @Test func fontSizeFollowsTheOriginalLineHeight() {
        #expect(abs(engine.baseFontSize(forLineHeight: 20) - 15.6) < 0.0001)
        #expect(engine.baseFontSize(forLineHeight: 4) == engine.minimumFontSize)
        #expect(engine.baseFontSize(forLineHeight: 200) == engine.maximumFontSize)
    }

    @Test func translationsOfSimilarLengthKeepTheOriginalSize() {
        let block = input("Hello world", frame: CGRect(x: 10, y: 10, width: 120, height: 20))
        let layout = engine.layout([block], in: bounds, measurer: measurer)[0]
        #expect(layout.fontSize == engine.baseFontSize(forLineHeight: 20))
        #expect(layout.frame.minX <= 10 && layout.frame.minY <= 10, "Aligned with the original")
        #expect(!layout.isCompressed)
    }

    @Test func longerLabelsWidenBeforeShrinkingButStopAtNeighbors() {
        let label = input("A considerably longer translation", frame: CGRect(x: 10, y: 10, width: 120, height: 20))
        let neighbor = input("Next", frame: CGRect(x: 250, y: 10, width: 60, height: 20))
        let layout = engine.layout([label, neighbor], in: bounds, measurer: measurer)[0]
        #expect(layout.frame.width > 120 + 10)
        #expect(layout.frame.maxX <= 250)
    }

    @Test func paragraphsGrowDownwardWithoutCoveringTheNextBlock() {
        let paragraph = input(
            String(repeating: "longer translated words ", count: 12),
            frame: CGRect(x: 10, y: 10, width: 300, height: 60),
            lines: 3
        )
        let below = input("Footer", frame: CGRect(x: 10, y: 160, width: 100, height: 20))
        let layout = engine.layout([paragraph, below], in: bounds, measurer: measurer)[0]
        #expect(layout.frame.height > 64)
        #expect(layout.frame.maxY <= 160)
        #expect(layout.fontSize >= engine.minimumFontSize)
    }

    @Test func impossibleFitsUseTheMinimumSizeAndAreFlagged() {
        let tiny = input(String(repeating: "word ", count: 400), frame: CGRect(x: 10, y: 10, width: 60, height: 14))
        let layout = engine.layout([tiny], in: CGRect(x: 0, y: 0, width: 100, height: 40), measurer: measurer)[0]
        #expect(layout.fontSize == engine.minimumFontSize)
        #expect(layout.isCompressed)
    }

    @Test func blocksStayInsideTheRegion() {
        let edge = input("Edge text", frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        let layout = engine.layout([edge], in: bounds, measurer: measurer)[0]
        #expect(bounds.contains(layout.frame))
    }
}

@Suite("Toolbar placement")
struct ToolbarPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 420, height: 44)

    @Test func prefersBelowTheRegion() {
        let result = ToolbarPlacement.place(toolbar: size, near: CGRect(x: 300, y: 400, width: 400, height: 200), within: screen)
        #expect(result.edge == .below)
        #expect(result.frame.maxY <= 400 - 10)
        #expect(result.frame.midX == 500)
    }

    @Test func movesAboveWhenThereIsNoRoomBelow() {
        let result = ToolbarPlacement.place(toolbar: size, near: CGRect(x: 300, y: 20, width: 400, height: 200), within: screen)
        #expect(result.edge == .above)
        #expect(result.frame.minY >= 230)
    }

    @Test func overlapsOnlyWhenTheRegionFillsTheScreen() {
        let result = ToolbarPlacement.place(toolbar: size, near: screen, within: screen)
        #expect(result.edge == .inside)
        #expect(screen.contains(result.frame))
    }

    @Test func staysOnScreenHorizontally() {
        let result = ToolbarPlacement.place(toolbar: size, near: CGRect(x: 1400, y: 400, width: 40, height: 40), within: screen)
        #expect(result.frame.maxX <= screen.maxX - 8)
        let negative = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let left = ToolbarPlacement.place(toolbar: size, near: CGRect(x: -1920, y: 500, width: 50, height: 50), within: negative)
        #expect(left.frame.minX >= negative.minX + 8)
    }
}
