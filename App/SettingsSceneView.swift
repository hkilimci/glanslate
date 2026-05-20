import AppKit
import KeyboardShortcuts
import Observation
import SwiftData
import SwiftUI
import GlanslateKit

private struct SendableKeyPath<Root, Value>: @unchecked Sendable {
    let keyPath: ReferenceWritableKeyPath<Root, Value>
}

@MainActor
private func persistedBinding<Value: Sendable>(
    settings: SettingsStore,
    _ keyPath: ReferenceWritableKeyPath<SettingsStore, Value>
) -> Binding<Value> {
    let box = SendableKeyPath(keyPath: keyPath)
    return Binding(
        get: {
            MainActor.assumeIsolated { settings[keyPath: box.keyPath] }
        },
        set: { newValue in
            MainActor.assumeIsolated {
                settings[keyPath: box.keyPath] = newValue
                settings.persist()
            }
        }
    )
}

@MainActor
private func hexColorBinding(
    settings: SettingsStore,
    _ keyPath: ReferenceWritableKeyPath<SettingsStore, String>,
    fallback: String
) -> Binding<Color> {
    let box = SendableKeyPath(keyPath: keyPath)
    return Binding(
        get: {
            MainActor.assumeIsolated {
                Color(hex: settings[keyPath: box.keyPath])
                    ?? Color(hex: fallback)
                    ?? .white
            }
        },
        set: { newValue in
            MainActor.assumeIsolated {
                settings[keyPath: box.keyPath] = newValue.rgbHexString ?? fallback
                settings.persist()
            }
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

            Section("Apple On-Device Languages") {
                if #available(macOS 26.0, *) {
                    AppleLanguagesView()
                } else {
                    Text("Requires macOS 26.0 or later.")
                        .foregroundStyle(.secondary)
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

            if settings.overlayStyle == .subtitle {
                Section("Subtitle") {
                    Toggle("Show Background", isOn: persistedBinding(settings: settings, \.subtitleShowBackground))

                    if settings.subtitleShowBackground {
                        ColorPicker(
                            "Background Color",
                            selection: hexColorBinding(
                                settings: settings,
                                \.subtitleBackgroundColorHex,
                                fallback: "#000000"
                            ),
                            supportsOpacity: false
                        )
                    }

                    Toggle("Show Hairline Border", isOn: persistedBinding(settings: settings, \.subtitleShowBorder))

                    ColorPicker(
                        "Text Color",
                        selection: hexColorBinding(
                            settings: settings,
                            \.subtitleTextColorHex,
                            fallback: "#FFFFFF"
                        ),
                        supportsOpacity: false
                    )

                    ColorPicker(
                        "Outline Color",
                        selection: hexColorBinding(
                            settings: settings,
                            \.subtitleOutlineColorHex,
                            fallback: "#000000"
                        ),
                        supportsOpacity: false
                    )

                    SubtitlePreviewView(
                        textColor: Color(hex: settings.subtitleTextColorHex) ?? .white,
                        outlineColor: Color(hex: settings.subtitleOutlineColorHex) ?? .black,
                        backgroundColor: Color(hex: settings.subtitleBackgroundColorHex) ?? .black,
                        showsBackground: settings.subtitleShowBackground,
                        showsBorder: settings.subtitleShowBorder
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct SubtitlePreviewView: View {
    let textColor: Color
    let outlineColor: Color
    let backgroundColor: Color
    let showsBackground: Bool
    let showsBorder: Bool

    private let outlineOffsets: [CGSize] = [
        CGSize(width: -1, height: 0),
        CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1),
        CGSize(width: 0, height: 1),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.86))

            if showsBackground {
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor.opacity(0.58))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
            }

            if showsBorder {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(outlineColor.opacity(0.26), lineWidth: 1)
                    .padding(.horizontal, showsBackground ? 22 : 0)
                    .padding(.vertical, showsBackground ? 14 : 0)
            }

            ZStack {
                ForEach(Array(outlineOffsets.enumerated()), id: \.offset) { _, offset in
                    previewText
                        .foregroundStyle(outlineColor)
                        .offset(offset)
                }
                previewText
                    .foregroundStyle(textColor)
            }
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
            .padding(.horizontal, 14)
        }
        .frame(height: 74)
        .frame(maxWidth: .infinity)
    }

    private var previewText: some View {
        Text("Thanks for your comment.")
            .font(.system(size: 22, weight: .bold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
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

    var rgbHexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let red = max(0, min(255, Int(round(color.redComponent * 255))))
        let green = max(0, min(255, Int(round(color.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(color.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private struct HistorySettingsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PinnedTranslation.createdAt, order: .reverse) private var items: [PinnedTranslation]
    @State private var isConfirmingClearHistory = false

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
                VStack(spacing: 0) {
                    HStack {
                        Text("Pinned Translations")
                            .font(.headline)

                        Spacer()

                        Button(role: .destructive) {
                            isConfirmingClearHistory = true
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(items) { item in
                                HistoryCard(item: item) {
                                    delete(item)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear all pinned translations?",
            isPresented: $isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func delete(_ item: PinnedTranslation) {
        modelContext.delete(item)
        try? modelContext.save()
    }

    private func clearHistory() {
        for item in Array(items) {
            modelContext.delete(item)
        }
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

@available(macOS 26.0, *)
@MainActor
private struct AppleLanguagesView: View {
    @State private var manager = AppleLanguageManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Manage language models for Apple Translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: {
                    Task { await manager.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(manager.isLoading)
            }

            if manager.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if manager.items.isEmpty {
                Text("No languages found.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.items) { item in
                            LanguageRow(item: item) {
                                Task { await manager.download(language: item.language) }
                            }
                            Divider()
                        }
                    }
                }
                .frame(height: 200)

                HStack {
                    Spacer()
                    Button("Download All Missing") {
                        Task { await manager.downloadAll() }
                    }
                    .disabled(manager.items.allSatisfy { $0.status != .supported })
                }
            }
        }
        .task {
            await manager.refresh()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private struct LanguageRow: View {
    let item: AppleLanguageManager.Item
    let onDownload: () -> Void

    var body: some View {
        HStack {
            Text(Locale.current.localizedString(forLanguageCode: item.language.languageCode?.identifier ?? "") ?? item.language.languageCode?.identifier ?? "Unknown")
            Spacer()
            switch item.status {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .supported:
                Button("Download", action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .unsupported:
                Text("Unsupported")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            @unknown default:
                Text("Unknown")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
