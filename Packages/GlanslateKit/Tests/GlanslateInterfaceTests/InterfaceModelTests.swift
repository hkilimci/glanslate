import Foundation
import GlanslateCore
import Testing
@testable import GlanslateInterface

@Suite("Interface models")
@MainActor
struct InterfaceModelTests {
    private func session(source: SourceLanguage = .automatic) -> GlanceSession {
        let display = DisplayDescriptor(id: 7, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1)
        return GlanceSession(
            target: .area(ScreenRegion(displayID: 7, rect: CGRect(x: 100, y: 50, width: 400, height: 200))),
            display: display,
            layout: DisplayLayout(displays: [DisplayDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2), display]),
            sourceLanguage: source,
            targetLanguage: .english,
            style: .liquidGlass
        )
    }

    @Test func sessionPlacesItsRegionInAppKitSpace() {
        // 100 pt from the left display's left edge, 50 pt below its top.
        #expect(session().appKitFrame == CGRect(x: -1820, y: 1080 - 250, width: 400, height: 200))
    }

    @Test func sessionDescribesItsProgress() {
        let session = session()
        #expect(session.isWorking)
        #expect(session.statusText == "Reading text…")
        session.phase = .translating
        #expect(session.statusText == "Translating…")
        session.phase = .ready
        #expect(!session.isWorking)
        session.isRetranslating = true
        #expect(session.isWorking)
    }

    @Test func revealCombinesToggleAndHeldKey() {
        let session = session()
        #expect(!session.isRevealingOriginal)
        session.isRevealHeld = true
        #expect(session.isRevealingOriginal)
        session.isRevealHeld = false
        session.isRevealToggled = true
        #expect(session.isRevealingOriginal)
    }

    @Test func toolbarLabelsReflectChoicesAndDetection() {
        let session = session()
        #expect(session.sourceLabel == "Detect")
        #expect(session.providerLabel == "Automatic")
        session.providerChoice = .specific(.deepL)
        #expect(session.providerLabel == "DeepL")
        let explicit = self.session(source: .specific(.german))
        #expect(explicit.sourceLabel == Language.german.localizedName())
    }

    @Test func menuKeyEquivalentsUseSingleCharacters() {
        #expect(StatusMenuController.keyEquivalent(for: .defaultTranslate) == "t")
        #expect(StatusMenuController.keyEquivalent(for: KeyCombo(keyCode: 0x31, modifiers: [.option], key: "Space")) == " ")
        #expect(StatusMenuController.keyEquivalent(for: KeyCombo(keyCode: 0x60, modifiers: [], key: "F5")) == nil)
    }

    @Test func settingsSectionsMatchTheSpecifiedOrder() {
        #expect(SettingsSection.allCases.map(\.title) == ["General", "Shortcuts", "Translation", "Appearance", "Saved Translations", "About"])
    }
}
