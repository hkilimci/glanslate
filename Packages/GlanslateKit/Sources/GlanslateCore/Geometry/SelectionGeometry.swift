import Foundation

/// What the user picked in the selection interface.
public enum SelectionTarget: Equatable, Sendable {
    /// A dragged rectangle.
    case area(ScreenRegion)
    /// A window, clipped to the display it was picked on.
    case window(id: UInt32, region: ScreenRegion)

    public var region: ScreenRegion {
        switch self {
        case .area(let region): return region
        case .window(_, let region): return region
        }
    }

    public var windowID: UInt32? {
        if case .window(let id, _) = self { return id }
        return nil
    }
}

/// Why a selection can't be used.
public enum SelectionIssue: Error, Equatable, Sendable {
    case tooSmall
    case outsideDisplay

    public var message: String {
        switch self {
        case .tooSmall: return "Drag a larger area to translate."
        case .outsideDisplay: return "Selections stay on one display."
        }
    }
}

/// Pure geometry behind the selection interface, all in display-local points.
public enum SelectionGeometry {
    /// Selections smaller than this on either side are rejected.
    public static let minimumSide: CGFloat = 12

    /// Clamps a point to a display's bounds so a drag can never leave its display.
    public static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// The normalized rectangle between the drag anchor and the current pointer, kept on the display.
    public static func dragRect(from anchor: CGPoint, to current: CGPoint, within bounds: CGRect) -> CGRect {
        let a = clamp(anchor, to: bounds)
        let b = clamp(current, to: bounds)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Whether the pointer has strayed outside the display the drag started on.
    public static func isOutside(_ point: CGPoint, bounds: CGRect) -> Bool {
        point.x < bounds.minX || point.x > bounds.maxX || point.y < bounds.minY || point.y > bounds.maxY
    }

    /// Validates a finished selection; returns the integral rect to capture.
    public static func validate(_ rect: CGRect, within bounds: CGRect) -> Result<CGRect, SelectionIssue> {
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return .failure(.outsideDisplay) }
        let snapped = clipped.integralOutward().intersection(bounds)
        guard snapped.width >= minimumSide, snapped.height >= minimumSide else { return .failure(.tooSmall) }
        return .success(snapped)
    }

    /// A window's frame (display-local) clipped to its display, or `nil` when nothing usable remains.
    public static func windowRegion(localFrame: CGRect, displayBounds: CGRect) -> CGRect? {
        if case .success(let rect) = validate(localFrame, within: displayBounds) { return rect }
        return nil
    }
}
