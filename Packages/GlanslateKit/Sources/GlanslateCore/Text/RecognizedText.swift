import Foundation

/// Where a line of text came from.
public enum TextSource: String, Hashable, Sendable, Codable {
    /// Vision optical character recognition on the captured pixels.
    case ocr
    /// The application's Accessibility tree, matched to OCR geometry.
    case accessibility
}

/// One visual line of text, in display-local points.
public struct RecognizedLine: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let frame: CGRect
    public let confidence: Double
    public let source: TextSource

    public init(id: UUID = UUID(), text: String, frame: CGRect, confidence: Double = 1, source: TextSource = .ocr) {
        self.id = id
        self.text = text
        self.frame = frame
        self.confidence = confidence
        self.source = source
    }
}

/// A run of text from an Accessibility element, in display-local points.
public struct AccessibleTextFragment: Equatable, Sendable {
    public let text: String
    public let frame: CGRect

    public init(text: String, frame: CGRect) {
        self.text = text
        self.frame = frame
    }
}

/// A paragraph or label: the unit Glanslate translates and lays out.
public struct TextBlock: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let lines: [RecognizedLine]
    /// The block's text in reading order, with lines joined into running prose.
    public let text: String
    /// The union of the line frames.
    public let frame: CGRect
    /// The median line height, used to size translated text.
    public let lineHeight: CGFloat

    public init(id: UUID = UUID(), lines: [RecognizedLine], text: String) {
        self.id = id
        self.lines = lines
        self.text = text
        self.frame = lines.reduce(CGRect.null) { $0.union($1.frame) }
        self.lineHeight = TextBlock.median(lines.map(\.frame.height))
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// Everything read from one capture.
public struct RecognizedText: Equatable, Sendable {
    public let region: ScreenRegion
    public let blocks: [TextBlock]
    public let detectedLanguage: DetectedLanguage?

    public init(region: ScreenRegion, blocks: [TextBlock], detectedLanguage: DetectedLanguage?) {
        self.region = region
        self.blocks = blocks
        self.detectedLanguage = detectedLanguage
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// The source text in reading order, one paragraph per block.
    public var fullText: String { blocks.map(\.text).joined(separator: "\n\n") }

    public var usedAccessibility: Bool {
        blocks.contains { $0.lines.contains { $0.source == .accessibility } }
    }
}
