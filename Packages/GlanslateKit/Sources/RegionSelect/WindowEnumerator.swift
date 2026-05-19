import CoreGraphics
import Foundation

/// Enumerates on-screen windows so the region selector can snap a selection to a whole window.
public struct WindowEnumerator: Sendable {
    /// A single on-screen window as reported by the window server.
    public struct Window: Sendable, Equatable {
        /// Window bounds in Core Graphics global coordinates (top-left origin, y grows down).
        public let cgRect: CGRect
        /// Window level; normal application windows are layer 0.
        public let layer: Int
        public let ownerPID: pid_t

        public init(cgRect: CGRect, layer: Int, ownerPID: pid_t) {
            self.cgRect = cgRect
            self.layer = layer
            self.ownerPID = ownerPID
        }
    }

    private let ownPID: pid_t
    private let windowsProvider: @Sendable () -> [Window]

    public init(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        windowsProvider: (@Sendable () -> [Window])? = nil
    ) {
        self.ownPID = ownPID
        self.windowsProvider = windowsProvider ?? Self.copySystemWindows
    }

    /// Normal-layer on-screen windows, front-to-back, excluding our own process.
    public func selectableWindows() -> [Window] {
        windowsProvider().filter { $0.layer == 0 && $0.ownerPID != ownPID }
    }

    /// Frontmost window under `globalPoint`, returned as an AppKit-global rect (bottom-left origin).
    /// - parameter primaryTopY: AppKit maxY of the primary display, used for the CG→AppKit flip.
    public func window(at globalPoint: CGPoint, primaryTopY: CGFloat) -> CGRect? {
        for window in selectableWindows() {
            let appKit = Self.appKitRect(fromCGRect: window.cgRect, primaryTopY: primaryTopY)
            if appKit.contains(globalPoint) {
                return appKit
            }
        }
        return nil
    }

    /// Converts a CG-global rect (top-left origin) to an AppKit-global rect (bottom-left origin).
    static func appKitRect(fromCGRect cg: CGRect, primaryTopY: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: primaryTopY - cg.maxY, width: cg.width, height: cg.height)
    }

    private static func copySystemWindows() -> [Window] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return infoList.compactMap { info -> Window? in
            guard
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                let layer = info[kCGWindowLayer as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else {
                return nil
            }
            return Window(cgRect: cgRect, layer: layer, ownerPID: pid)
        }
    }
}
