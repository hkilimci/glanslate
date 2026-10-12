import Foundation

/// Turns raw OCR lines and Accessibility fragments into translatable blocks.
public struct TextAssembler: Sendable {
    public let grouper: TextGrouper
    public let merger: AccessibilityTextMerger
    public let detector: (any LanguageDetecting)?

    public init(
        grouper: TextGrouper = TextGrouper(),
        merger: AccessibilityTextMerger = AccessibilityTextMerger(),
        detector: (any LanguageDetecting)?
    ) {
        self.grouper = grouper
        self.merger = merger
        self.detector = detector
    }

    public func assemble(
        region: ScreenRegion,
        ocrLines: [RecognizedLine],
        accessibilityFragments: [AccessibleTextFragment]
    ) -> RecognizedText {
        let lines = merger.merge(ocr: ocrLines, fragments: accessibilityFragments, within: region.rect)
        let blocks = grouper.group(lines)
        let fullText = blocks.map(\.text).joined(separator: "\n")
        let detected = fullText.isEmpty ? nil : detector?.detectLanguage(of: fullText)
        return RecognizedText(region: region, blocks: blocks, detectedLanguage: detected)
    }
}
