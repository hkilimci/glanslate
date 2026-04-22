import CoreGraphics
import XCTest
@testable import GlanslateCore
@testable import GlanslateGeometry
@testable import GlanslateRegionSelect

final class RegionSelectionGeometryTests: XCTestCase {
    func testNormalizedGlobalRectUsesMinimumOrigin() {
        let geometry = RegionSelectionGeometry(topology: sampleTopology())
        let rect = geometry.normalizedGlobalRect(
            from: CGPoint(x: 80, y: 20),
            to: CGPoint(x: 10, y: 70)
        )

        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 70, height: 50))
    }

    func testCrossScreenSelectionIsRejected() {
        let geometry = RegionSelectionGeometry(topology: dualDisplayTopology())
        let evaluation = geometry.evaluate(
            from: CGPoint(x: 80, y: 20),
            to: CGPoint(x: 120, y: 70)
        )

        XCTAssertEqual(evaluation.activeDisplayID, 1)
        XCTAssertEqual(evaluation.outcome, .crossScreenRejected)
    }

    func testSingleDisplaySelectionReturnsDisplayLocalRect() {
        let geometry = RegionSelectionGeometry(topology: sampleTopology())
        let evaluation = geometry.evaluate(
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 60, y: 50)
        )

        XCTAssertEqual(
            evaluation.outcome,
            .selected(DisplayLocalRect(
                displayID: 1,
                rect: CGRect(x: 20, y: 50, width: 40, height: 30)
            ))
        )
    }

    private func sampleTopology() -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(entries: [
            DisplayTopologyEntry(
                displayID: 1,
                appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 2,
                pixelSize: CGSize(width: 200, height: 200),
                isMain: true
            )
        ])
    }

    private func dualDisplayTopology() -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(entries: [
            DisplayTopologyEntry(
                displayID: 1,
                appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 1,
                pixelSize: CGSize(width: 100, height: 100),
                isMain: true
            ),
            DisplayTopologyEntry(
                displayID: 2,
                appKitFrame: CGRect(x: 100, y: 0, width: 100, height: 100),
                backingScale: 2,
                pixelSize: CGSize(width: 200, height: 200),
                isMain: false
            )
        ])
    }
}
