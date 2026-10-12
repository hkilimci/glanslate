import Foundation

/// Groups recognized lines into paragraphs and orders them for reading.
///
/// OCR reports one observation per visual line, sometimes split mid-line.
/// The grouper first reunites fragments that sit on the same row, then links
/// each line to the line that continues it, and finally orders the resulting
/// blocks with a recursive XY cut so multi-column layouts read column by column.
public struct TextGrouper: Sendable {
    public init() {}

    public func group(_ input: [RecognizedLine]) -> [TextBlock] {
        let usable = input.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.frame.width > 0 && $0.frame.height > 0
        }
        let lines = mergeRowFragments(usable)
        let blocks = linkParagraphs(lines).map { TextBlock(lines: $0, text: TextGrouper.join($0)) }
        return TextGrouper.readingOrder(blocks)
    }

    // MARK: Row fragments

    func mergeRowFragments(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        var rows: [RecognizedLine] = []
        for line in lines.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let candidate = rows.indices
                .filter { TextGrouper.continuesRow(rows[$0], with: line) }
                .min { line.frame.minX - rows[$0].frame.maxX < line.frame.minX - rows[$1].frame.maxX }
            if let index = candidate {
                rows[index] = TextGrouper.joinRow(rows[index], line)
            } else {
                rows.append(line)
            }
        }
        return rows
    }

    static func continuesRow(_ left: RecognizedLine, with right: RecognizedLine) -> Bool {
        let a = left.frame, b = right.frame
        let h = max(a.height, b.height)
        guard a.verticalOverlapRatio(with: b) >= 0.6 else { return false }
        guard max(a.height, b.height) / max(min(a.height, b.height), 0.1) <= 1.35 else { return false }
        let gap = b.minX - a.maxX
        return gap >= -0.5 * h && gap <= 0.8 * h
    }

    static func joinRow(_ left: RecognizedLine, _ right: RecognizedLine) -> RecognizedLine {
        // Right-to-left text starts with the fragment on the right.
        let (first, second) = isRightToLeft(left.text + right.text) ? (right, left) : (left, right)
        let separator = needsSpace(between: first.text, and: second.text) ? " " : ""
        return RecognizedLine(
            id: left.id,
            text: collapseWhitespace(first.text) + separator + collapseWhitespace(second.text),
            frame: left.frame.union(right.frame),
            confidence: min(left.confidence, right.confidence),
            source: left.source == .accessibility && right.source == .accessibility ? .accessibility : .ocr
        )
    }

    // MARK: Paragraph linking

    func linkParagraphs(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        let sorted = lines.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        struct Candidate { let upper: Int; let lower: Int; let gap: CGFloat; let offset: CGFloat }

        var candidates: [Candidate] = []
        for i in sorted.indices {
            for j in sorted.indices where i != j {
                guard TextGrouper.continues(sorted[i], into: sorted[j]) else { continue }
                candidates.append(Candidate(
                    upper: i,
                    lower: j,
                    gap: sorted[j].frame.minY - sorted[i].frame.maxY,
                    offset: abs(sorted[j].frame.minX - sorted[i].frame.minX)
                ))
            }
        }

        var next: [Int: Int] = [:]
        var previous: [Int: Int] = [:]
        for candidate in candidates.sorted(by: { ($0.gap, $0.offset) < ($1.gap, $1.offset) }) {
            guard next[candidate.upper] == nil, previous[candidate.lower] == nil else { continue }
            next[candidate.upper] = candidate.lower
            previous[candidate.lower] = candidate.upper
        }

        var chains: [[RecognizedLine]] = []
        for start in sorted.indices where previous[start] == nil {
            var chain = [sorted[start]]
            var cursor = start
            var visited: Set<Int> = [start]
            while let following = next[cursor], !visited.contains(following) {
                chain.append(sorted[following])
                visited.insert(following)
                cursor = following
            }
            chains.append(chain)
        }
        return chains
    }

    /// Whether `lower` continues the paragraph that `upper` belongs to.
    static func continues(_ upper: RecognizedLine, into lower: RecognizedLine) -> Bool {
        let a = upper.frame, b = lower.frame
        let h = max(a.height, b.height)
        guard b.minY > a.minY + 0.5 * a.height else { return false }
        guard h / max(min(a.height, b.height), 0.1) <= 1.45 else { return false }

        let gap = b.minY - a.maxY
        guard gap >= -0.35 * h, gap <= 0.75 * h else { return false }

        let aligned = a.horizontalOverlapRatio(with: b) >= 0.5
            || abs(a.minX - b.minX) <= 0.8 * h
            || abs(a.midX - b.midX) <= 0.8 * h
        guard aligned else { return false }

        let upperText = upper.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerText = lower.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !startsListItem(lowerText) else { return false }

        let strongContinuation = upperText.hasSuffix("-") || upperText.hasSuffix(",")
            || (lowerText.first?.isLowercase ?? false)
        if strongContinuation { return true }

        // A line that fills the column wrapped; a short one ended deliberately
        // (end of paragraph, list item, or label).
        let isFull = a.width >= 0.8 * max(a.width, b.width) && a.width >= 8 * h
        return isFull
    }

    static func startsListItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•◦▪▫‣⁃●○■□–—*".contains(first) { return true }
        if first == "-", text.dropFirst().first == " " { return true }
        // Enumerations such as "1. ", "12) ", or "a. ".
        let head = Array(text.prefix(5))
        guard let marker = head.firstIndex(where: { $0 == "." || $0 == ")" }),
              marker > 0, marker + 1 < head.count, head[marker + 1] == " " else { return false }
        let label = head[0..<marker]
        return label.allSatisfy(\.isNumber) || (label.count == 1 && label.allSatisfy(\.isLetter))
    }

    // MARK: Text

    /// Joins a paragraph's lines into running text, undoing hyphenation and
    /// omitting spaces for scripts that don't use them.
    static func join(_ lines: [RecognizedLine]) -> String {
        var result = ""
        for line in lines {
            let text = collapseWhitespace(line.text)
            guard !result.isEmpty else {
                result = text
                continue
            }
            if result.hasSuffix("-"), !result.hasSuffix(" -"),
               let first = text.first, first.isLetter, first.isLowercase {
                result.removeLast()
                result += text
            } else if needsSpace(between: result, and: text) {
                result += " " + text
            } else {
                result += text
            }
        }
        return result
    }

    static func needsSpace(between left: String, and right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else { return false }
        return !(isSpacelessScript(last) || isSpacelessScript(first))
    }

    static func isSpacelessScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x3400...0x4DBF, // CJK extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF00...0xFFEF, // Halfwidth and fullwidth forms
             0x0E00...0x0E7F: // Thai
            return true
        default:
            return false
        }
    }

    /// Whether most of the text's letters belong to a right-to-left script.
    static func isRightToLeft(_ text: String) -> Bool {
        var rightToLeft = 0, other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if isRightToLeftScript(scalar) { rightToLeft += 1 } else { other += 1 }
        }
        return rightToLeft > other
    }

    static func isRightToLeftScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, // Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic, Arabic extensions
             0xFB1D...0xFDFF, // Hebrew and Arabic presentation forms
             0xFE70...0xFEFF: // Arabic presentation forms B
            return true
        default:
            return false
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Reading order

    /// Orders blocks with a recursive XY cut.
    ///
    /// Blocks are cut into rows along horizontal gaps. Wide blocks (headings,
    /// full-width paragraphs) separate sections; inside a section, staggered
    /// narrow blocks read column by column (articles), while rows whose items
    /// line up read row by row (tables, forms, toolbars). Right-to-left text reads
    /// its columns and row items from the right.
    static func readingOrder(_ blocks: [TextBlock]) -> [TextBlock] {
        readingOrder(blocks, rightToLeft: isRightToLeft(blocks.map(\.text).joined()))
    }

    private static func readingOrder(_ blocks: [TextBlock], rightToLeft: Bool) -> [TextBlock] {
        guard blocks.count > 1 else { return blocks }
        func order(_ blocks: [TextBlock]) -> [TextBlock] { readingOrder(blocks, rightToLeft: rightToLeft) }
        /// Groups side by side, in the order they are read.
        func columnsInReadingOrder(_ blocks: [TextBlock]) -> [[TextBlock]] {
            let columns = split(blocks, vertical: false)
            return rightToLeft ? columns.reversed() : columns
        }

        let rows = split(blocks, vertical: true)
        guard rows.count > 1 else {
            let columns = columnsInReadingOrder(blocks)
            guard columns.count > 1 else {
                return blocks.sorted {
                    rightToLeft
                        ? ($0.frame.minY, -$0.frame.maxX) < ($1.frame.minY, -$1.frame.maxX)
                        : ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
                }
            }
            return columns.flatMap(order)
        }

        let totalWidth = blocks.reduce(CGRect.null) { $0.union($1.frame) }.width
        var ordered: [TextBlock] = []
        var section: [[TextBlock]] = []

        func flushSection() {
            guard !section.isEmpty else { return }
            let alignedRows = section.filter { split($0, vertical: false).count > 1 }.count
            let columns = columnsInReadingOrder(section.flatMap { $0 })
            if columns.count > 1, alignedRows * 2 < section.count {
                ordered += columns.flatMap(order)
            } else {
                ordered += section.flatMap(order)
            }
            section = []
        }

        for row in rows {
            if row.contains(where: { $0.frame.width >= 0.6 * totalWidth }) {
                flushSection()
                ordered += order(row)
            } else {
                section.append(row)
            }
        }
        flushSection()
        return ordered
    }

    private static func split(_ blocks: [TextBlock], vertical: Bool) -> [[TextBlock]] {
        let low: (CGRect) -> CGFloat = vertical ? { $0.minY } : { $0.minX }
        let high: (CGRect) -> CGFloat = vertical ? { $0.maxY } : { $0.maxX }
        let sorted = blocks.sorted { low($0.frame) < low($1.frame) }

        var groups: [[TextBlock]] = []
        var current: [TextBlock] = []
        var reach = -CGFloat.infinity
        for block in sorted {
            let gap = low(block.frame) - reach
            if !current.isEmpty, gap >= -1 {
                groups.append(current)
                current = []
            }
            current.append(block)
            reach = max(reach, high(block.frame))
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
