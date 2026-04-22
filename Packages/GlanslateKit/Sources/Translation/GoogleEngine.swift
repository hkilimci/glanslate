import Foundation
import GlanslateCore
import GlanslatePlatform

public struct GoogleEngine: TranslationEngine {
    public let identifier: TranslationProvider = .google
    public let http: HTTPClient
    public let keychain: KeychainStore
    public let keyAccount: String
    public let projectAccount: String

    public init(
        http: HTTPClient = HTTPClient(),
        keychain: KeychainStore = KeychainStore(),
        keyAccount: String = "google.apiKey",
        projectAccount: String = "google.projectId"
    ) {
        self.http = http
        self.keychain = keychain
        self.keyAccount = keyAccount
        self.projectAccount = projectAccount
    }

    public func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus {
        let key = (try? keychain.get(keyAccount)) ?? nil
        guard let key, !key.isEmpty else { return .unsupported }
        return .supported
    }

    public func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [Translation] {
        guard let key = try keychain.get(keyAccount), !key.isEmpty else {
            throw GlanslateError.missingAPIKey(.google)
        }
        var results: [Translation] = []
        for batch in blocks.chunked(into: 1024) {
            try Task.checkCancellation()
            let url = URL(string: "https://language.googleapis.com/language/translate/v2?key=\(key)")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "q": batch.map { $0.text },
                "target": to.bcp47,
            ].merging(from.flatMap { $0 == .auto ? nil : ["source": $0.bcp47] } ?? [:]) { a, _ in a }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await http.perform(req)
            guard (200...299).contains(resp.statusCode) else {
                throw GlanslateError.translation(provider: .google, reason: "HTTP \(resp.statusCode)")
            }
            struct GoogleResponse: Decodable {
                struct T: Decodable { let translatedText: String }
                let translations: [T]
            }
            let decoded: GoogleResponse
            do {
                decoded = try JSONDecoder().decode(GoogleResponse.self, from: data)
            } catch {
                throw GlanslateError.translation(provider: .google, reason: "Decode failed")
            }
            guard decoded.translations.count == batch.count else {
                throw GlanslateError.translation(provider: .google, reason: "Mismatched batch count")
            }
            for (i, t) in decoded.translations.enumerated() {
                results.append(Translation(
                    block: batch[i],
                    translatedText: t.translatedText,
                    targetLanguage: to,
                    provider: .google
                ))
            }
        }
        return results
    }
}
