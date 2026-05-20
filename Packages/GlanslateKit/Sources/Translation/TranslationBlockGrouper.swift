import CoreGraphics
import Foundation
import GlanslateCore

public struct TranslationBlockGrouper: Sendable {
    public init() {}

    public func groupedForContext(_ blocks: [TextBlock]) -> [TextBlock] {
        guard blocks.count > 1 else { return blocks }

        let ordered = readingOrder(blocks)
        let medianHeight = medianLineHeight(in: ordered)
        let paragraphGapLimit = max(medianHeight * 1.45, 8)
        let edgeTolerance = max(medianHeight * 2.2, 24)

        var groups: [[TextBlock]] = []
        var current: [TextBlock] = []

        for block in ordered where !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let last = current.last else {
                current = [block]
                continue
            }

            if shouldMerge(
                block,
                after: last,
                in: current,
                paragraphGapLimit: paragraphGapLimit,
                edgeTolerance: edgeTolerance,
                medianHeight: medianHeight
            ) {
                current.append(block)
            } else {
                groups.append(current)
                current = [block]
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups.map(mergedBlock)
    }

    public static func groupedForContext(_ blocks: [TextBlock]) -> [TextBlock] {
        TranslationBlockGrouper().groupedForContext(blocks)
    }

    private func shouldMerge(
        _ block: TextBlock,
        after last: TextBlock,
        in group: [TextBlock],
        paragraphGapLimit: CGFloat,
        edgeTolerance: CGFloat,
        medianHeight: CGFloat
    ) -> Bool {
        guard block.region.displayID == last.region.displayID else { return false }

        let groupRect = unionRect(for: group)
        let nextRect = block.region.rect
        let verticalGap = nextRect.minY - groupRect.maxY
        guard verticalGap >= -medianHeight * 0.6, verticalGap <= paragraphGapLimit else {
            return false
        }
        guard isHorizontallyRelated(groupRect, nextRect, edgeTolerance: edgeTolerance) else {
            return false
        }

        if endsParagraph(last.text), verticalGap > medianHeight * 0.8 {
            return false
        }

        return true
    }

    private func mergedBlock(_ blocks: [TextBlock]) -> TextBlock {
        guard blocks.count > 1 else { return blocks[0] }

        let displayID = blocks[0].region.displayID
        let rect = unionRect(for: blocks)
        let medianHeight = medianLineHeight(in: blocks)
        let paragraphGapThreshold = medianHeight * 1.3

        var parts: [String] = [normalizedLine(blocks[0].text)]

        for i in 1..<blocks.count {
            let prev = blocks[i - 1]
            let curr = blocks[i]
            let prevText = normalizedLine(prev.text)
            let currText = normalizedLine(curr.text)

            let verticalGap = curr.region.rect.minY - prev.region.rect.maxY
            let isParagraphGap = verticalGap > paragraphGapThreshold

            let endsSentence = ".!?".contains(prevText.last ?? Character(""))
            let startsCapital = currText.first?.isUppercase ?? false
            let isNewSentence = endsSentence && startsCapital

            let separator = (isParagraphGap || isNewSentence) ? "\n" : " "
            parts.append(separator + currText)
        }

        let text = parts.joined()

        return TextBlock(
            text: text,
            region: DisplayLocalRect(displayID: displayID, rect: rect),
            detectedLanguage: dominantLanguage(in: blocks),
            confidence: blocks.map(\.confidence).reduce(0, +) / Double(blocks.count),
            source: mergedSource(in: blocks)
        )
    }

    private func readingOrder(_ blocks: [TextBlock]) -> [TextBlock] {
        blocks.sorted { lhs, rhs in
            if lhs.region.displayID != rhs.region.displayID {
                return lhs.region.displayID < rhs.region.displayID
            }

            let lhsRect = lhs.region.rect
            let rhsRect = rhs.region.rect
            let tolerance = max(min(lhsRect.height, rhsRect.height) * 0.6, 4)
            if abs(lhsRect.minY - rhsRect.minY) > tolerance {
                return lhsRect.minY < rhsRect.minY
            }
            return lhsRect.minX < rhsRect.minX
        }
    }

    private func medianLineHeight(in blocks: [TextBlock]) -> CGFloat {
        let heights = blocks
            .map { $0.region.rect.height }
            .filter { $0 > 0 }
            .sorted()
        guard !heights.isEmpty else { return 12 }
        return heights[heights.count / 2]
    }

    private func unionRect(for blocks: [TextBlock]) -> CGRect {
        blocks.reduce(CGRect.null) { partial, block in
            partial.union(block.region.rect)
        }
    }

    private func isHorizontallyRelated(
        _ lhs: CGRect,
        _ rhs: CGRect,
        edgeTolerance: CGFloat
    ) -> Bool {
        let intersection = lhs.intersection(rhs)
        if !intersection.isNull {
            let denominator = min(lhs.width, rhs.width)
            if denominator > 0, intersection.width / denominator >= 0.12 {
                return true
            }
        }

        return abs(lhs.minX - rhs.minX) <= edgeTolerance
            || abs(lhs.maxX - rhs.maxX) <= edgeTolerance
    }

    private func normalizedLine(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func endsParagraph(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?。！？".contains(last)
    }

    private func dominantLanguage(in blocks: [TextBlock]) -> Language? {
        var scores: [Language: Double] = [:]
        for block in blocks {
            guard let language = block.detectedLanguage else { continue }
            scores[language, default: 0] += max(block.confidence, 0.5)
        }

        let total = scores.values.reduce(0, +)
        guard let best = scores.max(by: { $0.value < $1.value }), total > 0 else {
            return nil
        }
        return best.value / total >= 0.6 ? best.key : nil
    }

    private func mergedSource(in blocks: [TextBlock]) -> TextBlock.Source {
        let sources = Set(blocks.map(\.source))
        return sources.count == 1 ? blocks[0].source : .arbitrated
    }
}
