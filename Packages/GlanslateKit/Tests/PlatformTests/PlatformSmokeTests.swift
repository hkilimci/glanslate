import XCTest
@testable import GlanslatePlatform

final class PlatformSmokeTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let service = "com.glanslate.tests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)

        do {
            try store.set("secret", for: "account")
            XCTAssertEqual(try store.get("account"), "secret")

            try store.delete("account")
            XCTAssertNil(try store.get("account"))
        } catch KeychainStore.KeychainError.unhandled(let status)
            where status == errSecNotAvailable || status == errSecMissingEntitlement
        {
            throw XCTSkip("Keychain is not available in this test environment.")
        }
    }
}
