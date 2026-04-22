import Foundation

public struct TextBlock: Hashable, Sendable, Identifiable {
    public enum Source: String, Hashable, Sendable, Codable {
        case accessibility
        case vision
        case arbitrated
    }

    public let id: UUID
    public let text: String
    public let region: DisplayLocalRect
    public let detectedLanguage: Language?
    public let confidence: Double
    public let source: Source

    public init(
        id: UUID = UUID(),
        text: String,
        region: DisplayLocalRect,
        detectedLanguage: Language? = nil,
        confidence: Double = 0.0,
        source: Source
    ) {
        self.id = id
        self.text = text
        self.region = region
        self.detectedLanguage = detectedLanguage
        self.confidence = confidence
        self.source = source
    }
}
