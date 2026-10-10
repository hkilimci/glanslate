import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The result of checking an API key from Settings.
public enum CredentialCheck: Equatable, Sendable {
    case valid(detail: String?)
    case invalid(GlanslateError)
}

/// Checks an API key with the cheapest documented request for each provider.
/// No recognized text is sent.
public struct CredentialVerifier: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func verify(_ provider: TranslationProvider, key rawKey: String) async -> CredentialCheck {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, provider.requiresCredential else { return .invalid(.missingCredential(provider)) }
        let client = ProviderClient(provider: provider, transport: transport, maxAttempts: 1)
        do {
            let response = try await client.send(Self.request(for: provider, key: key))
            return Self.interpret(response, provider: provider)
        } catch let error as GlanslateError {
            return .invalid(error)
        } catch {
            return .invalid(.cancelled)
        }
    }

    static func request(for provider: TranslationProvider, key: String) throws -> URLRequest {
        switch provider {
        case .deepL:
            var request = URLRequest(url: DeepLEngine.baseURL(forKey: key).appendingPathComponent("v2/usage"))
            request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            return request
        case .google:
            return try GoogleTranslateEngine.makeRequest(key: key, texts: ["Hello"], source: .english, target: .spanish)
        case .openAI:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return request
        case .apple:
            throw GlanslateError.noProviderAvailable
        }
    }

    static func interpret(_ response: HTTPResponse, provider: TranslationProvider) -> CredentialCheck {
        switch provider {
        case .deepL:
            guard response.status == 200 else { return .invalid(DeepLEngine.error(for: response)) }
            struct Usage: Decodable {
                let character_count: Int?
                let character_limit: Int?
            }
            guard let usage = try? JSONDecoder().decode(Usage.self, from: response.body),
                  let used = usage.character_count, let limit = usage.character_limit, limit > 0 else {
                return .valid(detail: nil)
            }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let usedText = formatter.string(from: NSNumber(value: used)) ?? "\(used)"
            let limitText = formatter.string(from: NSNumber(value: limit)) ?? "\(limit)"
            return .valid(detail: "\(usedText) of \(limitText) characters used this period")
        case .google:
            guard response.status == 200 else { return .invalid(GoogleTranslateEngine.error(for: response)) }
            return .valid(detail: nil)
        case .openAI:
            // A restricted key may be unable to list models yet still translate.
            if response.status == 200 { return .valid(detail: nil) }
            if response.status == 403 { return .valid(detail: "This key can’t list models; translation may still work.") }
            return .invalid(OpenAIEngine.error(for: response, model: ""))
        case .apple:
            return .valid(detail: nil)
        }
    }
}
