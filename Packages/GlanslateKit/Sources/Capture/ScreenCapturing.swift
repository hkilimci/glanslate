import CoreGraphics
import Foundation
import GlanslateCore
import GlanslateGeometry

public struct SourceVisualContext: @unchecked Sendable {
    public let image: CGImage
    public let region: DisplayLocalRect
    public let topology: DisplayTopologySnapshot
    public let pixelScale: CGFloat
    public let capturedAt: Date

    public init(
        image: CGImage,
        region: DisplayLocalRect,
        topology: DisplayTopologySnapshot,
        pixelScale: CGFloat,
        capturedAt: Date = Date()
    ) {
        self.image = image
        self.region = region
        self.topology = topology
        self.pixelScale = pixelScale
        self.capturedAt = capturedAt
    }
}

public protocol ScreenCapturing: Sendable {
    func snapshot(_ region: DisplayLocalRect, topology: DisplayTopologySnapshot) async throws -> SourceVisualContext
}
