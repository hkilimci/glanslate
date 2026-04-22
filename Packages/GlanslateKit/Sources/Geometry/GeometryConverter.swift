import CoreGraphics
import Foundation
import GlanslateCore

public struct GeometryConverter: Sendable {
    public let snapshot: DisplayTopologySnapshot
    public let primaryTopY: CGFloat

    public init(snapshot: DisplayTopologySnapshot) {
        self.snapshot = snapshot
        self.primaryTopY = snapshot.primaryTopY
    }

    /// Convert an AppKit global point (bottom-left, points) into (displayID, displayLocal point with top-left origin in points).
    public func displayLocal(fromAppKitGlobalPoint p: CGPoint) -> (displayID: CGDirectDisplayID, local: CGPoint)? {
        guard let entry = snapshot.entries.first(where: { $0.appKitFrame.contains(p) }) else { return nil }
        let localX = p.x - entry.appKitFrame.minX
        // AppKit y grows upward; convert to top-left origin within display.
        let localY = entry.appKitFrame.maxY - p.y
        return (entry.displayID, CGPoint(x: localX, y: localY))
    }

    /// Convert an AppKit global rect (bottom-left origin) into DisplayLocalRect.
    /// Returns nil if rect corners span more than one display (cross-screen).
    public func displayLocal(fromAppKitGlobalRect r: CGRect) -> DisplayLocalRect? {
        let corners = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.maxX, y: r.maxY),
        ]
        var ids: Set<CGDirectDisplayID> = []
        for c in corners {
            guard let hit = snapshot.entries.first(where: { $0.appKitFrame.contains(c) }) else {
                return nil
            }
            ids.insert(hit.displayID)
        }
        guard ids.count == 1, let id = ids.first, let entry = snapshot.entry(for: id) else { return nil }
        let x = r.minX - entry.appKitFrame.minX
        let yTop = entry.appKitFrame.maxY - r.maxY
        let local = CGRect(x: x, y: yTop, width: r.width, height: r.height)
        return DisplayLocalRect(displayID: id, rect: local)
    }

    /// Convert display-local rect (top-left origin in points) back to AppKit global rect (bottom-left origin).
    public func appKitGlobal(fromDisplayLocalRect r: DisplayLocalRect) -> CGRect {
        guard let entry = snapshot.entry(for: r.displayID) else { return .zero }
        let x = entry.appKitFrame.minX + r.rect.minX
        let y = entry.appKitFrame.maxY - (r.rect.minY + r.rect.height)
        return CGRect(x: x, y: y, width: r.rect.width, height: r.rect.height)
    }

    /// Vision normalized bbox (0..1, bottom-left) → display-local rect (top-left, points) for the display the source was captured from.
    /// - parameter r: Vision bbox in normalized (0..1) coords relative to captured pixel buffer.
    /// - parameter capturedFrom: The display the pixel buffer was captured from.
    /// - parameter captureRegion: DisplayLocalRect of the capture region within that display (top-left points).
    public func displayLocal(
        visionNormalized r: CGRect,
        capturedFrom displayID: CGDirectDisplayID,
        captureRegion: DisplayLocalRect
    ) -> DisplayLocalRect {
        let region = captureRegion.rect
        let xPoints = region.minX + r.minX * region.width
        // Vision y is bottom-left normalized; top-left points needs flip.
        let yTopNormalized = 1.0 - (r.minY + r.height)
        let yPoints = region.minY + yTopNormalized * region.height
        let wPoints = r.width * region.width
        let hPoints = r.height * region.height
        return DisplayLocalRect(
            displayID: displayID,
            rect: CGRect(x: xPoints, y: yPoints, width: wPoints, height: hPoints)
        )
    }

    /// Convert display-local points rect to pixel rect (multiplies by backingScale of that display).
    public func pixelRect(forDisplayLocal r: DisplayLocalRect) -> CGRect {
        let scale = snapshot.entry(for: r.displayID)?.backingScale ?? 1.0
        return CGRect(
            x: r.rect.minX * scale,
            y: r.rect.minY * scale,
            width: r.rect.width * scale,
            height: r.rect.height * scale
        )
    }
}
