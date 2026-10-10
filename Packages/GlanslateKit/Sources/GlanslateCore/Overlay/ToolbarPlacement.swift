import Foundation

/// Positions the floating toolbar next to the translated region without covering it.
///
/// Works in AppKit global space (y grows up). The toolbar prefers the space
/// below the region, then above it, and only overlaps the region's bottom edge
/// when the region fills the display.
public enum ToolbarPlacement {
    public enum Edge: Equatable, Sendable {
        case below, above, inside
    }

    public struct Placement: Equatable, Sendable {
        public let frame: CGRect
        public let edge: Edge
    }

    public static func place(
        toolbar size: CGSize,
        near region: CGRect,
        within visibleFrame: CGRect,
        gap: CGFloat = 10,
        margin: CGFloat = 8
    ) -> Placement {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin - size.width
        let x = maxX >= minX ? min(max(region.midX - size.width / 2, minX), maxX) : visibleFrame.midX - size.width / 2

        let belowY = region.minY - gap - size.height
        if belowY >= visibleFrame.minY + margin {
            return Placement(frame: CGRect(x: x, y: belowY, width: size.width, height: size.height).integral, edge: .below)
        }
        let aboveY = region.maxY + gap
        if aboveY + size.height <= visibleFrame.maxY - margin {
            return Placement(frame: CGRect(x: x, y: aboveY, width: size.width, height: size.height).integral, edge: .above)
        }
        let insideY = max(region.minY, visibleFrame.minY) + gap
        return Placement(frame: CGRect(x: x, y: insideY, width: size.width, height: size.height).integral, edge: .inside)
    }
}
