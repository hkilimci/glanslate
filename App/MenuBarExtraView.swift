import AppKit
import SwiftUI

struct MenuBarExtraView: View {
    let appRoot: AppRoot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Glanslate")
                .font(.headline)

            Button("Translate Region") {
                Task {
                    await appRoot.invocationController.start()
                }
            }

            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Check for Updates…") {
                if let url = URL(string: "https://github.com/glanslate/releases") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 220)
    }
}
