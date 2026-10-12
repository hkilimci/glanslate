import Foundation
import GlanslateCore
import SwiftData

/// A pinned translation kept on this Mac.
@Model
public final class SavedTranslation {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var originalText: String
    public var translatedText: String
    public var sourceLanguageCode: String?
    public var targetLanguageCode: String
    public var providerRawValue: String
    @Attribute(.externalStorage) public var thumbnail: Data?

    public init(draft: SavedTranslationDraft) {
        id = draft.id
        createdAt = draft.createdAt
        originalText = draft.originalText
        translatedText = draft.translatedText
        sourceLanguageCode = draft.sourceLanguage?.code
        targetLanguageCode = draft.targetLanguage.code
        providerRawValue = draft.provider.rawValue
        thumbnail = draft.thumbnail
    }

    public func update(from draft: SavedTranslationDraft) {
        originalText = draft.originalText
        translatedText = draft.translatedText
        sourceLanguageCode = draft.sourceLanguage?.code
        targetLanguageCode = draft.targetLanguage.code
        providerRawValue = draft.provider.rawValue
        if let thumbnail = draft.thumbnail { self.thumbnail = thumbnail }
    }

    public var sourceLanguage: Language? { sourceLanguageCode.map(Language.init) }
    public var targetLanguage: Language { Language(targetLanguageCode) }
    public var provider: TranslationProvider { TranslationProvider(rawValue: providerRawValue) ?? .apple }

    /// "French → English"
    public var languagePairDescription: String {
        let source = sourceLanguage?.localizedName() ?? "Detected"
        return "\(source) → \(targetLanguage.localizedName())"
    }

    /// The first line of the translation, for list rows.
    public var headline: String {
        translatedText.split(whereSeparator: \.isNewline).first.map(String.init) ?? translatedText
    }
}

/// Saves, finds, and removes pinned translations.
@MainActor
public final class SavedTranslationStore {
    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }

    /// Opens the store in Application Support, or in memory for previews and tests.
    public init(inMemory: Bool = false) throws {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let directory = URL.applicationSupportDirectory.appending(path: "Glanslate", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: directory.appending(path: "SavedTranslations.store"))
        }
        container = try ModelContainer(for: SavedTranslation.self, configurations: configuration)
    }

    /// Inserts a new translation or updates the one with the same id.
    public func save(_ draft: SavedTranslationDraft) throws {
        if let existing = item(id: draft.id) {
            existing.update(from: draft)
        } else {
            context.insert(SavedTranslation(draft: draft))
        }
        try commit()
    }

    /// Saves pending changes, or discards them when saving fails so the context — and
    /// every list showing it — keeps matching what is actually on disk.
    private func commit() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func item(id: UUID) -> SavedTranslation? {
        var descriptor = FetchDescriptor<SavedTranslation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func contains(id: UUID) -> Bool {
        item(id: id) != nil
    }

    /// Newest first, optionally filtered by text in either language.
    public func items(matching search: String = "") throws -> [SavedTranslation] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor: FetchDescriptor<SavedTranslation>
        if term.isEmpty {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.translatedText.localizedStandardContains(term) || $0.originalText.localizedStandardContains(term)
                },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        }
        return try context.fetch(descriptor)
    }

    public func count() -> Int {
        (try? context.fetchCount(FetchDescriptor<SavedTranslation>())) ?? 0
    }

    public func delete(id: UUID) throws {
        guard let item = item(id: id) else { return }
        context.delete(item)
        try commit()
    }

    public func delete(_ item: SavedTranslation) throws {
        context.delete(item)
        try commit()
    }

    public func deleteAll() throws {
        do {
            try context.delete(model: SavedTranslation.self)
        } catch {
            context.rollback()
            throw error
        }
        try commit()
    }
}
