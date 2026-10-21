import Foundation
import GlanslateCore
import GlanslateSystem
import Observation
import OSLog

/// Checks for a newer release once a day and installs it when the user asks.
///
/// Automatic checks stay quiet when they fail; a check the user starts reports
/// its problem. A newly found version is announced once, unless the user skipped it.
@MainActor
@Observable
final class UpdateController {
    private static let log = Logger(subsystem: "app.glanslate", category: "update")
    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Activity: Equatable {
        case idle
        case checking
        /// Download progress from 0 to 1.
        case downloading(Double)
        case installing
    }

    let currentVersion: AppVersion
    private(set) var activity: Activity = .idle
    /// The newest release, when it's newer than this copy.
    private(set) var available: AvailableUpdate?
    /// Whether the last check found nothing newer.
    private(set) var isUpToDate = false
    /// What went wrong with the last check or install the user started.
    private(set) var problem: UpdateError?

    /// Called when an automatic check finds a version that hasn't been announced or skipped.
    @ObservationIgnored var onUpdateFound: (@MainActor (AvailableUpdate) -> Void)?
    /// Starts the installed copy and quits this one after `willQuit`, or calls `failed` if it can't start.
    @ObservationIgnored var relaunch: @MainActor (_ willQuit: @escaping @MainActor () -> Void, _ failed: @escaping @MainActor () -> Void) -> Void = {
        Relauncher.relaunch(willQuit: $0, failed: $1)
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let checker: any UpdateChecking
    @ObservationIgnored private let installer: any UpdateInstalling
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var announced: AppVersion?
    /// Identifies the current install, so progress from an earlier, cancelled one is ignored.
    @ObservationIgnored private var installNumber = 0

    init(currentVersion: AppVersion, settings: AppSettings, checker: any UpdateChecking, installer: any UpdateInstalling) {
        self.currentVersion = currentVersion
        self.settings = settings
        self.checker = checker
        self.installer = installer
    }

    var availability: SelfUpdateAvailability { installer.availability }
    var lastChecked: Date? { settings.lastUpdateCheck }

    /// The available update unless the user skipped it; the menu bar offers only this one.
    var announcedUpdate: AvailableUpdate? {
        guard let available, !isSkipped(available) else { return nil }
        return available
    }

    func isSkipped(_ update: AvailableUpdate) -> Bool {
        settings.skippedUpdateVersion.flatMap(AppVersion.init) == update.version
    }

    // MARK: Checking

    /// Checks every hour whether a day has passed since the last successful check.
    /// The first look waits a little so launch stays quick.
    func startSchedule(initialDelay: Duration = .seconds(10)) {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                if let self, self.isAutomaticCheckDue(now: Date()) {
                    await self.runCheck(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func stopSchedule() {
        schedule?.cancel()
        schedule = nil
    }

    func isAutomaticCheckDue(now: Date) -> Bool {
        guard settings.checksForUpdates, activity == .idle else { return false }
        guard let last = settings.lastUpdateCheck else { return true }
        // A clock set backwards would otherwise postpone checks indefinitely.
        return now.timeIntervalSince(last) >= Self.checkInterval || last > now
    }

    @discardableResult
    func checkNow() -> Task<Void, Never>? {
        guard activity == .idle else { return nil }
        let task = Task { await runCheck(userInitiated: true) }
        work = task
        return task
    }

    func runCheck(userInitiated: Bool) async {
        guard activity == .idle else { return }
        activity = .checking
        if userInitiated { problem = nil }
        defer { activity = .idle }

        do {
            let result = try await checker.check(currentVersion: currentVersion)
            settings.lastUpdateCheck = Date()
            problem = nil
            switch result {
            case .upToDate:
                available = nil
                isUpToDate = true
            case .available(let update):
                available = update
                isUpToDate = false
                if !userInitiated, announced != update.version, !isSkipped(update) {
                    announced = update.version
                    onUpdateFound?(update)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let failure = error as? UpdateError ?? .unexpectedResponse
            Self.log.error("Update check failed: \(String(describing: failure), privacy: .public)")
            if userInitiated { problem = failure }
        }
    }

    func skip() {
        guard let available else { return }
        settings.skippedUpdateVersion = available.version.description
    }

    // MARK: Installing

    /// Starts installing the available update. Returns `nil` when another check or install is under way.
    @discardableResult
    func install() -> Task<Void, Never>? {
        guard let update = available, activity == .idle else { return nil }
        // Claimed before the task runs, so a second click can't start another install.
        activity = .downloading(0)
        problem = nil
        installNumber += 1
        let number = installNumber
        let task = Task { await runInstall(update, number: number) }
        work = task
        return task
    }

    /// Stops a download in progress. Once the new copy is being swapped in, it can't be stopped.
    func cancelInstall() {
        guard case .downloading = activity else { return }
        work?.cancel()
    }

    private func runInstall(_ update: AvailableUpdate, number: Int) async {
        do {
            let installed = try await installer.install(update) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.installNumber == number, case .downloading = self.activity else { return }
                    self.activity = fraction >= 1 ? .installing : .downloading(fraction)
                }
            }
            activity = .installing
            let installer = installer
            relaunch({ installer.finish(installed) }, { [weak self] in self?.recover(installed) })
        } catch is CancellationError {
            activity = .idle
        } catch {
            let failure = error as? UpdateError ?? .installFailed
            Self.log.error("Update install failed: \(String(describing: failure), privacy: .public)")
            problem = failure
            activity = .idle
        }
    }

    /// The new copy wouldn't open: put the previous one back so what's installed is what's running.
    private func recover(_ installed: InstalledUpdate) {
        do {
            try installer.revert(installed)
            problem = .launchFailed
        } catch {
            problem = .installIncomplete
        }
        Self.log.error("Relaunch failed: \(String(describing: self.problem), privacy: .public)")
        activity = .idle
    }
}
