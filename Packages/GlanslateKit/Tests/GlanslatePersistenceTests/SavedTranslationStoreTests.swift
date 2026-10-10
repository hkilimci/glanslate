import Foundation
import GlanslateCore
import Testing
@testable import GlanslatePersistence

@Suite("Saved translations")
@MainActor
struct SavedTranslationStoreTests {
    private func draft(
        id: UUID = UUID(),
        original: String = "Bonjour le monde",
        translated: String = "Hello world",
        createdAt: Date = Date()
    ) -> SavedTranslationDraft {
        SavedTranslationDraft(
            id: id,
            createdAt: createdAt,
            originalText: original,
            translatedText: translated,
            sourceLanguage: .french,
            targetLanguage: .english,
            provider: .apple,
            thumbnail: Data([0xFF, 0xD8, 0xFF])
        )
    }

    @Test func savesEveryField() throws {
        let store = try SavedTranslationStore(inMemory: true)
        let id = UUID()
        try store.save(draft(id: id))

        let item = try #require(store.item(id: id))
        #expect(item.originalText == "Bonjour le monde")
        #expect(item.translatedText == "Hello world")
        #expect(item.sourceLanguage == .french)
        #expect(item.targetLanguage == .english)
        #expect(item.provider == .apple)
        #expect(item.thumbnail == Data([0xFF, 0xD8, 0xFF]))
        #expect(store.contains(id: id))
    }

    @Test func savingTheSameIDUpdatesInsteadOfDuplicating() throws {
        let store = try SavedTranslationStore(inMemory: true)
        let id = UUID()
        try store.save(draft(id: id, translated: "Hello world"))
        try store.save(draft(id: id, translated: "Hallo Welt"))
        #expect(store.count() == 1)
        #expect(store.item(id: id)?.translatedText == "Hallo Welt")
    }

    @Test func itemsAreNewestFirstAndSearchable() throws {
        let store = try SavedTranslationStore(inMemory: true)
        try store.save(draft(original: "Gare du Nord", translated: "North station", createdAt: Date(timeIntervalSince1970: 100)))
        try store.save(draft(original: "Boulangerie", translated: "Bakery", createdAt: Date(timeIntervalSince1970: 200)))

        #expect(try store.items().map(\.translatedText) == ["Bakery", "North station"])
        #expect(try store.items(matching: "station").map(\.translatedText) == ["North station"])
        #expect(try store.items(matching: "boulang").map(\.translatedText) == ["Bakery"])
        #expect(try store.items(matching: "nothing here").isEmpty)
    }

    @Test func deletesIndividuallyAndAll() throws {
        let store = try SavedTranslationStore(inMemory: true)
        let keep = UUID(), remove = UUID()
        try store.save(draft(id: keep))
        try store.save(draft(id: remove))

        try store.delete(id: remove)
        #expect(!store.contains(id: remove))
        #expect(store.contains(id: keep))

        try store.deleteAll()
        #expect(store.count() == 0)
    }

    @Test func listPresentation() throws {
        let store = try SavedTranslationStore(inMemory: true)
        let id = UUID()
        try store.save(draft(id: id, translated: "First line\nSecond line"))
        let item = try #require(store.item(id: id))
        #expect(item.headline == "First line")
        #expect(item.languagePairDescription.contains("→"))
    }
}
