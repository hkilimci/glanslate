import CryptoKit
import Foundation
import GlanslateCore
import OSLog
import Security

/// Whether this copy of Glanslate can replace itself with a downloaded release.
public enum SelfUpdateAvailability: Hashable, Sendable {
    case available
    /// Signed locally or with a development certificate, so a download can't be
    /// proven to come from the same developer. Updates must be downloaded by hand.
    case notDeveloperIDSigned
    /// Running from a disk image, a translocated copy, or a folder the user can't change.
    case locationNotWritable
}

/// An update swapped in where the app was installed, with the copy it replaced
/// set aside until the new one is known to open.
public struct InstalledUpdate: Hashable, Sendable {
    /// The replaced copy.
    public let previousCopy: URL
    /// The folder holding it, removed by ``UpdateInstalling/finish(_:)``.
    public let workspace: URL

    public init(previousCopy: URL, workspace: URL) {
        self.previousCopy = previousCopy
        self.workspace = workspace
    }
}

/// Installs a release over the running app. Abstracted so the interface can be tested without touching a bundle.
public protocol UpdateInstalling: Sendable {
    var availability: SelfUpdateAvailability { get }
    /// Downloads, verifies, and swaps in the update. On return the new copy is
    /// where the app was installed and the replaced copy is kept aside: relaunch,
    /// then call ``finish(_:)`` once the new copy is running or ``revert(_:)`` if it
    /// won't open. Throws ``UpdateError`` or `CancellationError`; nothing changes when it throws.
    func install(_ update: AvailableUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> InstalledUpdate
    /// Discards the replaced copy.
    func finish(_ installed: InstalledUpdate)
    /// Puts the replaced copy back. Throws ``UpdateError/installIncomplete`` if that fails.
    func revert(_ installed: InstalledUpdate) throws
}

/// Replaces the running app with a downloaded release, but only after proving the
/// download is Glanslate: same bundle identifier, the version the release names,
/// the published checksum, and a valid Developer ID signature from the same team.
/// It must also run on this Mac and be newer than the copy it replaces.
public struct UpdateInstaller: UpdateInstalling {
    private static let log = Logger(subsystem: "app.glanslate", category: "update")

    let bundleURL: URL
    let bundleIdentifier: String
    /// The code requirement a download must satisfy, or `nil` when the running copy isn't Developer ID signed.
    let requirement: String?
    /// The release container must be signed by the same team, with the app's identifier plus `.dmg`.
    let diskImageRequirement: String?
    var allowedSchemes: Set<String> = ["https"]
    var systemVersion = UpdateInstaller.currentSystemVersion
    /// An `NSBundleExecutableArchitecture…` value the new executable must contain.
    var architecture = UpdateInstaller.currentArchitecture

    public init(bundle: Bundle = .main) {
        bundleURL = bundle.bundleURL
        bundleIdentifier = bundle.bundleIdentifier ?? ""
        requirement = Self.developerIDRequirement(forAppAt: bundle.bundleURL)
        diskImageRequirement = Self.developerIDRequirement(forAppAt: bundle.bundleURL, identifierSuffix: ".dmg")
    }

    init(bundleURL: URL, bundleIdentifier: String, requirement: String?, allowedSchemes: Set<String> = ["https"], diskImageRequirement: String? = nil) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.requirement = requirement
        self.diskImageRequirement = diskImageRequirement
        self.allowedSchemes = allowedSchemes
    }

    public var availability: SelfUpdateAvailability {
        guard requirement != nil else { return .notDeveloperIDSigned }
        return Self.canReplace(bundleURL) ? .available : .locationNotWritable
    }

    public func install(_ update: AvailableUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> InstalledUpdate {
        guard let requirement else { throw UpdateError.untrustedSignature }
        guard Self.canReplace(bundleURL) else { throw UpdateError.locationNotWritable }
        guard let archive = update.archive, let scheme = archive.url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            throw UpdateError.unexpectedContents
        }

        let files = FileManager.default
        // On the app's own volume, so swapping copies is a rename rather than a copy.
        let staging: URL
        do {
            staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true)
        } catch {
            throw UpdateError.locationNotWritable
        }
        var keepsStaging = false
        defer { if !keepsStaging { try? files.removeItem(at: staging) } }

        let image = staging.appendingPathComponent("Update.dmg")
        try await Self.download(archive.url, to: image, progress: progress)
        try Task.checkCancellation()

        if let expected = archive.sha256 {
            guard (try? Self.sha256(of: image)) == expected else { throw UpdateError.checksumMismatch }
        }

        // Validate the container before handing its filesystem to the OS.
        if let diskImageRequirement { try Self.verifySignature(of: image, requirement: diskImageRequirement) }
        let extracted = staging.appendingPathComponent("Extracted", isDirectory: true)
        let app = try await Self.copyApp(fromDiskImage: image, into: extracted)
        try verify(app, version: update.version, requirement: requirement)
        try Task.checkCancellation()

        // Another copy may have installed something newer since this one launched.
        if let installed = Self.version(ofAppAt: bundleURL), installed >= update.version {
            throw UpdateError.newerVersionInstalled
        }

        let previous = try Self.swap(bundleURL, app, workspace: staging)
        keepsStaging = true
        Self.log.info("Installed version \(update.version.description, privacy: .public)")
        return InstalledUpdate(previousCopy: previous, workspace: staging)
    }

    public func finish(_ installed: InstalledUpdate) {
        try? FileManager.default.removeItem(at: installed.workspace)
    }

    public func revert(_ installed: InstalledUpdate) throws {
        do {
            _ = try Self.swap(bundleURL, installed.previousCopy, workspace: installed.workspace)
        } catch {
            Self.log.error("Putting the previous copy back failed")
            throw UpdateError.installIncomplete
        }
        finish(installed)
        Self.log.info("Reverted to the previous copy")
    }

    // MARK: Verification

    func verify(_ app: URL, version: AppVersion, requirement: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let short = info["CFBundleShortVersionString"] as? String,
              AppVersion(short) == version
        else { throw UpdateError.unexpectedContents }

        try Self.verifySignature(of: app, requirement: requirement)

        // Genuine but unable to run here: installing it would leave nothing that opens.
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            guard let required = AppVersion(minimum) else { throw UpdateError.unexpectedContents }
            guard required <= systemVersion else { throw UpdateError.incompatible(minimumSystem: minimum) }
        }
        guard let architectures = Bundle(url: app)?.executableArchitectures else { throw UpdateError.unexpectedContents }
        guard architectures.contains(where: { $0.intValue == architecture }) else {
            throw UpdateError.incompatible(minimumSystem: nil)
        }
    }

    static var currentSystemVersion: AppVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")!
    }

    static var currentArchitecture: Int {
        #if arch(arm64)
        return NSBundleExecutableArchitectureARM64
        #else
        return NSBundleExecutableArchitectureX86_64
        #endif
    }

    static func version(ofAppAt url: URL) -> AppVersion? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    /// Puts `other` where `installed` is, on the same volume, and returns where the
    /// previously installed copy now is. Atomic where the file system supports it;
    /// otherwise two moves, the first undone if the second fails, so the installed
    /// location is never left empty. Throws ``UpdateError/installFailed`` when nothing
    /// changed and ``UpdateError/installIncomplete`` when undoing failed.
    static func swap(_ installed: URL, _ other: URL, workspace: URL) throws -> URL {
        let swapped = installed.withUnsafeFileSystemRepresentation { from in
            other.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return renamex_np(from, to, UInt32(RENAME_SWAP)) == 0
            }
        }
        if swapped { return other }

        let files = FileManager.default
        let aside = workspace.appendingPathComponent("Aside-\(UUID().uuidString).app", isDirectory: true)
        do {
            try files.moveItem(at: installed, to: aside)
        } catch {
            log.error("Moving the installed copy aside failed: \(String(describing: type(of: error)), privacy: .public)")
            throw UpdateError.installFailed
        }
        do {
            try files.moveItem(at: other, to: installed)
        } catch {
            log.error("Moving the new copy into place failed: \(String(describing: type(of: error)), privacy: .public)")
            do {
                try files.moveItem(at: aside, to: installed)
            } catch {
                throw UpdateError.installIncomplete
            }
            throw UpdateError.installFailed
        }
        return aside
    }

    /// A Developer ID Application signature from the running copy's team, for its
    /// signing identifier. `nil` when the running copy doesn't meet that itself,
    /// such as a locally signed development build.
    static func developerIDRequirement(forAppAt url: URL, identifierSuffix: String = "") -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              let requirement = developerIDRequirement(identifier: identifier, team: team)
        else { return nil }
        // Resources were checked when the app launched; only the certificate chain matters here.
        guard satisfies(code, requirement, flags: SecCSFlags(rawValue: kSecCSDoNotValidateResources)) else { return nil }
        return developerIDRequirement(identifier: identifier + identifierSuffix, team: team)
    }

    static func developerIDRequirement(identifier: String, team: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard !identifier.isEmpty, !team.isEmpty, identifier.allSatisfy(allowed.contains), team.allSatisfy(allowed.contains) else { return nil }
        // The OIDs mark a Developer ID intermediate and a Developer ID Application leaf certificate.
        return "anchor apple generic and identifier \"\(identifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func satisfies(_ code: SecStaticCode, _ requirementText: String, flags: SecCSFlags) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    static func verifySignature(of url: URL, requirement: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              satisfies(code, requirement, flags: SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        else { throw UpdateError.untrustedSignature }
    }

    /// Whether the app can be swapped in place: not on a read-only volume (a disk
    /// image), not translocated by Gatekeeper, and in a folder the user can change.
    static func canReplace(_ url: URL) -> Bool {
        guard !url.path.contains("/AppTranslocation/") else { return false }
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return false }
        let files = FileManager.default
        return files.isWritableFile(atPath: url.deletingLastPathComponent().path) && files.isWritableFile(atPath: url.path)
    }

    // MARK: Files

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copy only the app from a private, read-only mount. `ditto` preserves its
    /// signature, notarization ticket, extended attributes, and internal symlinks.
    /// The mounted app is never executed, and the image is ejected before installation.
    static func copyApp(fromDiskImage image: URL, into directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let files = FileManager.default
        // macOS can deny access to volumes mounted inside an item replacement
        // directory (TemporaryItems). Mount separately; keep the copied app on
        // the installed app's volume so the eventual swap is still atomic.
        let mount = files.temporaryDirectory.appendingPathComponent("glanslate-update-mount-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try await runTool("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-quiet"])
            try Task.checkCancellation()
            let source = try singleApp(in: mount)
            let app = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try await runTool("/usr/bin/ditto", [source.path, app.path])
            try Task.checkCancellation()
            try await detachDiskImage(at: mount)
            try? files.removeItem(at: mount)
            return app
        } catch {
            // Also try after a failed attach, which may have partially mounted.
            // Cleanup must finish even if this task was cancelled.
            try? await detachDiskImage(at: mount)
            try? files.removeItem(at: mount)
            throw error
        }
    }

    private static func detachDiskImage(at mount: URL) async throws {
        do {
            try await runTool("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        } catch {
            try await runTool("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        }
    }

    private static func runTool(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: UpdateError.unexpectedContents)
            }
        }
        guard status == 0 else { throw UpdateError.unexpectedContents }
    }

    static func singleApp(in directory: URL) throws -> URL {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let apps = items.filter { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return item.pathExtension == "app" && values?.isDirectory == true && values?.isSymbolicLink != true
        }
        guard apps.count == 1 else { throw UpdateError.unexpectedContents }
        return apps[0]
    }

    // MARK: Download

    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let running = RunningDownload()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.downloadTask(with: url) { location, response, error in
                    running.finish()
                    if let error = error as? URLError {
                        continuation.resume(throwing: error.code == .cancelled ? CancellationError() : UpdateError.network(.init(error)))
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    guard error == nil, let location, (200..<300).contains(status) else {
                        continuation.resume(throwing: UpdateError.downloadFailed)
                        return
                    }
                    // The system deletes `location` when this handler returns.
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: UpdateError.downloadFailed)
                    }
                }
                running.start(task, progress: progress)
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// The download task and its progress observation, reachable from the cancellation handler.
private final class RunningDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        let observation = task.progress.observe(\.fractionCompleted) { value, _ in
            progress(value.fractionCompleted)
        }
        let cancelled = lock.withLock {
            self.task = task
            self.observation = observation
            return isCancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func finish() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}
