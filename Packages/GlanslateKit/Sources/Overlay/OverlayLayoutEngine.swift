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
    private struct LayoutMetrics {
        let outerPadding: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let minFontSize: CGFloat
        let maxFontSize: CGFloat
        let weight: NSFont.Weight
    }

    static func renderedBlocks(
        translations: [GlanslateCore.Translation],
        source: SourceVisualContext,
        style: OverlayStyle,
        excludedRects: [CGRect] = []
    ) -> [OverlayRenderedBlock] {
        translations.map { translation in
            renderedBlock(
                for: translation,
                source: source,
                style: style,
                excludedRects: excludedRects
            )
        }
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

        let metrics = layoutMetrics(for: style)
        let baseFrame = clamp(
            original.insetBy(dx: -metrics.outerPadding, dy: -metrics.outerPadding),
            within: bounds
        )
        let lineCount = max(translation.translatedText.components(separatedBy: "\n").count, 1)
        let lineHeight = original.height / CGFloat(lineCount)
        let initialFontSize = max(
            metrics.minFontSize,
            min(metrics.maxFontSize, lineHeight * 0.65)
        )
        let fitted = fittedFrame(
            text: translation.translatedText,
            sourceFrame: baseFrame,
            bounds: bounds,
            direction: direction,
            initialFontSize: initialFontSize,
            metrics: metrics
        )

        return OverlayRenderedBlock(
            id: translation.id,
            translation: translation,
            frame: fitted.frame,
            fontSize: fitted.fontSize,
            horizontalPadding: metrics.horizontalPadding,
            verticalPadding: metrics.verticalPadding,
            textAlignment: alignment,
            direction: direction
        )
    }

    private static func layoutMetrics(for style: OverlayStyle) -> LayoutMetrics {
        switch style {
        case .cleanPatch, .blurPatch:
            return LayoutMetrics(
                outerPadding: 1,
                horizontalPadding: 3,
                verticalPadding: 2,
                minFontSize: 8,
                maxFontSize: 28,
                weight: .semibold
            )
        case .subtitle:
            return LayoutMetrics(
                outerPadding: 0,
                horizontalPadding: 0,
                verticalPadding: 0,
                minFontSize: 12,
                maxFontSize: 32,
                weight: .bold
            )
        }
    }

    private static func fittedFrame(
        text: String,
        sourceFrame: CGRect,
        bounds: CGRect,
        direction: OverlayTextDirection,
        initialFontSize: CGFloat,
        metrics: LayoutMetrics
    ) -> (frame: CGRect, fontSize: CGFloat) {
        let baseWidth = min(max(sourceFrame.width, 1), bounds.width)
        let baseHeight = min(max(sourceFrame.height, 1), bounds.height)
        let maxWidth = max(baseWidth, bounds.width)
        let maxHeight = max(baseHeight, bounds.height)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return (sourceFrame, initialFontSize)
        }

        if let fitted = bestFittedFrame(
            text: text,
            sourceFrame: sourceFrame,
            bounds: bounds,
            direction: direction,
            initialFontSize: initialFontSize,
            minFontSize: initialFontSize,
            maxAllowedHeight: baseHeight,
            metrics: metrics
        ) {
            return fitted
        }

        if let fitted = bestFittedFrame(
            text: text,
            sourceFrame: sourceFrame,
            bounds: bounds,
            direction: direction,
            initialFontSize: initialFontSize - 1,
            minFontSize: metrics.minFontSize,
            maxAllowedHeight: baseHeight,
            metrics: metrics
        ) {
            return fitted
        }

        if let fitted = bestFittedFrame(
            text: text,
            sourceFrame: sourceFrame,
            bounds: bounds,
            direction: direction,
            initialFontSize: initialFontSize,
            minFontSize: metrics.minFontSize,
            maxAllowedHeight: maxHeight,
            metrics: metrics
        ) {
            return fitted
        }

        let fallbackFrame = anchoredRect(
            source: sourceFrame,
            size: CGSize(width: maxWidth, height: maxHeight),
            within: bounds,
            direction: direction
        )
        return (fallbackFrame, metrics.minFontSize)
    }

    private static func bestFittedFrame(
        text: String,
        sourceFrame: CGRect,
        bounds: CGRect,
        direction: OverlayTextDirection,
        initialFontSize: CGFloat,
        minFontSize: CGFloat,
        maxAllowedHeight: CGFloat,
        metrics: LayoutMetrics
    ) -> (frame: CGRect, fontSize: CGFloat)? {
        guard initialFontSize >= minFontSize else { return nil }

        var fontSize = initialFontSize
        var testedMinimum = false
        while fontSize >= minFontSize {
            testedMinimum = abs(fontSize - minFontSize) < 0.001
            if let frame = smallestFittingFrame(
                text: text,
                sourceFrame: sourceFrame,
                bounds: bounds,
                direction: direction,
                fontSize: fontSize,
                maxAllowedHeight: maxAllowedHeight,
                metrics: metrics
            ) {
                return (frame, fontSize)
            }
            fontSize -= 1
        }
        if !testedMinimum,
           let frame = smallestFittingFrame(
               text: text,
               sourceFrame: sourceFrame,
               bounds: bounds,
               direction: direction,
               fontSize: minFontSize,
               maxAllowedHeight: maxAllowedHeight,
               metrics: metrics
           ) {
            return (frame, minFontSize)
        }
        return nil
    }

    private static func smallestFittingFrame(
        text: String,
        sourceFrame: CGRect,
        bounds: CGRect,
        direction: OverlayTextDirection,
        fontSize: CGFloat,
        maxAllowedHeight: CGFloat,
        metrics: LayoutMetrics
    ) -> CGRect? {
        let baseWidth = min(max(sourceFrame.width, 1), bounds.width)
        let baseHeight = min(max(sourceFrame.height, 1), maxAllowedHeight)
        let maxWidth = max(baseWidth, bounds.width)
        let maxHeight = max(baseHeight, min(maxAllowedHeight, bounds.height))

        guard fits(
            text: text,
            width: maxWidth,
            height: maxHeight,
            fontSize: fontSize,
            metrics: metrics
        ) else {
            return nil
        }

        if fits(
            text: text,
            width: baseWidth,
            height: baseHeight,
            fontSize: fontSize,
            metrics: metrics
        ) {
            return sourceFrame
        }

        var low = baseWidth
        var high = maxWidth
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if fits(
                text: text,
                width: mid,
                height: maxHeight,
                fontSize: fontSize,
                metrics: metrics
            ) {
                high = mid
            } else {
                low = mid
            }
        }

        let width = ceil(high)
        let textWidth = max(width - metrics.horizontalPadding * 2, 1)
        let measured = measure(
            text: text,
            width: textWidth,
            fontSize: fontSize,
            weight: metrics.weight
        )
        let height = ceil(max(baseHeight, measured.height + metrics.verticalPadding * 2))
        return anchoredRect(
            source: sourceFrame,
            size: CGSize(width: width, height: min(maxHeight, height)),
            within: bounds,
            direction: direction
        )
    }

    private static func fits(
        text: String,
        width: CGFloat,
        height: CGFloat,
        fontSize: CGFloat,
        metrics: LayoutMetrics
    ) -> Bool {
        let textWidth = max(width - metrics.horizontalPadding * 2, 1)
        let textHeight = max(height - metrics.verticalPadding * 2, 1)
        let measured = measure(
            text: text,
            width: textWidth,
            fontSize: fontSize,
            weight: metrics.weight
        )
        return measured.width <= textWidth + 1 && measured.height <= textHeight + 1
    }

    private static func measure(
        text: String,
        width: CGFloat,
        fontSize: CGFloat,
        weight: NSFont.Weight
    ) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: OverlayFont.nsFont(ofSize: fontSize, fallbackWeight: weight),
                .paragraphStyle: paragraph,
            ]
        )
        return CGSize(width: ceil(bounding.width), height: ceil(bounding.height))
    }

    private static func anchoredRect(
        source: CGRect,
        size: CGSize,
        within bounds: CGRect,
        direction: OverlayTextDirection
    ) -> CGRect {
        let width = min(max(size.width, 1), bounds.width)
        let height = min(max(size.height, 1), bounds.height)

        let originX: CGFloat
        switch direction {
        case .leftToRight:
            originX = min(max(source.minX, bounds.minX), bounds.maxX - width)
        case .rightToLeft:
            originX = min(max(source.maxX - width, bounds.minX), bounds.maxX - width)
        }

        let originY = min(max(source.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private static func clamp(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            return CGRect(origin: bounds.origin, size: .zero)
        }

        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)

        var originX = rect.minX
        if originX + width > bounds.maxX {
            originX = bounds.maxX - width
        }
        originX = max(bounds.minX, originX)

        var originY = rect.minY
        if originY + height > bounds.maxY {
            originY = bounds.maxY - height
        }
        originY = max(bounds.minY, originY)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}
