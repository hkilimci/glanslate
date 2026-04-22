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
        translations.map { renderedBlock(for: $0, source: source, style: style, excludedRects: excludedRects) }
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

        let minFontSize = style == .subtitle ? CGFloat(12) : CGFloat(14)
        var fontSize = max(minFontSize, min(24, max(original.height * 0.72, minFontSize)))
        let horizontalPadding = style == .subtitle ? CGFloat(0) : max(8, original.height * 0.22)
        let verticalPadding = style == .subtitle ? CGFloat(0) : max(6, original.height * 0.16)
        let maximumSize = CGSize(width: bounds.width, height: bounds.height)
        let weight = style == .subtitle ? NSFont.Weight.bold : NSFont.Weight.semibold

        var targetSize = CGSize(
            width: max(original.width, min(maximumSize.width, original.width + (horizontalPadding * 2))),
            height: max(original.height, min(maximumSize.height, original.height + (verticalPadding * 2)))
        )

        func fittedRect() -> CGRect {
            centeredClampedRect(
                around: CGPoint(x: original.midX, y: original.midY),
                size: targetSize,
                within: bounds
            )
        }

        for _ in 0..<8 {
            let rect = fittedRect()
            let measured = measure(
                text: translation.translatedText,
                width: max(rect.width - (horizontalPadding * 2), 24),
                fontSize: fontSize,
                weight: weight
            )
            let neededWidth = measured.width + (horizontalPadding * 2)
            let neededHeight = measured.height + (verticalPadding * 2)

            let fits = neededWidth <= rect.width + 1 && neededHeight <= rect.height + 1
            if fits { break }

            let canGrowWidth = rect.width < maximumSize.width
            let canGrowHeight = rect.height < maximumSize.height

            if canGrowWidth {
                targetSize.width = min(maximumSize.width, max(rect.width * 1.18, neededWidth))
            }
            if canGrowHeight {
                targetSize.height = min(maximumSize.height, max(rect.height * 1.14, neededHeight))
            }

            if !canGrowWidth && !canGrowHeight {
                if fontSize > minFontSize {
                    fontSize -= 1
                } else {
                    break
                }
            }
        }

        while fontSize > minFontSize {
            let rect = fittedRect()
            let measured = measure(
                text: translation.translatedText,
                width: max(rect.width - (horizontalPadding * 2), 24),
                fontSize: fontSize,
                weight: weight
            )
            let fits = measured.height + (verticalPadding * 2) <= rect.height + 1
                && measured.width + (horizontalPadding * 2) <= rect.width + 1
            if fits { break }
            fontSize -= 1
        }

        let finalFrame = adjustedToAvoidExcludedRects(
            fittedRect(),
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

    private static func centeredClampedRect(
        around center: CGPoint,
        size: CGSize,
        within bounds: CGRect
    ) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        var origin = CGPoint(
            x: center.x - (width / 2),
            y: center.y - (height / 2)
        )
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
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
