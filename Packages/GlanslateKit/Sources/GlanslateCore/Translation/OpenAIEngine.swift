import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI Responses API (`POST /v1/responses`) with a strict JSON schema, so
/// every paragraph comes back under its own id. Requests set `store: false`.
public struct OpenAIEngine: TranslationEngine {
    public let provider = TranslationProvider.openAI
    public static let defaultModel = "gpt-5.4-mini"
    public static let suggestedModels = ["gpt-5.4-mini", "gpt-5.4-nano", "gpt-6-luna", "gpt-4.1-mini"]
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    private let credentials: any CredentialProviding
    private let client: ProviderClient
    private let model: String

    public init(credentials: any CredentialProviding, transport: any HTTPTransport, model: String) {
        self.credentials = credentials
        self.client = ProviderClient(provider: .openAI, transport: transport)
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
    }

    public func readiness(source: Language?, target: Language) async -> EngineReadiness {
        guard let key = credentials.credential(for: .openAI), !key.isEmpty else { return .missingCredential }
        return .ready
    }

    public func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult {
        guard let key = credentials.credential(for: .openAI), !key.isEmpty else {
            throw GlanslateError.missingCredential(.openAI)
        }
        var output: [String] = []
        for range in TextBatcher.batches(texts, maxCount: 80, maxCharacters: 12_000) {
            let batch = Array(texts[range])
            let request = try Self.makeRequest(key: key, model: model, texts: batch, source: source, target: target)
            let response = try await client.send(request)
            output += try Self.parse(response, expectedCount: batch.count, model: model)
        }
        return EngineResult(texts: output)
    }

    // MARK: Request

    struct Segment: Codable, Equatable {
        let id: Int
        let text: String
    }

    static func instructions(source: Language?, target: Language) -> String {
        let from = source.map { "from \($0.englishName) (\($0.code)) " } ?? ""
        return """
        You translate text captured from a screen. Translate each segment \(from)into \(target.englishName) (\(target.code)). \
        Segments are paragraphs or labels from the same screen, listed in reading order; use them as context for one another \
        but translate each one separately. Preserve meaning, tone, and line breaks. Keep numbers, URLs, code, and product \
        names unchanged. If a segment is already in \(target.englishName), return it unchanged. Return one translation for \
        every segment id and nothing else.
        """
    }

    static func makeRequest(key: String, model: String, texts: [String], source: Language?, target: Language) throws -> URLRequest {
        struct Input: Encodable { let segments: [Segment] }
        let segments = texts.enumerated().map { Segment(id: $0.offset, text: $0.element) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let input = String(decoding: try encoder.encode(Input(segments: segments)), as: UTF8.self)
        let characters = texts.reduce(0) { $0 + $1.count }

        let body = RequestBody(
            model: model,
            instructions: instructions(source: source, target: target),
            input: input,
            text: .init(format: .init(name: "translations", schema: .translations, strict: true, type: "json_schema")),
            store: false,
            max_output_tokens: min(32_000, 2_048 + characters * 3),
            reasoning: usesReasoning(model) ? .init(effort: "low") : nil
        )
        return try ProviderClient.jsonRequest(url: endpoint, headers: ["Authorization": "Bearer \(key)"], body: body)
    }

    /// Reasoning models accept a reasoning effort; others reject the parameter.
    static func usesReasoning(_ model: String) -> Bool {
        let name = model.lowercased()
        return name.hasPrefix("gpt-5") || name.hasPrefix("gpt-6") || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4")
    }

    struct RequestBody: Encodable {
        struct TextOptions: Encodable {
            struct Format: Encodable {
                let name: String
                let schema: JSONSchema
                let strict: Bool
                let type: String
            }
            let format: Format
        }
        struct Reasoning: Encodable { let effort: String }

        let model: String
        let instructions: String
        let input: String
        let text: TextOptions
        let store: Bool
        let max_output_tokens: Int
        let reasoning: Reasoning?
    }

    /// The structured-output schema: `{ "translations": [{ "id": Int, "text": String }] }`.
    indirect enum JSONSchema: Encodable, Sendable {
        case object([(String, JSONSchema)])
        case array(JSONSchema)
        case string
        case integer

        static let translations = JSONSchema.object([
            ("translations", .array(.object([("id", .integer), ("text", .string)]))),
        ])

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case .string: try container.encode("string", forKey: Key("type"))
            case .integer: try container.encode("integer", forKey: Key("type"))
            case .array(let items):
                try container.encode("array", forKey: Key("type"))
                try container.encode(items, forKey: Key("items"))
            case .object(let properties):
                try container.encode("object", forKey: Key("type"))
                var nested = container.nestedContainer(keyedBy: Key.self, forKey: Key("properties"))
                for (name, schema) in properties { try nested.encode(schema, forKey: Key(name)) }
                try container.encode(properties.map(\.0), forKey: Key("required"))
                try container.encode(false, forKey: Key("additionalProperties"))
            }
        }
    }

    // MARK: Response

    static func parse(_ response: HTTPResponse, expectedCount: Int, model: String) throws -> [String] {
        guard (200..<300).contains(response.status) else { throw error(for: response, model: model) }

        struct Payload: Decodable {
            struct Item: Decodable {
                struct Content: Decodable {
                    let type: String
                    let text: String?
                }
                let type: String
                let content: [Content]?
            }
            let status: String?
            let output: [Item]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
            throw GlanslateError.providerFailure(.openAI, detail: "Unreadable response")
        }
        let contents = payload.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if contents.contains(where: { $0.type == "refusal" }) {
            throw GlanslateError.providerFailure(.openAI, detail: "Refused")
        }
        let json = contents.filter { $0.type == "output_text" }.compactMap(\.text).joined()
        guard payload.status != "incomplete", let data = json.data(using: .utf8) else {
            throw GlanslateError.incompleteResponse(.openAI)
        }

        struct Result: Decodable { let translations: [Segment] }
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw GlanslateError.incompleteResponse(.openAI)
        }
        var byID: [Int: String] = [:]
        for segment in result.translations { byID[segment.id] = segment.text }
        return try (0..<expectedCount).map { id in
            guard let text = byID[id] else { throw GlanslateError.incompleteResponse(.openAI) }
            return text
        }
    }

    static func error(for response: HTTPResponse, model: String) -> GlanslateError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                let message: String?
                let type: String?
                let code: String?
            }
            let error: Body
        }
        let body = (try? JSONDecoder().decode(Envelope.self, from: response.body))?.error
        let code = body?.code ?? body?.type ?? ""
        switch response.status {
        case 401: return .invalidCredential(.openAI)
        case 429:
            if code == "insufficient_quota" || code == "credit_balance_exhausted" { return .quotaExceeded(.openAI) }
            return .rateLimited(.openAI, retryAfter: response.retryAfter)
        case 400, 403, 404:
            if code == "model_not_found" || code.contains("model") { return .modelUnavailable(.openAI, model: model) }
            if response.status == 403 { return .invalidCredential(.openAI) }
            return .providerFailure(.openAI, detail: body?.message ?? "HTTP \(response.status)")
        default:
            return .providerFailure(.openAI, detail: body?.message ?? "HTTP \(response.status)")
        }
    }
}
