import Foundation

/// Converts rectangles between AppKit global, Quartz global, and display-local space.
///
/// AppKit and Quartz global space share x; y is mirrored around the primary
/// display's height. Display-local space is relative to one display's top-left
/// corner, which also works for displays at negative global coordinates.
public struct ScreenCoordinateSpace: Sendable {
    public let layout: DisplayLayout

    public init(layout: DisplayLayout) {
        self.layout = layout
    }

    // MARK: Global ↔ global

    public func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: layout.primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: layout.primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: layout.primaryHeight - point.y)
    }

    public func appKitPoint(fromQuartz point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: layout.primaryHeight - point.y)
    }

    // MARK: Global ↔ display-local

    public func localRect(fromAppKit rect: CGRect, on display: DisplayDescriptor) -> CGRect {
        CGRect(
            x: rect.minX - display.frame.minX,
            y: display.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public func appKitRect(fromLocal rect: CGRect, on display: DisplayDescriptor) -> CGRect {
        CGRect(
            x: display.frame.minX + rect.minX,
            y: display.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public func localRect(fromQuartz rect: CGRect, on display: DisplayDescriptor) -> CGRect {
        localRect(fromAppKit: appKitRect(fromQuartz: rect), on: display)
    }

    public func quartzRect(fromLocal rect: CGRect, on display: DisplayDescriptor) -> CGRect {
        quartzRect(fromAppKit: appKitRect(fromLocal: rect, on: display))
    }

    /// The display's frame in Quartz global space.
    public func quartzFrame(of display: DisplayDescriptor) -> CGRect {
        quartzRect(fromAppKit: display.frame)
    }

    // MARK: Regions

    /// The region for an AppKit global rect, or `nil` when it isn't fully on one display.
    public func region(fromAppKit rect: CGRect) -> ScreenRegion? {
        guard let display = layout.displays.first(where: { $0.frame.contains(rect) }) else { return nil }
        return ScreenRegion(displayID: display.id, rect: localRect(fromAppKit: rect, on: display))
    }

    public func appKitRect(for region: ScreenRegion) -> CGRect? {
        guard let display = layout.display(withID: region.displayID) else { return nil }
        return appKitRect(fromLocal: region.rect, on: display)
    }

    public func quartzRect(for region: ScreenRegion) -> CGRect? {
        guard let display = layout.display(withID: region.displayID) else { return nil }
        return quartzRect(fromLocal: region.rect, on: display)
    }
}

/// Maps between a captured image and the display-local region it shows.
///
/// - Capture pixels: origin at the image's top-left, one unit per backing pixel.
/// - Vision normalized: 0...1 relative to the image, origin at the bottom-left.
public struct CaptureGeometry: Equatable, Sendable {
    /// The captured area in display-local points.
    public let region: CGRect
    /// Pixel dimensions of the captured image.
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(region: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.region = region
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// The pixel dimensions for capturing `region` on a display with `scale`.
    public static func pixelSize(for region: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((region.width * scale).rounded())), max(1, Int((region.height * scale).rounded())))
    }

    private var scaleX: CGFloat { region.width > 0 ? CGFloat(pixelWidth) / region.width : 1 }
    private var scaleY: CGFloat { region.height > 0 ? CGFloat(pixelHeight) / region.height : 1 }

    /// A Vision bounding box (normalized, bottom-left origin) in display-local points.
    public func localRect(fromNormalized rect: CGRect) -> CGRect {
        CGRect(
            x: region.minX + rect.minX * region.width,
            y: region.minY + (1 - rect.maxY) * region.height,
            width: rect.width * region.width,
            height: rect.height * region.height
        )
    }

    /// A display-local rect as a Vision-style normalized rect (bottom-left origin).
    public func normalizedRect(fromLocal rect: CGRect) -> CGRect {
        guard region.width > 0, region.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - region.minX) / region.width,
            y: 1 - (rect.maxY - region.minY) / region.height,
            width: rect.width / region.width,
            height: rect.height / region.height
        )
    }

    /// A display-local rect in image pixels (top-left origin), clipped to the image.
    public func pixelRect(fromLocal rect: CGRect) -> CGRect {
        let raw = CGRect(
            x: (rect.minX - region.minX) * scaleX,
            y: (rect.minY - region.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integralOutward()
        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let clipped = raw.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    /// An image pixel rect (top-left origin) in display-local points.
    public func localRect(fromPixel rect: CGRect) -> CGRect {
        CGRect(
            x: region.minX + rect.minX / scaleX,
            y: region.minY + rect.minY / scaleY,
            width: rect.width / scaleX,
            height: rect.height / scaleY
        )
    }
}
