import AppKit
import KeyboardShortcuts
import Observation
import SwiftData
import SwiftUI
import GlanslateKit

private func persistedBinding<Value>(
    settings: SettingsStore,
    _ keyPath: ReferenceWritableKeyPath<SettingsStore, Value>
) -> Binding<Value> {
    Binding(
        get: { settings[keyPath: keyPath] },
        set: {
            settings[keyPath: keyPath] = $0
            settings.persist()
        }
    )
}

struct SettingsSceneView: View {
    let appRoot: AppRoot

    var body: some View {
        TabView {
            ShortcutSettingsTab()
                .tabItem {
                    Label("Shortcut", systemImage: "keyboard")
                }

            TranslationSettingsTab(settings: appRoot.settingsStore)
                .tabItem {
                    Label("Translation", systemImage: "globe")
                }

            OverlaySettingsTab(settings: appRoot.settingsStore)
                .tabItem {
                    Label("Overlay", systemImage: "rectangle.on.rectangle")
                }

            HistorySettingsTab()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            AboutSettingsTab(appRoot: appRoot)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct ShortcutSettingsTab: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Translate Region")
                    Spacer()
                    KeyboardShortcuts.Recorder("Translate Region", name: .translateRegion)
                }
            } header: {
                Text("Global Hotkey")
            } footer: {
                Text("Press this key combination while Glanslate is running to start a translation overlay.")
                    .foregroundStyle(.secondary)
            }

            Section("Modifier Keys") {
                Text("The translate region hotkey uses modifier keys to avoid conflicts with other apps.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct TranslationSettingsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Providers") {
                Picker("Preferred Provider", selection: persistedBinding(settings: settings, \.preferredProvider)) {
                    ForEach(TranslationProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Picker("Fallback Provider", selection: persistedBinding(settings: settings, \.fallbackProvider)) {
                    ForEach(TranslationProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            }

            Section("Language") {
                Picker("Default Target", selection: persistedBinding(settings: settings, \.defaultTargetLanguage)) {
                    ForEach(Language.allCases.filter { $0 != .auto }, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section("Cloud Disclosure") {
                ForEach(TranslationProvider.allCases.filter(\.sendsTextOffDevice), id: \.self) { provider in
                    if settings.hasAcceptedDisclosure(for: provider) {
                        HStack {
                            Text("\(provider.displayName) may send recognized text off this Mac")
                            Spacer()
                            Text("Accepted")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Acknowledge \(provider.displayName) disclosure") {
                            settings.acceptDisclosure(for: provider)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct OverlaySettingsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Style") {
                Picker("Default Style", selection: persistedBinding(settings: settings, \.overlayStyle)) {
                    ForEach(OverlayStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Slider(
                    value: Binding(
                        get: { settings.overlayOpacity },
                        set: {
                            settings.overlayOpacity = $0
                            settings.persist()
                        }
                    ),
                    in: 0.2...1
                ) {
                    Text("Opacity")
                }

                Picker("Peek Modifier", selection: persistedBinding(settings: settings, \.peekModifier)) {
                    ForEach(PeekModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
            }

            Section("Subtitle") {
                Toggle("Show Hairline Border", isOn: persistedBinding(settings: settings, \.subtitleShowBorder))

                TextField(
                    "Text Color (#RRGGBB)",
                    text: persistedBinding(settings: settings, \.subtitleTextColorHex)
                )

                TextField(
                    "Outline Color (#RRGGBB)",
                    text: persistedBinding(settings: settings, \.subtitleOutlineColorHex)
                )
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct HistorySettingsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PinnedTranslation.createdAt, order: .reverse) private var items: [PinnedTranslation]

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No pinned translations yet.")
                        .font(.headline)
                    Text("Use the overlay pin button to persist a translation and its thumbnail.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(items) { item in
                            HistoryCard(item: item) {
                                delete(item)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func delete(_ item: PinnedTranslation) {
        modelContext.delete(item)
        try? modelContext.save()
    }
}

private struct HistoryCard: View {
    let item: PinnedTranslation
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            snapshotPreview

            VStack(alignment: .leading, spacing: 8) {
                Text(item.translatedText)
                    .font(.headline)
                    .textSelection(.enabled)

                Text(item.sourceText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    metadataChip(item.provider)
                    metadataChip("\(item.sourceLanguage.uppercased()) → \(item.targetLanguage.uppercased())")
                    metadataChip(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Spacer(minLength: 12)

            Button("Delete", role: .destructive, action: onDelete)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var snapshotPreview: some View {
        if let data = item.snapshotPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 96)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.06))
                .frame(width: 160, height: 96)
                .overlay {
                    Image(systemName: "text.viewfinder")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func metadataChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

private struct AboutSettingsTab: View {
    let appRoot: AppRoot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Glanslate")
                .font(.largeTitle.weight(.semibold))

            Text("Menu-bar OCR translation overlays for macOS.")
                .foregroundStyle(.secondary)

            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Dev")
            LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Local")

            Divider()

            Toggle("Show Dock Icon", isOn: Binding(
                get: { appRoot.settingsStore.showDockIcon },
                set: {
                    appRoot.settingsStore.showDockIcon = $0
                    appRoot.settingsStore.persist()
                    appRoot.updateDockIconVisibility()
                }
            ))

            if !PermissionProbe.screenRecordingGranted() || !PermissionProbe.accessibilityGranted() {
                Divider()
                Button("Fix Permissions") {
                    PermissionProbe.openPane(.screenRecording)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}
