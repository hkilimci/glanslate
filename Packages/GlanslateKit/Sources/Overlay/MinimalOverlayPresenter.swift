import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import SwiftUI
import GlanslateCapture
import GlanslateCore
import GlanslateGeometry
import GlanslateSettings

public actor OverlayEngine: OverlayPresenting {
    private let settings: SettingsStore
    private var sessions: [UUID: ManagedOverlayPresentationSession] = [:]
    private var lastDisplayID: CGDirectDisplayID?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public func present(_ session: OverlaySessionModel) async -> OverlaySessionHandle {
        let sessionID = UUID()
        lastDisplayID = session.source.region.displayID
        let presentation = await MainActor.run {
            ManagedOverlayPresentationSession(
                sessionID: sessionID,
                session: session,
                settings: settings
            )
        }

        let handle = OverlaySessionHandle(
            sessionID: sessionID,
            onPin: {
                await MainActor.run {
                    presentation.pinAndCreatePayload()
                }
            },
            onRetranslateRequested: { request in
                await MainActor.run {
                    presentation.prepareForRetranslation(request)
                }
            },
            onApplyRetranslation: { translations, request in
                await MainActor.run {
                    presentation.applyRetranslation(translations, request: request)
                }
            },
            onFinishRetranslation: {
                await MainActor.run {
                    presentation.finishRetranslation()
                }
            },
            onSetStyle: { style in
                await MainActor.run {
                    presentation.setStyleOverride(style)
                }
            },
            onBeginPeek: {
                await MainActor.run {
                    presentation.setPeeking(true)
                }
            },
            onEndPeek: {
                await MainActor.run {
                    presentation.setPeeking(false)
                }
            },
            onDismiss: { [weak self] closedID in
                await self?.dismissSession(id: closedID)
            }
        )

        await MainActor.run {
            presentation.bind(handle: handle)
            presentation.present()
        }

        sessions[sessionID] = presentation
        return handle
    }

    public func dismissAll() async {
        let active = sessions
        sessions.removeAll()
        await MainActor.run {
            for session in active.values {
                session.dismiss()
            }
        }
    }

    public func currentDisplayID() async -> CGDirectDisplayID? {
        lastDisplayID
    }

    private func dismissSession(id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await MainActor.run {
            session.dismiss()
        }
    }
}

public typealias MinimalOverlayPresenter = OverlayEngine

@MainActor
@Observable
final class OverlaySessionViewModel {
    let invocationID: UUID
    let topology: DisplayTopologySnapshot
    let sourceRegion: DisplayLocalRect
    let toolbarFrame: CGRect?
    var retainedSource: SourceVisualContext
    var translations: [GlanslateCore.Translation]
    var currentRequest: OverlayRetranslationRequest
    var styleOverride: OverlayStyle?
    var isPeeking = false
    var isPinned = false
    var isRetranslating = false
    var toolbarOpacity = OverlayToolbarHoverState.restingOpacity

    init(session: OverlaySessionModel) {
        self.invocationID = session.invocationID
        self.topology = session.topology
        self.sourceRegion = session.source.region
        self.retainedSource = session.source
        self.translations = session.translations
        self.currentRequest = OverlayRetranslationRequest(
            targetLanguage: session.translations.first?.targetLanguage ?? .en
        )
        if
            let entry = session.topology.entry(for: session.source.region.displayID)
        {
            self.toolbarFrame = OverlayToolbarLayout.frame(
                for: session.source.region.rect,
                displaySize: entry.appKitFrame.size
            )
        } else {
            self.toolbarFrame = nil
        }
    }

    func effectiveStyle(settings: SettingsStore) -> OverlayStyle {
        styleOverride ?? settings.overlayStyle
    }

    func toolbarFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        guard sourceRegion.displayID == displayID else { return nil }
        return toolbarFrame
    }

    func toolbarExclusionRects(for displayID: CGDirectDisplayID) -> [CGRect] {
        guard let toolbarFrame = toolbarFrame(for: displayID) else { return [] }
        return [toolbarFrame.insetBy(dx: -8, dy: -6)]
    }

    var providerDisplayLabel: String {
        if let provider = currentRequest.provider {
            return provider.toolbarLabel
        }
        return translations.first?.provider.toolbarLabel ?? "Default"
    }
}

@MainActor
final class ManagedOverlayPresentationSession: @unchecked Sendable {
    let sessionID: UUID
    let settings: SettingsStore
    let viewModel: OverlaySessionViewModel

    private var windows: [ManagedOverlayWindow] = []
    private var toolbarWindow: ManagedToolbarWindow?
    private weak var handle: OverlaySessionHandle?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var screenParameterObserver: NSObjectProtocol?
    private var hoverTimer: Timer?
    private var hoverState = OverlayToolbarHoverState()

    init(
        sessionID: UUID,
        session: OverlaySessionModel,
        settings: SettingsStore
    ) {
        self.sessionID = sessionID
        self.settings = settings
        self.viewModel = OverlaySessionViewModel(session: session)
    }

    func bind(handle: OverlaySessionHandle) {
        self.handle = handle
    }

    func present() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        installMonitors()
        installDisplayChangeObserver()

        for entry in viewModel.topology.entries {
            let window = ManagedOverlayWindow(contentRect: entry.appKitFrame)
            window.contentView = NSHostingView(rootView: OverlayRootView(
                entry: entry,
                viewModel: viewModel,
                settings: settings
            ))
            window.orderFrontRegardless()
            windows.append(window)
        }

        presentToolbarIfNeeded()
        updateToolbarHoverState()
    }

    func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let screenParameterObserver {
            NotificationCenter.default.removeObserver(screenParameterObserver)
            self.screenParameterObserver = nil
        }
        hoverTimer?.invalidate()
        hoverTimer = nil

        toolbarWindow?.orderOut(nil)
        toolbarWindow?.close()
        toolbarWindow = nil

        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    func pinAndCreatePayload() -> OverlayPinnedPayload {
        viewModel.isPinned = true
        let rendered = OverlayThumbnailRenderer.pinnedPayload(
            source: viewModel.retainedSource,
            translations: viewModel.translations
        )
        if let retainedSource = rendered.retainedSource {
            viewModel.retainedSource = retainedSource
        }
        return rendered.payload
    }

    func prepareForRetranslation(_ request: OverlayRetranslationRequest) {
        viewModel.currentRequest = request
        viewModel.isRetranslating = true
    }

    func applyRetranslation(
        _ translations: [GlanslateCore.Translation],
        request: OverlayRetranslationRequest
    ) {
        viewModel.translations = translations
        viewModel.currentRequest = request
        viewModel.isRetranslating = false
    }

    func finishRetranslation() {
        viewModel.isRetranslating = false
    }

    func setStyleOverride(_ style: OverlayStyle) {
        viewModel.styleOverride = style
    }

    func setPeeking(_ isPeeking: Bool) {
        viewModel.isPeeking = isPeeking
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let handle = self.handle else { return event }

            if event.keyCode == 53 {
                Task {
                    await handle.dismiss()
                }
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" {
                Task {
                    await handle.pin()
                }
                return nil
            }
            return event
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let handle = self.handle else { return event }
            let shouldPeek = self.settings.peekModifier.isActive(in: event.modifierFlags)
            let currentlyPeeking = self.viewModel.isPeeking

            if shouldPeek != currentlyPeeking {
                Task {
                    if shouldPeek {
                        await handle.beginPeek()
                    } else {
                        await handle.endPeek()
                    }
                }
            }
            return event
        }
    }

    private func installDisplayChangeObserver() {
        screenParameterObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let handle = self?.handle else { return }
                await handle.dismiss()
            }
        }
    }

    private func presentToolbarIfNeeded() {
        guard
            let handle,
            let toolbarFrame = viewModel.toolbarFrame(for: viewModel.sourceRegion.displayID)
        else {
            return
        }

        let converter = GeometryConverter(snapshot: viewModel.topology)
        let globalFrame = converter.appKitGlobal(
            fromDisplayLocalRect: DisplayLocalRect(
                displayID: viewModel.sourceRegion.displayID,
                rect: toolbarFrame
            )
        )
        let toolbarWindow = ManagedToolbarWindow(contentRect: globalFrame)
        toolbarWindow.contentView = NSHostingView(rootView: OverlayToolbarView(
            viewModel: viewModel,
            settings: settings,
            dismissAction: {
                Task {
                    await handle.dismiss()
                }
            },
            pinAction: {
                Task {
                    await handle.pin()
                }
            },
            styleAction: { style in
                Task {
                    await handle.setStyle(style)
                }
            },
            retranslateAction: { request in
                Task {
                    await handle.requestRetranslation(request)
                }
            }
        ))
        toolbarWindow.makeKeyAndOrderFront(nil)
        self.toolbarWindow = toolbarWindow
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateToolbarHoverState()
            }
        }
    }

    private func updateToolbarHoverState() {
        guard let toolbarWindow else { return }
        hoverState.update(
            pointer: NSEvent.mouseLocation,
            toolbarFrame: toolbarWindow.frame
        )
        viewModel.toolbarOpacity = hoverState.opacity
    }
}

@MainActor
final class ManagedOverlayWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ManagedToolbarWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private struct OverlayRootView: View {
    let entry: DisplayTopologyEntry
    let viewModel: OverlaySessionViewModel
    let settings: SettingsStore

    var body: some View {
        let style = viewModel.effectiveStyle(settings: settings)
        let source = viewModel.retainedSource
        let blocks = OverlayLayoutEngine.renderedBlocks(
            translations: displayTranslations,
            source: source,
            style: style,
            excludedRects: viewModel.toolbarExclusionRects(for: entry.displayID)
        )

        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(blocks) { block in
                OverlayRenderedBlockView(
                    block: block,
                    style: style,
                    settings: settings,
                    source: source
                )
                .opacity(viewModel.isPeeking ? 0 : settings.overlayOpacity)
                .offset(x: block.frame.minX, y: block.frame.minY)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: viewModel.isPeeking)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var displayTranslations: [GlanslateCore.Translation] {
        viewModel.translations.filter { $0.block.region.displayID == entry.displayID }
    }
}

@MainActor
private struct OverlayRenderedBlockView: View {
    let block: OverlayRenderedBlock
    let style: OverlayStyle
    let settings: SettingsStore
    let source: SourceVisualContext

    var body: some View {
        switch style {
        case .cleanPatch:
            CleanPatchBlockView(block: block, appearance: appearance)
        case .blurPatch:
            BlurPatchBlockView(block: block, appearance: appearance)
        case .subtitle:
            SubtitleBlockView(block: block, appearance: appearance, settings: settings)
        }
    }

    private var appearance: OverlayBlockAppearance {
        OverlayBlockAppearance.make(
            for: block.translation,
            source: source,
            settings: settings
        )
    }
}

private struct CleanPatchBlockView: View {
    let block: OverlayRenderedBlock
    let appearance: OverlayBlockAppearance

    var body: some View {
        Text(block.translation.translatedText)
            .font(.system(size: block.fontSize, weight: .semibold))
            .foregroundStyle(appearance.foregroundColor)
            .multilineTextAlignment(block.textAlignment.swiftUITextAlignment)
            .frame(
                width: max(block.frame.width - (block.horizontalPadding * 2), 24),
                height: max(block.frame.height - (block.verticalPadding * 2), 18),
                alignment: block.textAlignment.swiftUIAlignment
            )
            .frame(
                width: block.frame.width,
                height: block.frame.height,
                alignment: block.textAlignment.swiftUIAlignment
            )
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(appearance.cleanPatchFill)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(appearance.foregroundColor.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: appearance.foregroundColor.opacity(0.15), radius: 4, y: 1)
            .environment(\.layoutDirection, block.direction.swiftUILayoutDirection)
    }
}

private struct BlurPatchBlockView: View {
    let block: OverlayRenderedBlock
    let appearance: OverlayBlockAppearance

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10)
                .fill(appearance.tintColor.opacity(0.22))

            Text(block.translation.translatedText)
                .font(.system(size: block.fontSize, weight: .semibold))
                .foregroundStyle(appearance.foregroundColor)
                .multilineTextAlignment(block.textAlignment.swiftUITextAlignment)
                .frame(
                    width: max(block.frame.width - (block.horizontalPadding * 2), 24),
                    height: max(block.frame.height - (block.verticalPadding * 2), 18),
                    alignment: block.textAlignment.swiftUIAlignment
                )
        }
        .frame(width: block.frame.width, height: block.frame.height, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(appearance.foregroundColor.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 10, y: 2)
        .environment(\.layoutDirection, block.direction.swiftUILayoutDirection)
    }
}

private struct SubtitleBlockView: View {
    let block: OverlayRenderedBlock
    let appearance: OverlayBlockAppearance
    let settings: SettingsStore

    private let outlineOffsets: [CGSize] = [
        CGSize(width: -1, height: 0),
        CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1),
        CGSize(width: 0, height: 1),
    ]

    var body: some View {
        ZStack {
            if settings.subtitleShowBorder {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(appearance.subtitleOutline.opacity(0.18), lineWidth: 1)
            }

            ZStack {
                ForEach(Array(outlineOffsets.enumerated()), id: \.offset) { _, offset in
                    subtitleText
                        .foregroundStyle(appearance.subtitleOutline)
                        .offset(offset)
                }
                subtitleText
                    .foregroundStyle(appearance.subtitleFill)
            }
            .shadow(color: Color.black.opacity(0.7), radius: 2, y: 1)
        }
        .frame(width: block.frame.width, height: block.frame.height, alignment: .topLeading)
        .environment(\.layoutDirection, block.direction.swiftUILayoutDirection)
    }

    private var subtitleText: some View {
        Text(block.translation.translatedText)
            .font(.system(size: block.fontSize, weight: .bold))
            .multilineTextAlignment(block.textAlignment.swiftUITextAlignment)
            .frame(
                width: block.frame.width,
                height: block.frame.height,
                alignment: block.textAlignment.swiftUIAlignment
            )
    }
}

private struct OverlayBlockAppearance {
    let tintColor: Color
    let cleanPatchFill: Color
    let foregroundColor: Color
    let subtitleFill: Color
    let subtitleOutline: Color

    @MainActor
    static func make(
        for translation: GlanslateCore.Translation,
        source: SourceVisualContext,
        settings: SettingsStore
    ) -> OverlayBlockAppearance {
        let sampled = SourceVisualAnalyzer.averageColor(
            for: translation.block.region.rect,
            in: source
        ) ?? NSColor(calibratedWhite: 0.18, alpha: 1)
        let foreground = SourceVisualAnalyzer.contrastingColor(for: sampled)
        let muted = SourceVisualAnalyzer.mutedTint(from: sampled, foreground: foreground)

        return OverlayBlockAppearance(
            tintColor: Color(nsColor: sampled),
            cleanPatchFill: Color(nsColor: muted),
            foregroundColor: Color(nsColor: foreground),
            subtitleFill: Color(hex: settings.subtitleTextColorHex) ?? .white,
            subtitleOutline: Color(hex: settings.subtitleOutlineColorHex) ?? .black
        )
    }
}

private enum SourceVisualAnalyzer {
    private static let ciContext = CIContext(options: nil)

    static func averageColor(
        for rect: CGRect,
        in source: SourceVisualContext
    ) -> NSColor? {
        let crop = croppedImage(for: rect, in: source) ?? source.image
        let ciImage = CIImage(cgImage: crop)
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent

        guard let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return NSColor(
            calibratedRed: CGFloat(bitmap[0]) / 255.0,
            green: CGFloat(bitmap[1]) / 255.0,
            blue: CGFloat(bitmap[2]) / 255.0,
            alpha: 1
        )
    }

    static func contrastingColor(for color: NSColor) -> NSColor {
        let components = color.usingColorSpace(.deviceRGB) ?? color
        let luminance =
            (0.2126 * components.redComponent) +
            (0.7152 * components.greenComponent) +
            (0.0722 * components.blueComponent)
        return luminance < 0.56 ? .white : .black
    }

    static func mutedTint(from color: NSColor, foreground: NSColor) -> NSColor {
        if foreground == .white {
            return color.blended(withFraction: 0.35, of: .black) ?? color
        } else {
            return color.blended(withFraction: 0.18, of: .white) ?? color
        }
    }

    static func croppedImage(
        for displayRect: CGRect,
        in source: SourceVisualContext
    ) -> CGImage? {
        let captureRect = source.region.rect
        let localRect = CGRect(
            x: (displayRect.minX - captureRect.minX) * source.pixelScale,
            y: (displayRect.minY - captureRect.minY) * source.pixelScale,
            width: displayRect.width * source.pixelScale,
            height: displayRect.height * source.pixelScale
        )
        let imageRect = CGRect(
            x: 0,
            y: 0,
            width: source.image.width,
            height: source.image.height
        )
        let crop = localRect.integral.intersection(imageRect)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }
        return source.image.cropping(to: crop)
    }
}

private extension OverlayTextDirection {
    var swiftUILayoutDirection: LayoutDirection {
        switch self {
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        }
    }
}

private extension OverlayTextAlignment {
    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    var swiftUIAlignment: Alignment {
        switch self {
        case .leading: return .topLeading
        case .trailing: return .topTrailing
        case .center: return .center
        }
    }
}

private extension PeekModifier {
    func isActive(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .option: return flags.contains(.option)
        case .control: return flags.contains(.control)
        case .command: return flags.contains(.command)
        case .shift: return flags.contains(.shift)
        }
    }
}

private extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}
