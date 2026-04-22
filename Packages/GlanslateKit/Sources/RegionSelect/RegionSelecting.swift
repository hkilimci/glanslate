import Foundation
import GlanslateCore
import GlanslateGeometry

public protocol RegionSelecting: Sendable {
    func selectRegion(in topology: DisplayTopologySnapshot) async -> RegionSelection?
}

public struct RegionSelection: Sendable, Hashable {
    public let region: DisplayLocalRect
    public let topology: DisplayTopologySnapshot

    public init(region: DisplayLocalRect, topology: DisplayTopologySnapshot) {
        self.region = region
        self.topology = topology
    }
}
