import Foundation
import XCTest
@testable import GlanslateCore
@testable import GlanslateTranslation

final class GoogleEngineTests: XCTestCase {
    func testParseKeylessResponseSingleSegment() throws {
        let json = #"[[["Hola","Hello",null,null,10]],null,"en"]"#
        let result = try GoogleEngine.parseKeylessResponse(Data(json.utf8))
        XCTAssertEqual(result, "Hola")
    }

    func testParseKeylessResponseJoinsMultipleSegments() throws {
        let json = #"[[["Hola ","Hello ",null,null],["mundo","world",null,null]],null,"en"]"#
        let result = try GoogleEngine.parseKeylessResponse(Data(json.utf8))
        XCTAssertEqual(result, "Hola mundo")
    }

    func testParseKeylessResponseThrowsOnMalformedPayload() {
        let json = #"{"unexpected":true}"#
        XCTAssertThrowsError(try GoogleEngine.parseKeylessResponse(Data(json.utf8))) { error in
            guard case GlanslateError.translation(let provider, _) = error else {
                return XCTFail("Expected .translation error, got \(error)")
            }
            XCTAssertEqual(provider, .google)
        }
    }

    func testParseKeylessResponseThrowsOnEmptySegments() {
        let json = #"[[],null,"en"]"#
        XCTAssertThrowsError(try GoogleEngine.parseKeylessResponse(Data(json.utf8)))
    }

    func testGoogleCodeMapsLanguagesToEndpointCodes() {
        let engine = GoogleEngine()
        XCTAssertEqual(engine.googleCode(for: .zhHans), "zh-CN")
        XCTAssertEqual(engine.googleCode(for: .zhHant), "zh-TW")
        XCTAssertEqual(engine.googleCode(for: .en), "en")
        XCTAssertEqual(engine.googleCode(for: .tr), "tr")
        XCTAssertNil(engine.googleCode(for: .auto))
    }

    func testCanTranslateIsSupportedWithoutAnAPIKey() async {
        let status = await GoogleEngine().canTranslate(from: .en, to: .tr)
        XCTAssertEqual(status, .supported)
    }
}
