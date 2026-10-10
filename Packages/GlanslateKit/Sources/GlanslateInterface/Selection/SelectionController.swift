import AppKit
import GlanslateCapture
import GlanslateCore
import GlanslateSystem
import SwiftUI

/// Presents the full-screen selection interface on every display and returns
/// what the user picked, or `nil` when they cancel.
@MainActor
final class SelectionController {
    enum Mode {
        case area
        case window
    }

    private(set) var mode: Mode = .area
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<SelectionTarget?, Never>?
    private var escapeToken: HotKeyCenter.Token?
    private var layout = DisplayLayout(displays: [])
    private var windows: [WindowInfo] = []

    var isActive: Bool { continuation != nil }

    func select() async -> SelectionTarget? {
        guard continuation == nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                present()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        finish(with: nil)
    }

    // MARK: Presentation

    private func present() {
        layout = .current
        windows = WindowCatalog.onScreenWindows()
        mode = .area

        let pointer = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let display = screen.displayDescriptor else { continue }
            let view = SelectionView(display: display, controller: self)
            let panel = SelectionPanel(screen: screen, view: view)
            panels.append(panel)
            if screen.frame.contains(pointer) {
                view.showsHints = true
            }
        }
        if !panels.contains(where: { $0.selectionView.showsHints }) {
            panels.first?.selectionView.showsHints = true
        }

        NSApp.activate()
        for panel in panels {
            panel.orderFrontRegardless()
        }
        (panels.first { $0.selectionView.showsHints } ?? panels.first)?.makeKey()

        // Escape must cancel even if another app keeps keyboard focus.
        escapeToken = try? HotKeyCenter.shared.register(KeyCombo(keyCode: 0x35, modifiers: [], key: "⎋")) { [weak self] in
            self?.cancel()
        }
    }

    fileprivate func finish(with target: SelectionTarget?) {
        guard let continuation else { return }
        self.continuation = nil
        if let escapeToken {
            HotKeyCenter.shared.unregister(escapeToken)
            self.escapeToken = nil
        }
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        NSCursor.arrow.set()
        continuation.resume(returning: target)
    }

    // MARK: Interaction from views

    fileprivate func toggleMode() {
        mode = mode == .area ? .window : .area
        for panel in panels {
            panel.selectionView.modeDidChange()
        }
    }

    /// The frontmost window under a display-local point, clipped to that display.
    fileprivate func window(at point: CGPoint, on display: DisplayDescriptor) -> (id: UInt32, rect: CGRect)? {
        let space = ScreenCoordinateSpace(layout: layout)
        for window in windows {
            let local = space.localRect(fromQuartz: window.quartzFrame, on: display)
            guard local.contains(point),
                  let clipped = SelectionGeometry.windowRegion(localFrame: local, displayBounds: display.localBounds) else { continue }
            return (window.id, clipped)
        }
        return nil
    }
}

/// A borderless panel covering one display, above the menu bar and Dock.
final class SelectionPanel: NSPanel {
    let selectionView: SelectionView

    init(screen: NSScreen, view: SelectionView) {
        selectionView = view
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the dimmed screen, the selection or hovered window, and keyboard hints.
final class SelectionView: NSView {
    let display: DisplayDescriptor
    private weak var controller: SelectionController?

    private var anchor: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: (id: UInt32, rect: CGRect)?
    private var hintHost: NSHostingView<SelectionHintView>?
    private var hintModel = SelectionHintModel()
    private var messageTask: Task<Void, Never>?

    var showsHints = false {
        didSet { hintHost?.isHidden = !showsHints }
    }

    init(display: DisplayDescriptor, controller: SelectionController) {
        self.display = display
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        let host = NSHostingView(rootView: SelectionHintView(model: hintModel))
        // The hints sit on dimmed content, so they always use the dark appearance.
        host.appearance = NSAppearance(named: .darkAqua)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(display.visibleFrame.minY - display.frame.minY + 24)),
        ])
        hintHost = host
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screen selection. Drag to select an area, press Space to choose a window, or Escape to cancel.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: controller?.mode == .window ? .pointingHand : .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        (controller?.mode == .window ? NSCursor.pointingHand : NSCursor.crosshair).set()
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        cursorUpdate(with: event)
    }

    func modeDidChange() {
        anchor = nil
        selection = nil
        hoveredWindow = nil
        hintModel.mode = controller?.mode ?? .area
        window?.invalidateCursorRects(for: self)
        if let point = window?.mouseLocationOutsideOfEventStream, controller?.mode == .window {
            updateHover(at: convert(point, from: nil))
        }
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        guard controller?.mode == .window else { return }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    private func updateHover(at point: CGPoint) {
        let hovered = controller?.window(at: point, on: display)
        if hovered?.id != hoveredWindow?.id || hovered?.rect != hoveredWindow?.rect {
            hoveredWindow = hovered
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch controller?.mode {
        case .window:
            updateHover(at: point)
            if let hoveredWindow {
                controller?.finish(with: .window(id: hoveredWindow.id, region: ScreenRegion(displayID: display.id, rect: hoveredWindow.rect)))
            } else {
                showMessage("There’s no window here. Press Space to drag an area instead.")
            }
        default:
            anchor = SelectionGeometry.clamp(point, to: bounds)
            selection = nil
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard controller?.mode == .area, let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = SelectionGeometry.dragRect(from: anchor, to: point, within: bounds)
        if SelectionGeometry.isOutside(point, bounds: bounds) {
            showMessage(SelectionIssue.outsideDisplay.message)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard controller?.mode == .area, anchor != nil else { return }
        defer {
            anchor = nil
            needsDisplay = true
        }
        guard let selection, selection.width > 3 || selection.height > 3 else {
            self.selection = nil
            showMessage("Drag across the text you want to translate, or press Space to choose a window.")
            return
        }
        switch SelectionGeometry.validate(selection, within: bounds) {
        case .success(let rect):
            controller?.finish(with: .area(ScreenRegion(displayID: display.id, rect: rect)))
        case .failure(let issue):
            self.selection = nil
            showMessage(issue.message)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x35: controller?.cancel()
        case 0x31: controller?.toggleMode()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancel()
    }

    private func showMessage(_ text: String) {
        guard hintModel.message != text else { return }
        hintModel.message = text
        showsHints = true
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.hintModel.message = nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.28)
        let highlight: CGRect?
        switch controller?.mode {
        case .window: highlight = hoveredWindow?.rect
        default: highlight = selection
        }

        let path = NSBezierPath(rect: bounds)
        if let highlight, highlight.width > 0, highlight.height > 0 {
            path.append(NSBezierPath(rect: highlight))
            path.windingRule = .evenOdd
        }
        dim.setFill()
        path.fill()

        guard let highlight, highlight.width > 0, highlight.height > 0 else { return }

        if controller?.mode == .window {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            highlight.fill()
            let outline = NSBezierPath(rect: highlight.insetBy(dx: 1.5, dy: 1.5))
            outline.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
            return
        }

        // A white outline with a soft dark halo reads on light and dark content alike.
        let halo = NSBezierPath(rect: highlight.insetBy(dx: -0.5, dy: -0.5))
        halo.lineWidth = 2
        NSColor.black.withAlphaComponent(0.35).setStroke()
        halo.stroke()
        let outline = NSBezierPath(rect: highlight.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        NSColor.white.setStroke()
        outline.stroke()

        drawDimensions(for: highlight)
    }

    private func drawDimensions(for rect: CGRect) {
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let badge = CGSize(width: size.width + 12, height: size.height + 6)
        var origin = CGPoint(x: rect.maxX - badge.width, y: rect.maxY + 6)
        if origin.y + badge.height > bounds.maxY - 4 { origin.y = rect.maxY - badge.height - 6 }
        origin.x = max(bounds.minX + 4, origin.x)
        let badgeRect = CGRect(origin: origin, size: badge)
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        text.draw(at: CGPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3), withAttributes: attributes)
    }
}

@MainActor
@Observable
final class SelectionHintModel {
    var mode: SelectionController.Mode = .area
    var message: String?
}

/// The compact keyboard hint capsule shown at the bottom of the screen.
/// It always sits on dimmed content, so it uses light text on dark glass.
struct SelectionHintView: View {
    let model: SelectionHintModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 14) {
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.white)
                    .transition(.opacity)
            } else {
                hint(model.mode == .area ? "Drag to select text" : "Click a window to translate it", keys: [])
                hint(model.mode == .area ? "Window" : "Area", keys: ["Space"])
                hint("Cancel", keys: ["esc"])
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.black.opacity(reduceTransparency ? 0.85 : 0.45), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .animation(MotionAwareAnimation.standard(reduceMotion), value: model.message)
        .fixedSize()
        .padding(20)
    }

    private func hint(_ text: String, keys: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 18)
                    .background(Color.white.opacity(0.18), in: .rect(cornerRadius: 4, style: .continuous))
            }
            Text(text).foregroundStyle(Color.white.opacity(0.8))
        }
    }
}
