import Foundation

/// Matches `CGDirectDisplayID`.
public typealias DisplayID = UInt32

/// One connected display, described in AppKit's global coordinate space.
///
/// Glanslate works with four coordinate spaces:
/// - **AppKit global** — points, origin at the bottom-left of the primary display, y grows up (`NSScreen.frame`).
/// - **Quartz global** — points, origin at the top-left of the primary display, y grows down
///   (Core Graphics window lists, Accessibility, ScreenCaptureKit window frames).
/// - **Display-local** — points, origin at the top-left of one display, y grows down
///   (selection, capture source rects, recognized text, overlay layout).
/// - **Capture pixels / Vision normalized** — see ``CaptureGeometry``.
public struct DisplayDescriptor: Equatable, Sendable, Identifiable {
    public let id: DisplayID
    /// Full frame in AppKit global points.
    public let frame: CGRect
    /// Frame excluding the menu bar and Dock, in AppKit global points.
    public let visibleFrame: CGRect
    /// Backing scale factor (2 on Retina displays).
    public let scale: CGFloat
    public let name: String

    public init(id: DisplayID, frame: CGRect, visibleFrame: CGRect? = nil, scale: CGFloat, name: String = "") {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.scale = scale
        self.name = name
    }

    /// The display's own bounds in display-local coordinates.
    public var localBounds: CGRect { CGRect(origin: .zero, size: frame.size) }
}

/// A snapshot of the display arrangement at one moment.
public struct DisplayLayout: Equatable, Sendable {
    public let displays: [DisplayDescriptor]

    public init(displays: [DisplayDescriptor]) {
        self.displays = displays
    }

    /// The display that holds the menu bar; its AppKit frame starts at the global origin.
    public var primary: DisplayDescriptor? {
        displays.first { $0.frame.origin == .zero } ?? displays.first
    }

    /// Height of the primary display, the pivot between AppKit and Quartz global space.
    public var primaryHeight: CGFloat { primary?.frame.height ?? 0 }

    public func display(withID id: DisplayID) -> DisplayDescriptor? {
        displays.first { $0.id == id }
    }

    /// The display containing an AppKit global point. Edges belong to the display on their min side.
    public func display(containingAppKitPoint point: CGPoint) -> DisplayDescriptor? {
        displays.first { $0.frame.contains(point) }
    }

    /// Whether another layout has the same displays at the same places and scales.
    public func hasSameArrangement(as other: DisplayLayout) -> Bool {
        func key(_ list: [DisplayDescriptor]) -> [DisplayDescriptor] { list.sorted { $0.id < $1.id } }
        let lhs = key(displays), rhs = key(other.displays)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.frame == $1.frame && $0.scale == $1.scale }
    }
}

/// A rectangle on exactly one display, in display-local points (top-left origin).
public struct ScreenRegion: Equatable, Sendable, Codable {
    public let displayID: DisplayID
    public let rect: CGRect

    public init(displayID: DisplayID, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }
}

public extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { isNull ? 0 : width * height }

    /// The fraction of the smaller rectangle's height that overlaps vertically (0...1).
    func verticalOverlapRatio(with other: CGRect) -> CGFloat {
        let overlap = min(maxY, other.maxY) - max(minY, other.minY)
        let reference = min(height, other.height)
        guard overlap > 0, reference > 0 else { return 0 }
        return min(1, overlap / reference)
    }

    /// The fraction of the narrower rectangle's width that overlaps horizontally (0...1).
    func horizontalOverlapRatio(with other: CGRect) -> CGFloat {
        let overlap = min(maxX, other.maxX) - max(minX, other.minX)
        let reference = min(width, other.width)
        guard overlap > 0, reference > 0 else { return 0 }
        return min(1, overlap / reference)
    }

    /// Rounds the rect outward to whole values so it covers every touched pixel.
    func integralOutward() -> CGRect {
        let x0 = minX.rounded(.down), y0 = minY.rounded(.down)
        let x1 = maxX.rounded(.up), y1 = maxY.rounded(.up)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
