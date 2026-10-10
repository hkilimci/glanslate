import GlanslateCore
import SwiftUI

/// What the toolbar can ask its controller to do.
@MainActor
struct GlanceToolbarActions {
    var dismiss: @MainActor () -> Void
    var copy: @MainActor () -> Void
    var togglePin: @MainActor () -> Void
    var toggleReveal: @MainActor () -> Void
    var setSource: @MainActor (SourceLanguage) -> Void
    var setTarget: @MainActor (Language) -> Void
    var setProvider: @MainActor (ProviderChoice) -> Void
    var setStyle: @MainActor (OverlayStyle) -> Void
    var recover: @MainActor (GlanslateError.Recovery) -> Void
}

@MainActor
@Observable
final class ToolbarContext {
    var edge: FloatingToolbarPlacement.Edge = .below
    var configuredProviders: Set<TranslationProvider> = [.apple]
    var revealModifier: RevealModifier = .option
    var canPin = true
}

/// The compact floating toolbar shown next to a translation.
struct GlanceToolbar: View {
    let session: GlanceSession
    let context: ToolbarContext
    let actions: GlanceToolbarActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            if context.edge == .above { statusArea }
            mainBar
            if context.edge != .above { statusArea }
        }
        .padding(10)
        .fixedSize()
        .animation(MotionAwareAnimation.standard(reduceMotion), value: statusIdentity)
    }

    // MARK: Main bar

    private var mainBar: some View {
        HStack(spacing: 2) {
            Button(action: actions.dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close (esc)")
            .accessibilityLabel("Close")

            separator

            Button(action: actions.copy) {
                Image(systemName: session.didCopy ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ToolbarIconButtonStyle(isActive: session.didCopy))
            .keyboardShortcut("c", modifiers: .command)
            .disabled(session.result == nil)
            .help("Copy Translation (⌘C)")
            .accessibilityLabel("Copy translation")

            Button(action: actions.togglePin) {
                Image(systemName: session.isPinned ? "pin.fill" : "pin")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ToolbarIconButtonStyle(isActive: session.isPinned))
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session.result == nil || !context.canPin)
            .help(session.isPinned ? "Remove from Saved Translations (⌘S)" : "Save to Saved Translations (⌘S)")
            .accessibilityLabel(session.isPinned ? "Unpin" : "Pin to Saved Translations")

            Button(action: actions.toggleReveal) {
                Image(systemName: session.isRevealingOriginal ? "eye.slash" : "eye")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ToolbarIconButtonStyle(isActive: session.isRevealToggled))
            .keyboardShortcut("o", modifiers: .command)
            .disabled(session.result == nil)
            .help("Show Original (⌘O) — or hold \(context.revealModifier.symbol)")
            .accessibilityLabel(session.isRevealToggled ? "Show translation" : "Show original")

            separator

            languageMenus

            separator

            providerMenu
            styleMenu

            if session.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 6)
                    .accessibilityLabel(session.statusText ?? "Working")
            }
        }
        .padding(5)
        .toolbarSurface(in: Capsule())
    }

    private var separator: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 3)
    }

    private var languageMenus: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("Source Language", selection: Binding(get: { session.sourceLanguage }, set: { actions.setSource($0) })) {
                    Text(automaticSourceTitle).tag(SourceLanguage.automatic)
                    Divider()
                    ForEach(Language.sortedCatalog()) { language in
                        Text(language.localizedName()).tag(SourceLanguage.specific(language))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                chip(session.sourceLabel, systemImage: session.sourceLanguage == .automatic ? "sparkle.magnifyingglass" : nil)
            }
            .menuStyle(.button)
            .buttonStyle(ToolbarChipStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Source language")

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Menu {
                Picker("Target Language", selection: Binding(get: { session.targetLanguage }, set: { actions.setTarget($0) })) {
                    ForEach(Language.sortedCatalog()) { language in
                        Text(language.localizedName()).tag(language)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                chip(session.targetLanguage.localizedName(), systemImage: nil)
            }
            .menuStyle(.button)
            .buttonStyle(ToolbarChipStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Target language")
        }
    }

    private var automaticSourceTitle: String {
        if let detected = session.detectedLanguage {
            return "Detect Automatically (\(detected.localizedName()))"
        }
        return "Detect Automatically"
    }

    private var providerMenu: some View {
        Menu {
            Picker("Provider", selection: Binding(get: { session.providerChoice }, set: { actions.setProvider($0) })) {
                Text("Automatic").tag(ProviderChoice.automatic)
                Divider()
                ForEach(TranslationProvider.allCases) { provider in
                    Text(providerTitle(provider)).tag(ProviderChoice.specific(provider))
                }
            }
            .pickerStyle(.inline)
        } label: {
            chip(session.providerLabel, systemImage: nil)
        }
        .menuStyle(.button)
        .buttonStyle(ToolbarChipStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Translation provider")
    }

    private func providerTitle(_ provider: TranslationProvider) -> String {
        if provider == .apple { return "\(provider.displayName) (On Device)" }
        return context.configuredProviders.contains(provider) ? provider.displayName : "\(provider.displayName) — Not Set Up"
    }

    private var styleMenu: some View {
        Menu {
            Picker("Overlay Style", selection: Binding(get: { session.style }, set: { actions.setStyle($0) })) {
                ForEach(OverlayStyle.allCases) { style in
                    Label(style.displayName, systemImage: style.symbolName).tag(style)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: session.style.symbolName)
                .frame(width: 18)
        }
        .menuStyle(.button)
        .buttonStyle(ToolbarIconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Overlay style: \(session.style.displayName)")
        .accessibilityLabel("Overlay style")
    }

    private func chip(_ title: String, systemImage: String?) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    private var statusIdentity: String {
        if let error = session.error { return error.title }
        if let note = session.result?.outcome.fallback { return note.message }
        return session.result == nil ? (session.statusText ?? "") : ""
    }

    @ViewBuilder
    private var statusArea: some View {
        if let error = session.error {
            errorStatus(error)
        } else if session.result == nil, let status = session.statusText {
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .toolbarSurface(in: Capsule())
        } else if let note = session.result?.outcome.fallback, let provider = session.result?.outcome.provider {
            Label("Translated with \(provider.displayName). \(note.message).", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .toolbarSurface(in: Capsule())
        }
    }

    private func errorStatus(_ error: GlanslateError) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(error.title).font(.callout.weight(.semibold))
                Text(error.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360, alignment: .leading)
            if let recovery = error.recovery, let title = recoveryTitle(recovery) {
                Button(title) { actions.recover(recovery) }
                    .controlSize(.small)
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .toolbarSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func recoveryTitle(_ recovery: GlanslateError.Recovery) -> String? {
        switch recovery {
        case .openScreenRecordingSettings: return "Open System Settings"
        case .openProviderSettings: return "Open Settings"
        case .downloadLanguages: return "Download…"
        case .retry: return "Try Again"
        case .selectAgain: return "Select Again"
        case .chooseSourceLanguage, .chooseTargetLanguage, .chooseProvider: return nil
        }
    }
}

private struct ToolbarSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1) }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    if contrast == .increased { shape.stroke(Color.primary.opacity(0.4), lineWidth: 1) }
                }
        }
    }
}

extension View {
    func toolbarSurface<S: Shape>(in shape: S) -> some View {
        modifier(ToolbarSurface(shape: shape))
    }
}
