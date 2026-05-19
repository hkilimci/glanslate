import CoreGraphics
import XCTest
@testable import GlanslateRegionSelect

final class WindowEnumeratorTests: XCTestCase {
    func testAppKitRectFlipsFromCoreGraphicsCoordinates() {
        // CG rect uses a top-left origin; AppKit uses bottom-left.
        let cg = CGRect(x: 100, y: 50, width: 300, height: 200)
        let appKit = WindowEnumerator.appKitRect(fromCGRect: cg, primaryTopY: 900)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 900 - 250, width: 300, height: 200))
    }

    func testSelectableWindowsExcludesNonZeroLayerAndOwnProcess() {
        let windows = [
            WindowEnumerator.Window(cgRect: CGRect(x: 0, y: 0, width: 10, height: 10), layer: 0, ownerPID: 200),
            WindowEnumerator.Window(cgRect: CGRect(x: 0, y: 0, width: 10, height: 10), layer: 25, ownerPID: 200),
            WindowEnumerator.Window(cgRect: CGRect(x: 0, y: 0, width: 10, height: 10), layer: 0, ownerPID: 999),
        ]
        let enumerator = WindowEnumerator(ownPID: 999, windowsProvider: { windows })
        let selectable = enumerator.selectableWindows()
        XCTAssertEqual(selectable.count, 1)
        XCTAssertEqual(selectable.first?.ownerPID, 200)
    }

    func testWindowAtPointReturnsFrontmostMatchInAppKitCoordinates() {
        // The window list is front-to-back; the first match wins.
        let front = WindowEnumerator.Window(cgRect: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0, ownerPID: 1)
        let back = WindowEnumerator.Window(cgRect: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 0, ownerPID: 2)
        let enumerator = WindowEnumerator(ownPID: 999, windowsProvider: { [front, back] })

        // primaryTopY 500: CG (0,0,100,100) → AppKit (0,400,100,100), covering y 400..500.
        let hit = enumerator.window(at: CGPoint(x: 50, y: 450), primaryTopY: 500)
        XCTAssertEqual(hit, CGRect(x: 0, y: 400, width: 100, height: 100))
    }

    func testWindowAtPointReturnsNilWhenNoWindowContainsPoint() {
        let window = WindowEnumerator.Window(cgRect: CGRect(x: 0, y: 0, width: 50, height: 50), layer: 0, ownerPID: 1)
        let enumerator = WindowEnumerator(ownPID: 999, windowsProvider: { [window] })
        XCTAssertNil(enumerator.window(at: CGPoint(x: 300, y: 300), primaryTopY: 500))
    }
}
