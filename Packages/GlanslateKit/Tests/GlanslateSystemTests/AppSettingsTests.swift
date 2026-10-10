import Foundation
import GlanslateCore
import Testing
@testable import GlanslateSystem

@Suite("Settings")
@MainActor
struct AppSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "glanslate.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsAreSensible() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.preferredProvider == .apple)
        #expect(settings.fallbackProvider == nil)
        #expect(settings.prefersOnDevice)
        #expect(settings.overlayStyle == .liquidGlass)
        #expect(settings.translateShortcut == .defaultTranslate)
        #expect(settings.revealModifier == .option)
        #expect(settings.consentedProviders.isEmpty)
        #expect(!settings.showsDockIcon)
    }

    @Test func changesPersistAcrossLaunches() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.targetLanguage = .japanese
        settings.sourceLanguage = .specific(.german)
        settings.preferredProvider = .deepL
        settings.fallbackProvider = .google
        settings.overlayStyle = .subtitle
        settings.subtitle.showsBorder = true
        settings.translateShortcut = nil
        settings.revealModifier = .control
        settings.setConsent(true, for: .deepL)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.targetLanguage == .japanese)
        #expect(reloaded.sourceLanguage == .specific(.german))
        #expect(reloaded.preferredProvider == .deepL)
        #expect(reloaded.fallbackProvider == .google)
        #expect(reloaded.overlayStyle == .subtitle)
        #expect(reloaded.subtitle.showsBorder)
        #expect(reloaded.translateShortcut == nil, "A cleared shortcut stays cleared")
        #expect(reloaded.revealModifier == .control)
        #expect(reloaded.hasConsent(for: .deepL))
        #expect(!reloaded.hasConsent(for: .openAI))
        #expect(reloaded.hasConsent(for: .apple), "On-device translation needs no consent")
    }

    @Test func routingPolicyIgnoresAFallbackEqualToThePreferredProvider() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.preferredProvider = .google
        settings.fallbackProvider = .google
        #expect(settings.routingPolicy.fallback == nil)
    }

    @Test func carbonModifiersMatchTheHotKeyAPI() {
        #expect(HotKeyCenter.carbonModifiers([.command, .shift]) == 256 | 512)
        #expect(HotKeyCenter.carbonModifiers([.option, .control]) == 2048 | 4096)
    }
}
