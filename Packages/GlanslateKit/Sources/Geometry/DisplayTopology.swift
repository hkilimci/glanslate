import AppKit
import CoreGraphics
import Foundation
import GlanslateCore

public struct DisplayTopologyEntry: Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    /// AppKit global frame (bottom-left origin, points).
    public let appKitFrame: CGRect
    public let backingScale: CGFloat
    /// Display's pixel size (native pixels).
    public let pixelSize: CGSize
    public let isMain: Bool

    public init(
        displayID: CGDirectDisplayID,
        appKitFrame: CGRect,
        backingScale: CGFloat,
        pixelSize: CGSize,
        isMain: Bool
    ) {
        self.displayID = displayID
        self.appKitFrame = appKitFrame
        self.backingScale = backingScale
        self.pixelSize = pixelSize
        self.isMain = isMain
    }
}

public struct DisplayTopologySnapshot: Hashable, Sendable {
    public let entries: [DisplayTopologyEntry]
    public let capturedAt: Date

    public init(entries: [DisplayTopologyEntry], capturedAt: Date = Date()) {
        self.entries = entries
        self.capturedAt = capturedAt
    }

    /// Compare only the display arrangement. `capturedAt` is metadata and
    /// should not invalidate an in-flight invocation by itself.
    public func hasSameArrangement(as other: DisplayTopologySnapshot) -> Bool {
        entries == other.entries
    }

    public var mainEntry: DisplayTopologyEntry? {
        entries.first(where: { $0.isMain }) ?? entries.first
    }

    public func entry(for id: CGDirectDisplayID) -> DisplayTopologyEntry? {
        entries.first(where: { $0.displayID == id })
    }

    /// AppKit global origin of the primary display's top-left corner (top of primary = AppKit global y = primary.frame.maxY).
    public var primaryTopY: CGFloat {
        mainEntry?.appKitFrame.maxY ?? 0
    }
}

public protocol DisplayTopologyProviding: Sendable {
    func current() -> DisplayTopologySnapshot
}

public struct RealDisplayTopology: DisplayTopologyProviding {
    public init() {}

    public func current() -> DisplayTopologySnapshot {
        let screens = NSScreen.screens
        let mainID = NSScreen.main?.displayID
        let entries: [DisplayTopologyEntry] = screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let pixelW = CGDisplayPixelsWide(id)
            let pixelH = CGDisplayPixelsHigh(id)
            return DisplayTopologyEntry(
                displayID: id,
                appKitFrame: screen.frame,
                backingScale: screen.backingScaleFactor,
                pixelSize: CGSize(width: pixelW, height: pixelH),
                isMain: (id == mainID)
            )
        }
        return DisplayTopologySnapshot(entries: entries)
    }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
