import Foundation
import GlanslateCore
import Testing
@testable import GlanslateSystem

@Suite("Update installer", .serialized)
struct UpdateInstallerTests {
    private static let identifier = "app.glanslate.UpdateTests"
    /// Satisfied by any signature with the test identifier, including an ad hoc one.
    private static let anySignature = "identifier \"\(identifier)\""
    private static let anyDiskImageSignature = "identifier \"\(identifier).dmg\""

    private let root: URL
    private let installed: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glanslate-update-\(UUID().uuidString)", isDirectory: true)
        installed = root.appendingPathComponent("Applications/Glanslate.app", isDirectory: true)
        try Self.makeApp(at: installed, version: "1.0.0")
    }

    // MARK: Requirements and location

    @Test func requirementDemandsDeveloperIDFromTheSameTeam() throws {
        defer { cleanUp() }
        let requirement = try #require(UpdateInstaller.developerIDRequirement(identifier: "app.glanslate.Glanslate", team: "ABCDE12345"))
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("identifier \"app.glanslate.Glanslate\""))
        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6]"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13]"))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        #expect(UpdateInstaller.developerIDRequirement(identifier: "x\" or anchor apple", team: "ABCDE12345") == nil)
        #expect(UpdateInstaller.developerIDRequirement(identifier: "app.glanslate.Glanslate", team: "") == nil)
    }

    @Test func unsignedCopiesCantUpdateThemselves() throws {
        defer { cleanUp() }
        #expect(UpdateInstaller.developerIDRequirement(forAppAt: installed) == nil)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: nil)
        #expect(installer.availability == .notDeveloperIDSigned)
    }

    @Test func onlyWritableUntranslocatedCopiesCanBeReplaced() {
        defer { cleanUp() }
        #expect(UpdateInstaller.canReplace(installed))
        #expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/Glanslate.app")))
        #expect(!UpdateInstaller.canReplace(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature)
        #expect(installer.availability == .available)
    }

    @Test func hashesFilesInChunks() throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: Installing

    @Test func installsAGenuineUpdateAndKeepsThePreviousCopyUntilFinished() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true, minimumSystem: "26.0")
        var installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        installer.systemVersion = AppVersion("26.0")!
        let result = try await installer.install(update(image, version: "1.2.0", sha256: UpdateInstaller.sha256(of: image))) { _ in }

        #expect(installedVersion() == "1.2.0")
        #expect(UpdateInstaller.version(ofAppAt: result.previousCopy) == AppVersion("1.0.0"))
        installer.finish(result)
        #expect(!FileManager.default.fileExists(atPath: result.workspace.path))
        #expect(installedVersion() == "1.2.0")
    }

    @Test func revertingPutsThePreviousCopyBack() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        let result = try await installer.install(update(image, version: "1.2.0")) { _ in }
        #expect(installedVersion() == "1.2.0")

        try installer.revert(result)

        #expect(installedVersion() == "1.0.0")
        #expect(!FileManager.default.fileExists(atPath: result.workspace.path))
    }

    @Test func refusesAnUpdateThatNeedsANewerMacOS() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true, minimumSystem: "27.0")
        var installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        installer.systemVersion = AppVersion("26.4.1")!
        await #expect(throws: UpdateError.incompatible(minimumSystem: "27.0")) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func refusesAnUpdateBuiltForAnotherProcessor() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true)
        var installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        installer.architecture = 18 // CPU_TYPE_POWERPC, which no current Mac executable contains
        await #expect(throws: UpdateError.incompatible(minimumSystem: nil)) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func leavesANewerInstalledCopyAlone() async throws {
        defer { cleanUp() }
        try FileManager.default.removeItem(at: installed)
        try Self.makeApp(at: installed, version: "1.3.0")
        let image = try makeDiskImage(version: "1.2.0", signed: true)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        await #expect(throws: UpdateError.newerVersionInstalled) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.3.0")
    }

    @Test func aFailedSwapLeavesTheInstalledCopyInPlace() throws {
        defer { cleanUp() }
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let missing = workspace.appendingPathComponent("Missing.app")
        #expect(throws: UpdateError.installFailed) {
            _ = try UpdateInstaller.swap(installed, missing, workspace: workspace)
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func refusesADamagedDownload() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        await #expect(throws: UpdateError.checksumMismatch) {
            _ = try await installer.install(update(image, version: "1.2.0", sha256: String(repeating: "0", count: 64))) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func refusesAnUnsignedApp() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: false)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        await #expect(throws: UpdateError.untrustedSignature) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func refusesAnAppSignedBySomeoneElse() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true)
        let developerID = try #require(UpdateInstaller.developerIDRequirement(identifier: Self.identifier, team: "ABCDE12345"))
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: developerID, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        await #expect(throws: UpdateError.untrustedSignature) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func refusesAVersionOtherThanTheReleaseNames() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "0.9.0", signed: true)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        await #expect(throws: UpdateError.unexpectedContents) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func refusesDiskImagesWithoutAnApp() async throws {
        defer { cleanUp() }
        let source = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("README.txt"))
        let image = try makeImage(from: source)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        await #expect(throws: UpdateError.unexpectedContents) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test(arguments: [false, true])
    func refusesUnsignedOrDifferentlySignedDiskImages(signed: Bool) async throws {
        defer { cleanUp() }
        let source = root.appendingPathComponent("Untrusted", isDirectory: true)
        try Self.makeApp(at: source.appendingPathComponent("Glanslate.app"), version: "1.2.0")
        try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", Self.identifier, source.appendingPathComponent("Glanslate.app").path])
        let image = try makeImage(from: source, signed: signed, identifier: "another.developer.dmg")
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"], diskImageRequirement: Self.anyDiskImageSignature)
        await #expect(throws: UpdateError.untrustedSignature) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func copiesOnlyTheAppAndEjectsTheImage() async throws {
        defer { cleanUp() }
        let source = root.appendingPathComponent("WithLinks", isDirectory: true)
        let app = source.appendingPathComponent("Glanslate.app", isDirectory: true)
        try Self.makeApp(at: app, version: "1.2.0")
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("resource".utf8).write(to: resources.appendingPathComponent("Original.txt"))
        try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("Link.txt").path, withDestinationPath: "Original.txt")
        try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", Self.identifier, app.path])
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let image = try makeImage(from: source)
        let destination = root.appendingPathComponent("Copied", isDirectory: true)

        let copied = try await UpdateInstaller.copyApp(fromDiskImage: image, into: destination)

        try UpdateInstaller.verifySignature(of: copied, requirement: Self.anySignature)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("Contents/Resources/Link.txt").path) == "Original.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Glanslate.app"])
        #expect(try !Self.isMounted(image))
    }

    @Test(arguments: [false, true])
    func rejectsAmbiguousOrSymlinkedAppsAndEjectsTheImage(symlink: Bool) async throws {
        defer { cleanUp() }
        let source = root.appendingPathComponent("InvalidContents", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        if symlink {
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Glanslate.app").path, withDestinationPath: installed.path)
        } else {
            try Self.makeApp(at: source.appendingPathComponent("First.app"), version: "1.2.0")
            try Self.makeApp(at: source.appendingPathComponent("Second.app"), version: "1.2.0")
        }
        let image = try makeImage(from: source)
        let destination = root.appendingPathComponent("Rejected", isDirectory: true)

        await #expect(throws: UpdateError.unexpectedContents) {
            _ = try await UpdateInstaller.copyApp(fromDiskImage: image, into: destination)
        }

        #expect(try !Self.isMounted(image))
        #expect(installedVersion() == "1.0.0")
    }

    @Test func aCorruptDiskImageDoesNotChangeTheInstalledApp() async throws {
        defer { cleanUp() }
        let image = root.appendingPathComponent("Corrupt.dmg")
        try Data("not a disk image".utf8).write(to: image)
        // Omit the container requirement to exercise attach failure and cleanup.
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature, allowedSchemes: ["file"])
        await #expect(throws: UpdateError.unexpectedContents) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    @Test func cancellationDoesNotMountTheImage() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true)
        let destination = root.appendingPathComponent("Cancelled", isDirectory: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await UpdateInstaller.copyApp(fromDiskImage: image, into: destination)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(installedVersion() == "1.0.0")
    }

    @Test func downloadsOnlyOverHTTPS() async throws {
        defer { cleanUp() }
        let image = try makeDiskImage(version: "1.2.0", signed: true)
        let installer = UpdateInstaller(bundleURL: installed, bundleIdentifier: Self.identifier, requirement: Self.anySignature)
        await #expect(throws: UpdateError.unexpectedContents) {
            _ = try await installer.install(update(image, version: "1.2.0")) { _ in }
        }
        #expect(installedVersion() == "1.0.0")
    }

    // MARK: Fixtures

    private func update(_ image: URL, version: String, sha256: String? = nil) -> AvailableUpdate {
        AvailableUpdate(
            version: AppVersion(version)!,
            title: "Glanslate \(version)",
            notes: "",
            publishedAt: nil,
            releasePage: URL(string: "https://example.com/release")!,
            archive: .init(url: image, size: 0, sha256: sha256)
        )
    }

    private func makeDiskImage(version: String, signed: Bool, minimumSystem: String? = nil) throws -> URL {
        let app = root.appendingPathComponent("Build-\(UUID().uuidString)/Glanslate.app", isDirectory: true)
        try Self.makeApp(at: app, version: version, minimumSystem: minimumSystem)
        if signed {
            try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", Self.identifier, app.path])
        }
        return try makeImage(from: app.deletingLastPathComponent())
    }

    private func makeImage(from directory: URL, signed: Bool = true, identifier: String? = nil) throws -> URL {
        let image = root.appendingPathComponent("Glanslate-\(UUID().uuidString).dmg")
        try Self.run("/usr/bin/hdiutil", ["create", "-volname", "Glanslate Update Tests", "-srcfolder", directory.path, "-ov", "-format", "UDZO", image.path])
        if signed {
            try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier ?? Self.identifier + ".dmg", image.path])
        }
        return image
    }

    private func installedVersion() -> String? {
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func isMounted(_ image: URL) throws -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let images = try #require(info?["images"] as? [[String: Any]])
        #expect(process.terminationStatus == 0)
        return images.contains { entry in
            guard let path = entry["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath() == image.resolvingSymlinksInPath()
        }
    }

    /// A minimal bundle whose executable is a real Mach-O, so it can be code signed.
    private static func makeApp(at url: URL, version: String, minimumSystem: String? = nil) throws {
        let files = FileManager.default
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Glanslate"))
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Glanslate",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
        ]
        info["LSMinimumSystemVersion"] = minimumSystem
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"])
        }
    }
}
