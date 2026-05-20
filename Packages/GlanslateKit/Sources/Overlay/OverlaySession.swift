import CoreGraphics
import Foundation
import GlanslateCapture
import GlanslateCore
import GlanslateGeometry

public protocol OverlayPresenting: Sendable {
    func present(_ session: OverlaySessionModel) async -> OverlaySessionHandle
    func dismissAll() async
    func currentDisplayID() async -> CGDirectDisplayID?
}

public struct OverlaySessionModel: Sendable {
    public let invocationID: UUID
    public let topology: DisplayTopologySnapshot
    public let source: SourceVisualContext
    public let translations: [Translation]

    public init(
        invocationID: UUID,
        topology: DisplayTopologySnapshot,
        source: SourceVisualContext,
        translations: [Translation]
    ) {
        self.invocationID = invocationID
        self.topology = topology
        self.source = source
        self.translations = translations
    }
}

public struct OverlayRetranslationRequest: Sendable, Hashable {
    public let targetLanguage: Language
    public let provider: TranslationProvider?
    public let sourceLanguage: Language?

    public init(
        targetLanguage: Language,
        provider: TranslationProvider? = nil,
        sourceLanguage: Language? = nil
    ) {
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.sourceLanguage = sourceLanguage
    }
}

public struct OverlayPinnedPayload: Sendable, Hashable {
    public let translations: [Translation]
    public let thumbnailPNG: Data?

    public init(translations: [Translation], thumbnailPNG: Data?) {
        self.translations = translations
        self.thumbnailPNG = thumbnailPNG
    }
}

public enum OverlayEvent: Sendable, Hashable {
    case styleChanged(OverlayStyle)
    case retranslateRequested(OverlayRetranslationRequest)
    case pinned(OverlayPinnedPayload)
    case unpinned(OverlayPinnedPayload)
    case dismissed
    case peekBegan
    case peekEnded
}

public actor OverlaySessionHandle {
    public nonisolated let sessionID: UUID
    private let onPin: @Sendable () async -> OverlayPinnedPayload
    private let onUnpin: @Sendable () async -> OverlayPinnedPayload
    private let onRetranslateRequested: @Sendable (OverlayRetranslationRequest) async -> Void
    private let onApplyRetranslation: @Sendable ([Translation], OverlayRetranslationRequest) async -> Void
    private let onFinishRetranslation: @Sendable () async -> Void
    private let onSetStyle: @Sendable (OverlayStyle) async -> Void
    private let onBeginPeek: @Sendable () async -> Void
    private let onEndPeek: @Sendable () async -> Void
    private let onDismiss: @Sendable (UUID) async -> Void
    private let eventStream: AsyncStream<OverlayEvent>
    private let continuation: AsyncStream<OverlayEvent>.Continuation
    private var isDismissed = false
    private var isPinned = false
    private var isPeeking = false

    public nonisolated var events: AsyncStream<OverlayEvent> {
        eventStream
    }

    public init(
        sessionID: UUID = UUID(),
        onPin: @escaping @Sendable () async -> OverlayPinnedPayload = {
            OverlayPinnedPayload(translations: [], thumbnailPNG: nil)
        },
        onUnpin: @escaping @Sendable () async -> OverlayPinnedPayload = {
            OverlayPinnedPayload(translations: [], thumbnailPNG: nil)
        },
        onRetranslateRequested: @escaping @Sendable (OverlayRetranslationRequest) async -> Void = { _ in },
        onApplyRetranslation: @escaping @Sendable ([Translation], OverlayRetranslationRequest) async -> Void = { _, _ in },
        onFinishRetranslation: @escaping @Sendable () async -> Void = {},
        onSetStyle: @escaping @Sendable (OverlayStyle) async -> Void = { _ in },
        onBeginPeek: @escaping @Sendable () async -> Void = {},
        onEndPeek: @escaping @Sendable () async -> Void = {},
        onDismiss: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.onPin = onPin
        self.onUnpin = onUnpin
        self.onRetranslateRequested = onRetranslateRequested
        self.onApplyRetranslation = onApplyRetranslation
        self.onFinishRetranslation = onFinishRetranslation
        self.onSetStyle = onSetStyle
        self.onBeginPeek = onBeginPeek
        self.onEndPeek = onEndPeek
        self.onDismiss = onDismiss
        var localContinuation: AsyncStream<OverlayEvent>.Continuation?
        self.eventStream = AsyncStream<OverlayEvent> { continuation in
            localContinuation = continuation
        }
        self.continuation = localContinuation!
    }

    public func pin() async {
        guard !isDismissed, !isPinned else { return }
        isPinned = true
        let payload = await onPin()
        continuation.yield(.pinned(payload))
    }

    public func unpin() async {
        guard !isDismissed, isPinned else { return }
        isPinned = false
        let payload = await onUnpin()
        continuation.yield(.unpinned(payload))
    }

    public func togglePin() async {
        guard !isDismissed else { return }
        if isPinned {
            isPinned = false
            let payload = await onUnpin()
            continuation.yield(.unpinned(payload))
        } else {
            isPinned = true
            let payload = await onPin()
            continuation.yield(.pinned(payload))
        }
    }

    public func requestRetranslation(_ request: OverlayRetranslationRequest) async {
        guard !isDismissed else { return }
        await onRetranslateRequested(request)
        continuation.yield(.retranslateRequested(request))
    }

    public func applyRetranslation(
        _ translations: [Translation],
        request: OverlayRetranslationRequest
    ) async {
        guard !isDismissed else { return }
        await onApplyRetranslation(translations, request)
    }

    public func finishRetranslation() async {
        guard !isDismissed else { return }
        await onFinishRetranslation()
    }

    public func setStyle(_ style: OverlayStyle) async {
        guard !isDismissed else { return }
        await onSetStyle(style)
        continuation.yield(.styleChanged(style))
    }

    public func beginPeek() async {
        guard !isDismissed, !isPeeking else { return }
        isPeeking = true
        await onBeginPeek()
        continuation.yield(.peekBegan)
    }

    public func endPeek() async {
        guard !isDismissed, isPeeking else { return }
        isPeeking = false
        await onEndPeek()
        continuation.yield(.peekEnded)
    }

    public func togglePeek() async {
        guard !isDismissed else { return }
        if isPeeking {
            isPeeking = false
            await onEndPeek()
            continuation.yield(.peekEnded)
        } else {
            isPeeking = true
            await onBeginPeek()
            continuation.yield(.peekBegan)
        }
    }

    public func dismiss() async {
        guard !isDismissed else { return }
        isDismissed = true
        continuation.yield(.dismissed)
        continuation.finish()
        await onDismiss(sessionID)
    }
}

public actor NoopOverlayPresenter: OverlayPresenting {
    private var handles: [UUID: OverlaySessionHandle] = [:]

    public init() {}

    public func present(_ session: OverlaySessionModel) async -> OverlaySessionHandle {
        let sessionID = UUID()
        let handle = OverlaySessionHandle(
            sessionID: sessionID,
            onPin: {
                OverlayPinnedPayload(
                    translations: session.translations,
                    thumbnailPNG: nil
                )
            },
            onUnpin: {
                OverlayPinnedPayload(
                    translations: session.translations,
                    thumbnailPNG: nil
                )
            },
            onDismiss: { [self] closedID in
                await removeHandle(id: closedID)
            }
        )
        handles[sessionID] = handle
        return handle
    }

    public func dismissAll() async {
        let activeHandles = Array(handles.values)
        handles.removeAll()
        for handle in activeHandles {
            await handle.dismiss()
        }
    }

    public func currentDisplayID() async -> CGDirectDisplayID? {
        nil
    }

    func activeSessionCount() -> Int {
        handles.count
    }

    private func removeHandle(id: UUID) {
        handles[id] = nil
    }
}
