import AppKit
import GlanslateAppleTranslation
import GlanslateCapture
import GlanslateCore
import GlanslatePersistence
import GlanslateRecognition
import GlanslateSystem
import OSLog

/// Runs the primary workflow: select → capture → recognize → translate → present.
///
/// Every step is cancellable. Only one glance is on screen at a time; starting
/// a new one dismisses the previous overlay, and retranslations replace the
/// running request so an older response can never overwrite a newer one.
@MainActor
final class GlanceController {
    struct Navigation {
        var showPermissions: @MainActor () -> Void
        var openSettings: @MainActor (SettingsSection) -> Void
        var downloadLanguages: @MainActor (Language, Language) -> Void
    }

    private static let log = Logger(subsystem: "app.glanslate", category: "workflow")

    private let settings: AppSettings
    private let store: SavedTranslationStore?
    private let credentials: any CredentialStoring
    private let navigation: Navigation
    private let selection = SelectionController()
    private let capturer: any ScreenCapturing = ScreenCaptureService()
    private let recognizer = TextRecognitionService()
    private let transport = URLSessionTransport()
    private let toasts = ToastPresenter()
    private let translationRunner = LatestTaskRunner<TranslationOutcome>()

    private var workflow: Task<Void, Never>?
    private var backdropTask: Task<Void, Never>?
    /// The app that was in front before Glanslate took focus for a selection.
    private var previousApplication: NSRunningApplication?
    private var current: GlanceOverlayController?
    private var screenObserver: (any NSObjectProtocol)?

    init(settings: AppSettings, store: SavedTranslationStore?, credentials: any CredentialStoring, navigation: Navigation) {
        self.settings = settings
        self.store = store
        self.credentials = credentials
        self.navigation = navigation
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysDidChange() }
        }
    }

    var isSelecting: Bool { selection.isActive }

    // MARK: Workflow

    /// Starts a new glance. Pressing the shortcut again while selecting cancels.
    func translateRegion() {
        if selection.isActive {
            selection.cancel()
            return
        }
        guard Permission.screenRecording.isGranted else {
            navigation.showPermissions()
            return
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            previousApplication = frontmost
        }
        dismiss(restoringFocus: false)
        toasts.dismiss()
        workflow?.cancel()
        workflow = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        guard let target = await selection.select(), !Task.isCancelled else {
            restoreFocus()
            return
        }

        let layout = DisplayLayout.current
        guard let display = layout.display(withID: target.region.displayID) else {
            toasts.show(.displayChanged)
            return
        }
        let session = GlanceSession(
            target: target,
            display: display,
            layout: layout,
            sourceLanguage: settings.sourceLanguage,
            targetLanguage: settings.targetLanguage,
            style: settings.overlayStyle
        )
        let overlay = GlanceOverlayController(session: session, settings: settings, actions: actions(for: session))
        overlay.setConfiguredProviders(configuredProviders(), canPin: store != nil)
        current = overlay
        overlay.show()

        do {
            let capture = try await capturer.capture(target)
            try Task.checkCancellation()
            session.capture = capture
            session.phase = .recognizing

            let quartzRect = settings.usesAccessibilityText && AccessibilityTextReader.isAvailable
                ? ScreenCoordinateSpace(layout: layout).quartzRect(for: target.region)
                : nil
            let recognized = try await recognizer.recognize(
                image: capture.cgImage,
                geometry: capture.geometry,
                region: target.region,
                quartzRect: quartzRect,
                sourceHint: session.sourceLanguage.language
            )
            try Task.checkCancellation()
            guard !recognized.isEmpty else { throw GlanslateError.noTextFound }
            Self.log.info("Recognized \(recognized.blocks.count, privacy: .public) blocks (accessibility: \(recognized.usedAccessibility, privacy: .public))")

            session.recognized = recognized
            renderBackdrops(for: session)
            translate(session)
        } catch is CancellationError {
            return
        } catch {
            let failure = error as? GlanslateError ?? .captureFailed(detail: String(describing: type(of: error)))
            guard failure != .cancelled else { return }
            Self.log.error("Glance failed: \(failure.title, privacy: .public)")
            session.error = failure
            session.phase = .failed
        }
    }

    /// Translates (or retranslates) the session's recognized text with its current choices.
    func translate(_ session: GlanceSession) {
        guard let recognized = session.recognized else { return }
        current?.setConfiguredProviders(configuredProviders(), canPin: store != nil)
        session.error = nil
        if session.result == nil {
            session.phase = .translating
        } else {
            session.isRetranslating = true
        }

        let request = TranslationRequest(
            texts: recognized.blocks.map(\.text),
            source: session.sourceLanguage,
            detected: recognized.detectedLanguage,
            target: session.targetLanguage,
            choice: session.providerChoice
        )
        let router = makeRouter()
        let policy = settings.routingPolicy

        translationRunner.run({
            try await router.translate(request, policy: policy)
        }, completion: { [weak self, weak session] result in
            guard let self, let session, self.current?.session === session else { return }
            session.isRetranslating = false
            switch result {
            case .success(let outcome):
                session.result = GlanceResult(recognized: recognized, outcome: outcome)
                session.error = nil
                session.phase = .ready
                self.current?.relayout()
                self.renderBackdrops(for: session)
                if session.isPinned { self.savePinned(session) }
                Self.log.info("Translated with \(outcome.provider.rawValue, privacy: .public)")
            case .failure(let error):
                if error is CancellationError { return }
                let failure = error as? GlanslateError ?? .providerFailure(.apple, detail: String(describing: type(of: error)))
                guard failure != .cancelled else { return }
                Self.log.error("Translation failed: \(failure.title, privacy: .public)")
                session.error = failure
                if session.result == nil { session.phase = .failed }
            }
        })
    }

    private func makeRouter() -> TranslationRouter {
        TranslationRouter(
            engines: [
                AppleTranslationEngine(),
                DeepLEngine(credentials: credentials, transport: transport),
                GoogleTranslateEngine(credentials: credentials, transport: transport),
                OpenAIEngine(credentials: credentials, transport: transport, model: settings.openAIModel),
            ],
            consent: ConsentPrompter(settings: settings)
        )
    }

    private func renderBackdrops(for session: GlanceSession) {
        guard let capture = session.capture, let overlay = current, overlay.session === session else { return }
        // Crop exactly the frames the blocks are drawn in, so blurred backdrops aren't stretched.
        let frames = overlay.backdropFrames().mapValues { $0.intersection(session.region.rect) }.filter { !$0.value.isNull }
        backdropTask?.cancel()
        backdropTask = Task { [weak session] in
            let backdrops = await BackdropRenderer.render(capture: capture, frames: frames)
            guard !Task.isCancelled else { return }
            session?.backdrops = backdrops
        }
    }

    // MARK: Toolbar actions

    private func actions(for session: GlanceSession) -> GlanceToolbarActions {
        GlanceToolbarActions(
            dismiss: { [weak self] in self?.dismiss() },
            copy: { [weak self, weak session] in
                guard let session, let result = session.result else { return }
                Pasteboard.copy(result.translatedText)
                self?.current?.flashCopied()
            },
            togglePin: { [weak self, weak session] in
                guard let self, let session else { return }
                self.togglePin(session)
            },
            toggleReveal: { [weak session] in
                session?.isRevealToggled.toggle()
            },
            setSource: { [weak self, weak session] source in
                guard let self, let session, session.sourceLanguage != source else { return }
                session.sourceLanguage = source
                self.translate(session)
            },
            setTarget: { [weak self, weak session] target in
                guard let self, let session, session.targetLanguage != target else { return }
                session.targetLanguage = target
                self.translate(session)
            },
            setProvider: { [weak self, weak session] choice in
                guard let self, let session, session.providerChoice != choice else { return }
                session.providerChoice = choice
                self.translate(session)
            },
            setStyle: { [weak self, weak session] style in
                session?.style = style
                self?.current?.relayout()
            },
            recover: { [weak self, weak session] recovery in
                guard let self, let session else { return }
                self.perform(recovery, for: session)
            }
        )
    }

    private func perform(_ recovery: GlanslateError.Recovery, for session: GlanceSession) {
        switch recovery {
        case .openScreenRecordingSettings:
            Permission.screenRecording.requestAndOpenSettings()
        case .openProviderSettings:
            navigation.openSettings(.translation)
        case .downloadLanguages(let source, let target):
            navigation.downloadLanguages(source, target)
        case .retry:
            translate(session)
        case .selectAgain:
            translateRegion()
        case .chooseSourceLanguage, .chooseTargetLanguage, .chooseProvider:
            break
        }
    }

    private func togglePin(_ session: GlanceSession) {
        guard let store, session.result != nil else { return }
        if session.isPinned {
            do {
                try store.delete(id: session.id)
                session.isPinned = false
            } catch {
                Self.log.error("Couldn’t remove saved translation")
                session.error = .saveFailed
            }
        } else {
            savePinned(session)
        }
    }

    private func savePinned(_ session: GlanceSession) {
        guard let store, let result = session.result else { return }
        let thumbnail = settings.savesThumbnails ? session.capture?.thumbnailData() : nil
        do {
            try store.save(SavedTranslationDraft(id: session.id, result: result, thumbnail: thumbnail))
            session.isPinned = true
        } catch {
            Self.log.error("Couldn’t save translation")
            session.error = .saveFailed
        }
    }

    private func configuredProviders() -> Set<TranslationProvider> {
        Set(TranslationProvider.allCases.filter { !$0.requiresCredential || credentials.hasCredential(for: $0) })
    }

    // MARK: Lifecycle

    /// Hides the current overlay and cancels any work for it.
    func dismiss() {
        dismiss(restoringFocus: true)
    }

    private func dismiss(restoringFocus: Bool) {
        let hadOverlay = current != nil
        translationRunner.cancel()
        backdropTask?.cancel()
        workflow?.cancel()
        current?.close()
        current = nil
        if restoringFocus, hadOverlay { restoreFocus() }
    }

    /// Hands keyboard focus back to the app the user was in, unless one of
    /// Glanslate's own windows (Settings, Saved Translations) is in front.
    private func restoreFocus() {
        guard NSApp.isActive, let app = previousApplication, !app.isTerminated else { return }
        if let key = NSApp.keyWindow, !(key is NSPanel), key.isVisible { return }
        app.activate()
    }

    func cancelAll() {
        selection.cancel()
        dismiss(restoringFocus: false)
        toasts.dismiss()
    }

    private func displaysDidChange() {
        if selection.isActive {
            selection.cancel()
            toasts.show(.displayChanged)
        }
        if let session = current?.session, !session.layout.hasSameArrangement(as: .current) {
            dismiss()
            toasts.show(.displayChanged)
        }
    }
}
