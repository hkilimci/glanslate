import Foundation
import Testing
@testable import GlanslateCore

@Suite("Domain model")
struct DomainModelTests {
    @Test(arguments: [
        ("EN-US", "en"), ("en_GB", "en"), ("pt-BR", "pt"), ("zh", "zh-Hans"), ("zh-CN", "zh-Hans"),
        ("zh-TW", "zh-Hant"), ("zh-Hant-HK", "zh-Hant"), ("iw", "he"), ("no", "nb"), ("in", "id"), ("", "und"),
    ])
    func languageCodesAreNormalized(raw: String, expected: String) {
        #expect(Language(raw).code == expected)
    }

    @Test func languagesHaveReadableNames() {
        #expect(Language.german.localizedName(in: Locale(identifier: "en")) == "German")
        #expect(Language.german.englishName == "German")
        #expect(Language.hebrew.isRightToLeft)
        #expect(!Language.japanese.usesInterwordSpacing)
    }

    @Test func preferredTargetFallsBackToEnglish() {
        #expect(Language.preferredTarget(preferredLanguages: ["tr-TR", "en"]) == .turkish)
        #expect(Language.preferredTarget(preferredLanguages: ["xx"]) == .english)
    }

    @Test func sourceLanguageRoundTripsThroughCodable() throws {
        for value in [SourceLanguage.automatic, .specific(.japanese)] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(SourceLanguage.self, from: data) == value)
        }
    }

    @Test func colorsParseAndFormatHex() throws {
        let color = try #require(RGBAColor(hex: "#1E90FFCC"))
        #expect(color.hex == "#1E90FFCC")
        #expect(RGBAColor(hex: "fff")?.hex == "#FFFFFF")
        #expect(RGBAColor(hex: "nope") == nil)
        #expect(RGBAColor.white.contrastRatio(with: .black) > 20)
    }

    @Test func shortcutsDisplayInMenuOrder() {
        let combo = KeyCombo(keyCode: 0x11, modifiers: [.command, .shift, .option, .control], key: "T")
        #expect(combo.displayString == "⌃⌥⇧⌘T")
        #expect(KeyCombo.defaultTranslate.displayString == "⇧⌘T")
        #expect(KeyCombo.defaultTranslate.isValidGlobalShortcut)
        #expect(!KeyCombo(keyCode: 0x11, modifiers: [.shift], key: "T").isValidGlobalShortcut)
        #expect(KeyCombo(keyCode: 0x60, modifiers: [], key: "F5").isValidGlobalShortcut)
        #expect(KeyCombo.label(forKeyCode: 0x31) == "Space")
        #expect(KeyCombo.label(forKeyCode: 0x7A) == "F1")
    }

    @Test func errorsAlwaysExplainWhatToDo() {
        let errors: [GlanslateError] = [
            .screenRecordingNotAuthorized, .noTextFound, .sourceLanguageUndetermined,
            .languageModelsNotInstalled(source: .french, target: .english), .missingCredential(.deepL),
            .rateLimited(.openAI, retryAfter: 12), .network(.google, .offline), .serviceNotEnabled(.google),
        ]
        for error in errors {
            #expect(!error.title.isEmpty)
            #expect(!error.message.isEmpty)
            #expect(error.recovery != nil)
        }
        #expect(GlanslateError.rateLimited(.openAI, retryAfter: 12).message.contains("12 seconds"))
    }

    @Test func savedDraftCapturesTheResult() {
        let region = ScreenRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 40))
        let block = TextBlock(lines: [line("Hallo", x: 0, y: 0, width: 40)], text: "Hallo")
        let result = GlanceResult(
            recognized: RecognizedText(region: region, blocks: [block], detectedLanguage: nil),
            outcome: TranslationOutcome(provider: .deepL, texts: ["Hello "], source: .german, target: .english, fallback: nil)
        )
        let draft = SavedTranslationDraft(id: UUID(), result: result, thumbnail: nil)
        #expect(draft.originalText == "Hallo")
        #expect(draft.translatedText == "Hello")
        #expect(draft.sourceLanguage == .german)
        #expect(draft.provider == .deepL)
        #expect(result.pairs.first?.translation == "Hello ")
    }
}
