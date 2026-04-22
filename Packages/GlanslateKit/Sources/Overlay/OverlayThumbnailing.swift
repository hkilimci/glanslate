import AppKit
import CoreGraphics
import Foundation
import GlanslateCapture
import GlanslateCore

enum OverlayThumbnailRenderer {
    static func pinnedPayload(
        source: SourceVisualContext,
        translations: [GlanslateCore.Translation]
    ) -> (payload: OverlayPinnedPayload, retainedSource: SourceVisualContext?) {
        guard
            let reducedImage = downsampledImage(
                source.image,
                maxPixelDimension: 512
            )
        else {
            return (
                OverlayPinnedPayload(translations: translations, thumbnailPNG: nil),
                nil
            )
        }

        let bitmap = NSBitmapImageRep(cgImage: reducedImage)
        let pngData = bitmap.representation(using: .png, properties: [:])
        let updatedScale = max(
            1,
            CGFloat(reducedImage.width) / max(source.region.rect.width, 1)
        )
        let retainedSource = SourceVisualContext(
            image: reducedImage,
            region: source.region,
            topology: source.topology,
            pixelScale: updatedScale,
            capturedAt: source.capturedAt
        )

        return (
            OverlayPinnedPayload(
                translations: translations,
                thumbnailPNG: pngData
            ),
            retainedSource
        )
    }

    private static func downsampledImage(
        _ image: CGImage,
        maxPixelDimension: CGFloat
    ) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longestEdge = max(width, height)
        let scale = min(1, maxPixelDimension / max(longestEdge, 1))
        let targetWidth = max(1, Int((width * scale).rounded(.toNearestOrAwayFromZero)))
        let targetHeight = max(1, Int((height * scale).rounded(.toNearestOrAwayFromZero)))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }
}
