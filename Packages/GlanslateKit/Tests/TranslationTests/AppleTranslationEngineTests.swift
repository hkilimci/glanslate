import XCTest
@testable import GlanslateTranslation
#if canImport(Translation)
import Translation
#endif

final class AppleTranslationEngineTests: XCTestCase {
    #if canImport(Translation)
    @available(macOS 26.0, *)
    func testLanguageAvailabilityStatusMapping() {
        XCTAssertEqual(AppleLanguageAvailability.map(.installed), .supported)
        XCTAssertEqual(AppleLanguageAvailability.map(.supported), .needsDownload)
        XCTAssertEqual(AppleLanguageAvailability.map(.unsupported), .unsupported)
    }
    #endif
}
