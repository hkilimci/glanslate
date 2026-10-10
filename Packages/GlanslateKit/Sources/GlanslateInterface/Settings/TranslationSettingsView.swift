import GlanslateAppleTranslation
import GlanslateCore
import GlanslateSystem
import SwiftUI
@preconcurrency import Translation

struct TranslationSettingsView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Languages") {
                Picker("Translate to", selection: $settings.targetLanguage) {
                    ForEach(Language.sortedCatalog()) { Text($0.localizedName()).tag($0) }
                }
                Picker("Source language", selection: $settings.sourceLanguage) {
                    Text("Detect Automatically").tag(SourceLanguage.automatic)
                    Divider()
                    ForEach(Language.sortedCatalog()) { Text($0.localizedName()).tag(SourceLanguage.specific($0)) }
                }
            }

            Section {
                Picker("Preferred provider", selection: $settings.preferredProvider) {
                    ForEach(TranslationProvider.allCases) { provider in
                        ProviderPickerLabel(provider: provider, configured: app.hasCredential(for: provider)).tag(provider)
                    }
                }
                Picker("If it can’t translate, use", selection: $settings.fallbackProvider) {
                    Text("No Fallback").tag(TranslationProvider?.none)
                    Divider()
                    ForEach(TranslationProvider.allCases.filter { $0 != settings.preferredProvider }) { provider in
                        ProviderPickerLabel(provider: provider, configured: app.hasCredential(for: provider)).tag(Optional(provider))
                    }
                }
                Toggle("Prefer on-device translation when available", isOn: $settings.prefersOnDevice)
            } header: {
                Text("Provider")
            } footer: {
                Text(routingSummary)
            }

            AppleTranslationSection()

            ForEach(TranslationProvider.cloudProviders) { provider in
                CloudProviderSection(provider: provider)
            }
        }
        .formStyle(.grouped)
    }

    private var routingSummary: String {
        let settings = app.settings
        var parts: [String] = []
        if settings.prefersOnDevice, settings.preferredProvider != .apple {
            parts.append("Apple Translation is used first whenever its languages are downloaded.")
        }
        if let fallback = settings.fallbackProvider, fallback != settings.preferredProvider {
            parts.append("\(fallback.displayName) is used when \(settings.preferredProvider.displayName) can’t translate.")
        } else {
            parts.append("Without a fallback, Glanslate shows what went wrong and how to fix it.")
        }
        if settings.preferredProvider.requiresCredential || (settings.fallbackProvider?.requiresCredential ?? false) {
            parts.append("Cloud providers are only used after you allow them.")
        }
        return parts.joined(separator: " ")
    }
}

private struct ProviderPickerLabel: View {
    let provider: TranslationProvider
    let configured: Bool

    var body: some View {
        if provider.isOnDevice {
            Text("\(provider.displayName) (On Device)")
        } else if configured {
            Text(provider.displayName)
        } else {
            Text("\(provider.displayName) — Not Set Up")
        }
    }
}

// MARK: - Apple Translation

/// Shows whether Apple's on-device models for a pair are installed and
/// downloads them with the system prompt.
struct AppleTranslationSection: View {
    @Environment(AppEnvironment.self) private var app
    @State private var source: Language = .french
    @State private var status: AppleLanguageSupport.Status?
    @State private var configuration: TranslationSession.Configuration?
    @State private var downloadError: String?
    @State private var isDownloading = false

    var body: some View {
        Section {
            Picker("Translate from", selection: $source) {
                ForEach(Language.sortedCatalog().filter { $0 != app.settings.targetLanguage }) { Text($0.localizedName()).tag($0) }
            }
            LabeledContent("To \(app.settings.targetLanguage.localizedName())") {
                HStack(spacing: 10) {
                    statusBadge
                    if status == .downloadable {
                        Button(isDownloading ? "Downloading…" : "Download…", action: download)
                            .disabled(isDownloading)
                    }
                }
            }
            if let downloadError {
                Text(downloadError).font(.callout).foregroundStyle(.red)
            }
            Button("Manage Languages in System Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
            }
        } header: {
            Text("Apple Translation")
        } footer: {
            Text("Apple Translation runs entirely on this Mac. Each language is downloaded once and shared with other apps. Without downloaded languages, Glanslate uses your fallback provider or tells you what to download.")
        }
        .task(id: StatusKey(source: source, target: app.settings.targetLanguage)) { await refresh() }
        .onAppear {
            if let pending = app.pendingDownload {
                source = pending.source
                app.pendingDownload = nil
            } else {
                source = app.settings.targetLanguage == .english ? .french : .english
            }
        }
        .onChange(of: app.pendingDownload) { _, pending in
            guard let pending else { return }
            source = pending.source
            app.pendingDownload = nil
        }
        .translationTask(configuration) { session in
            // The session is used only here, on the main actor, while the view is alive.
            nonisolated(unsafe) let downloadSession = session
            do {
                try await downloadSession.prepareTranslation()
                downloadError = nil
            } catch {
                downloadError = "The download didn’t finish. Check your connection and try again."
            }
            isDownloading = false
            configuration = nil
            await refresh()
        }
    }

    private struct StatusKey: Hashable {
        let source: Language
        let target: Language
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .installed: StatusBadge(text: "Downloaded", tone: .positive)
        case .downloadable: StatusBadge(text: "Not Downloaded", tone: .neutral)
        case .unsupported: StatusBadge(text: "Not Supported", tone: .attention)
        case nil: ProgressView().controlSize(.small)
        }
    }

    private func refresh() async {
        status = nil
        status = await AppleLanguageSupport.status(source: source, target: app.settings.targetLanguage)
    }

    private func download() {
        downloadError = nil
        isDownloading = true
        configuration = TranslationSession.Configuration(
            source: AppleLanguageSupport.localeLanguage(for: source),
            target: AppleLanguageSupport.localeLanguage(for: app.settings.targetLanguage)
        )
    }
}

// MARK: - Cloud providers

/// API key entry, verification, and consent for one cloud provider.
struct CloudProviderSection: View {
    let provider: TranslationProvider
    @Environment(AppEnvironment.self) private var app
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var check: CredentialCheck?
    @State private var isVerifying = false
    @State private var saveError: String?

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            if hasKey {
                LabeledContent(provider.credentialName) {
                    HStack(spacing: 10) {
                        Label("Saved in Keychain", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                        Button("Verify", action: verify).disabled(isVerifying)
                        Button("Remove", role: .destructive, action: removeKey)
                    }
                }
            } else {
                LabeledContent(provider.credentialName) {
                    HStack(spacing: 8) {
                        SecureField("Paste your key", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit(saveKey)
                            .accessibilityLabel(provider.credentialName)
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            if isVerifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking key…").foregroundStyle(.secondary)
                }
            } else if let check {
                switch check {
                case .valid(let detail):
                    StatusBadge(text: detail.map { "Key works — \($0)" } ?? "Key works", tone: .positive)
                case .invalid(let error):
                    StatusBadge(text: "\(error.title). \(error.message)", tone: .attention)
                }
            }
            if let saveError {
                Text(saveError).foregroundStyle(.red)
            }

            if provider == .openAI {
                LabeledContent("Model") {
                    HStack(spacing: 6) {
                        TextField("Model", text: $settings.openAIModel, prompt: Text(OpenAIEngine.defaultModel))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Menu {
                            ForEach(OpenAIEngine.suggestedModels, id: \.self) { model in
                                Button(model) { settings.openAIModel = model }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Suggested models")
                    }
                }
            }

            Toggle("Allow sending recognized text to \(provider.displayName)", isOn: Binding(
                get: { settings.hasConsent(for: provider) },
                set: { settings.setConsent($0, for: provider) }
            ))
        } header: {
            HStack {
                Text(provider.displayName)
                Spacer()
                if let url = provider.credentialHelpURL {
                    Link("Get an API Key", destination: url).font(.callout)
                }
            }
        } footer: {
            Text(note)
        }
        .onAppear(perform: reload)
        .onChange(of: app.credentialsRevision) { reload() }
    }

    private var note: String {
        switch provider {
        case .deepL:
            return "Works with DeepL API Free and Pro keys. DeepL receives only the recognized text. Free keys include a monthly character allowance."
        case .google:
            return "Uses Cloud Translation – Basic. Enable the Cloud Translation API and billing in your Google Cloud project, then create an API key. Google receives only the recognized text."
        case .openAI:
            return "Uses the Responses API with storage turned off. OpenAI receives only the recognized text and the language names. Usage is billed to your OpenAI account."
        case .apple:
            return ""
        }
    }

    private func reload() {
        hasKey = app.credentials.hasCredential(for: provider)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try app.credentials.setCredential(key, for: provider)
            keyDraft = ""
            saveError = nil
            app.credentialsRevision += 1
            verify()
        } catch {
            saveError = "The key couldn’t be saved to the Keychain."
        }
    }

    private func removeKey() {
        try? app.credentials.removeCredential(for: provider)
        check = nil
        app.credentialsRevision += 1
    }

    private func verify() {
        guard let key = app.credentials.credential(for: provider) else { return }
        isVerifying = true
        check = nil
        let provider = provider
        Task {
            let result = await CredentialVerifier(transport: URLSessionTransport()).verify(provider, key: key)
            check = result
            isVerifying = false
        }
    }
}
