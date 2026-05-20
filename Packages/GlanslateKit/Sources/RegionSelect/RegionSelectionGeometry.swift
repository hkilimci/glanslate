import CoreGraphics
import Foundation
import GlanslateCore
import GlanslateGeometry

public struct RegionSelectionEvaluation: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case selected(DisplayLocalRect)
        case crossScreenRejected
        case tooSmall
    }

    public let activeDisplayID: CGDirectDisplayID?
    public let normalizedGlobalRect: CGRect
    public let outcome: Outcome

    public init(
        activeDisplayID: CGDirectDisplayID?,
        normalizedGlobalRect: CGRect,
        outcome: Outcome
    ) {
        self.activeDisplayID = activeDisplayID
        self.normalizedGlobalRect = normalizedGlobalRect
        self.outcome = outcome
    }
}

public struct RegionSelectionGeometry: Sendable {
    public let topology: DisplayTopologySnapshot
    private let converter: GeometryConverter

    public init(topology: DisplayTopologySnapshot) {
        self.topology = topology
        self.converter = GeometryConverter(snapshot: topology)
    }

    public func normalizedGlobalRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public func activeDisplayID(for globalPoint: CGPoint) -> CGDirectDisplayID? {
        topology.entries.first(where: { $0.appKitFrame.contains(globalPoint) })?.displayID
    }

    public func evaluate(
        from start: CGPoint,
        to end: CGPoint,
        minimumDimension: CGFloat = 4
    ) -> RegionSelectionEvaluation {
        let rect = normalizedGlobalRect(from: start, to: end)
        let activeDisplayID = activeDisplayID(for: start)

        guard rect.width >= minimumDimension, rect.height >= minimumDimension else {
            return RegionSelectionEvaluation(
                activeDisplayID: activeDisplayID,
                normalizedGlobalRect: rect,
                outcome: .tooSmall
            )
        }

        if let localRect = converter.displayLocal(fromAppKitGlobalRect: rect) {
            return RegionSelectionEvaluation(
                activeDisplayID: activeDisplayID,
                normalizedGlobalRect: rect,
                outcome: .selected(localRect)
            )
        }

        return RegionSelectionEvaluation(
            activeDisplayID: activeDisplayID,
            normalizedGlobalRect: rect,
            outcome: .crossScreenRejected
        )
    }

    /// Evaluates a whole-window (or otherwise pre-formed) AppKit-global rect as a selection.
    /// The rect is clamped to the display under its center so a partially off-screen window
    /// still resolves cleanly instead of being rejected as cross-screen.
    public func evaluate(
        globalRect rect: CGRect,
        minimumDimension: CGFloat = 4
    ) -> RegionSelectionEvaluation {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let activeDisplayID = activeDisplayID(for: center)

        let clamped: CGRect
        if let id = activeDisplayID, let entry = topology.entry(for: id) {
            clamped = rect.intersection(entry.appKitFrame).integral
        } else {
            clamped = rect.integral
        }

        guard !clamped.isNull, clamped.width >= minimumDimension, clamped.height >= minimumDimension else {
            return RegionSelectionEvaluation(
                activeDisplayID: activeDisplayID,
                normalizedGlobalRect: clamped.isNull ? rect : clamped,
                outcome: .tooSmall
            )
        }

        let localRect = converter.displayLocal(fromAppKitGlobalRect: clamped)
        if let localRect = localRect {
            return RegionSelectionEvaluation(
                activeDisplayID: activeDisplayID,
                normalizedGlobalRect: clamped,
                outcome: .selected(localRect)
            )
        }

        return RegionSelectionEvaluation(
            activeDisplayID: activeDisplayID,
            normalizedGlobalRect: clamped,
            outcome: .crossScreenRejected
        )
    }

    public func localRect(
        for globalRect: CGRect,
        on displayID: CGDirectDisplayID
    ) -> CGRect? {
        guard let entry = topology.entry(for: displayID) else { return nil }
        let x = globalRect.minX - entry.appKitFrame.minX
        let y = entry.appKitFrame.maxY - globalRect.maxY
        let local = CGRect(x: x, y: y, width: globalRect.width, height: globalRect.height)
        return local.intersection(CGRect(origin: .zero, size: entry.appKitFrame.size))
    }
}
