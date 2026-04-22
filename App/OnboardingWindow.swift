import AppKit
import KeyboardShortcuts
import SwiftUI
import GlanslateKit

struct OnboardingWindow: View {
    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var screenRecordingGranted = PermissionProbe.screenRecordingGranted()
    @State private var accessibilityGranted = PermissionProbe.accessibilityGranted()
    @State private var pollingTimer: Timer?

    private let stepCount = 3

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 24)

            Spacer()

            stepContent
                .frame(maxWidth: .infinity)

            Spacer()

            navigationButtons
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(width: 640, height: 480)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    @ViewBuilder
    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(0..<stepCount, id: \.self) { index in
                Circle()
                    .fill(index <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            welcomeStep
        case 1:
            screenRecordingStep
        case 2:
            accessibilityStep
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "character.bubble")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Welcome to Glanslate")
                .font(.largeTitle.weight(.semibold))

            Text("Translate any text on your screen with a global hotkey and floating overlay. Let's get set up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
        .padding(40)
    }

    @ViewBuilder
    private var screenRecordingStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Screen Recording Access")
                .font(.title.weight(.semibold))

            Text("Glanslate needs screen recording access to capture text from apps. This is required for the translation feature to work.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            if screenRecordingGranted {
                Label("Screen recording access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings") {
                    PermissionProbe.openPane(.screenRecording)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    @ViewBuilder
    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "accessibility")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Accessibility Access")
                .font(.title.weight(.semibold))

            Text("Glanslate needs accessibility access to read text from apps that don't support screen recording, like Safari and PDF viewers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            if accessibilityGranted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings") {
                    PermissionProbe.openPane(.accessibility)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    @ViewBuilder
    private var navigationButtons: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation { currentStep -= 1 }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < stepCount - 1 {
                Button("Continue") {
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                self.checkPermissions()
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func checkPermissions() {
        let newScreenRecording = PermissionProbe.screenRecordingGranted()
        let newAccessibility = PermissionProbe.accessibilityGranted()

        if newScreenRecording != screenRecordingGranted {
            screenRecordingGranted = newScreenRecording
        }
        if newAccessibility != accessibilityGranted {
            accessibilityGranted = newAccessibility
        }
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "didShowOnboarding")
        isPresented = false
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let isPresented: Binding<Bool>

    init(isPresented: Binding<Bool>) {
        self.isPresented = isPresented
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glanslate Setup"
        window.center()

        let contentView = OnboardingWindow(isPresented: isPresented)
        window.contentView = NSHostingView(rootView: contentView)
        window.setFrameAutosaveName("OnboardingWindow")
        window.delegate = OnboardingWindowDelegate(isPresented: isPresented)

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private let isPresented: Binding<Bool>

    init(isPresented: Binding<Bool>) {
        self.isPresented = isPresented
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        isPresented.wrappedValue = false
        UserDefaults.standard.set(true, forKey: "didShowOnboarding")
    }
}

@MainActor
final class OnboardingPresenter: ObservableObject {
    @Published private(set) var isPresented = false
    private var windowController: OnboardingWindowController?

    func checkAndShow() {
        guard !UserDefaults.standard.bool(forKey: "didShowOnboarding") else { return }
        isPresented = true
        let binding = Binding(
            get: { self.isPresented },
            set: { self.isPresented = $0 }
        )
        windowController = OnboardingWindowController(isPresented: binding)
        windowController?.show()
    }

    func dismiss() {
        isPresented = false
        UserDefaults.standard.set(true, forKey: "didShowOnboarding")
    }
}
