import AppKit
import GlanslateCore
import GlanslateSystem
import SwiftUI

/// Records a global keyboard shortcut. While recording, the current shortcut is
/// suspended so pressing it is captured instead of starting a translation.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var onChange: () -> Void

    @Environment(AppEnvironment.self) private var app
    @State private var model = ShortcutRecorderModel()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    Text(title)
                        .monospacedDigit()
                        .frame(minWidth: 110)
                        .foregroundStyle(model.isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.bordered)
                .help(model.isRecording ? "Type the new shortcut, or press esc to cancel" : "Click to record a new shortcut")
                .accessibilityLabel(model.isRecording ? "Recording shortcut" : "Shortcut \(combo?.displayString ?? "none")")

                if combo != nil, !model.isRecording {
                    Button {
                        combo = nil
                        onChange()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
                    .accessibilityLabel("Remove shortcut")
                }
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear { if model.isRecording { stop(commit: false) } }
    }

    private var title: String {
        if model.isRecording { return "Type Shortcut…" }
        return combo?.displayString ?? "Record Shortcut"
    }

    private func toggle() {
        model.isRecording ? stop(commit: false) : start()
    }

    private func start() {
        app.commands.suspendShortcut()
        model.start { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 0x35, modifiers.isEmpty {
                stop(commit: false)
                return true
            }
            if event.keyCode == 0x33 || event.keyCode == 0x75, modifiers.isEmpty {
                combo = nil
                stop(commit: true)
                return true
            }
            guard let candidate = KeyCombo(event: event) else { return true }
            guard candidate.isValidGlobalShortcut else {
                model.message = "Include ⌘, ⌥, or ⌃ in the shortcut."
                return true
            }
            combo = candidate
            stop(commit: true)
            return true
        }
    }

    private func stop(commit: Bool) {
        model.stop()
        if commit { onChange() } else { app.commands.applyShortcut() }
    }
}

@MainActor
@Observable
final class ShortcutRecorderModel {
    var isRecording = false
    var message: String?
    @ObservationIgnored private var monitor: Any?

    /// - Parameter handler: Returns `true` when it consumed the event.
    func start(_ handler: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        isRecording = true
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let consumed = MainActor.assumeIsolated { handler(event) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        message = nil
    }
}
