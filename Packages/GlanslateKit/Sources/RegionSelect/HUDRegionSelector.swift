import AppKit
import Foundation
import Observation
import SwiftUI
import GlanslateCore
import GlanslateGeometry

public actor HUDRegionSelector: RegionSelecting {
    public init() {}

    public func selectRegion(in topology: DisplayTopologySnapshot) async -> RegionSelection? {
        let session = await MainActor.run {
            RegionSelectionSession(topology: topology)
        }

        return await withTaskCancellationHandler {
            await session.run()
        } onCancel: {
            Task { @MainActor in
                session.cancel()
            }
        }
    }
}

@MainActor
final class RegionSelectionSession: @unchecked Sendable {
    private let topology: DisplayTopologySnapshot
    private let geometry: RegionSelectionGeometry
    private let model: RegionSelectionModel
    private var windows: [SelectionHUDWindow] = []
    private var continuation: CheckedContinuation<RegionSelection?, Never>?
    private var startPoint: CGPoint?
    private var finished = false

    init(topology: DisplayTopologySnapshot) {
        self.topology = topology
        self.geometry = RegionSelectionGeometry(topology: topology)
        self.model = RegionSelectionModel()
    }

    func run() async -> RegionSelection? {
        if topology.entries.isEmpty { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentWindows()
        }
    }

    func cancel() {
        finish(with: nil)
    }

    func beginDrag(at globalPoint: CGPoint) {
        startPoint = globalPoint
        model.activeDisplayID = geometry.activeDisplayID(for: globalPoint)
        model.normalizedGlobalRect = .null
        model.statusMessage = nil
    }

    func updateDrag(at globalPoint: CGPoint) {
        guard let startPoint else { return }
        model.normalizedGlobalRect = geometry.normalizedGlobalRect(from: startPoint, to: globalPoint)
    }

    func completeDrag(at globalPoint: CGPoint) {
        guard let startPoint else { return }
        let evaluation = geometry.evaluate(from: startPoint, to: globalPoint)
        model.activeDisplayID = evaluation.activeDisplayID
        model.normalizedGlobalRect = evaluation.normalizedGlobalRect

        switch evaluation.outcome {
        case .selected(let localRect):
            finish(with: RegionSelection(region: localRect, topology: topology))
        case .crossScreenRejected:
            rejectSelection(message: "Select on one display")
        case .tooSmall:
            resetDrag()
        }
    }

    private func presentWindows() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        for entry in topology.entries {
            let inputView = RegionSelectInputView(
                entry: entry,
                model: model,
                geometry: geometry,
                session: self
            )
            let window = SelectionHUDWindow(contentRect: entry.appKitFrame)
            window.contentView = inputView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(inputView)
            windows.append(window)
        }
    }

    private func rejectSelection(message: String) {
        model.statusMessage = message
        model.rejectionPulse.toggle()
        resetDrag()
    }

    private func resetDrag() {
        startPoint = nil
        model.normalizedGlobalRect = .null
    }

    private func finish(with result: RegionSelection?) {
        guard !finished else { return }
        finished = true

        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
@Observable
final class RegionSelectionModel {
    var activeDisplayID: CGDirectDisplayID?
    var normalizedGlobalRect: CGRect = .null
    var statusMessage: String?
    var rejectionPulse = false

    var dimensionsText: String? {
        guard !normalizedGlobalRect.isNull, normalizedGlobalRect.width > 0, normalizedGlobalRect.height > 0 else {
            return nil
        }
        let width = Int(normalizedGlobalRect.width.rounded())
        let height = Int(normalizedGlobalRect.height.rounded())
        return "\(width) × \(height) pt"
    }
}

@MainActor
final class RegionSelectInputView: NSView {
    private let entry: DisplayTopologyEntry
    private let model: RegionSelectionModel
    private let geometry: RegionSelectionGeometry
    private unowned let session: RegionSelectionSession
    private let hostingView: NSHostingView<RegionSelectHUDView>

    init(
        entry: DisplayTopologyEntry,
        model: RegionSelectionModel,
        geometry: RegionSelectionGeometry,
        session: RegionSelectionSession
    ) {
        self.entry = entry
        self.model = model
        self.geometry = geometry
        self.session = session
        self.hostingView = NSHostingView(rootView: RegionSelectHUDView(
            model: model,
            entry: entry,
            geometry: geometry
        ))
        super.init(frame: CGRect(origin: .zero, size: entry.appKitFrame.size))
        wantsLayer = true
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        session.beginDrag(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        session.updateDrag(at: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        session.completeDrag(at: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            session.cancel()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private struct RegionSelectHUDView: View {
    @Bindable var model: RegionSelectionModel
    let entry: DisplayTopologyEntry
    let geometry: RegionSelectionGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            if let marqueeRect {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                    )
                    .shadow(color: Color.white.opacity(0.25), radius: 10)
                    .frame(width: marqueeRect.width, height: marqueeRect.height)
                    .offset(x: marqueeRect.minX, y: marqueeRect.minY)

                if let dimensions = model.dimensionsText {
                    Text(dimensions)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .offset(
                            x: min(marqueeRect.maxX + 12, entry.appKitFrame.width - 120),
                            y: max(marqueeRect.minY - 4, 12)
                        )
                }
            }

            if let message = model.statusMessage {
                Text(message)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .offset(x: 24 + (model.rejectionPulse ? 6 : 0), y: 24)
                    .animation(.snappy(duration: 0.22), value: model.rejectionPulse)
            }
        }
    }

    private var marqueeRect: CGRect? {
        guard model.activeDisplayID == entry.displayID else { return nil }
        guard !model.normalizedGlobalRect.isNull else { return nil }
        return geometry.localRect(for: model.normalizedGlobalRect, on: entry.displayID)
    }
}

@MainActor
final class SelectionHUDWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .screenSaver - 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovable = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
