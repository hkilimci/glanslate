import CoreGraphics
import Foundation

public struct DisplayLocalRect: Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let rect: CGRect

    public init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }
}
