import CoreGraphics
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

    func translate(
        _ blocks: [TextBlock],
        to target: Language,
        invocationOverride: InvocationRoutingOverride?
    ) async throws -> [GlanslateCore.Translation] {
        requests.append((target, invocationOverride))
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

    private func sampleTopology() -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(entries: [
            DisplayTopologyEntry(
                displayID: 1,
                appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 2,
                pixelSize: CGSize(width: 200, height: 200),
                isMain: true
            )
        ])
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
}
