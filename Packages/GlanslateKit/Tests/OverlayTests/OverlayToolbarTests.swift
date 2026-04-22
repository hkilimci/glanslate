import CoreGraphics
import XCTest
@testable import GlanslateOverlay

final class OverlayToolbarTests: XCTestCase {
    func testLayoutPinsToolbarToTopInset() {
        let frame = OverlayToolbarLayout.frame(
            for: CGRect(x: 180, y: 140, width: 120, height: 36),
            displaySize: CGSize(width: 960, height: 640)
        )

        XCTAssertEqual(frame.minY, OverlayToolbarLayout.inset, accuracy: 0.01)
        XCTAssertTrue(frame.maxX <= 960 - OverlayToolbarLayout.inset)
        XCTAssertTrue(frame.minX >= OverlayToolbarLayout.inset)
    }

    func testHoverStateActivatesWithinProximityThreshold() {
        var state = OverlayToolbarHoverState()
        let frame = CGRect(x: 100, y: 100, width: 220, height: 56)

        state.update(pointer: CGPoint(x: 90, y: 90), toolbarFrame: frame)
        XCTAssertEqual(state.opacity, OverlayToolbarHoverState.activeOpacity)

        state.update(pointer: CGPoint(x: 10, y: 10), toolbarFrame: frame)
        XCTAssertEqual(state.opacity, OverlayToolbarHoverState.restingOpacity)
    }
}
