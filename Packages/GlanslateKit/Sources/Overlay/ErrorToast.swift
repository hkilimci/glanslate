import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import GlanslateCore
import GlanslateGeometry

@MainActor
public protocol ErrorToasting: AnyObject {
    func showToast(_ error: GlanslateError, display: CGDirectDisplayID?) async
}

@MainActor
public final class ErrorToastPresenter: ErrorToasting {
    public static let shared = ErrorToastPresenter()

    private var currentToastWindow: NSWindow?
    private var dismissTask: Task<Void, Never>?

    public func showToast(_ error: GlanslateError, display: CGDirectDisplayID?) async {
        dismissTask?.cancel()
        dismissTask = nil

        currentToastWindow?.close()

        let toastWindow = ToastWindow(
            message: error.localizedDescription,
            display: display
        )
        toastWindow.show()
        currentToastWindow = toastWindow

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                toastWindow.performClose(nil)
                currentToastWindow = nil
            }
        }
    }

    private func positionOnDisplay(_ window: NSWindow, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let deviceDescription = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return deviceDescription == displayID
        }) else {
            window.center()
            return
        }

        let screenFrame = screen.visibleFrame
        let windowFrame = window.frame
        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.midY - windowFrame.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
private final class ToastWindow: NSWindow {
    init(message: String, display: CGDirectDisplayID?) {
        let contentView = ToastContentView(message: message)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.contentView = NSHostingView(rootView: contentView)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.hasShadow = true

        if let display = display {
            positionOnDisplay(displayID: display)
        } else {
            center()
        }
    }

    func show() {
        self.alphaValue = 0
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1
        }
    }

    private func positionOnDisplay(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let deviceDescription = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return deviceDescription == displayID
        }) else {
            center()
            return
        }

        let screenFrame = screen.visibleFrame
        let windowFrame = self.frame
        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.midY - windowFrame.height / 2
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct ToastContentView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
