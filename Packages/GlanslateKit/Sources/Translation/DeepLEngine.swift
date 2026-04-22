import Foundation
import GlanslateCore
import GlanslatePlatform

public struct DeepLEngine: TranslationEngine {
    public let identifier: TranslationProvider = .deepL
    public let http: HTTPClient
    public let keychain: KeychainStore
    public let keyAccount: String

    public init(http: HTTPClient = HTTPClient(), keychain: KeychainStore = KeychainStore(), keyAccount: String = "deepL.apiKey") {
        self.http = http
        self.keychain = keychain
        self.keyAccount = keyAccount
    }

    public func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus {
        guard let key = try? keychain.get(keyAccount), !key.isEmpty else { return .unsupported }
        if to == .zhHant { return .unsupported }
        return .supported
    }

    public func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [Translation] {
        guard let key = try keychain.get(keyAccount), !key.isEmpty else {
            throw GlanslateError.missingAPIKey(.deepL)
        }
        let base = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        var results: [Translation] = []
        // Batch up to 50.
        let batches = blocks.chunked(into: 50)
        for batch in batches {
            try Task.checkCancellation()
            let url = URL(string: "\(base)/v2/translate")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [
                URLQueryItem(name: "target_lang", value: deepLCode(to).uppercased()),
                URLQueryItem(name: "preserve_formatting", value: "1"),
            ]
            if let from = from, let code = deepLCodeOptional(from) {
                body.queryItems?.append(URLQueryItem(name: "source_lang", value: code.uppercased()))
            }
            for b in batch {
                body.queryItems?.append(URLQueryItem(name: "text", value: b.text))
            }
            req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

            let (data, http) = try await http.perform(req)
            guard (200...299).contains(http.statusCode) else {
                throw GlanslateError.translation(provider: .deepL, reason: "HTTP \(http.statusCode)")
            }
            struct DeepLResponse: Decodable {
                struct T: Decodable { let text: String; let detected_source_language: String? }
                let translations: [T]
            }
            let decoded: DeepLResponse
            do {
                decoded = try JSONDecoder().decode(DeepLResponse.self, from: data)
            } catch {
                throw GlanslateError.translation(provider: .deepL, reason: "Decode failed")
            }
            guard decoded.translations.count == batch.count else {
                throw GlanslateError.translation(provider: .deepL, reason: "Mismatched batch count")
            }
            for (i, t) in decoded.translations.enumerated() {
                results.append(Translation(
                    block: batch[i],
                    translatedText: t.text,
                    targetLanguage: to,
                    provider: .deepL
                ))
            }
        }
        return results
    }

    private func deepLCode(_ l: Language) -> String {
        switch l {
        case .zhHans: return "ZH"
        case .zhHant: return "ZH"
        default: return l.rawValue
        }
    }

    private func deepLCodeOptional(_ l: Language) -> String? {
        if l == .auto { return nil }
        return deepLCode(l)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
