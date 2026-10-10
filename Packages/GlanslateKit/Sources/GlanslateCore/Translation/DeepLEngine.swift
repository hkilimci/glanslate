import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DeepL API v2 (`POST /v2/translate`), authenticated with the
/// `Authorization: DeepL-Auth-Key` header. Free-plan keys end in `:fx` and use
/// the `api-free` host.
public struct DeepLEngine: TranslationEngine {
    public let provider = TranslationProvider.deepL
    private let credentials: any CredentialProviding
    private let client: ProviderClient

    public init(credentials: any CredentialProviding, transport: any HTTPTransport) {
        self.credentials = credentials
        self.client = ProviderClient(provider: .deepL, transport: transport)
    }

    static func baseURL(forKey key: String) -> URL {
        URL(string: key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com")!
    }

    /// Target codes. English and Portuguese must name a variant; Chinese names its script.
    static func targetCode(for language: Language) -> String? {
        switch language.code {
        case "en": return "EN-US"
        case "pt": return "PT-BR"
        case "zh-Hans": return "ZH-HANS"
        case "zh-Hant": return "ZH-HANT"
        default: return supported.contains(language.baseCode) ? language.baseCode.uppercased() : nil
        }
    }

    /// Source codes never carry a variant.
    static func sourceCode(for language: Language) -> String? {
        supported.contains(language.baseCode) ? language.baseCode.uppercased() : nil
    }

    static let supported: Set<String> = [
        "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "he", "hi", "hu", "id", "it",
        "ja", "ko", "lt", "lv", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "th", "tr",
        "uk", "vi", "zh",
    ]

    public func readiness(source: Language?, target: Language) async -> EngineReadiness {
        guard let key = credentials.credential(for: .deepL), !key.isEmpty else { return .missingCredential }
        guard Self.targetCode(for: target) != nil else { return .unsupportedPair }
        if let source, Self.sourceCode(for: source) == nil { return .unsupportedPair }
        return .ready
    }

    public func translate(_ texts: [String], source: Language?, target: Language) async throws -> EngineResult {
        guard let key = credentials.credential(for: .deepL), !key.isEmpty else {
            throw GlanslateError.missingCredential(.deepL)
        }
        guard let targetCode = Self.targetCode(for: target) else {
            throw GlanslateError.unsupportedLanguagePair(.deepL, source: source, target: target)
        }
        let sourceCode = source.flatMap(Self.sourceCode(for:))

        var output: [String] = []
        var detected: Language?
        // DeepL caps a request at 128 KiB; stay well below with plain-text batches.
        for range in TextBatcher.batches(texts, maxCount: 50, maxCharacters: 30_000) {
            let request = try Self.makeRequest(
                key: key,
                texts: Array(texts[range]),
                sourceCode: sourceCode,
                targetCode: targetCode
            )
            let response = try await client.send(request)
            let parsed = try Self.parse(response, expectedCount: range.count)
            output += parsed.texts
            detected = detected ?? parsed.detectedSource
        }
        return EngineResult(texts: output, detectedSource: detected)
    }

    struct Body: Encodable {
        let text: [String]
        let target_lang: String
        let source_lang: String?
        let preserve_formatting: Bool
    }

    static func makeRequest(key: String, texts: [String], sourceCode: String?, targetCode: String) throws -> URLRequest {
        try ProviderClient.jsonRequest(
            url: baseURL(forKey: key).appendingPathComponent("v2/translate"),
            headers: ["Authorization": "DeepL-Auth-Key \(key)"],
            body: Body(text: texts, target_lang: targetCode, source_lang: sourceCode, preserve_formatting: true)
        )
    }

    static func parse(_ response: HTTPResponse, expectedCount: Int) throws -> EngineResult {
        guard (200..<300).contains(response.status) else { throw error(for: response) }
        struct Payload: Decodable {
            struct Item: Decodable {
                let text: String
                let detected_source_language: String?
            }
            let translations: [Item]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
            throw GlanslateError.providerFailure(.deepL, detail: "Unreadable response")
        }
        guard payload.translations.count == expectedCount else { throw GlanslateError.incompleteResponse(.deepL) }
        return EngineResult(
            texts: payload.translations.map(\.text),
            detectedSource: payload.translations.first?.detected_source_language.map(Language.init)
        )
    }

    static func error(for response: HTTPResponse) -> GlanslateError {
        switch response.status {
        case 401, 403: return .invalidCredential(.deepL)
        case 456: return .quotaExceeded(.deepL)
        case 429, 529: return .rateLimited(.deepL, retryAfter: response.retryAfter)
        case 413, 414: return .providerFailure(.deepL, detail: "Request too large")
        default:
            struct Message: Decodable {
                struct Nested: Decodable { let message: String? }
                let message: String?
                let error: Nested?
            }
            let decoded = try? JSONDecoder().decode(Message.self, from: response.body)
            let detail = decoded?.message ?? decoded?.error?.message ?? "HTTP \(response.status)"
            return .providerFailure(.deepL, detail: detail)
        }
    }
}
