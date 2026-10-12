import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `Retry-After` in seconds, when the server sent one.
    public var retryAfter: TimeInterval? {
        header("Retry-After").flatMap(TimeInterval.init)
    }
}

/// Sends one HTTP request. Abstracted so providers can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// An ephemeral `URLSession` with bounded timeouts and no caches or cookies,
/// so neither recognized text nor credentials are written to disk.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Sends one cloud provider's requests only while the user's consent to it is on
/// record. Checked before every request — each batch and each retry — so consent
/// revoked during a translation stops any text that hasn't been sent yet.
public struct ConsentCheckingTransport: HTTPTransport {
    private let provider: TranslationProvider
    private let consent: any ConsentGate
    private let base: any HTTPTransport

    public init(provider: TranslationProvider, consent: any ConsentGate, base: any HTTPTransport) {
        self.provider = provider
        self.consent = consent
        self.base = base
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard await consent.hasConsent(for: provider) else { throw GlanslateError.consentDeclined(provider) }
        try Task.checkCancellation()
        return try await base.send(request)
    }
}

/// Runs provider requests with cancellation, one bounded retry for transient
/// server errors, and translation of transport failures into ``GlanslateError``.
struct ProviderClient: Sendable {
    let provider: TranslationProvider
    let transport: any HTTPTransport
    var maxAttempts = 2
    var retryDelay: Duration = .milliseconds(400)

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw GlanslateError.network(provider, Self.networkFailure(for: error))
            }
            if Self.isTransient(response.status), attempt < maxAttempts {
                try await Task.sleep(for: retryDelay * attempt)
                continue
            }
            return response
        }
    }

    static func isTransient(_ status: Int) -> Bool {
        status == 408 || status == 500 || status == 502 || status == 503 || status == 504 || status == 529
    }

    static func networkFailure(for error: URLError) -> GlanslateError.NetworkFailure {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        default:
            return .unreachable
        }
    }

    static func jsonRequest(url: URL, headers: [String: String], body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }
}

/// Splits paragraphs into request-sized batches without breaking any paragraph.
enum TextBatcher {
    static func batches(_ texts: [String], maxCount: Int, maxCharacters: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var characters = 0
        for (index, text) in texts.enumerated() {
            let length = text.count
            let full = index - start >= maxCount || (characters + length > maxCharacters && index > start)
            if full {
                ranges.append(start..<index)
                start = index
                characters = 0
            }
            characters += length
        }
        if start < texts.count { ranges.append(start..<texts.count) }
        return ranges
    }
}
