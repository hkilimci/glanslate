import CoreGraphics
import XCTest
@testable import GlanslateCore
@testable import GlanslateTextDetect

final class TextDetectionPipelineTests: XCTestCase {
    func testMergePrefersAXTextAndVisionBoundsForOverlappingBlocks() {
        let pipeline = TextDetectionPipeline()
        let axBlock = TextBlock(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            text: "Source Text",
            region: DisplayLocalRect(displayID: 7, rect: CGRect(x: 10, y: 10, width: 100, height: 20)),
            detectedLanguage: .en,
            confidence: 0.8,
            source: .accessibility
        )
        let visionBlock = TextBlock(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            text: "OCR Text",
            region: DisplayLocalRect(displayID: 7, rect: CGRect(x: 12, y: 12, width: 102, height: 18)),
            detectedLanguage: .en,
            confidence: 0.9,
            source: .vision
        )

        let merged = pipeline.merge(ax: [axBlock], vision: [visionBlock])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "Source Text")
        XCTAssertEqual(merged[0].region, visionBlock.region)
        XCTAssertEqual(merged[0].source, .arbitrated)
    }
}
