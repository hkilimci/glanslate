import CoreGraphics
import Foundation
import GlanslateCore
import ImageIO
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One still image of a selected region. Captures stay in memory and on this Mac.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let target: SelectionTarget
    public let geometry: CaptureGeometry
    public let scale: CGFloat
    public let capturedAt: Date

    public init(cgImage: CGImage, target: SelectionTarget, geometry: CaptureGeometry, scale: CGFloat, capturedAt: Date = Date()) {
        self.cgImage = cgImage
        self.target = target
        self.geometry = geometry
        self.scale = scale
        self.capturedAt = capturedAt
    }

    public var region: ScreenRegion { target.region }

    /// The pixels under a display-local rect.
    public func crop(to localRect: CGRect) -> CGImage? {
        let pixels = geometry.pixelRect(fromLocal: localRect)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return cgImage.cropping(to: pixels)
    }

    /// A downscaled JPEG for Saved Translations.
    public func thumbnailData(maxPixelSize: Int = 720) -> Data? {
        let longest = max(cgImage.width, cgImage.height)
        let factor = min(1, CGFloat(maxPixelSize) / CGFloat(max(longest, 1)))
        let width = max(1, Int(CGFloat(cgImage.width) * factor))
        let height = max(1, Int(CGFloat(cgImage.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

public protocol ScreenCapturing: Sendable {
    func capture(_ target: SelectionTarget) async throws -> CapturedImage
}

/// Captures a region with ScreenCaptureKit. Every Glanslate window — the
/// selection interface and any existing overlay — is excluded from the image.
public struct ScreenCaptureService: ScreenCapturing {
    private static let log = Logger(subsystem: "app.glanslate", category: "capture")

    public init() {}

    public func capture(_ target: SelectionTarget) async throws -> CapturedImage {
        guard CGPreflightScreenCaptureAccess() else { throw GlanslateError.screenRecordingNotAuthorized }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Self.log.error("Shareable content unavailable: \(String(describing: type(of: error)), privacy: .public)")
            throw Self.map(error)
        }
        try Task.checkCancellation()

        let region = target.region
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw GlanslateError.displayChanged
        }

        let filter: SCContentFilter
        if let windowID = target.windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
            // Only the chosen window, so overlapping windows don't leak into the capture.
            filter = SCContentFilter(display: display, including: [window])
        } else {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }

        let scale = CGFloat(max(filter.pointPixelScale, 1))
        let pixelSize = CaptureGeometry.pixelSize(for: region.rect, scale: scale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.rect
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.ignoreShadowsDisplay = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            Self.log.error("Capture failed: \(String(describing: type(of: error)), privacy: .public)")
            throw Self.map(error)
        }
        try Task.checkCancellation()

        return CapturedImage(
            cgImage: image,
            target: target,
            geometry: CaptureGeometry(region: region.rect, pixelWidth: image.width, pixelHeight: image.height),
            scale: scale
        )
    }

    static func map(_ error: any Error) -> GlanslateError {
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .screenRecordingNotAuthorized
        }
        return .captureFailed(detail: "\(nsError.domain) \(nsError.code)")
    }
}
