import CoreGraphics
import Foundation
import GlanslateCore
import GlanslateGeometry
import GlanslatePlatform
import ScreenCaptureKit

public struct SCKScreenCapturer: ScreenCapturing {
    private static let targetColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public let excludedBundleIDs: Set<String>
    public let settleDelayNanoseconds: UInt64

    public init(
        excludedBundleIDs: Set<String> = ["com.glanslate.app"],
        settleDelayNanoseconds: UInt64 = 16_000_000
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.settleDelayNanoseconds = settleDelayNanoseconds
    }

    public func snapshot(_ region: DisplayLocalRect, topology: DisplayTopologySnapshot) async throws -> SourceVisualContext {
        guard PermissionProbe.screenRecordingGranted() else {
            throw GlanslateError.permissionDenied(.screenRecording)
        }
        try? await Task.sleep(nanoseconds: settleDelayNanoseconds)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw GlanslateError.capture(reason: "SCShareableContent failed: \(error.localizedDescription)")
        }

        guard let scDisplay = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw GlanslateError.capture(reason: "Display \(region.displayID) not visible to ScreenCaptureKit")
        }

        let excludedApps = content.applications.filter { excludedBundleIDs.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])

        let scale = topology.entry(for: region.displayID)?.backingScale ?? 1.0

        let config = SCStreamConfiguration()
        config.sourceRect = region.rect
        config.width  = max(1, Int((region.rect.width  * scale).rounded()))
        config.height = max(1, Int((region.rect.height * scale).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureDynamicRange = .SDR
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsDisplay = true
        config.scalesToFit = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw GlanslateError.capture(reason: "captureImage failed: \(error.localizedDescription)")
        }

        let mapped = toneMapToSRGB(cgImage)
        return SourceVisualContext(
            image: mapped,
            region: region,
            topology: topology,
            pixelScale: scale
        )
    }

    /// Redraw a non-sRGB capture into sRGB, preserving dimensions.
    private func toneMapToSRGB(_ image: CGImage) -> CGImage {
        let targetSpace = Self.targetColorSpace
        if let cs = image.colorSpace, cs.name == targetSpace.name { return image }

        // Redraw through Core Graphics to avoid the Core Image / Metal path here.
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: targetSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage() ?? image
    }
}
