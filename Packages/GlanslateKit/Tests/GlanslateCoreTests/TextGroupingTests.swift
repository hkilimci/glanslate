import Foundation
import Testing
@testable import GlanslateCore

@Suite("Text grouping")
struct TextGroupingTests {
    let grouper = TextGrouper()

    @Test func wrappedLinesFormOneParagraph() {
        let blocks = grouper.group([
            line("Glanslate captures the region you select and", x: 20, y: 100, width: 380),
            line("recognizes its text on this Mac before it", x: 20, y: 121, width: 370),
            line("translates it.", x: 20, y: 142, width: 110),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "Glanslate captures the region you select and recognizes its text on this Mac before it translates it.")
        #expect(blocks[0].frame == CGRect(x: 20, y: 100, width: 380, height: 58))
        #expect(blocks[0].lineHeight == 16)
    }

    @Test func headingsAndParagraphGapsSplitBlocks() {
        let blocks = grouper.group([
            line("Getting Started", x: 20, y: 20, width: 220, height: 30),
            line("The first paragraph wraps onto a second line because", x: 20, y: 64, width: 400),
            line("it is long.", x: 20, y: 85, width: 80),
            line("A second paragraph starts after a blank line and it", x: 20, y: 125, width: 395),
            line("continues here.", x: 20, y: 146, width: 120),
        ])
        #expect(blocks.map(\.text) == [
            "Getting Started",
            "The first paragraph wraps onto a second line because it is long.",
            "A second paragraph starts after a blank line and it continues here.",
        ])
    }

    @Test func shortLinesStaySeparate() {
        // Menu items and list rows are deliberate line breaks, not wrapped prose.
        let blocks = grouper.group([
            line("Open Recent", x: 10, y: 10, width: 90),
            line("Save As…", x: 10, y: 30, width: 70),
            line("Export", x: 10, y: 50, width: 50),
        ])
        #expect(blocks.map(\.text) == ["Open Recent", "Save As…", "Export"])
    }

    @Test func lowercaseContinuationJoinsEvenShortLines() {
        let blocks = grouper.group([
            line("Tap here to", x: 10, y: 10, width: 90),
            line("continue setup", x: 10, y: 30, width: 110),
        ])
        #expect(blocks.map(\.text) == ["Tap here to continue setup"])
    }

    @Test func bulletsStartNewBlocks() {
        let blocks = grouper.group([
            line("• Select any text on screen, even inside images and", x: 10, y: 10, width: 400),
            line("• Read the translation in place", x: 10, y: 31, width: 400),
        ])
        #expect(blocks.count == 2)
    }

    @Test func hyphenatedLineBreaksAreRejoined() {
        let blocks = grouper.group([
            line("Recognition happens on device, and transla-", x: 10, y: 10, width: 360),
            line("tion follows your provider settings.", x: 10, y: 31, width: 300),
        ])
        #expect(blocks.first?.text == "Recognition happens on device, and translation follows your provider settings.")
    }

    @Test func chineseLinesJoinWithoutSpaces() {
        let blocks = grouper.group([
            line("这是一个很长的句子，它在屏幕上被分成了", x: 10, y: 10, width: 300, height: 18),
            line("两行。", x: 10, y: 32, width: 60, height: 18),
        ])
        #expect(blocks.first?.text == "这是一个很长的句子，它在屏幕上被分成了两行。")
    }

    @Test func fragmentsOnTheSameRowAreReunited() {
        let blocks = grouper.group([
            line("Screen", x: 10, y: 10, width: 50),
            line("Recording", x: 64, y: 11, width: 74),
        ])
        #expect(blocks.map(\.text) == ["Screen Recording"])
    }

    @Test func rightToLeftFragmentsAreReunitedRightToLeft() {
        // "Welcome" on the right, "to the app" on the left: Arabic reads from the right.
        let blocks = grouper.group([
            line("في التطبيق", x: 100, y: 10, width: 90),
            line("مرحبا بكم", x: 196, y: 10, width: 80),
        ])
        #expect(blocks.map(\.text) == ["مرحبا بكم في التطبيق"])
    }

    @Test func distantItemsOnARowStaySeparateAndReadLeftToRight() {
        let blocks = grouper.group([
            line("Size", x: 400, y: 10, width: 40),
            line("Name", x: 10, y: 10, width: 44),
            line("Kind", x: 600, y: 10, width: 36),
        ])
        #expect(blocks.map(\.text) == ["Name", "Size", "Kind"])
    }

    @Test func columnsReadTopToBottomBeforeMovingRight() {
        let blocks = grouper.group([
            line("Article Title Across Both Columns", x: 20, y: 10, width: 560, height: 28),
            line("Left column first paragraph text", x: 20, y: 60, width: 260),
            line("Right column first paragraph", x: 320, y: 60, width: 250),
            line("Left column second paragraph", x: 20, y: 120, width: 240),
            line("Right column second paragraph", x: 320, y: 140, width: 245),
        ])
        #expect(blocks.map(\.text) == [
            "Article Title Across Both Columns",
            "Left column first paragraph text",
            "Left column second paragraph",
            "Right column first paragraph",
            "Right column second paragraph",
        ])
    }

    @Test func rightToLeftColumnsReadTheRightColumnFirst() {
        let title = "عنوان المقال عبر العمودين"
        let rightFirst = "الفقرة الأولى في العمود الأيمن"
        let rightSecond = "الفقرة الثانية في العمود الأيمن"
        let leftFirst = "الفقرة الأولى في العمود الأيسر"
        let leftSecond = "الفقرة الثانية في العمود الأيسر"
        let blocks = grouper.group([
            line(title, x: 20, y: 10, width: 560, height: 28),
            line(leftFirst, x: 20, y: 60, width: 260),
            line(rightFirst, x: 320, y: 60, width: 250),
            line(leftSecond, x: 20, y: 120, width: 240),
            line(rightSecond, x: 320, y: 140, width: 245),
        ])
        #expect(blocks.map(\.text) == [title, rightFirst, rightSecond, leftFirst, leftSecond])
    }

    @Test func distantRightToLeftItemsOnARowReadFromTheRight() {
        let blocks = grouper.group([
            line("الحجم", x: 400, y: 10, width: 40),
            line("الاسم", x: 10, y: 10, width: 44),
            line("النوع", x: 600, y: 10, width: 36),
        ])
        #expect(blocks.map(\.text) == ["النوع", "الحجم", "الاسم"])
    }

    @Test func emptyAndDegenerateLinesAreIgnored() {
        let blocks = grouper.group([
            line("   ", x: 10, y: 10, width: 40),
            RecognizedLine(text: "Zero", frame: CGRect(x: 10, y: 40, width: 0, height: 16)),
            line("Kept", x: 10, y: 80, width: 40),
        ])
        #expect(blocks.map(\.text) == ["Kept"])
    }
}

@Suite("Accessibility merge")
struct AccessibilityMergeTests {
    let merger = AccessibilityTextMerger()

    @Test func accessibilityTextCorrectsOCRCharacters() {
        let ocr = [line("Prefer0nces", x: 10, y: 10, width: 90)]
        let fragments = [AccessibleTextFragment(text: "Preferences", frame: CGRect(x: 8, y: 8, width: 96, height: 20))]
        let merged = merger.merge(ocr: ocr, fragments: fragments)
        #expect(merged.count == 1)
        #expect(merged[0].text == "Preferences")
        #expect(merged[0].source == .accessibility)
        #expect(merged[0].frame == ocr[0].frame, "OCR geometry is kept")
    }

    @Test func splitOCRLinesBecomeOneLineWithoutDuplication() {
        let ocr = [
            line("Download", x: 10, y: 10, width: 70),
            line("Languages", x: 84, y: 10, width: 80),
        ]
        let fragments = [
            AccessibleTextFragment(text: "Download Languages", frame: CGRect(x: 8, y: 8, width: 160, height: 20)),
            // The same text reported again by a parent element.
            AccessibleTextFragment(text: "Download Languages", frame: CGRect(x: 6, y: 6, width: 170, height: 24)),
        ]
        let merged = merger.merge(ocr: ocr, fragments: fragments)
        #expect(merged.map(\.text) == ["Download Languages"])
        #expect(merged[0].frame == CGRect(x: 10, y: 10, width: 154, height: 16))
    }

    @Test func fragmentsWithoutVisibleTextAreIgnored() {
        let ocr = [line("Visible", x: 10, y: 10, width: 60)]
        let fragments = [AccessibleTextFragment(text: "Hidden offscreen label", frame: CGRect(x: 10, y: 300, width: 160, height: 18))]
        #expect(merger.merge(ocr: ocr, fragments: fragments).map(\.text) == ["Visible"])
    }

    @Test func fragmentsExtendingPastTheSelectionAreIgnored() {
        let selection = CGRect(x: 0, y: 0, width: 200, height: 40)
        let ocr = [line("Customer name: Jane Smith", x: 10, y: 10, width: 185)]
        // One element whose text continues past the selection's right edge.
        let wider = AccessibleTextFragment(text: "Customer name: Jane Smith SSN 123456789", frame: CGRect(x: 8, y: 8, width: 300, height: 20))
        #expect(merger.merge(ocr: ocr, fragments: [wider], within: selection).map(\.text) == ["Customer name: Jane Smith"])

        let inside = AccessibleTextFragment(text: "Customer name: Jane Smith", frame: CGRect(x: 8, y: 8, width: 190, height: 20))
        let merged = merger.merge(ocr: ocr, fragments: [inside], within: selection)
        #expect(merged.map(\.source) == [.accessibility], "Fragments inside the selection still apply")
    }

    @Test func unrelatedTextIsNotSubstituted() {
        let ocr = [line("Cancel", x: 10, y: 10, width: 50)]
        let fragments = [AccessibleTextFragment(text: "Button", frame: CGRect(x: 8, y: 8, width: 60, height: 20))]
        #expect(merger.merge(ocr: ocr, fragments: fragments).map(\.text) == ["Cancel"])
    }

    @Test func multiLineFragmentsLeaveOCRUntouched() {
        let ocr = [line("First line", x: 10, y: 10, width: 80), line("Second line", x: 10, y: 30, width: 90)]
        let fragments = [AccessibleTextFragment(text: "First line Second line", frame: CGRect(x: 8, y: 8, width: 100, height: 60))]
        #expect(merger.merge(ocr: ocr, fragments: fragments).map(\.text) == ["First line", "Second line"])
    }

    @Test func similarityIsTolerantToOCRSlips() {
        #expect(AccessibilityTextMerger.similarity("preferences", "prefer0nces") > 0.7)
        #expect(AccessibilityTextMerger.similarity("cancel", "button") < 0.2)
    }

    @Test func assemblerDetectsTheDominantLanguage() {
        struct FixedDetector: LanguageDetecting {
            func detectLanguage(of text: String) -> DetectedLanguage? { DetectedLanguage(language: .german, confidence: 0.93) }
        }
        let assembler = TextAssembler(detector: FixedDetector())
        let region = ScreenRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 400, height: 200))
        let text = assembler.assemble(region: region, ocrLines: [line("Guten Tag", x: 10, y: 10, width: 80)], accessibilityFragments: [])
        #expect(text.blocks.count == 1)
        #expect(text.detectedLanguage?.language == .german)
        #expect(!text.usedAccessibility)
    }
}
