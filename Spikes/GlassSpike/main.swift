// Spike harness for Phase 0.5: Glass sampling + key-window event delivery
// Build with: swiftc -typealias MainActor -Xfrontend -enable-upcoming-feature -Xfrontend global-actor-isolation -target arm64-apple-macos26.0 main.swift -o GlassSpike && ./GlassSpike
// Or: swift package init --type executable --name GlassSpike

import AppKit
import SwiftUI

@main
struct GlassSpikeApp {
    static func main() {
        let delegate = GlassSpikeAppDelegate()
        NSApp.setDelegate(delegate)
        NSApp.run()
    }
}

final class GlassSpikeAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupKeyMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupWindow() {
        let contentView = NSHostingView(rootView: GlassSpikeContentView())
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.level = .statusBar + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.window.close()
                self?.cleanup()
                return nil
            }
            return event
        }
    }

    private func cleanup() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

struct GlassSpikeContentView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.2), lineWidth: 1)

            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                Text("Glass Spike")
                    .font(.headline)

                Text("Press Esc to close")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("This window tests .glassEffect() sampling")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 400, height: 300)
    }
}
