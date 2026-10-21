import Foundation
import Testing
@testable import GlanslateCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("App versions")
struct AppVersionTests {
    @Test func parsesTagsAndPlainVersions() {
        #expect(AppVersion("v1.4.2")?.components == [1, 4, 2])
        #expect(AppVersion("V2.0")?.components == [2, 0])
        #expect(AppVersion(" 3 ")?.components == [3])
        #expect(AppVersion("1.10.0")?.description == "1.10.0")
    }

    @Test func rejectsPreReleasesAndJunk() {
        for text in ["", "v", "1.", ".1", "1..2", "1.2.0-beta.1", "1.2+5", "latest", "1.2.3.4.5", "１.２"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func comparesNumericallyAndIgnoresTrailingZeros() throws {
        let v = { (text: String) in try #require(AppVersion(text)) }
        #expect(try v("1.10") > v("1.9"))
        #expect(try v("2") > v("1.99.99"))
        #expect(try v("1.2") == v("1.2.0"))
        #expect(try Set([v("1.2"), v("1.2.0")]).count == 1)
        #expect(try !(v("1.2.0") < v("1.2")))
    }
}

@Suite("GitHub release feed")
struct GitHubReleaseFeedTests {
    private let current = AppVersion("1.0.0")!

    private func releaseJSON(
        tag: String = "v1.2.0",
        name: String? = "Glanslate 1.2",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: String = #"[{"name":"Glanslate-1.2.0.dmg","browser_download_url":"https://github.com/o/r/releases/download/v1.2.0/Glanslate-1.2.0.dmg","size":9000,"state":"uploaded"},{"name":"Glanslate-1.2.0.zip","browser_download_url":"https://github.com/o/r/releases/download/v1.2.0/Glanslate-1.2.0.zip","size":8000,"state":"uploaded","digest":"sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}]"#
    ) -> String {
        let nameField = name.map { #""\#($0)""# } ?? "null"
        return #"{"tag_name":"\#(tag)","name":\#(nameField),"body":"**Faster** overlays.\n","html_url":"https://github.com/o/r/releases/tag/\#(tag)","published_at":"2026-10-01T12:00:00Z","draft":\#(draft),"prerelease":\#(prerelease),"assets":\#(assets)}"#
    }

    private func feed(_ transport: StubTransport) throws -> GitHubReleaseFeed {
        try #require(GitHubReleaseFeed(repository: "o/r", appVersion: "1.0.0", transport: transport))
    }

    @Test func asksForTheLatestReleaseWithOnlyTheVersion() async throws {
        let transport = StubTransport(status: 200, json: releaseJSON(tag: "v1.0.0"))
        _ = try await feed(transport).check(currentVersion: current)
        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/o/r/releases/latest")
        #expect(request.httpMethod ?? "GET" == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Glanslate/1.0.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func offersANewerReleaseWithItsZipAndDigest() async throws {
        let result = try await feed(StubTransport(status: 200, json: releaseJSON())).check(currentVersion: current)
        guard case .available(let update) = result else {
            Issue.record("Expected an update, got \(result)")
            return
        }
        #expect(update.version == AppVersion("1.2.0"))
        #expect(update.title == "Glanslate 1.2")
        #expect(update.notes == "**Faster** overlays.")
        #expect(update.releasePage.absoluteString == "https://github.com/o/r/releases/tag/v1.2.0")
        #expect(update.publishedAt == Date(timeIntervalSince1970: 1_790_856_000))
        let archive = try #require(update.archive)
        #expect(archive.url.lastPathComponent == "Glanslate-1.2.0.zip")
        #expect(archive.size == 8000)
        #expect(archive.sha256 == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
    }

    @Test func sameOrOlderReleasesAreUpToDate() async throws {
        let same = try await feed(StubTransport(status: 200, json: releaseJSON(tag: "1.0"))).check(currentVersion: current)
        #expect(same == .upToDate(latest: AppVersion("1.0")))
        let older = try await feed(StubTransport(status: 200, json: releaseJSON(tag: "v0.9.5"))).check(currentVersion: current)
        #expect(older == .upToDate(latest: AppVersion("0.9.5")))
    }

    @Test func draftsPreReleasesAndOddTagsAreNeverOffered() async throws {
        for json in [releaseJSON(draft: true), releaseJSON(prerelease: true), releaseJSON(tag: "v2.0.0-beta"), releaseJSON(tag: "nightly")] {
            let result = try await feed(StubTransport(status: 200, json: json)).check(currentVersion: current)
            #expect(result == .upToDate(latest: nil))
        }
    }

    @Test func releasesWithoutAZipCanOnlyBeDownloadedByHand() async throws {
        let json = releaseJSON(name: nil, assets: #"[{"name":"Glanslate.dmg","browser_download_url":"https://example.com/a.dmg","size":1},{"name":"Glanslate.zip","browser_download_url":"https://example.com/a.zip","size":1,"state":"starter"}]"#)
        let result = try await feed(StubTransport(status: 200, json: json)).check(currentVersion: current)
        guard case .available(let update) = result else {
            Issue.record("Expected an update, got \(result)")
            return
        }
        #expect(update.archive == nil)
        #expect(update.title == "Glanslate 1.2.0")
    }

    @Test func digestsMustBeSHA256() {
        #expect(GitHubReleaseFeed.sha256(fromDigest: nil) == nil)
        #expect(GitHubReleaseFeed.sha256(fromDigest: "md5:abc") == nil)
        #expect(GitHubReleaseFeed.sha256(fromDigest: "sha256:xyz") == nil)
        #expect(GitHubReleaseFeed.sha256(fromDigest: "sha256:" + String(repeating: "A", count: 64)) == String(repeating: "a", count: 64))
    }

    @Test func statusCodesMapToUpdateErrors() async throws {
        func failure(_ status: Int, _ headers: [String: String] = [:]) async throws -> UpdateError? {
            do {
                _ = try await feed(StubTransport(status: status, json: "{}", headers: headers)).check(currentVersion: current)
                return nil
            } catch let error as UpdateError {
                return error
            }
        }
        #expect(try await failure(404) == .noPublishedRelease)
        #expect(try await failure(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1790856000"]) == .rateLimited(until: Date(timeIntervalSince1970: 1_790_856_000)))
        #expect(try await failure(429) == .rateLimited(until: nil))
        #expect(try await failure(403) == .unexpectedResponse)
        #expect(try await failure(500) == .unexpectedResponse)
        #expect(try await failure(200) == .unexpectedResponse, "A body that isn't a release")
    }

    @Test func transportFailuresBecomeNetworkErrors() async throws {
        let offline = StubTransport([.failure(URLError(.notConnectedToInternet))])
        await #expect(throws: UpdateError.network(.offline)) { try await feed(offline).check(currentVersion: current) }
        let cancelled = StubTransport([.failure(URLError(.cancelled))])
        await #expect(throws: CancellationError.self) { try await feed(cancelled).check(currentVersion: current) }
    }

    @Test func repositoryMustBeOwnerAndName() {
        #expect(GitHubReleaseFeed(repository: "hkilimci/glanslate", appVersion: "1") != nil)
        for repository in ["", "glanslate", "a/b/c", "/b", "a/", "../b", "a/..", "a b/c", "a/b?x=1"] {
            #expect(GitHubReleaseFeed(repository: repository, appVersion: "1") == nil, "\(repository)")
        }
    }

    @Test func failuresThatCallForAManualDownload() {
        #expect(UpdateError.untrustedSignature.suggestsManualDownload)
        #expect(UpdateError.locationNotWritable.suggestsManualDownload)
        #expect(!UpdateError.network(.offline).suggestsManualDownload)
        #expect(!UpdateError.checksumMismatch.suggestsManualDownload, "A damaged download is worth retrying")
        #expect(UpdateError.launchFailed.suggestsManualDownload)
        #expect(UpdateError.installIncomplete.suggestsManualDownload)
        #expect(!UpdateError.incompatible(minimumSystem: "27.0").suggestsManualDownload, "Downloading it by hand wouldn't help")
        #expect(!UpdateError.newerVersionInstalled.suggestsManualDownload)
    }

    @Test func incompatibleUpdatesSayWhatTheyNeed() {
        #expect(UpdateError.incompatible(minimumSystem: "27.0").message.contains("macOS 27.0"))
        #expect(UpdateError.incompatible(minimumSystem: nil).message.contains("processor"))
        #expect(UpdateError.launchFailed.message.contains("went back"), "Says the previous version is in place")
    }
}
