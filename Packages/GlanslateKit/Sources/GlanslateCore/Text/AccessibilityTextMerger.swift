import Foundation

/// Improves OCR lines with exact text from the Accessibility tree.
///
/// OCR is the source of truth for *what is visible and where*; Accessibility
/// is the source of truth for *exact characters*. A fragment replaces the OCR
/// lines it covers only when the two clearly describe the same text, and each
/// OCR line is consumed at most once, so nothing is duplicated. Fragments with
/// no visible OCR counterpart are ignored: they may be scrolled out of view or
/// hidden behind another window.
public struct AccessibilityTextMerger: Sendable {
    /// Minimum bigram similarity between fragment and OCR text.
    public var minimumSimilarity: Double = 0.55

    public init() {}

    public func merge(ocr lines: [RecognizedLine], fragments: [AccessibleTextFragment]) -> [RecognizedLine] {
        guard !lines.isEmpty, !fragments.isEmpty else { return lines }
        let typicalHeight = TextBlock.median(lines.map(\.frame.height))

        // Most specific fragments first, so a link nested in a paragraph wins over the paragraph.
        let candidates = deduplicated(fragments)
            .filter { $0.frame.height > 0 && $0.frame.height <= typicalHeight * 2.2 }
            .sorted { $0.frame.area < $1.frame.area }

        var consumed: Set<UUID> = []
        var replacements: [RecognizedLine] = []

        for fragment in candidates {
            let zone = fragment.frame.insetBy(dx: -2, dy: -2)
            let matched = lines
                .filter { !consumed.contains($0.id) }
                .filter { zone.contains($0.frame.center) && $0.frame.verticalOverlapRatio(with: fragment.frame) >= 0.5 }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard !matched.isEmpty else { continue }

            let fragmentText = TextGrouper.collapseWhitespace(fragment.text)
            let ocrText = matched.map(\.text).joined(separator: " ")
            guard Self.isPlausibleMatch(fragmentText, ocrText, minimumSimilarity: minimumSimilarity) else { continue }

            matched.forEach { consumed.insert($0.id) }
            replacements.append(RecognizedLine(
                id: matched[0].id,
                text: fragmentText,
                frame: matched.reduce(CGRect.null) { $0.union($1.frame) },
                confidence: 1,
                source: .accessibility
            ))
        }

        return lines.filter { !consumed.contains($0.id) } + replacements
    }

    private func deduplicated(_ fragments: [AccessibleTextFragment]) -> [AccessibleTextFragment] {
        var unique: [AccessibleTextFragment] = []
        for fragment in fragments {
            let text = Self.normalized(fragment.text)
            guard !text.isEmpty else { continue }
            let duplicate = unique.contains {
                Self.normalized($0.text) == text && $0.frame.intersection(fragment.frame).area >= 0.5 * min($0.frame.area, fragment.frame.area)
            }
            if !duplicate { unique.append(fragment) }
        }
        return unique
    }

    static func isPlausibleMatch(_ fragment: String, _ ocr: String, minimumSimilarity: Double) -> Bool {
        let a = normalized(fragment), b = normalized(ocr)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let ratio = Double(a.count) / Double(b.count)
        guard ratio >= 0.6, ratio <= 1.6 else { return false }
        return similarity(a, b) >= minimumSimilarity
    }

    /// Letters and digits only, lowercased, so OCR spacing and punctuation slips don't matter.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Sørensen–Dice coefficient over character bigrams (0...1).
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        guard x.count > 1, y.count > 1 else { return 0 }
        var bigrams: [String: Int] = [:]
        for i in 0..<(x.count - 1) { bigrams[String(x[i...i + 1]), default: 0] += 1 }
        var shared = 0
        for i in 0..<(y.count - 1) {
            let key = String(y[i...i + 1])
            if let count = bigrams[key], count > 0 {
                shared += 1
                bigrams[key] = count - 1
            }
        }
        return 2 * Double(shared) / Double(x.count - 1 + y.count - 1)
    }
}
