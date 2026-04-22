import Foundation
import XCTest
@testable import GlanslateCore
@testable import GlanslatePlatform
@testable import GlanslateSettings

final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testPersistRoundTrip() {
        let suite = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults, keychain: KeychainStore(service: suite))

        store.preferredProvider = .google
        store.defaultTargetLanguage = .fr
        store.overlayStyle = .subtitle
        store.acceptDisclosure(for: .google)
        store.persist()

        let reloaded = SettingsStore(defaults: defaults, keychain: KeychainStore(service: suite))
        XCTAssertEqual(reloaded.preferredProvider, .google)
        XCTAssertEqual(reloaded.defaultTargetLanguage, .fr)
        XCTAssertEqual(reloaded.overlayStyle, .subtitle)
        XCTAssertTrue(reloaded.hasAcceptedDisclosure(for: .google))
    }
}
