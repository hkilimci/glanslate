import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A release newer than the running copy of Glanslate.
public struct AvailableUpdate: Hashable, Sendable {
    public let version: AppVersion
    public let title: String
    /// Release notes as published (Markdown).
    public let notes: String
    public let publishedAt: Date?
    public let releasePage: URL
    /// The zipped app to install. `nil` when the release has none, so it can only be downloaded by hand.
    public let archive: Archive?

    public struct Archive: Hashable, Sendable {
        public let url: URL
        public let size: Int
        /// Lowercase hex SHA-256 of the archive, when the feed publishes one.
        public let sha256: String?

        public init(url: URL, size: Int, sha256: String?) {
            self.url = url
            self.size = size
            self.sha256 = sha256
        }
    }

    public init(version: AppVersion, title: String, notes: String, publishedAt: Date?, releasePage: URL, archive: Archive?) {
        self.version = version
        self.title = title
        self.notes = notes
        self.publishedAt = publishedAt
        self.releasePage = releasePage
        self.archive = archive
    }
}

public enum UpdateCheckResult: Hashable, Sendable {
    /// `latest` is the newest published version, when it could be read.
    case upToDate(latest: AppVersion?)
    case available(AvailableUpdate)
}

/// Finds out whether a newer release exists. Abstracted so the interface can be tested without a network.
public protocol UpdateChecking: Sendable {
    func check(currentVersion: AppVersion) async throws -> UpdateCheckResult
}

/// Every update failure the user can see, phrased so they know what to do next.
public enum UpdateError: Error, Hashable, Sendable {
    // Checking
    case network(GlanslateError.NetworkFailure)
    case noPublishedRelease
    case rateLimited(until: Date?)
    case unexpectedResponse

    // Installing
    case downloadFailed
    case checksumMismatch
    case unexpectedContents
    case untrustedSignature
    case locationNotWritable
    /// Signed and genuine, but needs a newer macOS (named when known) or another processor.
    case incompatible(minimumSystem: String?)
    /// Another copy already put a version at least this new where Glanslate is installed.
    case newerVersionInstalled
    /// Nothing was swapped in.
    case installFailed
    /// The new copy was swapped in but wouldn't open, so the previous copy was put back.
    case launchFailed
    /// Swapping in or putting back a copy failed partway; the installed app may not open.
    case installIncomplete

    public var title: String {
        switch self {
        case .network(.offline): return "You’re offline"
        case .network(.timedOut): return "GitHub didn’t respond"
        case .network(.unreachable): return "Can’t reach GitHub"
        case .noPublishedRelease: return "No releases found"
        case .rateLimited: return "Too many update checks"
        case .unexpectedResponse: return "Couldn’t check for updates"
        case .downloadFailed: return "Couldn’t download the update"
        case .checksumMismatch: return "The download was damaged"
        case .unexpectedContents: return "The update couldn’t be opened"
        case .untrustedSignature: return "The update isn’t signed by Glanslate’s developer"
        case .locationNotWritable: return "Glanslate can’t replace itself"
        case .incompatible: return "This update doesn’t run on this Mac"
        case .newerVersionInstalled: return "A newer Glanslate is already installed"
        case .installFailed: return "Couldn’t install the update"
        case .launchFailed: return "The new version didn’t open"
        case .installIncomplete: return "Couldn’t finish updating"
        }
    }

    public var message: String {
        switch self {
        case .network(.offline): return "Connect to the internet and try again."
        case .network(.timedOut): return "The request took too long. Try again in a moment."
        case .network(.unreachable): return "Check your connection and try again."
        case .noPublishedRelease: return "There’s no published release of Glanslate yet."
        case .rateLimited(let until):
            if let until, until > Date() {
                let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
                return "GitHub limits how often it can be asked. Try again in \(minutes) minute\(minutes == 1 ? "" : "s")."
            }
            return "GitHub limits how often it can be asked. Try again later."
        case .unexpectedResponse: return "GitHub returned a response Glanslate didn’t understand. Try again later."
        case .downloadFailed: return "Try again, or download it from the release page."
        case .checksumMismatch: return "It didn’t match the published file, so nothing was installed. Try again."
        case .unexpectedContents: return "The download didn’t contain a matching copy of Glanslate. Download it from the release page instead."
        case .untrustedSignature: return "Its signature doesn’t match this copy, so nothing was installed. Download it from the release page instead."
        case .locationNotWritable: return "It’s in a folder you can’t change. Download the update and move it to Applications."
        case .incompatible(let minimum?): return "It needs macOS \(minimum) or later, so nothing was installed."
        case .incompatible(nil): return "It isn’t built for this Mac’s processor, so nothing was installed."
        case .newerVersionInstalled: return "Quit and reopen Glanslate to use it."
        case .installFailed: return "Glanslate is unchanged. Try again, or download the update from the release page."
        case .launchFailed: return "Glanslate went back to the version you had. Try again, or download the update from the release page."
        case .installIncomplete: return "Glanslate may not open. Download the new version from the release page and move it to Applications."
        }
    }

    /// Whether downloading by hand from the release page is the way forward.
    public var suggestsManualDownload: Bool {
        switch self {
        case .downloadFailed, .unexpectedContents, .untrustedSignature, .locationNotWritable, .installFailed, .launchFailed, .installIncomplete:
            return true
        default: return false
        }
    }
}

/// Reads the newest published release of a public GitHub repository.
///
/// Drafts and pre-releases are never offered. The release's tag names its version
/// (`v1.4.2`), and its first `.zip` asset is the app to install.
public struct GitHubReleaseFeed: UpdateChecking {
    public let repository: String
    private let userAgent: String
    private let transport: any HTTPTransport

    /// `repository` is `owner/name`; returns `nil` for anything else.
    public init?(repository: String, appVersion: String, transport: any HTTPTransport = URLSessionTransport()) {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed.contains) && $0 != "." && $0 != ".." }) else {
            return nil
        }
        self.repository = repository
        userAgent = "Glanslate/\(appVersion)"
        self.transport = transport
    }

    var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public func check(currentVersion: AppVersion) async throws -> UpdateCheckResult {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub rejects requests without one. It carries only the app version.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do {
            try Task.checkCancellation()
            response = try await transport.send(request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw UpdateError.network(GlanslateError.NetworkFailure(error))
        }
        guard response.status == 200 else { throw Self.error(for: response) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let release = try? decoder.decode(Release.self, from: response.body) else {
            throw UpdateError.unexpectedResponse
        }
        return Self.result(for: release, current: currentVersion)
    }

    static func result(for release: Release, current: AppVersion) -> UpdateCheckResult {
        guard !release.draft, !release.prerelease, let version = AppVersion(release.tagName) else {
            return .upToDate(latest: nil)
        }
        guard version > current else { return .upToDate(latest: version) }

        let archive = release.assets
            .first { ($0.state ?? "uploaded") == "uploaded" && $0.name.lowercased().hasSuffix(".zip") }
            .map { AvailableUpdate.Archive(url: $0.browserDownloadURL, size: $0.size, sha256: sha256(fromDigest: $0.digest)) }
        let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .available(AvailableUpdate(
            version: version,
            title: name.isEmpty ? "Glanslate \(version)" : name,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            publishedAt: release.publishedAt,
            releasePage: release.htmlURL,
            archive: archive
        ))
    }

    /// GitHub publishes asset digests as `sha256:<hex>`.
    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    static func error(for response: HTTPResponse) -> UpdateError {
        switch response.status {
        case 404:
            // Also what a private repository looks like to an anonymous request.
            return .noPublishedRelease
        case 403, 429:
            guard response.status == 429 || response.header("X-RateLimit-Remaining") == "0" else { return .unexpectedResponse }
            if let reset = response.header("X-RateLimit-Reset").flatMap(TimeInterval.init) {
                return .rateLimited(until: Date(timeIntervalSince1970: reset))
            }
            return .rateLimited(until: response.retryAfter.map { Date().addingTimeInterval($0) })
        default:
            return .unexpectedResponse
        }
    }

    struct Release: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let publishedAt: Date?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body, htmlURL = "html_url", publishedAt = "published_at", draft, prerelease, assets
        }
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int
        let state: String?
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, browserDownloadURL = "browser_download_url", size, state, digest
        }
    }
}

public extension GlanslateError.NetworkFailure {
    /// How a failed request should be described to the user.
    init(_ error: URLError) {
        self = ProviderClient.networkFailure(for: error)
    }
}
