import Foundation
import Testing
@testable import GlanslateCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("DeepL adapter")
struct DeepLAdapterTests {
    @Test func freeKeysUseTheFreeHostAndHeaderAuth() async throws {
        let transport = StubTransport(status: 200, json: #"{"translations":[{"detected_source_language":"FR","text":"Hello"},{"detected_source_language":"FR","text":"Thanks"}]}"#)
        let engine = DeepLEngine(credentials: FixedCredentials(keys: [.deepL: "abc:fx"]), transport: transport)
        let result = try await engine.translate(["Bonjour", "Merci"], source: nil, target: .english)

        #expect(result.texts == ["Hello", "Thanks"])
        #expect(result.detectedSource == .french)
        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString == "https://api-free.deepl.com/v2/translate")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key abc:fx")
        let body = try #require(request.jsonBody)
        #expect(body["text"] as? [String] == ["Bonjour", "Merci"])
        #expect(body["target_lang"] as? String == "EN-US")
        #expect(body["source_lang"] == nil)
    }

    @Test func proKeysUseTheProHostAndSourceCodes() async throws {
        let transport = StubTransport(status: 200, json: #"{"translations":[{"text":"a"},{"text":"b"}]}"#)
        let engine = DeepLEngine(credentials: FixedCredentials(keys: [.deepL: "pro-key"]), transport: transport)
        _ = try await engine.translate(["x", "y"], source: .chineseTraditional, target: .portuguese)
        let request = try #require(transport.lastRequest)
        #expect(request.url?.host == "api.deepl.com")
        #expect(request.jsonBody?["source_lang"] as? String == "ZH")
        #expect(request.jsonBody?["target_lang"] as? String == "PT-BR")
    }

    @Test func languageCodes() {
        #expect(DeepLEngine.targetCode(for: .chineseSimplified) == "ZH-HANS")
        #expect(DeepLEngine.targetCode(for: .chineseTraditional) == "ZH-HANT")
        #expect(DeepLEngine.targetCode(for: .norwegian) == "NB")
        #expect(DeepLEngine.targetCode(for: Language("xx")) == nil)
    }

    @Test func statusCodesMapToActionableErrors() {
        func error(_ status: Int, _ headers: [String: String] = [:]) -> GlanslateError {
            DeepLEngine.error(for: HTTPResponse(status: status, headers: headers, body: Data("{}".utf8)))
        }
        #expect(error(403) == .invalidCredential(.deepL))
        #expect(error(456) == .quotaExceeded(.deepL))
        #expect(error(429, ["Retry-After": "3"]) == .rateLimited(.deepL, retryAfter: 3))
    }

    @Test func readinessRequiresAKey() async {
        let engine = DeepLEngine(credentials: FixedCredentials(keys: [:]), transport: StubTransport([]))
        #expect(await engine.readiness(source: nil, target: .english) == .missingCredential)
    }

    @Test func largeInputsAreBatched() async throws {
        let texts = (0..<120).map { "Paragraph \($0)" }
        let first = (0..<50).map { #"{"text":"t\#($0)"}"# }.joined(separator: ",")
        let second = (50..<100).map { #"{"text":"t\#($0)"}"# }.joined(separator: ",")
        let third = (100..<120).map { #"{"text":"t\#($0)"}"# }.joined(separator: ",")
        let transport = StubTransport([first, second, third].map {
            .success(HTTPResponse(status: 200, body: Data(#"{"translations":[\#($0)]}"#.utf8)))
        })
        let engine = DeepLEngine(credentials: FixedCredentials(keys: [.deepL: "k"]), transport: transport)
        let result = try await engine.translate(texts, source: nil, target: .german)
        #expect(result.texts.count == 120)
        #expect(result.texts.last == "t119")
        #expect(transport.requestCount == 3)
    }
}

@Suite("Google adapter")
struct GoogleAdapterTests {
    @Test func requestUsesHeaderKeyAndPlainTextFormat() async throws {
        let transport = StubTransport(status: 200, json: #"{"data":{"translations":[{"translatedText":"Hola","detectedSourceLanguage":"en"}]}}"#)
        let engine = GoogleTranslateEngine(credentials: FixedCredentials(keys: [.google: "g-key"]), transport: transport)
        let result = try await engine.translate(["Hello"], source: nil, target: .chineseTraditional)
        #expect(result.texts == ["Hola"])
        #expect(result.detectedSource == .english)

        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString == "https://translation.googleapis.com/language/translate/v2")
        #expect(request.url?.query == nil, "The key never appears in the URL")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == "g-key")
        #expect(request.jsonBody?["format"] as? String == "text")
        #expect(request.jsonBody?["target"] as? String == "zh-TW")
    }

    @Test func invalidKeyAndDisabledServiceAreDistinguished() {
        let invalid = #"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#
        let disabled = #"{"error":{"code":403,"message":"Cloud Translation API has not been used","status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#
        let limited = #"{"error":{"code":403,"message":"User Rate Limit Exceeded","errors":[{"reason":"userRateLimitExceeded"}]}}"#
        #expect(GoogleTranslateEngine.error(for: HTTPResponse(status: 400, body: Data(invalid.utf8))) == .invalidCredential(.google))
        #expect(GoogleTranslateEngine.error(for: HTTPResponse(status: 403, body: Data(disabled.utf8))) == .serviceNotEnabled(.google))
        #expect(GoogleTranslateEngine.error(for: HTTPResponse(status: 403, body: Data(limited.utf8))) == .rateLimited(.google, retryAfter: nil))
    }
}

@Suite("OpenAI adapter")
struct OpenAIAdapterTests {
    private func responseJSON(_ payload: String) -> String {
        let escaped = payload.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"\#(escaped)"}]}]}"#
    }

    @Test func requestUsesStrictSchemaAndDoesNotStore() async throws {
        let transport = StubTransport(status: 200, json: responseJSON(#"{"translations":[{"id":1,"text":"World"},{"id":0,"text":"Hello"}]}"#))
        let engine = OpenAIEngine(credentials: FixedCredentials(keys: [.openAI: "sk-test"]), transport: transport, model: "gpt-5.4-mini")
        let result = try await engine.translate(["Hallo", "Welt"], source: .german, target: .english)
        #expect(result.texts == ["Hello", "World"], "Results are matched by id, not position")

        let request = try #require(transport.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(request.jsonBody)
        #expect(body["store"] as? Bool == false)
        #expect(body["model"] as? String == "gpt-5.4-mini")
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["translations"])
        #expect((body["instructions"] as? String)?.contains("German") == true)
        #expect((body["input"] as? String)?.contains("Hallo") == true)
    }

    @Test func reasoningEffortOnlyForReasoningModels() throws {
        let reasoning = try OpenAIEngine.makeRequest(key: "k", model: "gpt-5.4-mini", texts: ["a"], source: nil, target: .english)
        let classic = try OpenAIEngine.makeRequest(key: "k", model: "gpt-4.1-mini", texts: ["a"], source: nil, target: .english)
        #expect(reasoning.jsonBody?["reasoning"] != nil)
        #expect(classic.jsonBody?["reasoning"] == nil)
    }

    @Test func missingSegmentsAreIncomplete() {
        let response = HTTPResponse(status: 200, body: Data(responseJSON(#"{"translations":[{"id":0,"text":"Hello"}]}"#).utf8))
        #expect(throws: GlanslateError.incompleteResponse(.openAI)) {
            try OpenAIEngine.parse(response, expectedCount: 2, model: "m")
        }
    }

    @Test func quotaAndRateLimitsAreDistinguished() {
        let quota = #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#
        let rate = #"{"error":{"message":"Rate limit reached","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#
        let model = #"{"error":{"message":"The model does not exist","type":"invalid_request_error","param":null,"code":"model_not_found"}}"#
        #expect(OpenAIEngine.error(for: HTTPResponse(status: 429, body: Data(quota.utf8)), model: "m") == .quotaExceeded(.openAI))
        #expect(OpenAIEngine.error(for: HTTPResponse(status: 429, body: Data(rate.utf8)), model: "m") == .rateLimited(.openAI, retryAfter: nil))
        #expect(OpenAIEngine.error(for: HTTPResponse(status: 404, body: Data(model.utf8)), model: "m") == .modelUnavailable(.openAI, model: "m"))
        #expect(OpenAIEngine.error(for: HTTPResponse(status: 401, body: Data()), model: "m") == .invalidCredential(.openAI))
    }
}

@Suite("HTTP handling")
struct HTTPHandlingTests {
    @Test func transientServerErrorsAreRetriedOnce() async throws {
        let transport = StubTransport([
            .success(HTTPResponse(status: 503, body: Data())),
            .success(HTTPResponse(status: 200, body: Data(#"{"translations":[{"text":"ok"}]}"#.utf8))),
        ])
        let engine = DeepLEngine(credentials: FixedCredentials(keys: [.deepL: "k"]), transport: transport)
        let result = try await engine.translate(["x"], source: nil, target: .english)
        #expect(result.texts == ["ok"])
        #expect(transport.requestCount == 2)
    }

    @Test func persistentServerErrorsAreNotRetriedForever() async {
        let transport = StubTransport([
            .success(HTTPResponse(status: 503, body: Data())),
            .success(HTTPResponse(status: 503, body: Data())),
            .success(HTTPResponse(status: 200, body: Data())),
        ])
        let engine = DeepLEngine(credentials: FixedCredentials(keys: [.deepL: "k"]), transport: transport)
        await #expect(throws: GlanslateError.providerFailure(.deepL, detail: "HTTP 503")) {
            try await engine.translate(["x"], source: nil, target: .english)
        }
        #expect(transport.requestCount == 2)
    }

    @Test func offlineErrorsAreReportedAsNetworkFailures() async {
        let transport = StubTransport([.failure(URLError(.notConnectedToInternet))])
        let engine = GoogleTranslateEngine(credentials: FixedCredentials(keys: [.google: "k"]), transport: transport)
        await #expect(throws: GlanslateError.network(.google, .offline)) {
            try await engine.translate(["x"], source: nil, target: .english)
        }
    }

    @Test func batcherKeepsParagraphsWhole() {
        let ranges = TextBatcher.batches(["aaaa", "bbbb", "cccc", "dd"], maxCount: 10, maxCharacters: 8)
        #expect(ranges == [0..<2, 2..<4])
        #expect(TextBatcher.batches(["a very long paragraph"], maxCount: 10, maxCharacters: 5) == [0..<1])
        #expect(TextBatcher.batches([], maxCount: 10, maxCharacters: 5).isEmpty)
    }

    @Test func credentialChecksUseNoRecognizedText() async throws {
        let transport = StubTransport(status: 200, json: #"{"character_count":1200,"character_limit":500000}"#)
        let check = await CredentialVerifier(transport: transport).verify(.deepL, key: "k:fx")
        guard case .valid(let detail) = check else {
            Issue.record("Expected a valid key")
            return
        }
        #expect(detail?.contains("500") == true)
        #expect(transport.lastRequest?.url?.path == "/v2/usage")
    }
}
