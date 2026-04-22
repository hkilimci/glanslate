import CoreGraphics
import Foundation
import GlanslateCore
import GlanslateGeometry
import GlanslateCapture

public protocol TextDetecting: Sendable {
    func detect(_ source: SourceVisualContext) async throws -> [TextBlock]
}

public struct TextDetectionPipeline: TextDetecting, Sendable {
    public let ax: AXCandidate
    public let vision: VisionCandidate

    public init(ax: AXCandidate = AXCandidate(), vision: VisionCandidate = VisionCandidate()) {
        self.ax = ax
        self.vision = vision
    }

    public func detect(_ source: SourceVisualContext) async throws -> [TextBlock] {
        async let axAsync = ax.detect(source.region, topology: source.topology)
        async let visionAsync = try vision.detect(source)
        let axReport = await axAsync
        let visionBlocks = try await visionAsync

        if axReport.blocks.isEmpty && visionBlocks.isEmpty {
            throw GlanslateError.noTextFound
        }
        if axReport.quality >= 0.7 && axReport.coverageRatio >= 0.8 {
            return axReport.blocks
        }
        if axReport.blocks.isEmpty { return visionBlocks }
        if visionBlocks.isEmpty { return axReport.blocks }
        return merge(ax: axReport.blocks, vision: visionBlocks)
    }

    func merge(ax: [TextBlock], vision: [TextBlock]) -> [TextBlock] {
        var merged: [TextBlock] = []
        var consumedAX: Set<UUID> = []

        for vb in vision {
            if let match = bestMatch(for: vb, in: ax, ioUThreshold: 0.6) {
                merged.append(TextBlock(
                    id: UUID(),
                    text: match.text,
                    region: vb.region, // pixel-accurate bounds from Vision
                    detectedLanguage: vb.detectedLanguage ?? match.detectedLanguage,
                    confidence: max(vb.confidence, match.confidence),
                    source: .arbitrated
                ))
                consumedAX.insert(match.id)
            } else {
                merged.append(vb)
            }
        }
        // AX-only blocks with at least partial overlap to any Vision block for sanity.
        for ab in ax where !consumedAX.contains(ab.id) {
            let hasVisionSupport = vision.contains { ab.region.rect.intersects($0.region.rect) }
            if hasVisionSupport {
                merged.append(ab)
            }
        }
        return merged
    }

    private func bestMatch(for vb: TextBlock, in ax: [TextBlock], ioUThreshold: Double) -> TextBlock? {
        var best: TextBlock?
        var bestIoU: Double = 0
        for ab in ax where ab.region.displayID == vb.region.displayID {
            let inter = ab.region.rect.intersection(vb.region.rect)
            if inter.isNull { continue }
            let interArea = Double(inter.width * inter.height)
            let unionArea = Double(ab.region.rect.width * ab.region.rect.height + vb.region.rect.width * vb.region.rect.height) - interArea
            guard unionArea > 0 else { continue }
            let iou = interArea / unionArea
            if iou >= ioUThreshold && iou > bestIoU {
                bestIoU = iou
                best = ab
            }
        }
        return best
    }
}
