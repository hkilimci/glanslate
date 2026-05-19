import Foundation
import GlanslateCore
import GlanslatePlatform

public struct OpenAIEngine: TranslationEngine {
    public let identifier: TranslationProvider = .openAI
    public let http: HTTPClient
    public let keychain: KeychainStore
    public let keyAccount: String
    public let model: @Sendable () async -> String

    public init(
        http: HTTPClient = HTTPClient(),
        keychain: KeychainStore = KeychainStore(),
        keyAccount: String = "openAI.apiKey",
        model: @escaping @Sendable () async -> String = { "gpt-4o-mini" }
    ) {
        self.http = http
        self.keychain = keychain
        self.keyAccount = keyAccount
        self.model = model
    }

    public func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus {
        guard let key = try? keychain.get(keyAccount), !key.isEmpty else { return .unsupported }
        return .supported
    }

    public func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [Translation] {
        guard let key = try keychain.get(keyAccount), !key.isEmpty else {
            throw GlanslateError.missingAPIKey(.openAI)
        }
        guard !blocks.isEmpty else { return [] }
        try Task.checkCancellation()

        let url = URL(string: "https://api.openai.com/v1/responses")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "translations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string"],
                            "text": ["type": "string"],
                        ],
                        "required": ["id", "text"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["translations"],
            "additionalProperties": false,
        ]

        let sourceHint = from.map { "source=\($0.bcp47)" } ?? "source=auto"
        let target = to.bcp47
        let payload: [[String: Any]] = blocks.map { ["id": $0.id.uuidString, "text": $0.text] }
        let input = """
        Translate each block's text from \(sourceHint) to \(target).
        Preserve line breaks. Keep proper nouns, code identifiers, URLs, and numbers intact.
        Return a JSON object matching the schema.
        Input: \(String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "[]")
        """

        let body: [String: Any] = [
            "model": await model(),
            "input": input,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "TranslatedBlocks",
                    "schema": schema,
                    "strict": true,
                ],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await http.perform(req)
        guard (200...299).contains(resp.statusCode) else {
            throw GlanslateError.translation(provider: .openAI, reason: "HTTP \(resp.statusCode)")
        }

        struct ResponsesShape: Decodable {
            struct Out: Decodable {
                struct Content: Decodable {
                    let type: String
                    let text: String?
                }
                let content: [Content]?
            }
            let output: [Out]?
            let output_text: String?
        }
        let shape: ResponsesShape
        do {
            shape = try JSONDecoder().decode(ResponsesShape.self, from: data)
        } catch {
            throw GlanslateError.translation(provider: .openAI, reason: "Decode outer failed")
        }
        let rawJSON: String = shape.output_text
            ?? shape.output?.flatMap { $0.content ?? [] }.compactMap { $0.text }.joined() ?? ""
        guard let jsonData = rawJSON.data(using: .utf8) else {
            throw GlanslateError.translation(provider: .openAI, reason: "Empty response")
        }
        struct Translations: Decodable {
            struct Item: Decodable { let id: String; let text: String }
            let translations: [Item]
        }
        let parsed: Translations
        do {
            parsed = try JSONDecoder().decode(Translations.self, from: jsonData)
        } catch {
            throw GlanslateError.translation(provider: .openAI, reason: "Decode schema failed")
        }
        var byID: [String: String] = [:]
        for t in parsed.translations { byID[t.id] = t.text }
        return try blocks.map { b in
            guard let text = byID[b.id.uuidString] else {
                throw GlanslateError.translation(provider: .openAI, reason: "Missing translation for block")
            }
            return Translation(
                block: b,
                translatedText: text,
                targetLanguage: to,
                provider: .openAI
            )
        }
    }
}
