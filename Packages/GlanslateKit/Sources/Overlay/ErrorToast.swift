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

        dismiss(window: currentToastWindow)

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
                dismiss(window: toastWindow)
            }
        }
    }

    public func dismissCurrentToast() async {
        dismissTask?.cancel()
        dismissTask = nil
        dismiss(window: currentToastWindow)
    }

    private func dismiss(window: NSWindow?) {
        guard let window else { return }
        if currentToastWindow === window {
            currentToastWindow = nil
        }
        window.orderOut(nil)
        window.close()
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
        self.isReleasedWhenClosed = false
        self.contentView = NSHostingView(rootView: contentView)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.animationBehavior = .none
        self.hasShadow = true
        self.ignoresMouseEvents = true

        if let display = display {
            positionOnDisplay(displayID: display)
        } else {
            center()
        }
    }

    func show() {
        self.alphaValue = 1
        self.orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionOnDisplay(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
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
