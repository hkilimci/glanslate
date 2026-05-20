import SwiftData
import SwiftUI
import AppKit

@main
struct GlanslateApp: App {
    @NSApplicationDelegateAdaptor(GlanslateAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Glanslate", systemImage: "character.bubble") {
            MenuBarExtraView(appRoot: appDelegate.appRoot)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            let appRoot = appDelegate.appRoot
            if let container = appRoot.historyContainer {
                SettingsSceneView(appRoot: appRoot)
                    .modelContainer(container)
            } else {
                SettingsSceneView(appRoot: appRoot)
            }
        }
    }
}

@MainActor
final class GlanslateAppDelegate: NSObject, NSApplicationDelegate {
    let appRoot = AppRoot()
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateDockIconVisibility()
        NotificationCenter.default.addObserver(
            forName: .updateDockIconVisibility,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDockIconVisibility()
            }
        }
    }

    private func updateDockIconVisibility() {
        let showDockIcon = appRoot.settingsStore.showDockIcon
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        Task { @MainActor in
            await appRoot.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}
