import GlanslateCore
import GlanslateSystem
import SwiftUI

/// The first-run guide: what Glanslate does, the permissions it needs (with
/// live status), translation setup, and the shortcut.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, translation, ready
    }

    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep()
                case .translation: TranslationStep()
                case .ready: ReadyStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity.combined(with: .offset(x: -24))
            ))
            .id(step)

            footer
        }
        .frame(width: 620, height: 600)
        .onAppear {
            app.permissions.refresh()
            app.permissions.startPolling()
            if app.settings.hasCompletedOnboarding, !app.permissions.screenRecording { step = .permissions }
        }
        .onDisappear { app.permissions.stopPolling() }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            Spacer()

            if step != .welcome {
                Button("Back") { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) }
                    .controlSize(.large)
            }
            Button(primaryTitle, action: advance)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .permissions: return app.permissions.screenRecording ? "Continue" : "Continue Without Access"
        case .translation: return "Continue"
        case .ready: return "Done"
        }
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            go(to: next)
        } else {
            app.commands.finishOnboarding()
        }
    }

    private func go(to next: Step) {
        withAnimation(MotionAwareAnimation.standard(reduceMotion)) { step = next }
    }
}

// MARK: - Steps

private struct StepHeader: View {
    let symbol: String?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(height: 44)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                StepHeader(
                    symbol: nil,
                    title: "Welcome to Glanslate",
                    subtitle: "Translate text anywhere on your screen — right where you’re reading it."
                )
            }
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "text.viewfinder", title: "Select any text", detail: "Drag over text in a browser, PDF, image, or app — or pick a whole window.")
                FeatureRow(symbol: "rectangle.on.rectangle", title: "Read it in place", detail: "Translations appear over the original and keep its layout. Hold ⌥ to peek at the original.")
                FeatureRow(symbol: "lock.shield", title: "Private by design", detail: "Capture and text recognition happen on your Mac. Cloud translation is only used if you allow it.")
            }
            .frame(maxWidth: 440)
            Spacer(minLength: 0)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionsStep: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        VStack(spacing: 26) {
            StepHeader(
                symbol: "hand.raised",
                title: "Allow Access",
                subtitle: "Glanslate needs to see the area you select. Status updates when you come back from System Settings."
            )
            VStack(spacing: 12) {
                PermissionCard(permission: .screenRecording)
                PermissionCard(permission: .accessibility)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionCard: View {
    let permission: Permission
    @Environment(AppEnvironment.self) private var app
    @State private var requested = false

    var body: some View {
        let granted = app.permissions.isGranted(permission)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: permission.symbolName)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(permission.title).font(.headline)
                        Text(permission.isRequired ? "Required" : "Optional")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Text(permission.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if granted {
                    StatusBadge(text: "Allowed", tone: .positive)
                } else {
                    Button("Open Settings…") {
                        requested = true
                        permission.requestAndOpenSettings()
                    }
                }
            }
            if permission == .screenRecording, requested, !granted {
                HStack {
                    Text("Allowed it already? macOS applies the change after a restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Glanslate") { Relauncher.relaunch() }
                        .controlSize(.small)
                }
                .padding(.leading, 44)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }
}

private struct TranslationStep: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 26) {
            StepHeader(
                symbol: "translate",
                title: "Choose Your Language",
                subtitle: "Glanslate detects the source language automatically and translates into the language you choose."
            )
            Form {
                Picker("Translate to", selection: $settings.targetLanguage) {
                    ForEach(Language.sortedCatalog()) { Text($0.localizedName()).tag($0) }
                }
                Picker("Translate with", selection: $settings.preferredProvider) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Text(provider.isOnDevice ? "\(provider.displayName) (On Device)" : provider.displayName).tag(provider)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 440, maxHeight: 130)

            Text(providerNote(settings.preferredProvider))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)

            if settings.preferredProvider.requiresCredential {
                Button("Add API Key in Settings…") { app.commands.openSettings(.translation) }
            }
            Spacer(minLength: 0)
        }
    }

    private func providerNote(_ provider: TranslationProvider) -> String {
        if provider.isOnDevice {
            return "Apple Translation works on this Mac without sending text anywhere. The first time you translate a language pair, you may be asked to download it in Settings › Translation."
        }
        return "\(provider.displayName) needs an API key. Before its first use, Glanslate asks whether to send the recognized text — never the screenshot — to \(provider.dataRecipient)."
    }
}

private struct ReadyStep: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        VStack(spacing: 26) {
            StepHeader(
                symbol: "checkmark.circle",
                title: "You’re All Set",
                subtitle: "Glanslate lives in the menu bar. Press the shortcut anytime to translate what’s on screen."
            )
            HStack(spacing: 6) {
                if let combo = app.settings.translateShortcut {
                    ForEach(Array(combo.modifiers.symbols).map(String.init) + [combo.key], id: \.self) { key in
                        Text(key)
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .frame(minWidth: 44, minHeight: 44)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                    }
                } else {
                    Text("Set a shortcut in Settings › Shortcuts").foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Shortcut: \(app.settings.translateShortcut?.displayString ?? "none")")

            Button {
                app.commands.finishOnboarding()
                app.commands.translateRegion()
            } label: {
                Label("Try It Now", systemImage: "text.viewfinder")
            }
            .controlSize(.large)
            .disabled(!app.permissions.screenRecording)

            Text("Tip: press Space while selecting to pick a whole window.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
