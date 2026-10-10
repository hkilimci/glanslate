import Foundation
@testable import GlanslateCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Approximates proportional text: each character is 0.55 em wide, lines are 1.2 em tall.
struct ApproximateMeasurer: TextMeasuring {
    func size(of text: String, fontSize: CGFloat, width: CGFloat) -> CGSize {
        let charWidth = fontSize * 0.55
        var lines = 1
        var current: CGFloat = 0
        var widest: CGFloat = 0
        for word in text.split(separator: " ") {
            let wordWidth = CGFloat(word.count) * charWidth
            let needed = current == 0 ? wordWidth : current + charWidth + wordWidth
            if needed > width, current > 0 {
                widest = max(widest, current)
                lines += 1
                current = wordWidth
            } else {
                current = needed
            }
        }
        widest = max(widest, current)
        return CGSize(width: min(widest, width), height: CGFloat(lines) * fontSize * 1.2)
    }
}

struct FixedCredentials: CredentialProviding {
    var keys: [TranslationProvider: String]
    func credential(for provider: TranslationProvider) -> String? { keys[provider] }
}

/// Records requests and replies with queued responses.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<HTTPResponse, any Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<HTTPResponse, any Error>]) {
        queue = responses
    }

    convenience init(status: Int, json: String, headers: [String: String] = [:]) {
        self.init([.success(HTTPResponse(status: status, headers: headers, body: Data(json.utf8)))])
    }

    var requestCount: Int { lock.withLock { requests.count } }
    var lastRequest: URLRequest? { lock.withLock { requests.last } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let next: Result<HTTPResponse, any Error> = lock.withLock {
            requests.append(request)
            return queue.isEmpty ? .failure(URLError(.badServerResponse)) : queue.removeFirst()
        }
        return try next.get()
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: httpBody)) as? [String: Any]
    }
}

func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 16) -> RecognizedLine {
    RecognizedLine(text: text, frame: CGRect(x: x, y: y, width: width, height: height))
}
