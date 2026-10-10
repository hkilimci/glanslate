import Foundation
import Testing
@testable import GlanslateCore

/// A Retina laptop as primary, an external display to the left and lower
/// (negative x), and one stacked above the primary.
private let primary = DisplayDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let left = DisplayDescriptor(id: 2, frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080), scale: 1)
private let above = DisplayDescriptor(id: 3, frame: CGRect(x: 200, y: 982, width: 2560, height: 1440), scale: 2)
private let layout = DisplayLayout(displays: [left, primary, above])
private let space = CoordinateSpace(layout: layout)

@Suite("Coordinate conversion")
struct CoordinateConversionTests {
    @Test func primaryIsTheDisplayAtTheOrigin() {
        #expect(layout.primary?.id == 1)
        #expect(layout.primaryHeight == 982)
    }

    @Test func appKitAndQuartzAreMirroredAroundThePrimaryHeight() {
        let appKit = CGRect(x: 100, y: 800, width: 200, height: 50)
        let quartz = space.quartzRect(fromAppKit: appKit)
        #expect(quartz == CGRect(x: 100, y: 132, width: 200, height: 50))
        #expect(space.appKitRect(fromQuartz: quartz) == appKit)
    }

    @Test func displayAbovePrimaryHasNegativeQuartzY() {
        let quartzFrame = space.quartzFrame(of: above)
        #expect(quartzFrame == CGRect(x: 200, y: -1440, width: 2560, height: 1440))
    }

    @Test func localRectOnDisplayWithNegativeOrigin() {
        // 100 pt from the left display's left edge and 40 pt below its top.
        let appKit = CGRect(x: -1820, y: -300 + 1080 - 40 - 60, width: 300, height: 60)
        let local = space.localRect(fromAppKit: appKit, on: left)
        #expect(local == CGRect(x: 100, y: 40, width: 300, height: 60))
        #expect(space.appKitRect(fromLocal: local, on: left) == appKit)
    }

    @Test func quartzWindowFrameToLocalOnDisplayAbove() {
        // A window whose top-left sits 50 × 70 pt inside the upper display.
        let quartz = CGRect(x: 250, y: -1440 + 70, width: 800, height: 600)
        let local = space.localRect(fromQuartz: quartz, on: above)
        #expect(local == CGRect(x: 50, y: 70, width: 800, height: 600))
        #expect(space.quartzRect(fromLocal: local, on: above) == quartz)
    }

    @Test func regionRequiresASingleDisplay() {
        let onPrimary = CGRect(x: 10, y: 10, width: 100, height: 100)
        #expect(space.region(fromAppKit: onPrimary)?.displayID == 1)

        let spanning = CGRect(x: -50, y: 10, width: 100, height: 100)
        #expect(space.region(fromAppKit: spanning) == nil)
    }

    @Test func regionRoundTripsThroughEverySpace() throws {
        let region = ScreenRegion(displayID: 2, rect: CGRect(x: 12, y: 34, width: 56, height: 78))
        let appKit = try #require(space.appKitRect(for: region))
        let back = try #require(space.region(fromAppKit: appKit))
        #expect(back == region)
        let quartz = try #require(space.quartzRect(for: region))
        #expect(space.localRect(fromQuartz: quartz, on: left) == region.rect)
    }

    @Test func arrangementComparisonIgnoresOrder() {
        let reordered = DisplayLayout(displays: [primary, above, left])
        #expect(layout.hasSameArrangement(as: reordered))
        let moved = DisplayLayout(displays: [primary, above, DisplayDescriptor(id: 2, frame: left.frame.offsetBy(dx: 0, dy: 10), scale: 1)])
        #expect(!layout.hasSameArrangement(as: moved))
    }
}

@Suite("Capture geometry")
struct CaptureGeometryTests {
    // A 300 × 100 pt region captured on a 2× display.
    let geometry = CaptureGeometry(region: CGRect(x: 40, y: 60, width: 300, height: 100), pixelWidth: 600, pixelHeight: 200)

    @Test func pixelSizeFollowsBackingScale() {
        let size = CaptureGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 300.5, height: 100), scale: 2)
        #expect(size.width == 601)
        #expect(size.height == 200)
    }

    @Test func visionNormalizedRectUsesBottomLeftOrigin() {
        // The top-left quarter of the image in Vision's coordinates.
        let normalized = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        #expect(geometry.localRect(fromNormalized: normalized) == CGRect(x: 40, y: 60, width: 150, height: 50))
    }

    @Test func normalizedRoundTrip() {
        let local = CGRect(x: 100, y: 90, width: 60, height: 20)
        let normalized = geometry.normalizedRect(fromLocal: local)
        let back = geometry.localRect(fromNormalized: normalized)
        #expect(abs(back.minX - local.minX) < 0.0001)
        #expect(abs(back.minY - local.minY) < 0.0001)
        #expect(abs(back.width - local.width) < 0.0001)
        #expect(abs(back.height - local.height) < 0.0001)
    }

    @Test func pixelRectScalesAndClips() {
        let local = CGRect(x: 50, y: 70, width: 20.25, height: 10)
        #expect(geometry.pixelRect(fromLocal: local) == CGRect(x: 20, y: 20, width: 41, height: 20))
        let overflowing = CGRect(x: 300, y: 140, width: 100, height: 100)
        #expect(geometry.pixelRect(fromLocal: overflowing) == CGRect(x: 520, y: 160, width: 80, height: 40))
        #expect(geometry.localRect(fromPixel: CGRect(x: 20, y: 20, width: 40, height: 20)) == CGRect(x: 50, y: 70, width: 20, height: 10))
    }
}

@Suite("Selection geometry")
struct SelectionGeometryTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func dragRectNormalizesAnyDirection() {
        let rect = SelectionGeometry.dragRect(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50), within: bounds)
        #expect(rect == CGRect(x: 100, y: 50, width: 200, height: 150))
    }

    @Test func dragIsClampedToTheStartingDisplay() {
        let rect = SelectionGeometry.dragRect(from: CGPoint(x: 1400, y: 900), to: CGPoint(x: 1700, y: 1200), within: bounds)
        #expect(rect == CGRect(x: 1400, y: 900, width: 112, height: 82))
        #expect(SelectionGeometry.isOutside(CGPoint(x: 1700, y: 10), bounds: bounds))
    }

    @Test func tinySelectionsAreRejected() {
        let result = SelectionGeometry.validate(CGRect(x: 10, y: 10, width: 8, height: 40), within: bounds)
        #expect(result == .failure(.tooSmall))
    }

    @Test func validSelectionsSnapOutwardToWholePoints() {
        let result = SelectionGeometry.validate(CGRect(x: 10.4, y: 10.6, width: 100.2, height: 50), within: bounds)
        #expect(result == .success(CGRect(x: 10, y: 10, width: 101, height: 51)))
    }

    @Test func windowsAreClippedToTheirDisplay() {
        let frame = CGRect(x: -100, y: 900, width: 400, height: 300)
        #expect(SelectionGeometry.windowRegion(localFrame: frame, displayBounds: bounds) == CGRect(x: 0, y: 900, width: 300, height: 82))
        #expect(SelectionGeometry.windowRegion(localFrame: CGRect(x: 2000, y: 0, width: 10, height: 10), displayBounds: bounds) == nil)
    }
}
