import CoreGraphics
import Foundation
import XCTest
@testable import GlanslateCapture
@testable import GlanslateCore
@testable import GlanslateGeometry
@testable import GlanslateHistory
@testable import GlanslateInvocation
@testable import GlanslateOverlay
@testable import GlanslatePlatform
@testable import GlanslateRegionSelect
@testable import GlanslateSettings
@testable import GlanslateTextDetect
@testable import GlanslateTranslation

private struct StubTopology: DisplayTopologyProviding {
    let snapshot: DisplayTopologySnapshot

    func current() -> DisplayTopologySnapshot {
        snapshot
    }
}

private final class RefreshingTopology: @unchecked Sendable, DisplayTopologyProviding {
    private let snapshots: [DisplayTopologySnapshot]
    private let lock = NSLock()
    private var nextIndex = 0

    init(snapshots: [DisplayTopologySnapshot]) {
        self.snapshots = snapshots
    }

    func current() -> DisplayTopologySnapshot {
        lock.lock()
        defer { lock.unlock() }

        let index = min(nextIndex, snapshots.count - 1)
        nextIndex += 1
        return snapshots[index]
    }
}

private struct StubRegionSelector: RegionSelecting {
    let selection: RegionSelection?

    func selectRegion(in topology: DisplayTopologySnapshot) async -> RegionSelection? {
        selection
    }
}

private struct StubCapture: ScreenCapturing {
    let source: SourceVisualContext

    func snapshot(_ region: DisplayLocalRect, topology: DisplayTopologySnapshot) async throws -> SourceVisualContext {
        source
    }
}

private struct StubDetector: TextDetecting {
    let blocks: [TextBlock]

    func detect(_ source: SourceVisualContext) async throws -> [TextBlock] {
        blocks
    }
}

private struct StubTranslator: TranslationRouting {
    let translations: [GlanslateCore.Translation]

    func translate(
        _ blocks: [TextBlock],
        to target: Language,
        invocationOverride: InvocationRoutingOverride?
    ) async throws -> [GlanslateCore.Translation] {
        translations
    }
}

private actor RecordingTranslator: TranslationRouting {
    private(set) var requests: [(Language, InvocationRoutingOverride?)] = []
    private(set) var blockRequests: [[TextBlock]] = []

    func translate(
        _ blocks: [TextBlock],
        to target: Language,
        invocationOverride: InvocationRoutingOverride?
    ) async throws -> [GlanslateCore.Translation] {
        requests.append((target, invocationOverride))
        blockRequests.append(blocks)
        let provider = invocationOverride?.provider ?? .openAI
        return blocks.map { block in
            GlanslateCore.Translation(
                block: block,
                translatedText: "\(target.rawValue)-\(provider.rawValue)",
                targetLanguage: target,
                provider: provider
            )
        }
    }

    func latestBlocks() -> [TextBlock] {
        blockRequests.last ?? []
    }
}

private actor SlowDismissingOverlayPresenter: OverlayPresenting {
    private var lastHandle: OverlaySessionHandle?
    private var presentationCount = 0
    private var dismissalCount = 0

    func present(_ session: OverlaySessionModel) async -> OverlaySessionHandle {
        presentationCount += 1
        let handle = OverlaySessionHandle(
            onDismiss: { [weak self] _ in
                try? await Task.sleep(nanoseconds: 50_000_000)
                await self?.recordDismissal()
            }
        )
        lastHandle = handle
        return handle
    }

    func dismissAll() async {
        if let lastHandle {
            await lastHandle.dismiss()
        }
    }

    func currentDisplayID() async -> CGDirectDisplayID? {
        nil
    }

    func latestHandle() -> OverlaySessionHandle? {
        lastHandle
    }

    func hasDismissedOverlay() -> Bool {
        dismissalCount > 0
    }

    func presentations() -> Int {
        presentationCount
    }

    private func recordDismissal() {
        dismissalCount += 1
    }
}

private actor DismissAwareRegionSelector: RegionSelecting {
    private let selection: RegionSelection
    private let overlay: SlowDismissingOverlayPresenter
    private var selectionCount = 0
    private(set) var secondSelectionStartedBeforeDismiss = false

    init(selection: RegionSelection, overlay: SlowDismissingOverlayPresenter) {
        self.selection = selection
        self.overlay = overlay
    }

    func selectRegion(in topology: DisplayTopologySnapshot) async -> RegionSelection? {
        selectionCount += 1
        if selectionCount == 2 {
            secondSelectionStartedBeforeDismiss = !(await overlay.hasDismissedOverlay())
        }
        return selection
    }

    func didStartSecondSelectionBeforeDismiss() -> Bool {
        secondSelectionStartedBeforeDismiss
    }
}

private actor RecordingOverlayPresenter: OverlayPresenting {
    private var lastHandle: OverlaySessionHandle?
    private var lastAppliedTranslations: [GlanslateCore.Translation] = []

    func present(_ session: OverlaySessionModel) async -> OverlaySessionHandle {
        let handle = OverlaySessionHandle(
            onPin: {
                OverlayPinnedPayload(
                    translations: session.translations,
                    thumbnailPNG: Data([9, 9, 9])
                )
            },
            onUnpin: {
                OverlayPinnedPayload(
                    translations: session.translations,
                    thumbnailPNG: nil
                )
            },
            onApplyRetranslation: { [weak self] translations, _ in
                await self?.setAppliedTranslations(translations)
            },
            onDismiss: { [weak self] _ in
                await self?.clearHandle()
            }
        )
        lastHandle = handle
        return handle
    }

    func dismissAll() async {
        if let lastHandle {
            await lastHandle.dismiss()
        }
    }

    func currentDisplayID() async -> CGDirectDisplayID? {
        nil
    }

    func latestHandle() -> OverlaySessionHandle? {
        lastHandle
    }

    func appliedTranslations() -> [GlanslateCore.Translation] {
        lastAppliedTranslations
    }

    private func setAppliedTranslations(_ translations: [GlanslateCore.Translation]) {
        lastAppliedTranslations = translations
    }

    private func clearHandle() {
        lastHandle = nil
    }
}

@MainActor
private final class RecordingToastPresenter: ErrorToasting {
    private(set) var errors: [GlanslateError] = []

    func showToast(_ error: GlanslateError, display: CGDirectDisplayID?) async {
        errors.append(error)
    }
}

private actor RetranslationFailingTranslator: TranslationRouting {
    func translate(
        _ blocks: [TextBlock],
        to target: Language,
        invocationOverride: InvocationRoutingOverride?
    ) async throws -> [GlanslateCore.Translation] {
        if invocationOverride != nil {
            throw GlanslateError.unsupportedPair(.deepL, from: .en, to: target)
        }

        return blocks.map { block in
            GlanslateCore.Translation(
                block: block,
                translatedText: "\(target.rawValue)-openAI",
                targetLanguage: target,
                provider: .openAI
            )
        }
    }
}

final class InvocationControllerTests: XCTestCase {
    @MainActor
    func testSelectionCancellationReturnsToIdle() async throws {
        let controller = InvocationController(
            topology: StubTopology(snapshot: sampleTopology()),
            regionSelect: StubRegionSelector(selection: nil),
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: sampleBlocks()),
            translate: StubTranslator(translations: sampleTranslations()),
            overlay: NoopOverlayPresenter(),
            history: try SwiftDataHistoryStore(inMemory: true),
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationCancel-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationCancel-\(UUID().uuidString)")
            )
        )

        let stream = controller.state
        let valuesTask = Task<[InvocationState], Never> {
            var values: [InvocationState] = []
            for await value in stream {
                values.append(value)
                if values.count == 4 {
                    break
                }
            }
            return values
        }

        await Task.yield()
        await controller.start()
        let values: [InvocationState] = await valuesTask.value

        XCTAssertEqual(values[0], InvocationState.idle)
        XCTAssertEqual(values[1], InvocationState.selecting)
        XCTAssertEqual(values[2], InvocationState.cancelled)
        XCTAssertEqual(values[3], InvocationState.idle)
    }

    @MainActor
    func testHappyPathReachesPresenting() async throws {
        let selection = RegionSelection(region: sampleBlocks()[0].region, topology: sampleTopology())
        let overlay = NoopOverlayPresenter()
        let controller = InvocationController(
            topology: StubTopology(snapshot: sampleTopology()),
            regionSelect: StubRegionSelector(selection: selection),
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: sampleBlocks()),
            translate: StubTranslator(translations: sampleTranslations()),
            overlay: overlay,
            history: try SwiftDataHistoryStore(inMemory: true),
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationHappy-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationHappy-\(UUID().uuidString)")
            )
        )

        let stream = controller.state
        let valuesTask = Task<[InvocationState], Never> {
            var values: [InvocationState] = []
            for await value in stream {
                values.append(value)
                if case .presenting = value {
                    break
                }
            }
            return values
        }

        await Task.yield()
        await controller.start()
        let values: [InvocationState] = await valuesTask.value

        XCTAssertTrue(values.contains(InvocationState.selecting))
        XCTAssertTrue(values.contains(InvocationState.capturing))
        XCTAssertTrue(values.contains(InvocationState.detecting))
        XCTAssertTrue(values.contains(InvocationState.translating))
        XCTAssertTrue(values.contains(where: {
            if case InvocationState.presenting = $0 { return true }
            return false
        }))

        await overlay.dismissAll()
    }

    @MainActor
    func testInvocationGroupsDetectedLinesBeforeTranslation() async throws {
        let blocks = sampleParagraphBlocks()
        let translator = RecordingTranslator()
        let overlay = RecordingOverlayPresenter()
        let controller = InvocationController(
            topology: StubTopology(snapshot: sampleTopology()),
            regionSelect: StubRegionSelector(selection: RegionSelection(region: blocks[0].region, topology: sampleTopology())),
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: blocks),
            translate: translator,
            overlay: overlay,
            history: try SwiftDataHistoryStore(inMemory: true),
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationGrouped-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationGrouped-\(UUID().uuidString)")
            )
        )

        await controller.start()
        _ = await waitForHandle(from: overlay)

        let translatedBlocks = await translator.latestBlocks()
        XCTAssertEqual(translatedBlocks.count, 1)
        XCTAssertEqual(
            translatedBlocks[0].text,
            "Thanks for your comment. You have a point.\nI would also behave like you in terms of security.\nIt is an open-source app."
        )
        XCTAssertEqual(translatedBlocks[0].region.rect, CGRect(x: 10, y: 10, width: 72, height: 44))

        await overlay.dismissAll()
    }

    @MainActor
    func testHappyPathIgnoresFreshTopologyTimestampWhenArrangementMatches() async throws {
        let snapshots = [
            sampleTopology(capturedAt: Date(timeIntervalSince1970: 1)),
            sampleTopology(capturedAt: Date(timeIntervalSince1970: 2)),
            sampleTopology(capturedAt: Date(timeIntervalSince1970: 3)),
            sampleTopology(capturedAt: Date(timeIntervalSince1970: 4)),
        ]
        let selection = RegionSelection(region: sampleBlocks()[0].region, topology: snapshots[0])
        let overlay = NoopOverlayPresenter()
        let controller = InvocationController(
            topology: RefreshingTopology(snapshots: snapshots),
            regionSelect: StubRegionSelector(selection: selection),
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: sampleBlocks()),
            translate: StubTranslator(translations: sampleTranslations()),
            overlay: overlay,
            history: try SwiftDataHistoryStore(inMemory: true),
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationFreshTimestamp-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationFreshTimestamp-\(UUID().uuidString)")
            )
        )

        let stream = controller.state
        let valuesTask = Task<[InvocationState], Never> {
            var values: [InvocationState] = []
            for await value in stream {
                values.append(value)
                if case .presenting = value {
                    break
                }
                if case .errored = value {
                    break
                }
            }
            return values
        }

        await Task.yield()
        await controller.start()
        let values: [InvocationState] = await valuesTask.value

        XCTAssertTrue(values.contains(where: {
            if case InvocationState.presenting = $0 { return true }
            return false
        }))
        XCTAssertFalse(values.contains(where: {
            if case .errored(.displayTopologyChanged) = $0 { return true }
            return false
        }))

        await overlay.dismissAll()
    }

    @MainActor
    func testStartWaitsForActiveOverlayDismissalBeforeSelectingAgain() async throws {
        let overlay = SlowDismissingOverlayPresenter()
        let selection = RegionSelection(region: sampleBlocks()[0].region, topology: sampleTopology())
        let selector = DismissAwareRegionSelector(selection: selection, overlay: overlay)
        let controller = InvocationController(
            topology: StubTopology(snapshot: sampleTopology()),
            regionSelect: selector,
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: sampleBlocks()),
            translate: StubTranslator(translations: sampleTranslations()),
            overlay: overlay,
            history: try SwiftDataHistoryStore(inMemory: true),
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationRestart-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationRestart-\(UUID().uuidString)")
            )
        )

        await controller.start()
        _ = await waitForPresentationCount(from: overlay, expectedCount: 1)

        await controller.start()
        _ = await waitForPresentationCount(from: overlay, expectedCount: 2)

        let startedBeforeDismiss = await selector.didStartSecondSelectionBeforeDismiss()
        XCTAssertFalse(startedBeforeDismiss)

        await overlay.dismissAll()
    }

    @MainActor
    func testPinnedOverlayPersistsHistoryEntries() async throws {
        let overlay = RecordingOverlayPresenter()
        let history = try SwiftDataHistoryStore(inMemory: true)
        let controller = InvocationController(
            topology: StubTopology(snapshot: sampleTopology()),
            regionSelect: StubRegionSelector(selection: RegionSelection(region: sampleBlocks()[0].region, topology: sampleTopology())),
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: sampleBlocks()),
            translate: StubTranslator(translations: sampleTranslations()),
            overlay: overlay,
            history: history,
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationPin-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationPin-\(UUID().uuidString)")
            )
        )

        await controller.start()
        let handle = await waitForHandle(from: overlay)

        await handle.pin()
        let items = try await waitForHistoryItems(in: history, expectedCount: 1)

        XCTAssertEqual(items[0].translatedText, "merhaba")
        XCTAssertEqual(items[0].snapshotPNG, Data([9, 9, 9]))

        await handle.unpin()
        let itemsAfterUnpin = try await waitForHistoryItems(in: history, expectedCount: 1)
        XCTAssertEqual(itemsAfterUnpin[0].translatedText, "merhaba")

        await overlay.dismissAll()
    }

    @MainActor
    func testRetranslateEventUsesToolbarOverridesAndUpdatesOverlay() async throws {
        let overlay = RecordingOverlayPresenter()
        let translator = RecordingTranslator()
        let controller = InvocationController(
            topology: StubTopology(snapshot: sampleTopology()),
            regionSelect: StubRegionSelector(selection: RegionSelection(region: sampleBlocks()[0].region, topology: sampleTopology())),
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: sampleBlocks()),
            translate: translator,
            overlay: overlay,
            history: try SwiftDataHistoryStore(inMemory: true),
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationRetranslate-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationRetranslate-\(UUID().uuidString)")
            )
        )

        await controller.start()
        let handle = await waitForHandle(from: overlay)

        await handle.requestRetranslation(
            OverlayRetranslationRequest(
                targetLanguage: .de,
                provider: .deepL,
                sourceLanguage: .en
            )
        )

        let requests = await waitForTranslatorRequests(from: translator, expectedCount: 2)
        let appliedTranslations = await waitForAppliedTranslations(from: overlay)

        XCTAssertEqual(requests[1].0, .de)
        XCTAssertEqual(requests[1].1?.provider, .deepL)
        XCTAssertEqual(requests[1].1?.sourceLanguage, .en)
        XCTAssertEqual(appliedTranslations.first?.targetLanguage, .de)
        XCTAssertEqual(appliedTranslations.first?.provider, .deepL)

        await overlay.dismissAll()
    }

    @MainActor
    func testRetranslateFailureShowsToast() async throws {
        let overlay = RecordingOverlayPresenter()
        let toastPresenter = RecordingToastPresenter()
        let controller = InvocationController(
            topology: StubTopology(snapshot: sampleTopology()),
            regionSelect: StubRegionSelector(selection: RegionSelection(region: sampleBlocks()[0].region, topology: sampleTopology())),
            capture: StubCapture(source: sampleSource()),
            detect: StubDetector(blocks: sampleBlocks()),
            translate: RetranslationFailingTranslator(),
            overlay: overlay,
            history: try SwiftDataHistoryStore(inMemory: true),
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "InvocationRetranslateToast-\(UUID().uuidString)")!,
                keychain: KeychainStore(service: "InvocationRetranslateToast-\(UUID().uuidString)")
            )
        )

        controller.setErrorToastPresenter(toastPresenter)

        await controller.start()
        let handle = await waitForHandle(from: overlay)

        await handle.requestRetranslation(
            OverlayRetranslationRequest(
                targetLanguage: .de,
                provider: .deepL,
                sourceLanguage: .en
            )
        )

        let error = await waitForToastError(from: toastPresenter)
        XCTAssertEqual(error, .unsupportedPair(.deepL, from: .en, to: .de))

        await overlay.dismissAll()
    }

    private func sampleTopology(capturedAt: Date = Date()) -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(entries: [
            DisplayTopologyEntry(
                displayID: 1,
                appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 2,
                pixelSize: CGSize(width: 200, height: 200),
                isMain: true
            )
        ], capturedAt: capturedAt)
    }

    private func sampleSource() -> SourceVisualContext {
        SourceVisualContext(
            image: makeImage(),
            region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 10, y: 10, width: 30, height: 12)),
            topology: sampleTopology(),
            pixelScale: 2
        )
    }

    private func sampleBlocks() -> [TextBlock] {
        [
            TextBlock(
                text: "hello",
                region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 10, y: 10, width: 30, height: 12)),
                detectedLanguage: .en,
                confidence: 1,
                source: .vision
            )
        ]
    }

    private func sampleParagraphBlocks() -> [TextBlock] {
        [
            TextBlock(
                text: "Thanks for your comment. You have a point.",
                region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 10, y: 10, width: 68, height: 12)),
                detectedLanguage: .en,
                confidence: 1,
                source: .vision
            ),
            TextBlock(
                text: "I would also behave like you in terms of security.",
                region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 10, y: 26, width: 72, height: 12)),
                detectedLanguage: .en,
                confidence: 1,
                source: .vision
            ),
            TextBlock(
                text: "It is an open-source app.",
                region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 10, y: 42, width: 48, height: 12)),
                detectedLanguage: .en,
                confidence: 1,
                source: .vision
            ),
        ]
    }

    private func sampleTranslations() -> [GlanslateCore.Translation] {
        sampleBlocks().map {
            GlanslateCore.Translation(
                block: $0,
                translatedText: "merhaba",
                targetLanguage: .tr,
                provider: .openAI
            )
        }
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    @MainActor
    private func waitForToastError(
        from presenter: RecordingToastPresenter
    ) async -> GlanslateError {
        for _ in 0..<50 {
            if let error = presenter.errors.last {
                return error
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for retranslation toast")
        return .cancelled
    }

    @MainActor
    private func waitForHandle(
        from overlay: RecordingOverlayPresenter
    ) async -> OverlaySessionHandle {
        for _ in 0..<50 {
            if let handle = await overlay.latestHandle() {
                return handle
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for overlay handle")
        return OverlaySessionHandle()
    }

    @MainActor
    private func waitForHistoryItems(
        in history: SwiftDataHistoryStore,
        expectedCount: Int
    ) async throws -> [PinnedTranslation] {
        for _ in 0..<50 {
            let items = try await history.list()
            if items.count == expectedCount {
                return items
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for history items")
        return try await history.list()
    }

    @MainActor
    private func waitForTranslatorRequests(
        from translator: RecordingTranslator,
        expectedCount: Int
    ) async -> [(Language, InvocationRoutingOverride?)] {
        for _ in 0..<50 {
            let requests = await translator.requests
            if requests.count >= expectedCount {
                return requests
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for translator requests")
        return await translator.requests
    }

    @MainActor
    private func waitForAppliedTranslations(
        from overlay: RecordingOverlayPresenter
    ) async -> [GlanslateCore.Translation] {
        for _ in 0..<50 {
            let applied = await overlay.appliedTranslations()
            if !applied.isEmpty {
                return applied
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for applied translations")
        return await overlay.appliedTranslations()
    }

    @MainActor
    private func waitForPresentationCount(
        from overlay: SlowDismissingOverlayPresenter,
        expectedCount: Int
    ) async -> Int {
        for _ in 0..<50 {
            let count = await overlay.presentations()
            if count >= expectedCount {
                return count
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for overlay presentation count")
        return await overlay.presentations()
    }
}
