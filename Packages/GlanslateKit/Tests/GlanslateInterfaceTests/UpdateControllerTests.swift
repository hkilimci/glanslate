import Foundation
import GlanslateCore
import GlanslateSystem
import Testing
@testable import GlanslateInterface

/// Answers update checks with a fixed result.
final class StubUpdateChecker: UpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UpdateCheckResult, UpdateError>
    private var count = 0

    init(_ result: Result<UpdateCheckResult, UpdateError>) {
        self.result = result
    }

    var calls: Int { lock.withLock { count } }

    func check(currentVersion: AppVersion) async throws -> UpdateCheckResult {
        let result = lock.withLock {
            count += 1
            return self.result
        }
        return try result.get()
    }
}

/// Records installs instead of replacing a bundle.
final class StubUpdateInstaller: UpdateInstalling, @unchecked Sendable {
    let availability: SelfUpdateAvailability
    private let failure: UpdateError?
    private let revertFails: Bool
    private let lock = NSLock()
    private var versions: [AppVersion] = []
    private var finishCount = 0
    private var revertCount = 0

    init(availability: SelfUpdateAvailability = .available, failure: UpdateError? = nil, revertFails: Bool = false) {
        self.availability = availability
        self.failure = failure
        self.revertFails = revertFails
    }

    var installed: [AppVersion] { lock.withLock { versions } }
    var finished: Int { lock.withLock { finishCount } }
    var reverted: Int { lock.withLock { revertCount } }

    func install(_ update: AvailableUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> InstalledUpdate {
        progress(0.5)
        // Yields, as a real download would, so a second request can arrive meanwhile.
        await Task.yield()
        if let failure { throw failure }
        lock.withLock { versions.append(update.version) }
        let workspace = URL(fileURLWithPath: "/tmp/glanslate-stub-workspace")
        return InstalledUpdate(previousCopy: workspace.appendingPathComponent("Glanslate.app"), workspace: workspace)
    }

    func finish(_ installed: InstalledUpdate) {
        lock.withLock { finishCount += 1 }
    }

    func revert(_ installed: InstalledUpdate) throws {
        lock.withLock { revertCount += 1 }
        if revertFails { throw UpdateError.installIncomplete }
    }
}

extension AvailableUpdate {
    static func sample(_ version: String = "1.2.0") -> AvailableUpdate {
        AvailableUpdate(
            version: AppVersion(version)!,
            title: "Glanslate \(version)",
            notes: "- **Faster** overlays on large displays\n- Subtitle style keeps its border in dark mode\n- Fixes for right-to-left text",
            publishedAt: Date(timeIntervalSince1970: 1_790_856_000),
            releasePage: URL(string: "https://github.com/hkilimci/glanslate/releases/tag/v\(version)")!,
            archive: .init(url: URL(string: "https://github.com/hkilimci/glanslate/releases/download/v\(version)/Glanslate-\(version).zip")!, size: 9_000_000, sha256: nil)
        )
    }
}

@Suite("Update controller")
@MainActor
struct UpdateControllerTests {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "glanslate.tests.\(UUID().uuidString)")!)
    }

    private func controller(
        _ result: Result<UpdateCheckResult, UpdateError>,
        installer: StubUpdateInstaller = StubUpdateInstaller(),
        settings: AppSettings? = nil
    ) -> (UpdateController, AppSettings) {
        let settings = settings ?? makeSettings()
        let controller = UpdateController(currentVersion: AppVersion("1.0.0")!, settings: settings, checker: StubUpdateChecker(result), installer: installer)
        return (controller, settings)
    }

    @Test func automaticChecksAnnounceANewVersionOnce() async {
        let (updates, settings) = controller(.success(.available(.sample())))
        var announced: [AppVersion] = []
        updates.onUpdateFound = { announced.append($0.version) }

        await updates.runCheck(userInitiated: false)
        await updates.runCheck(userInitiated: false)

        #expect(announced == [AppVersion("1.2.0")!])
        #expect(updates.available == .sample())
        #expect(updates.announcedUpdate == .sample())
        #expect(updates.activity == .idle)
        #expect(settings.lastUpdateCheck != nil)
    }

    @Test func skippedVersionsAreNotAnnounced() async {
        let settings = makeSettings()
        settings.skippedUpdateVersion = "1.2"
        let (updates, _) = controller(.success(.available(.sample())), settings: settings)
        var announced = false
        updates.onUpdateFound = { _ in announced = true }

        await updates.runCheck(userInitiated: false)

        #expect(!announced)
        #expect(updates.available == .sample(), "Settings still shows it")
        #expect(updates.announcedUpdate == nil, "The menu bar doesn't")
    }

    @Test func skippingHidesTheUpdateFromTheMenuBar() async {
        let (updates, settings) = controller(.success(.available(.sample())))
        await updates.runCheck(userInitiated: true)
        updates.skip()
        #expect(settings.skippedUpdateVersion == "1.2.0")
        #expect(updates.announcedUpdate == nil)
    }

    @Test func upToDateClearsAnEarlierUpdate() async {
        let (updates, _) = controller(.success(.upToDate(latest: AppVersion("1.0.0"))))
        await updates.runCheck(userInitiated: true)
        #expect(updates.isUpToDate)
        #expect(updates.available == nil)
        #expect(updates.problem == nil)
    }

    @Test func onlyChecksTheUserStartedReportProblems() async {
        let (updates, settings) = controller(.failure(.network(.offline)))
        await updates.runCheck(userInitiated: false)
        #expect(updates.problem == nil)
        #expect(settings.lastUpdateCheck == nil, "A failed check is retried within the hour")

        await updates.runCheck(userInitiated: true)
        #expect(updates.problem == .network(.offline))
    }

    @Test func automaticChecksRunOnceADayWhileEnabled() {
        let (updates, settings) = controller(.success(.upToDate(latest: nil)))
        let now = Date()
        #expect(updates.isAutomaticCheckDue(now: now), "Never checked")
        settings.lastUpdateCheck = now.addingTimeInterval(-3_600)
        #expect(!updates.isAutomaticCheckDue(now: now))
        settings.lastUpdateCheck = now.addingTimeInterval(-UpdateController.checkInterval - 1)
        #expect(updates.isAutomaticCheckDue(now: now))
        settings.lastUpdateCheck = now.addingTimeInterval(86_400 * 30)
        #expect(updates.isAutomaticCheckDue(now: now), "A clock set backwards doesn't postpone checks")
        settings.checksForUpdates = false
        #expect(!updates.isAutomaticCheckDue(now: now))
    }

    @Test func installingRelaunchesAndThenDiscardsThePreviousCopy() async {
        let installer = StubUpdateInstaller()
        let (updates, _) = controller(.success(.available(.sample())), installer: installer)
        var relaunched = false
        updates.relaunch = { willQuit, _ in
            relaunched = true
            willQuit()
        }
        await updates.runCheck(userInitiated: true)

        await updates.install()?.value

        #expect(installer.installed == [AppVersion("1.2.0")!])
        #expect(relaunched)
        #expect(installer.finished == 1)
        #expect(installer.reverted == 0)
        #expect(updates.activity == .installing)
    }

    @Test func aNewCopyThatWontOpenIsReplacedByThePreviousOne() async {
        let installer = StubUpdateInstaller()
        let (updates, _) = controller(.success(.available(.sample())), installer: installer)
        updates.relaunch = { _, failed in failed() }
        await updates.runCheck(userInitiated: true)

        await updates.install()?.value

        #expect(installer.reverted == 1)
        #expect(installer.finished == 0)
        #expect(updates.problem == .launchFailed)
        #expect(updates.activity == .idle)
        #expect(updates.available == .sample(), "It can be tried again")
    }

    @Test func aFailedRevertIsReportedAsIncomplete() async {
        let (updates, _) = controller(.success(.available(.sample())), installer: StubUpdateInstaller(revertFails: true))
        updates.relaunch = { _, failed in failed() }
        await updates.runCheck(userInitiated: true)

        await updates.install()?.value

        #expect(updates.problem == .installIncomplete)
        #expect(updates.problem?.suggestsManualDownload == true)
    }

    @Test func aSecondClickDoesNotStartAnotherInstall() async {
        let installer = StubUpdateInstaller()
        let (updates, _) = controller(.success(.available(.sample())), installer: installer)
        updates.relaunch = { _, _ in }
        await updates.runCheck(userInitiated: true)

        let first = updates.install()
        let second = updates.install()
        #expect(first != nil)
        #expect(second == nil)
        #expect(updates.activity == .downloading(0), "Claimed before the task runs")
        #expect(updates.checkNow() == nil, "No check while installing")
        await first?.value

        #expect(installer.installed.count == 1)
    }

    @Test func failedInstallsKeepTheUpdateOnOffer() async {
        let (updates, _) = controller(.success(.available(.sample())), installer: StubUpdateInstaller(failure: .untrustedSignature))
        var relaunched = false
        updates.relaunch = { _, _ in relaunched = true }
        await updates.runCheck(userInitiated: true)

        await updates.install()?.value

        #expect(!relaunched)
        #expect(updates.problem == .untrustedSignature)
        #expect(updates.activity == .idle)
        #expect(updates.available == .sample())
    }
}
