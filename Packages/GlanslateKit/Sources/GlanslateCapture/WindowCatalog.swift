import CoreGraphics
import Foundation
import GlanslateCore

/// An on-screen window that can be picked in window-selection mode.
public struct WindowInfo: Equatable, Sendable, Identifiable {
    public let id: UInt32
    /// Frame in Quartz global space (top-left origin).
    public let quartzFrame: CGRect
    public let ownerName: String
    public let title: String
}

/// Lists normal application windows front to back, excluding Glanslate's own.
public enum WindowCatalog {
    public static func onScreenWindows(excludingProcess pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info -> WindowInfo? in
            guard
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                let owner = info[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value != pid,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.width >= 40, bounds.height >= 24
            else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue < 0.05 { return nil }
            return WindowInfo(
                id: number.uint32Value,
                quartzFrame: bounds,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? ""
            )
        }
    }
}
