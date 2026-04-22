import CoreGraphics
import XCTest
@testable import GlanslateCore
@testable import GlanslateGeometry

final class GeometryConverterTests: XCTestCase {
    func testAppKitRectRoundTripOnSingleDisplay() {
        let snapshot = DisplayTopologySnapshot(entries: [
            DisplayTopologyEntry(
                displayID: 101,
                appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                backingScale: 2,
                pixelSize: CGSize(width: 2880, height: 1800),
                isMain: true
            )
        ])
        let converter = GeometryConverter(snapshot: snapshot)
        let rect = CGRect(x: 120, y: 250, width: 300, height: 80)

        let local = converter.displayLocal(fromAppKitGlobalRect: rect)
        XCTAssertNotNil(local)
        XCTAssertEqual(local?.displayID, 101)
        XCTAssertEqual(local?.rect, CGRect(x: 120, y: 570, width: 300, height: 80))

        let roundTrip = converter.appKitGlobal(fromDisplayLocalRect: local!)
        XCTAssertEqual(roundTrip, rect)
    }

    func testCrossScreenRectIsRejected() {
        let snapshot = DisplayTopologySnapshot(entries: [
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
        let converter = GeometryConverter(snapshot: snapshot)

        XCTAssertNil(converter.displayLocal(fromAppKitGlobalRect: CGRect(x: 90, y: 20, width: 30, height: 30)))
    }
}
