import Foundation
import GlanslateCore

public struct HTTPClient: Sendable {
    public let session: URLSession
    public let timeout: TimeInterval
    public let maxRetries: Int

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 15,
        maxRetries: Int = 1
    ) {
        self.session = session
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var backoff: UInt64 = 250_000_000
        while true {
            try Task.checkCancellation()
            var req = request
            if req.timeoutInterval == 60 { req.timeoutInterval = timeout }
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: req)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < maxRetries {
                    try await Task.sleep(nanoseconds: backoff)
                    attempt += 1
                    backoff = min(1_500_000_000, backoff * 2)
                    continue
                }
                throw error
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let code = http.statusCode
            let retryable = (code == 408 || code == 429 || (500...599).contains(code))
            if retryable && attempt < maxRetries {
                try await Task.sleep(nanoseconds: backoff)
                attempt += 1
                backoff = min(1_500_000_000, backoff * 2)
                continue
            }
            return (data, http)
        }
    }
}
