import Foundation
import GlanslateCore
import SwiftData

@Model
public final class PinnedTranslation {
    @Attribute(.unique) public var id: UUID
    public var sourceText: String
    public var translatedText: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var provider: String
    public var createdAt: Date
    public var snapshotPNG: Data?

    public init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String,
        provider: String,
        createdAt: Date = Date(),
        snapshotPNG: Data? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.createdAt = createdAt
        self.snapshotPNG = snapshotPNG
    }
}

@MainActor
public protocol HistoryStoring: AnyObject {
    func pin(_ translation: Translation, thumbnail: Data?) async throws
    func list() async throws -> [PinnedTranslation]
    func delete(_ id: UUID) async throws
}

@MainActor
public final class SwiftDataHistoryStore: HistoryStoring {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public convenience init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try ModelContainer(for: PinnedTranslation.self, configurations: configuration)
        self.init(container: container)
    }

    public func pin(_ translation: Translation, thumbnail: Data?) async throws {
        let context = ModelContext(container)
        let record = PinnedTranslation(
            id: translation.id,
            sourceText: translation.block.text,
            translatedText: translation.translatedText,
            sourceLanguage: translation.block.detectedLanguage?.rawValue ?? Language.auto.rawValue,
            targetLanguage: translation.targetLanguage.rawValue,
            provider: translation.provider.rawValue,
            snapshotPNG: thumbnail
        )
        context.insert(record)
        try context.save()
    }

    public func list() async throws -> [PinnedTranslation] {
        let descriptor = FetchDescriptor<PinnedTranslation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let context = ModelContext(container)
        return try context.fetch(descriptor)
    }

    public func delete(_ id: UUID) async throws {
        let descriptor = FetchDescriptor<PinnedTranslation>(
            predicate: #Predicate<PinnedTranslation> { item in
                item.id == id
            }
        )
        let context = ModelContext(container)
        let matches = try context.fetch(descriptor)
        for item in matches {
            context.delete(item)
        }
        if !matches.isEmpty {
            try context.save()
        }
    }
}
