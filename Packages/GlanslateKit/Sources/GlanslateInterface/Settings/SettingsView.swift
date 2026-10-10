import GlanslateCore
import GlanslateSystem
import SwiftUI

/// The Settings window: a System Settings–style sidebar with grouped forms.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    SettingsIcon(systemName: section.symbolName, color: Color(nsColor: section.tint))
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(app.settingsSection.title)
                .frame(minWidth: 460)
        }
    }

    private var selection: Binding<SettingsSection?> {
        Binding(get: { app.settingsSection }, set: { if let section = $0 { app.settingsSection = section } })
    }

    @ViewBuilder
    private var detail: some View {
        switch app.settingsSection {
        case .general: GeneralSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .translation: TranslationSettingsView()
        case .appearance: AppearanceSettingsView()
        case .saved: SavedSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if LaunchAtLogin.requiresApproval {
                    LabeledContent("Approval needed") {
                        Button("Open Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                Toggle("Show Glanslate in the Dock", isOn: $settings.showsDockIcon)
                    .onChange(of: settings.showsDockIcon) { app.commands.applyDockIcon() }
            } footer: {
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(.red)
                } else {
                    Text("Glanslate always stays in the menu bar.")
                }
            }

            Section("Permissions") {
                PermissionRow(permission: .screenRecording)
                PermissionRow(permission: .accessibility)
            }

            Section {
                Toggle("Use exact text from apps when available", isOn: $settings.usesAccessibilityText)
                    .disabled(!app.permissions.accessibility)
            } header: {
                Text("Text Recognition")
            } footer: {
                Text("Glanslate always reads text from the captured image on this Mac. With Accessibility access, it also uses the exact text that apps expose, which fixes recognition mistakes.")
            }

            Section {
                Button("Show Welcome Guide…") { app.commands.showOnboarding() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            app.permissions.refresh()
            app.permissions.startPolling()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
        .onDisappear { app.permissions.stopPolling() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Couldn’t update the login item. Check System Settings › General › Login Items."
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

/// A permission with its live status and the action that resolves it.
struct PermissionRow: View {
    let permission: Permission
    @Environment(AppEnvironment.self) private var app
    @State private var requested = false

    var body: some View {
        let granted = app.permissions.isGranted(permission)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(permission.title)
                            Text(permission.isRequired ? "Required" : "Optional")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(permission.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: permission.symbolName)
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 16)
                if granted {
                    StatusBadge(text: "Allowed", tone: .positive)
                } else {
                    Button("Open System Settings…") {
                        requested = true
                        permission.requestAndOpenSettings()
                    }
                }
            }
            if permission == .screenRecording, requested, !granted {
                HStack {
                    Text("Already allowed it? macOS applies the change after Glanslate restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Glanslate") { Relauncher.relaunch() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                LabeledContent("Translate Region") {
                    ShortcutRecorder(combo: $settings.translateShortcut) {
                        app.commands.applyShortcut()
                    }
                }
            } footer: {
                if let problem = app.shortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Works in any app. Use a combination with ⌘, ⌥, or ⌃.")
                }
            }

            Section {
                Picker("Hold to Show Original", selection: $settings.revealModifier) {
                    ForEach(RevealModifier.allCases) { modifier in
                        Text("\(modifier.symbol) \(modifier.displayName)").tag(modifier)
                    }
                }
            } header: {
                Text("Translation Overlay")
            } footer: {
                Text("While you hold this key, the original text shows through. Release it to see the translation again.")
            }

            Section("Overlay Keys") {
                KeyRow(title: "Close overlay", keys: ["esc"])
                KeyRow(title: "Copy translation", keys: ["⌘", "C"])
                KeyRow(title: "Save to Saved Translations", keys: ["⌘", "S"])
                KeyRow(title: "Show original", keys: ["⌘", "O"])
            }

            Section("Selection Keys") {
                KeyRow(title: "Switch between area and window", keys: ["Space"])
                KeyRow(title: "Cancel", keys: ["esc"])
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyRow: View {
    let title: String
    let keys: [String]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(keys.joined(separator: " "))")
    }
}

// MARK: - Saved Translations

struct SavedSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var count = 0
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                LabeledContent("Saved translations", value: count.formatted())
                Toggle("Save an image of the captured area", isOn: $settings.savesThumbnails)
            } footer: {
                if app.isStoreTemporary {
                    Label("Glanslate couldn’t open its saved translations file, so new pins last only until you quit. Restart Glanslate to try again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Pin a translation from the overlay toolbar to keep it. Saved translations are stored only on this Mac.")
                }
            }

            Section {
                HStack {
                    Button("Open Saved Translations…") { app.commands.openSavedTranslations() }
                    Spacer()
                    Button("Clear All…", role: .destructive) { confirmClear = true }
                        .disabled(count == 0)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(app.store == nil)
        .onAppear(perform: refresh)
        .confirmationDialog("Clear all saved translations?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) {
                try? app.store?.deleteAll()
                refresh()
            }
        } message: {
            Text("This removes \(count) saved translations from this Mac. This can’t be undone.")
        }
    }

    private func refresh() {
        count = app.store?.count() ?? 0
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    Text("Glanslate").font(.title2.weight(.semibold))
                    Text("Version \(Self.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Translate text anywhere on your screen, right where you read it.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("Privacy") {
                PrivacyRow(symbol: "lock.shield", text: "Captures and text recognition never leave your Mac.")
                PrivacyRow(symbol: "laptopcomputer", text: "Apple Translation works entirely on device.")
                PrivacyRow(symbol: "cloud", text: "Cloud providers receive only the recognized text, and only after you allow it.")
                PrivacyRow(symbol: "key", text: "API keys are kept in your Keychain. Glanslate doesn’t log captured content.")
            }

            Section("Providers") {
                ForEach(TranslationProvider.cloudProviders) { provider in
                    if let url = provider.privacyPolicyURL {
                        Link("\(provider.displayName) Privacy Policy", destination: url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private struct PrivacyRow: View {
        let symbol: String
        let text: String

        var body: some View {
            Label {
                Text(text)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
