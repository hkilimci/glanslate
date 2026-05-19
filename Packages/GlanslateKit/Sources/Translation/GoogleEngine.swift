import Foundation
import GlanslateCore

public struct GoogleEngine: TranslationEngine {
    public let identifier: TranslationProvider = .google
    public let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus {
        googleCode(for: to) != nil ? .supported : .unsupported
    }

    public func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [Translation] {
        guard !blocks.isEmpty else { return [] }
        guard let tl = googleCode(for: to) else {
            throw GlanslateError.unsupportedPair(.google, from: from, to: to)
        }
        try Task.checkCancellation()

        let translatedTexts = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [String] in
            for (index, block) in blocks.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await translateOne(text: block.text, tl: tl))
                }
            }
            var ordered = Array(repeating: "", count: blocks.count)
            for try await (index, text) in group {
                ordered[index] = text
            }
            return ordered
        }

        return zip(blocks, translatedTexts).map { block, text in
            Translation(
                block: block,
                translatedText: text,
                targetLanguage: to,
                provider: .google
            )
        }
    }

    /// Maps a glanslate `Language` to the language code expected by the keyless endpoint.
    /// Returns nil for `.auto`, which is never a valid translation target.
    func googleCode(for language: Language) -> String? {
        switch language {
        case .auto: return nil
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        default: return language.rawValue
        }
    }

    private func translateOne(text: String, tl: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: tl),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components.url else {
            throw GlanslateError.translation(provider: .google, reason: "Bad URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.perform(request)
        guard (200...299).contains(response.statusCode) else {
            throw GlanslateError.translation(provider: .google, reason: "HTTP \(response.statusCode)")
        }
        return try Self.parseKeylessResponse(data)
    }

    /// Parses the keyless `translate_a/single` payload: a JSON array whose first element
    /// is an array of segment arrays; each segment's first element is the translated string.
    static func parseKeylessResponse(_ data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [Any],
            let segments = json.first as? [[Any]]
        else {
            throw GlanslateError.translation(provider: .google, reason: "Decode failed")
        }
        let pieces = segments.compactMap { $0.first as? String }
        guard !pieces.isEmpty else {
            throw GlanslateError.translation(provider: .google, reason: "Empty translation")
        }
        return pieces.joined()
    }
}
