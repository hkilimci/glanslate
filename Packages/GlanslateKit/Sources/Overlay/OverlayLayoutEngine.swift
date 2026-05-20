import AppKit
import Foundation
import GlanslateCapture
import GlanslateCore

struct OverlayRenderedBlock: Identifiable, Sendable {
    let id: UUID
    let translation: GlanslateCore.Translation
    let frame: CGRect
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let textAlignment: OverlayTextAlignment
    let direction: OverlayTextDirection
}

enum OverlayTextAlignment: Sendable, Hashable {
    case leading
    case trailing
    case center
}

enum OverlayTextDirection: Sendable, Hashable {
    case leftToRight
    case rightToLeft
}

struct OverlayLayoutEngine: Sendable {
    static func renderedBlocks(
        translations: [GlanslateCore.Translation],
        source: SourceVisualContext,
        style: OverlayStyle,
        excludedRects: [CGRect] = []
    ) -> [OverlayRenderedBlock] {
        var results: [OverlayRenderedBlock] = []
        var cumulativeExcluded = excludedRects

        for translation in translations {
            let block = renderedBlock(
                for: translation,
                source: source,
                style: style,
                excludedRects: cumulativeExcluded
            )
            results.append(block)
            // Add this block (with a small padding) to exclusions so subsequent blocks avoid it.
            cumulativeExcluded.append(block.frame.insetBy(dx: -4, dy: -4))
        }

        return results
    }

    static func renderedBlock(
        for translation: GlanslateCore.Translation,
        source: SourceVisualContext,
        style: OverlayStyle,
        excludedRects: [CGRect] = []
    ) -> OverlayRenderedBlock {
        let original = translation.block.region.rect
        let bounds = source.region.rect
        let alignment: OverlayTextAlignment = translation.targetLanguage.isRightToLeft ? .trailing : .leading
        let direction: OverlayTextDirection = translation.targetLanguage.isRightToLeft ? .rightToLeft : .leftToRight

        let minFontSize: CGFloat = style == .subtitle ? 12 : 14
        let maxFontSize: CGFloat = 28
        // Scale the font to the source line height (macshot's 0.65 ratio), kept within readable bounds.
        var fontSize = max(minFontSize, min(maxFontSize, original.height * 0.65))
        let horizontalPadding: CGFloat = style == .subtitle ? 0 : max(8, original.height * 0.22)
        let verticalPadding: CGFloat = style == .subtitle ? 0 : max(6, original.height * 0.16)
        let weight: NSFont.Weight = style == .subtitle ? .bold : .semibold

        let maxWidth = bounds.width
        let maxHeight = bounds.height
        // Room available growing straight down from the source top edge (no upward drift).
        let maxDownHeight = min(maxHeight, max(original.height, bounds.maxY - original.minY))

        // The box never starts smaller than the source text box.
        var boxWidth = min(maxWidth, max(original.width, original.width + horizontalPadding * 2))
        var boxHeight = min(maxDownHeight, max(original.height, original.height + verticalPadding * 2))

        func textWidth(for width: CGFloat) -> CGFloat {
            max(width - horizontalPadding * 2, 24)
        }
        func neededHeight(at width: CGFloat) -> CGFloat {
            measure(
                text: translation.translatedText,
                width: textWidth(for: width),
                fontSize: fontSize,
                weight: weight
            ).height + verticalPadding * 2
        }

        // `measure` wraps to the given width, so width never overflows on its own. To fit a
        // longer translation: grow height downward, then widen the box (which reduces the line
        // count and height), then shrink the font, and only as a last resort grow past the
        // downward room. Every dimension is monotonic and capped, so this terminates.
        while true {
            let need = neededHeight(at: boxWidth)
            if need <= boxHeight + 1 { break }
            if boxHeight < maxDownHeight {
                boxHeight = min(maxDownHeight, need)
                continue
            }
            if boxWidth < maxWidth {
                boxWidth = min(maxWidth, boxWidth + max(40, boxWidth * 0.25))
                continue
            }
            if fontSize > minFontSize {
                fontSize = max(minFontSize, fontSize - 1)
                continue
            }
            if boxHeight < maxHeight {
                boxHeight = min(maxHeight, need)
                continue
            }
            break
        }

        // Shrink the box back to a snug fit around the final text.
        let finalMeasured = measure(
            text: translation.translatedText,
            width: textWidth(for: boxWidth),
            fontSize: fontSize,
            weight: weight
        )
        boxWidth = min(boxWidth, max(original.width, finalMeasured.width + horizontalPadding * 2))
        boxHeight = min(boxHeight, max(original.height, finalMeasured.height + verticalPadding * 2))

        let baseRect = anchoredRect(
            source: original,
            size: CGSize(width: boxWidth, height: boxHeight),
            within: bounds,
            direction: direction
        )
        let finalFrame = adjustedToAvoidExcludedRects(
            baseRect,
            within: bounds,
            excludedRects: excludedRects
        )

        return OverlayRenderedBlock(
            id: translation.id,
            translation: translation,
            frame: finalFrame,
            fontSize: fontSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            textAlignment: alignment,
            direction: direction
        )
    }

    /// Anchors the overlay box to the source block's leading-top corner and grows it in the
    /// reading direction and downward, clamped to `bounds`. The box never drifts off the
    /// source text the way a centroid-centered box does when the translation length differs.
    private static func anchoredRect(
        source original: CGRect,
        size: CGSize,
        within bounds: CGRect,
        direction: OverlayTextDirection
    ) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)

        var originX: CGFloat
        switch direction {
        case .leftToRight:
            originX = original.minX
            if originX + width > bounds.maxX {
                originX = bounds.maxX - width
            }
            originX = max(originX, bounds.minX)
        case .rightToLeft:
            var maxX = original.maxX
            if maxX - width < bounds.minX {
                maxX = bounds.minX + width
            }
            maxX = min(maxX, bounds.maxX)
            originX = maxX - width
        }

        var originY = original.minY
        if originY + height > bounds.maxY {
            originY = bounds.maxY - height
        }
        originY = max(originY, bounds.minY)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private static func measure(
        text: String,
        width: CGFloat,
        fontSize: CGFloat,
        weight: NSFont.Weight
    ) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return CGSize(width: ceil(bounding.width), height: ceil(bounding.height))
    }

    private static func adjustedToAvoidExcludedRects(
        _ frame: CGRect,
        within bounds: CGRect,
        excludedRects: [CGRect]
    ) -> CGRect {
        guard !excludedRects.isEmpty else { return frame }

        let collisionPadding = CGFloat(10)
        var adjusted = frame

        for excluded in excludedRects {
            let paddedExcluded = excluded.insetBy(dx: -collisionPadding, dy: -collisionPadding)
            guard adjusted.intersects(paddedExcluded) else { continue }

            let shiftedDown = CGRect(
                x: adjusted.origin.x,
                y: min(bounds.maxY - adjusted.height, paddedExcluded.maxY + collisionPadding),
                width: adjusted.width,
                height: adjusted.height
            )
            if bounds.contains(shiftedDown) && !shiftedDown.intersects(paddedExcluded) {
                adjusted = shiftedDown
                continue
            }

            let shiftedLeft = CGRect(
                x: max(bounds.minX, paddedExcluded.minX - adjusted.width - collisionPadding),
                y: adjusted.origin.y,
                width: adjusted.width,
                height: adjusted.height
            )
            if bounds.contains(shiftedLeft) && !shiftedLeft.intersects(paddedExcluded) {
                adjusted = shiftedLeft
                continue
            }

            let shiftedUp = CGRect(
                x: adjusted.origin.x,
                y: max(bounds.minY, paddedExcluded.minY - adjusted.height - collisionPadding),
                width: adjusted.width,
                height: adjusted.height
            )
            if bounds.contains(shiftedUp) && !shiftedUp.intersects(paddedExcluded) {
                adjusted = shiftedUp
            }
        }

        return adjusted
    }
}
