import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import GlanslateCore
import GlanslateGeometry
import GlanslatePlatform
import ScreenCaptureKit

public struct SCKScreenCapturer: ScreenCapturing {
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
        // Let the HUD window leave the window list.
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

    /// Tone-map a possibly wide-gamut / HDR CGImage to sRGB, preserving dimensions.
    private func toneMapToSRGB(_ image: CGImage) -> CGImage {
        let targetSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        if let cs = image.colorSpace, cs.name == targetSpace.name { return image }
        let ci = CIImage(cgImage: image)
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        if let out = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: targetSpace) {
            return out
        }
        return image
    }
}
