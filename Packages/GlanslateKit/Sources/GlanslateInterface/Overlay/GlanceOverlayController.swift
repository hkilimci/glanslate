import AppKit
import GlanslateCore
import GlanslateSystem
import SwiftUI

/// A borderless floating panel for overlay content. Transparent areas let
/// clicks through to the app underneath.
final class OverlayPanel: NSPanel {
    /// Called when the user presses Escape while this panel has keyboard focus.
    var onCancel: (@MainActor () -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}

/// A hosting view that reports when its SwiftUI content changes size.
final class SelfSizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((CGSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onSizeChange?(self.fittingSize)
        }
    }
}

/// Shows one ``GlanceSession``: the translated blocks over the region and the
/// floating toolbar next to it. Also watches the reveal modifier key.
@MainActor
final class GlanceOverlayController {
    let session: GlanceSession
    let toolbarContext = ToolbarContext()

    private let settings: AppSettings
    private let canvasPanel: OverlayPanel
    private let toolbarPanel: OverlayPanel
    private let measurer = AppKitTextMeasurer()
    private var modifierTimer: Timer?
    private var copyResetTask: Task<Void, Never>?

    init(session: GlanceSession, settings: AppSettings, actions: GlanceToolbarActions) {
        self.session = session
        self.settings = settings
        let regionFrame = session.appKitFrame

        canvasPanel = OverlayPanel(frame: regionFrame)
        let canvas = NSHostingView(rootView: OverlayCanvas(session: session, settings: settings))
        canvas.sizingOptions = []
        canvasPanel.contentView = canvas
        canvasPanel.setFrame(regionFrame, display: false)

        toolbarPanel = OverlayPanel(frame: CGRect(x: regionFrame.midX, y: regionFrame.minY, width: 10, height: 10))
        // Keep the toolbar above the translation even when it overlaps a full-display region.
        toolbarPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        toolbarContext.revealModifier = settings.revealModifier
        let toolbar = SelfSizingHostingView(rootView: GlanceToolbar(session: session, context: toolbarContext, actions: actions))
        toolbar.sizingOptions = [.intrinsicContentSize]
        toolbarPanel.contentView = toolbar
        toolbar.onSizeChange = { [weak self] size in self?.placeToolbar(size: size) }
        canvasPanel.onCancel = actions.dismiss
        toolbarPanel.onCancel = actions.dismiss
        placeToolbar(size: toolbar.fittingSize)
    }

    func show() {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
        for panel in [canvasPanel, toolbarPanel] {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        toolbarPanel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            canvasPanel.animator().alphaValue = 1
            toolbarPanel.animator().alphaValue = 1
        }
        startWatchingModifier()
    }

    func close() {
        modifierTimer?.invalidate()
        modifierTimer = nil
        copyResetTask?.cancel()
        let panels = [canvasPanel, toolbarPanel]
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            for panel in panels { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                for panel in panels {
                    panel.orderOut(nil)
                    panel.close()
                }
            }
        })
    }

    func setConfiguredProviders(_ providers: Set<TranslationProvider>, canPin: Bool) {
        if toolbarContext.configuredProviders != providers { toolbarContext.configuredProviders = providers }
        toolbarContext.canPin = canPin
        if toolbarContext.revealModifier != settings.revealModifier { toolbarContext.revealModifier = settings.revealModifier }
    }

    /// Display-local frames that backdrops should cover: the laid-out blocks once
    /// a translation exists, otherwise the padded original blocks.
    func backdropFrames() -> [UUID: CGRect] {
        if !session.blockLayouts.isEmpty {
            return Dictionary(uniqueKeysWithValues: session.blockLayouts.map { ($0.id, $0.frame) })
        }
        var frames: [UUID: CGRect] = [:]
        for block in session.recognized?.blocks ?? [] {
            let padding = max(3, block.lineHeight * 0.3)
            frames[block.id] = block.frame.insetBy(dx: -padding, dy: -padding).intersection(session.region.rect)
        }
        return frames
    }

    /// Recomputes block positions for the current translation and style.
    func relayout() {
        guard let result = session.result else {
            session.blockLayouts = []
            return
        }
        let inputs = result.pairs.map { OverlayLayoutInput(block: $0.block, translation: $0.translation) }
        session.blockLayouts = OverlayLayoutEngine().layout(
            inputs,
            in: session.region.rect,
            measurer: measurer,
            textScale: CGFloat(settings.textScale)
        )
    }

    func flashCopied() {
        session.didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.session.didCopy = false
        }
    }

    // MARK: Toolbar placement

    private func placeToolbar(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let placement = FloatingToolbarPlacement.place(toolbar: size, near: session.appKitFrame, within: session.display.visibleFrame)
        if toolbarContext.edge != placement.edge { toolbarContext.edge = placement.edge }
        toolbarPanel.setFrame(placement.frame, display: true)
    }

    // MARK: Reveal modifier

    /// Polls the modifier state, which needs no Accessibility or Input Monitoring permission.
    private func startWatchingModifier() {
        modifierTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkModifier() }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }

    private func checkModifier() {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let pressed = NSEvent.modifierFlags.intersection(relevant)
        let held = pressed == settings.revealModifier.eventFlag
        if session.isRevealHeld != held { session.isRevealHeld = held }
    }
}
