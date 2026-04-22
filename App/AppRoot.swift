import Foundation
import Observation
import GlanslateKit

extension Notification.Name {
    static let updateDockIconVisibility = Notification.Name("updateDockIconVisibility")
}

@MainActor
@Observable
final class AppRoot {
    let settingsStore: SettingsStore
    let historyStore: SwiftDataHistoryStore
    let overlayPresenter: OverlayEngine
    let invocationController: InvocationController
    let onboardingPresenter = OnboardingPresenter()

    init() {
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore

        do {
            self.historyStore = try SwiftDataHistoryStore()
        } catch {
            self.historyStore = try! SwiftDataHistoryStore(inMemory: true)
        }

        let overlayPresenter = OverlayEngine(settings: settingsStore)
        self.overlayPresenter = overlayPresenter

        let keychain = settingsStore.keychain
        let router = TranslationRouter(
            engines: [
                .apple: AppleTranslationEngine.create(),
                .deepL: DeepLEngine(keychain: keychain),
                .google: GoogleEngine(keychain: keychain),
                .openAI: OpenAIEngine(keychain: keychain)
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
}
