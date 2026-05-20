import Foundation
import Observation
import SwiftData
import GlanslateKit

extension Notification.Name {
    static let updateDockIconVisibility = Notification.Name("updateDockIconVisibility")
}

@MainActor
@Observable
final class AppRoot {
    let settingsStore: SettingsStore
    let historyStore: any HistoryStoring
    let historyContainer: ModelContainer?
    let overlayPresenter: OverlayEngine
    let invocationController: InvocationController
    let onboardingPresenter = OnboardingPresenter()

    init() {
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore

        let (store, container) = Self.makeHistoryStore()
        self.historyStore = store
        self.historyContainer = container

        let overlayPresenter = OverlayEngine(settings: settingsStore)
        self.overlayPresenter = overlayPresenter

        let keychain = settingsStore.keychain
        let router = TranslationRouter(
            engines: [
                .apple: AppleTranslationEngine.create(),
                .deepL: DeepLEngine(keychain: keychain),
                .google: GoogleEngine(http: HTTPClient(timeout: 10)),
                .openAI: OpenAIEngine(
                    keychain: keychain,
                    model: { [settingsStore] in
                        await MainActor.run { settingsStore.openAIModel }
                    }
                )
            ],
            settings: settingsStore,
            keychain: keychain
        )

        self.invocationController = InvocationController(
            topology: RealDisplayTopology(),
            regionSelect: HUDRegionSelector(),
            capture: SCKScreenCapturer(),
            detect: TextDetectionPipeline(),
            translate: router,
            overlay: overlayPresenter,
            history: historyStore,
            settings: settingsStore
        )

        ShortcutBinding.onTriggerTranslate { [controller = invocationController] in
            Task {
                await controller.start()
            }
        }

        invocationController.setErrorToastPresenter(ErrorToastPresenter.shared)
        onboardingPresenter.checkAndShow()
    }

    func prepareForTermination() async {
        onboardingPresenter.dismiss()
        await invocationController.cancelCurrent()
        await overlayPresenter.dismissAll()
        await ErrorToastPresenter.shared.dismissCurrentToast()
    }

    func updateDockIconVisibility() {
        NotificationCenter.default.post(name: .updateDockIconVisibility, object: nil)
    }

    private static func makeHistoryStore() -> (any HistoryStoring, ModelContainer?) {
        do {
            let store = try SwiftDataHistoryStore()
            return (store, store.container)
        } catch {
            GlanslateLog.history.error("Persistent history store failed to open: \(error.localizedDescription, privacy: .public). Falling back to in-memory store.")
        }
        do {
            let store = try SwiftDataHistoryStore(inMemory: true)
            return (store, store.container)
        } catch {
            GlanslateLog.history.error("In-memory history store failed to open: \(error.localizedDescription, privacy: .public). History will be disabled this session.")
            return (NoopHistoryStore(), nil)
        }
    }
}
