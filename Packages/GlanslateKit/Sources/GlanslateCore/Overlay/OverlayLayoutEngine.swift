import Foundation

/// Measures text set in the overlay font. Implemented with AppKit text
/// measurement on macOS; tests use a deterministic approximation.
public protocol TextMeasuring: Sendable {
    /// The size of `text` wrapped to `width` at `fontSize` points.
    func size(of text: String, fontSize: CGFloat, width: CGFloat) -> CGSize
}

/// Where and how large one translated block is drawn, in display-local points.
public struct OverlayBlockLayout: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let frame: CGRect
    public let fontSize: CGFloat
    public let padding: CGSize
    /// True when even the smallest size couldn't fit without clipping.
    public let isCompressed: Bool

    public init(id: UUID, frame: CGRect, fontSize: CGFloat, padding: CGSize, isCompressed: Bool) {
        self.id = id
        self.frame = frame
        self.fontSize = fontSize
        self.padding = padding
        self.isCompressed = isCompressed
    }
}

public struct OverlayLayoutInput: Equatable, Sendable {
    public let id: UUID
    public let sourceFrame: CGRect
    public let lineHeight: CGFloat
    public let lineCount: Int
    public let text: String

    public init(id: UUID, sourceFrame: CGRect, lineHeight: CGFloat, lineCount: Int, text: String) {
        self.id = id
        self.sourceFrame = sourceFrame
        self.lineHeight = lineHeight
        self.lineCount = lineCount
        self.text = text
    }

    public init(block: TextBlock, translation: String) {
        self.init(id: block.id, sourceFrame: block.frame, lineHeight: block.lineHeight, lineCount: block.lines.count, text: translation)
    }
}

/// Fits translated text into the space of the original.
///
/// Each block starts at the original's position and font size (estimated from
/// the OCR line height). When the translation is longer it first borrows free
/// space — to the right for single-line labels, below for paragraphs — and only
/// then shrinks the font, never below a readable minimum. Free space is measured
/// against the *original* frames of neighboring blocks, so translations never
/// cover one another and the spatial relationship is preserved.
public struct OverlayLayoutEngine: Sendable {
    public var minimumFontSize: CGFloat = 9
    public var maximumFontSize: CGFloat = 44
    /// Ratio of font size to the OCR line-box height.
    public var fontToLineHeight: CGFloat = 0.78
    /// The smallest scale applied before borrowing vertical space.
    public var preferredMinimumScale: CGFloat = 0.78
    public var neighborGap: CGFloat = 2

    public init() {}

    public func baseFontSize(forLineHeight lineHeight: CGFloat, textScale: CGFloat = 1) -> CGFloat {
        min(max(lineHeight * fontToLineHeight * textScale, minimumFontSize), maximumFontSize)
    }

    public func layout(
        _ inputs: [OverlayLayoutInput],
        in bounds: CGRect,
        measurer: any TextMeasuring,
        textScale: CGFloat = 1
    ) -> [OverlayBlockLayout] {
        inputs.map { input in
            layout(input, among: inputs, in: bounds, measurer: measurer, textScale: textScale)
        }
    }

    private func layout(
        _ input: OverlayLayoutInput,
        among all: [OverlayLayoutInput],
        in bounds: CGRect,
        measurer: any TextMeasuring,
        textScale: CGFloat
    ) -> OverlayBlockLayout {
        let base = baseFontSize(forLineHeight: input.lineHeight, textScale: textScale)
        let padding = CGSize(width: max(3, (base * 0.32).rounded()), height: max(1.5, (base * 0.14).rounded()))
        let others = all.filter { $0.id != input.id }.map(\.sourceFrame)

        var frame = input.sourceFrame.insetBy(dx: -padding.width, dy: -padding.height).intersection(bounds)
        if frame.isNull { frame = input.sourceFrame }

        let rightLimit = others
            .filter { $0.verticalOverlapRatio(with: frame) > 0.3 && $0.minX >= input.sourceFrame.maxX - 1 }
            .map { $0.minX - neighborGap }
            .min() ?? bounds.maxX
        let bottomLimit = others
            .filter { $0.horizontalOverlapRatio(with: frame) > 0 && $0.minY >= input.sourceFrame.maxY - 1 }
            .map { $0.minY - neighborGap }
            .min() ?? bounds.maxY

        let isLabel = input.lineCount <= 1
        let widerWidth = max(frame.width, min(rightLimit - frame.minX, frame.width * (isLabel ? 1.8 : 1.12)))
        let widths = widerWidth > frame.width + 1 ? [frame.width, widerWidth] : [frame.width]

        func neededHeight(_ size: CGFloat, _ width: CGFloat) -> CGFloat {
            measurer.size(of: input.text, fontSize: size, width: max(1, width - 2 * padding.width)).height + 2 * padding.height
        }

        // 1. Fit inside the original area, shrinking modestly. A wider frame is
        //    used only when it allows a larger size than the original width.
        let modest = sizes(from: base, to: max(minimumFontSize, base * preferredMinimumScale))
        var best: (size: CGFloat, width: CGFloat)?
        for width in widths {
            if let size = largestFitting(modest, fits: { neededHeight($0, width) <= frame.height + 0.5 }),
               size > (best?.size ?? 0) {
                best = (size, width)
            }
        }
        if let best {
            return OverlayBlockLayout(
                id: input.id,
                frame: CGRect(x: frame.minX, y: frame.minY, width: best.width, height: frame.height),
                fontSize: best.size,
                padding: padding,
                isCompressed: false
            )
        }

        // 2. Borrow space below, down to the next block or the region edge.
        let width = widths.last ?? frame.width
        let maxHeight = max(frame.height, bottomLimit - frame.minY)
        if let size = largestFitting(sizes(from: base, to: minimumFontSize), fits: { neededHeight($0, width) <= maxHeight }) {
            return OverlayBlockLayout(
                id: input.id,
                frame: CGRect(x: frame.minX, y: frame.minY, width: width, height: max(neededHeight(size, width), frame.height)),
                fontSize: size,
                padding: padding,
                isCompressed: false
            )
        }

        // 3. Smallest readable size, using every point available.
        let fallbackHeight = min(neededHeight(minimumFontSize, width), max(maxHeight, bounds.maxY - frame.minY))
        return OverlayBlockLayout(
            id: input.id,
            frame: CGRect(x: frame.minX, y: frame.minY, width: width, height: max(fallbackHeight, frame.height)),
            fontSize: minimumFontSize,
            padding: padding,
            isCompressed: true
        )
    }

    /// The largest size that fits, by binary search over sizes in descending
    /// order. Text never grows taller when its font shrinks, so `fits` is monotonic.
    private func largestFitting(_ sizes: [CGFloat], fits: (CGFloat) -> Bool) -> CGFloat? {
        var low = 0, high = sizes.count - 1
        var answer: CGFloat?
        while low <= high {
            let middle = (low + high) / 2
            if fits(sizes[middle]) {
                answer = sizes[middle]
                high = middle - 1
            } else {
                low = middle + 1
            }
        }
        return answer
    }

    private func sizes(from upper: CGFloat, to lower: CGFloat) -> [CGFloat] {
        guard upper > lower else { return [upper] }
        return Array(stride(from: upper, through: lower, by: -0.5)) + [lower]
    }
}
