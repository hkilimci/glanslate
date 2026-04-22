import SwiftData
import SwiftUI

@main
struct GlanslateApp: App {
    @State private var appRoot = AppRoot()

    var body: some Scene {
        MenuBarExtra("Glanslate", systemImage: "character.bubble") {
            MenuBarExtraView(appRoot: appRoot)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsSceneView(appRoot: appRoot)
                .modelContainer(appRoot.historyStore.container)
        }
    }
}
