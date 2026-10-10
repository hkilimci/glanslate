import AppKit
import CoreImage
import GlanslateCapture
import GlanslateCore

/// What sits beneath one translated block: a heavily blurred copy of the
/// original pixels and their average color, used to keep text readable and
/// to hide the source text in the Blur Patch style.
struct BlockBackdrop: @unchecked Sendable {
    let blurred: CGImage?
    let averageColor: RGBAColor

    /// Light backgrounds get dark text and vice versa.
    var isLight: Bool { averageColor.luminance > 0.42 }
}

enum BackdropRenderer {
    /// `CIContext` is thread-safe; one shared context avoids repeated setup.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Renders backdrops for display-local block frames, off the main thread.
    static func render(capture: CapturedImage, frames: [UUID: CGRect]) async -> [UUID: BlockBackdrop] {
        await Task.detached(priority: .userInitiated) {
            var result: [UUID: BlockBackdrop] = [:]
            for (id, frame) in frames {
                if Task.isCancelled { break }
                guard let crop = capture.crop(to: frame) else { continue }
                result[id] = makeBackdrop(from: crop, scale: capture.scale, lineHeight: frame.height)
            }
            return result
        }.value
    }

    static func makeBackdrop(from image: CGImage, scale: CGFloat, lineHeight: CGFloat) -> BlockBackdrop {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        // Strong enough to make glyphs unreadable at any size, scaled for Retina.
        let sigma = max(8, min(lineHeight, 28) * 0.6) * scale
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let blurredImage = context.createCGImage(blurred, from: extent)
        return BlockBackdrop(blurred: blurredImage, averageColor: averageColor(of: input) ?? RGBAColor(red: 0.5, green: 0.5, blue: 0.5))
    }

    private static func averageColor(of image: CIImage) -> RGBAColor? {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: space
        )
        return RGBAColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

/// Measures text in the system font, matching how SwiftUI lays out overlay text.
struct AppKitTextMeasurer: TextMeasuring {
    func size(of text: String, fontSize: CGFloat, width: CGFloat) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraph,
        ])
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height) + 1)
    }
}
