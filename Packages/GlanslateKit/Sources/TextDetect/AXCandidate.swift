import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GlanslateCore
import GlanslateGeometry
import GlanslatePlatform

public struct AXDetectionReport: Sendable {
    public let blocks: [TextBlock]
    public let quality: Double
    public let coverageRatio: Double

    public init(blocks: [TextBlock], quality: Double, coverageRatio: Double) {
        self.blocks = blocks
        self.quality = quality
        self.coverageRatio = coverageRatio
    }

    public static let empty = AXDetectionReport(blocks: [], quality: 0.0, coverageRatio: 0.0)
}

public struct AXCandidate: Sendable {
    public init() {}

    public func detect(_ region: DisplayLocalRect, topology: DisplayTopologySnapshot) async -> AXDetectionReport {
        guard PermissionProbe.accessibilityGranted(promptIfNot: false) else { return .empty }

        // Build AppKit-global sample points by flipping top-left display-local → bottom-left AppKit-global.
        let converter = GeometryConverter(snapshot: topology)
        let globalRect = converter.appKitGlobal(fromDisplayLocalRect: region)

        // AX uses screen coords with TOP-LEFT origin across the primary display's top edge.
        // Convert AppKit-global (bottom-left) → AX (top-left) via snapshot.primaryTopY.
        let axRect = axRect(fromAppKitGlobal: globalRect, primaryTopY: topology.primaryTopY)

        let samples = gridSamples(in: axRect, rows: 6, cols: 6)
        var elements: [AXUIElement] = []
        let systemWide = AXUIElementCreateSystemWide()
        for p in samples {
            var ref: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &ref)
            if status == .success, let el = ref {
                elements.append(el)
            }
        }

        // De-dupe by hash of reference; AX provides equality but no Hashable, use pointer identity via CFHash.
        var seen = Set<CFHashCode>()
        let unique = elements.filter { el in
            let h = CFHash(el)
            if seen.contains(h) { return false }
            seen.insert(h)
            return true
        }

        var blocks: [TextBlock] = []
        for el in unique {
            guard let role = stringAttr(el, kAXRoleAttribute as CFString) else { continue }
            guard ["AXStaticText", "AXTextField", "AXTextArea", "AXLink"].contains(role) else { continue }
            guard let value = stringAttr(el, kAXValueAttribute as CFString), !value.isEmpty else { continue }
            guard let elFrameAX = frameAttr(el) else { continue }

            // Clip against AX rect; compute overlap ratio.
            let clipped = elFrameAX.intersection(axRect)
            guard !clipped.isNull else { continue }
            let overlap = (clipped.width * clipped.height) / max(1, elFrameAX.width * elFrameAX.height)
            guard overlap >= 0.4 else { continue }

            // AX (top-left) → AppKit-global (bottom-left) → DisplayLocalRect.
            let appkitGlobal = appKitRect(fromAX: clipped, primaryTopY: topology.primaryTopY)
            guard let dlr = converter.displayLocal(fromAppKitGlobalRect: appkitGlobal) else { continue }

            blocks.append(TextBlock(
                text: value,
                region: dlr,
                detectedLanguage: nil,
                confidence: 0.9,
                source: .accessibility
            ))
        }

        let coverage = coverageRatio(blocks: blocks, over: region.rect)
        let quality = qualityScore(blocks: blocks, coverage: coverage, regionArea: region.rect.width * region.rect.height)
        return AXDetectionReport(blocks: blocks, quality: quality, coverageRatio: coverage)
    }

    // MARK: - Helpers

    private func gridSamples(in rect: CGRect, rows: Int, cols: Int) -> [CGPoint] {
        guard rows > 0, cols > 0, rect.width > 0, rect.height > 0 else { return [] }
        var out: [CGPoint] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x = rect.minX + rect.width * (CGFloat(c) + 0.5) / CGFloat(cols)
                let y = rect.minY + rect.height * (CGFloat(r) + 0.5) / CGFloat(rows)
                out.append(CGPoint(x: x, y: y))
            }
        }
        return out
    }

    private func stringAttr(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func frameAttr(_ el: AXUIElement) -> CGRect? {
        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let posValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func axRect(fromAppKitGlobal r: CGRect, primaryTopY: CGFloat) -> CGRect {
        // AppKit (bottom-left, y grows up) → AX (top-left, y grows down) relative to primary display's top edge.
        let top = primaryTopY - r.maxY
        return CGRect(x: r.minX, y: top, width: r.width, height: r.height)
    }

    private func appKitRect(fromAX r: CGRect, primaryTopY: CGFloat) -> CGRect {
        let bottomY = primaryTopY - (r.minY + r.height)
        return CGRect(x: r.minX, y: bottomY, width: r.width, height: r.height)
    }

    private func coverageRatio(blocks: [TextBlock], over area: CGRect) -> Double {
        let total = blocks.reduce(0.0) { acc, b in
            acc + Double(b.region.rect.width * b.region.rect.height)
        }
        let denom = Double(area.width * area.height)
        guard denom > 0 else { return 0 }
        return min(1.0, total / denom)
    }

    private func qualityScore(blocks: [TextBlock], coverage: Double, regionArea: CGFloat) -> Double {
        guard !blocks.isEmpty else { return 0 }
        let totalChars = blocks.reduce(0) { $0 + $1.text.count }
        // Rough heuristic: expected characters per 10000 px² ≈ 20 (body copy).
        let expected = max(1.0, Double(regionArea) / 10_000.0 * 20.0)
        let charFactor = min(1.0, Double(totalChars) / expected)
        return min(1.0, coverage) * charFactor
    }
}
