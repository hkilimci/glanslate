import AppKit
import GlanslateCore
import SwiftUI

/// A brief floating message for problems that happen before an overlay exists.
@MainActor
final class ToastPresenter {
    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ error: GlanslateError, near anchor: CGRect? = nil, action: (title: String, handler: @MainActor () -> Void)? = nil) {
        guard error != .cancelled else { return }
        dismiss()

        let view = ToastView(
            title: error.title,
            message: error.message,
            actionTitle: action?.title,
            onAction: { [weak self] in
                action?.handler()
                self?.dismiss()
            }
        )
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize

        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame: CGRect
        if let anchor, anchor.intersects(visible) {
            frame = FloatingToolbarPlacement.place(toolbar: size, near: anchor, within: visible).frame
        } else {
            frame = CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12, width: size.width, height: size.height)
        }

        let panel = OverlayPanel(frame: frame)
        panel.level = .statusBar
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: host,
            notification: .announcementRequested,
            userInfo: [.announcement: "\(error.title). \(error.message)", .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(action == nil ? 4 : 7))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct ToastView: View {
    let title: String
    let message: String
    let actionTitle: String?
    let onAction: @MainActor () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340, alignment: .leading)
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .toolbarSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(12)
        .fixedSize()
    }
}
