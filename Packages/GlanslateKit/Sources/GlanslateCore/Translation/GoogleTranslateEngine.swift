import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google Cloud Translation – Basic (v2), authenticated with an API key in the
/// `X-Goog-Api-Key` header. (The Advanced v3 API doesn't accept API keys.)
public struct GoogleTranslateEngine: TranslationEngine {
    public let provider = TranslationProvider.google
    private let credentials: any CredentialProviding
    private let client: ProviderClient

    static let endpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")!

    public init(credentials: any CredentialProviding, transport: any HTTPTransport) {
        self.credentials = credentials
        self.client = ProviderClient(provider: .google, transport: transport)
    }

    static func code(for language: Language) -> String {
        switch language.code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "nb": return "no"
        default: return language.baseCode
        }
    }

    public func readiness(source: Language?, target: Language) async -> EngineReadiness {
        guard let key = credentials.credential(for: .google), !key.isEmpty else { return .missingCredential }
        return .ready
    }

    public func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult {
        guard let key = credentials.credential(for: .google), !key.isEmpty else {
            throw GlanslateError.missingCredential(.google)
        }
        var output: [String] = []
        var detected: Language?
        // Google recommends at most 128 segments and about 5,000 characters per request.
        for range in TextBatcher.batches(texts, maxCount: 128, maxCharacters: 5_000) {
            let request = try Self.makeRequest(key: key, texts: Array(texts[range]), source: source, target: target)
            let response = try await client.send(request)
            let parsed = try Self.parse(response, expectedCount: range.count)
            output += parsed.texts
            detected = detected ?? parsed.detectedSource
        }
        return EngineResult(texts: output, detectedSource: detected)
    }

    struct Body: Encodable {
        let q: [String]
        let target: String
        let source: String?
        let format: String
    }

    static func makeRequest(key: String, texts: [String], source: Language?, target: Language) throws -> URLRequest {
        try ProviderClient.jsonRequest(
            url: endpoint,
            headers: ["X-Goog-Api-Key": key],
            body: Body(q: texts, target: code(for: target), source: source.map(code(for:)), format: "text")
        )
    }

    static func parse(_ response: HTTPResponse, expectedCount: Int) throws -> EngineResult {
        guard (200..<300).contains(response.status) else { throw error(for: response) }
        struct Payload: Decodable {
            struct DataWrapper: Decodable {
                struct Item: Decodable {
                    let translatedText: String
                    let detectedSourceLanguage: String?
                }
                let translations: [Item]
            }
            let data: DataWrapper
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
            throw GlanslateError.providerFailure(.google, detail: "Unreadable response")
        }
        let items = payload.data.translations
        guard items.count == expectedCount else { throw GlanslateError.incompleteResponse(.google) }
        return EngineResult(
            texts: items.map(\.translatedText),
            detectedSource: items.first?.detectedSourceLanguage.map(Language.init)
        )
    }

    static func error(for response: HTTPResponse) -> GlanslateError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                struct Reason: Decodable { let reason: String? }
                let message: String?
                let status: String?
                let errors: [Reason]?
                let details: [Reason]?
            }
            let error: Body
        }
        let body = (try? JSONDecoder().decode(Envelope.self, from: response.body))?.error
        let reasons = ((body?.errors ?? []) + (body?.details ?? [])).compactMap(\.reason) + [body?.status].compactMap { $0 }
        func has(_ needle: String) -> Bool { reasons.contains { $0.localizedCaseInsensitiveContains(needle) } }

        if has("API_KEY_INVALID") || has("keyInvalid") || response.status == 401 { return .invalidCredential(.google) }
        if has("dailyLimitExceeded") || has("quotaExceeded") { return .quotaExceeded(.google) }
        if has("RateLimitExceeded") || has("RESOURCE_EXHAUSTED") || response.status == 429 {
            return .rateLimited(.google, retryAfter: response.retryAfter)
        }
        if has("SERVICE_DISABLED") || has("accessNotConfigured") || has("BILLING") { return .serviceNotEnabled(.google) }
        if response.status == 403 { return .invalidCredential(.google) }
        return .providerFailure(.google, detail: body?.message ?? "HTTP \(response.status)")
    }
}
