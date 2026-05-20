import Foundation
import GlanslateCapture
import GlanslateCore
import GlanslateGeometry
import GlanslateHistory
import GlanslateOverlay
import GlanslateRegionSelect
import GlanslateSettings
import GlanslateTextDetect
import GlanslateTranslation

public struct Invocation: Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let topology: DisplayTopologySnapshot
    public var region: DisplayLocalRect?
    public var source: SourceVisualContext?
    public var blocks: [TextBlock]?
    public var translations: [Translation]?
    public var state: InvocationState

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        topology: DisplayTopologySnapshot,
        region: DisplayLocalRect? = nil,
        source: SourceVisualContext? = nil,
        blocks: [TextBlock]? = nil,
        translations: [Translation]? = nil,
        state: InvocationState = .idle
    ) {
        self.id = id
        self.startedAt = startedAt
        self.topology = topology
        self.region = region
        self.source = source
        self.blocks = blocks
        self.translations = translations
        self.state = state
    }
}

public enum InvocationState: Sendable, Hashable {
    case idle
    case selecting
    case capturing
    case detecting
    case translating
    case presenting(overlaySessionID: UUID)
    case cancelled
    case errored(GlanslateError)
}

public actor InvocationController {
    private struct ActiveOverlayContext: Sendable {
        let blocks: [TextBlock]
        var translations: [Translation]
        var currentRequest: OverlayRetranslationRequest
    }

    private let topology: any DisplayTopologyProviding
    private let regionSelect: any RegionSelecting
    private let capture: any ScreenCapturing
    private let detect: any TextDetecting
    private let translate: any TranslationRouting
    private let overlay: any OverlayPresenting
    @MainActor private let history: any HistoryStoring
    private let settings: SettingsStore
    private let stateBroadcaster: AsyncStreamBroadcaster<InvocationState>
    @MainActor private var errorToastPresenter: ErrorToasting?

    private var currentInvocationID: UUID?
    private var currentTask: Task<Void, Never>?
    private var overlayEventsTask: Task<Void, Never>?
    private var currentOverlay: OverlaySessionHandle?
    private var currentOverlayContext: ActiveOverlayContext?
    private var retranslationTask: Task<Void, Never>?

    public nonisolated var state: AsyncStream<InvocationState> {
        stateBroadcaster.stream()
    }

    @MainActor
    public init(
        topology: any DisplayTopologyProviding,
        regionSelect: any RegionSelecting,
        capture: any ScreenCapturing,
        detect: any TextDetecting,
        translate: any TranslationRouting,
        overlay: any OverlayPresenting,
        history: any HistoryStoring,
        settings: SettingsStore
    ) {
        self.topology = topology
        self.regionSelect = regionSelect
        self.capture = capture
        self.detect = detect
        self.translate = translate
        self.overlay = overlay
        self.history = history
        self.settings = settings
        self.stateBroadcaster = AsyncStreamBroadcaster(seed: .idle)
    }

    @MainActor
    public func setErrorToastPresenter(_ presenter: ErrorToasting?) {
        self.errorToastPresenter = presenter
    }

    public func start() async {
        await cancelCurrentInternal()

        let snapshot = topology.current()
        let invocationID = UUID()

        currentInvocationID = invocationID
        stateBroadcaster.yield(.selecting)

        currentTask = Task { [snapshot] in
            await self.runInvocation(id: invocationID, topology: snapshot)
        }
    }

    public func cancelCurrent() async {
        await cancelCurrentInternal()
    }

    private func cancelCurrentInternal() async {
        let hadActiveInvocation =
            currentInvocationID != nil ||
            currentTask != nil ||
            currentOverlay != nil

        currentInvocationID = nil
        currentTask?.cancel()
        currentTask = nil
        overlayEventsTask?.cancel()
        overlayEventsTask = nil
        retranslationTask?.cancel()
        retranslationTask = nil
        currentOverlayContext = nil

        if let overlayHandle = currentOverlay {
            currentOverlay = nil
            await overlayHandle.dismiss()
        }

        if hadActiveInvocation {
            stateBroadcaster.yield(.cancelled)
            stateBroadcaster.yield(.idle)
        }
    }

    private func runInvocation(id: UUID, topology snapshot: DisplayTopologySnapshot) async {
        do {
            try Task.checkCancellation()
            guard isCurrent(id) else { return }

            guard let selection = await regionSelect.selectRegion(in: snapshot) else {
                finishCancellation(ifCurrent: id)
                return
            }

            try verifyTopologyUnchanged(expected: snapshot, invocationID: id)
            stateBroadcaster.yield(.capturing)
            let source = try await capture.snapshot(selection.region, topology: snapshot)

            try verifyTopologyUnchanged(expected: snapshot, invocationID: id)
            stateBroadcaster.yield(.detecting)
            let blocks = try await detect.detect(source)
            let translationBlocks = TranslationBlockGrouper.groupedForContext(blocks)

            try verifyTopologyUnchanged(expected: snapshot, invocationID: id)
            stateBroadcaster.yield(.translating)
            let targetLanguage = await MainActor.run { settings.defaultTargetLanguage }
            let translations = try await translate.translate(translationBlocks, to: targetLanguage, invocationOverride: nil)

            try verifyTopologyUnchanged(expected: snapshot, invocationID: id)
            let session = OverlaySessionModel(
                invocationID: id,
                topology: snapshot,
                source: source,
                translations: translations
            )
            let handle = await overlay.present(session)
            guard isCurrent(id) else {
                await handle.dismiss()
                return
            }

            currentOverlay = handle
            currentOverlayContext = ActiveOverlayContext(
                blocks: translationBlocks,
                translations: translations,
                currentRequest: OverlayRetranslationRequest(targetLanguage: targetLanguage)
            )
            stateBroadcaster.yield(.presenting(overlaySessionID: handle.sessionID))
            observeOverlayEvents(handle, invocationID: id)
            currentTask = nil
        } catch is CancellationError {
            finishCancellation(ifCurrent: id)
        } catch let error as GlanslateError {
            fail(error, invocationID: id)
        } catch {
            fail(.capture(reason: error.localizedDescription), invocationID: id)
        }
    }

    private func observeOverlayEvents(_ handle: OverlaySessionHandle, invocationID: UUID) {
        overlayEventsTask?.cancel()
        let events = handle.events
        overlayEventsTask = Task {
            for await event in events {
                await self.handleOverlayEvent(event, invocationID: invocationID)
            }
        }
    }

    private func handleOverlayEvent(_ event: OverlayEvent, invocationID: UUID) async {
        guard currentInvocationID == invocationID else { return }

        switch event {
        case .dismissed:
            currentOverlay = nil
            currentOverlayContext = nil
            retranslationTask?.cancel()
            retranslationTask = nil
            overlayEventsTask?.cancel()
            overlayEventsTask = nil
            currentInvocationID = nil
            stateBroadcaster.yield(.idle)
        case .pinned(let payload):
            do {
                try await persistPinnedPayload(payload)
            } catch {
                GlanslateLog.history.error("Failed to pin translation history: \(error.localizedDescription, privacy: .public)")
            }
        case .unpinned:
            break
        case .styleChanged:
            break
        case .retranslateRequested(let request):
            scheduleRetranslation(request, invocationID: invocationID)
        case .peekBegan, .peekEnded:
            break
        }
    }

    private func scheduleRetranslation(
        _ request: OverlayRetranslationRequest,
        invocationID: UUID
    ) {
        guard let context = currentOverlayContext, let overlayHandle = currentOverlay else { return }

        retranslationTask?.cancel()
        retranslationTask = Task { [blocks = context.blocks] in
            await self.performRetranslation(
                request,
                invocationID: invocationID,
                blocks: blocks,
                overlayHandle: overlayHandle
            )
        }
    }

    private func performRetranslation(
        _ request: OverlayRetranslationRequest,
        invocationID: UUID,
        blocks: [TextBlock],
        overlayHandle: OverlaySessionHandle
    ) async {
        do {
            let translations = try await translate.translate(
                blocks,
                to: request.targetLanguage,
                invocationOverride: InvocationRoutingOverride(
                    provider: request.provider,
                    sourceLanguage: request.sourceLanguage
                )
            )

            guard currentInvocationID == invocationID else { return }
            currentOverlayContext?.translations = translations
            currentOverlayContext?.currentRequest = request
            await overlayHandle.applyRetranslation(translations, request: request)
        } catch is CancellationError {
            await overlayHandle.finishRetranslation()
        } catch GlanslateError.cancelled {
            await overlayHandle.finishRetranslation()
        } catch {
            guard currentInvocationID == invocationID else { return }
            GlanslateLog.translate.error("Retranslation failed: \(error.localizedDescription, privacy: .public)")
            await overlayHandle.finishRetranslation()
            let toastError = await retranslationError(from: error, request: request)
            await showErrorToast(toastError)
        }
    }

    @MainActor
    private func persistPinnedPayload(_ payload: OverlayPinnedPayload) async throws {
        for translation in payload.translations {
            try await history.pin(translation, thumbnail: payload.thumbnailPNG)
        }
    }

    private func verifyTopologyUnchanged(
        expected snapshot: DisplayTopologySnapshot,
        invocationID: UUID
    ) throws {
        try Task.checkCancellation()
        guard currentInvocationID == invocationID else {
            throw CancellationError()
        }
        guard topology.current().hasSameArrangement(as: snapshot) else {
            throw GlanslateError.displayTopologyChanged
        }
    }

    private func isCurrent(_ invocationID: UUID) -> Bool {
        currentInvocationID == invocationID
    }

    private func finishCancellation(ifCurrent invocationID: UUID) {
        guard currentInvocationID == invocationID else { return }
        currentInvocationID = nil
        currentTask = nil
        currentOverlayContext = nil
        retranslationTask?.cancel()
        retranslationTask = nil
        stateBroadcaster.yield(.cancelled)
        stateBroadcaster.yield(.idle)
    }

    private func fail(_ error: GlanslateError, invocationID: UUID) {
        guard currentInvocationID == invocationID else { return }
        currentInvocationID = nil
        currentTask = nil
        currentOverlayContext = nil
        retranslationTask?.cancel()
        retranslationTask = nil
        stateBroadcaster.yield(.errored(error))
        stateBroadcaster.yield(.idle)

        Task {
            await self.showErrorToast(error)
        }
    }

    private func retranslationError(
        from error: Error,
        request: OverlayRetranslationRequest
    ) async -> GlanslateError {
        if let glanslateError = error as? GlanslateError {
            return glanslateError
        }

        let provider: TranslationProvider
        if let requestedProvider = request.provider {
            provider = requestedProvider
        } else {
            provider = await MainActor.run { settings.preferredProvider }
        }
        return .translation(provider: provider, reason: error.localizedDescription)
    }

    private func showErrorToast(_ error: GlanslateError) async {
        let display = await overlay.currentDisplayID()
        let presenter = await MainActor.run { errorToastPresenter }
        await presenter?.showToast(error, display: display)
    }
}

final class AsyncStreamBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Element
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    init(seed: Element) {
        self.latest = seed
    }

    func stream() -> AsyncStream<Element> {
        AsyncStream<Element> { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let latestValue = latest
            continuation.yield(latestValue)
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    func yield(_ value: Element) {
        lock.lock()
        defer { lock.unlock() }
        latest = value
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
