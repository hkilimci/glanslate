import CoreGraphics
import XCTest
@testable import GlanslateOverlay

final class OverlayToolbarTests: XCTestCase {
    func testHoverStateActivatesWithinProximityThreshold() {
        var state = OverlayToolbarHoverState()
        let frame = CGRect(x: 100, y: 100, width: 220, height: 56)

        state.update(pointer: CGPoint(x: 90, y: 90), toolbarFrame: frame)
        XCTAssertEqual(state.opacity, OverlayToolbarHoverState.activeOpacity)

        state.update(pointer: CGPoint(x: 10, y: 10), toolbarFrame: frame)
        XCTAssertEqual(state.opacity, OverlayToolbarHoverState.restingOpacity)
    }
}
