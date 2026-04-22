import AppKit
import Foundation
import SwiftUI
import GlanslateCore
import GlanslateSettings

struct OverlayToolbarLayout {
    static let preferredSize = CGSize(width: 620, height: 58)
    static let minimumWidth = CGFloat(440)
    static let inset = CGFloat(12)

    static func frame(
        for sourceRect: CGRect,
        displaySize: CGSize
    ) -> CGRect {
        let displayBounds = CGRect(origin: .zero, size: displaySize)
        let width = min(
            preferredSize.width,
            max(260, min(displayBounds.width - (inset * 2), max(sourceRect.width, minimumWidth)))
        )
        let originX = min(
            max(inset, sourceRect.maxX - width),
            displayBounds.maxX - width - inset
        )
        let originY = min(
            max(inset, sourceRect.minY + 8),
            displayBounds.maxY - preferredSize.height - inset
        )

        return CGRect(
            x: originX,
            y: originY,
            width: width,
            height: preferredSize.height
        )
    }
}

struct OverlayToolbarHoverState: Equatable, Sendable {
    static let restingOpacity = 0.3
    static let activeOpacity = 1.0
    static let activationDistance = CGFloat(80)

    private(set) var opacity = restingOpacity

    mutating func update(pointer: CGPoint, toolbarFrame: CGRect) {
        let expandedFrame = toolbarFrame.insetBy(
            dx: -Self.activationDistance,
            dy: -Self.activationDistance
        )
        opacity = expandedFrame.contains(pointer)
            ? Self.activeOpacity
            : Self.restingOpacity
    }
}

@MainActor
struct OverlayToolbarView: View {
    let viewModel: OverlaySessionViewModel
    let settings: SettingsStore
    let dismissAction: () -> Void
    let pinAction: () -> Void
    let styleAction: (OverlayStyle) -> Void
    let retranslateAction: (OverlayRetranslationRequest) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: dismissAction) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")

            Button(action: pinAction) {
                Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isPinned)
            .help(viewModel.isPinned ? "Pinned to History" : "Pin to History")

            Label(
                settings.peekModifier.displayName,
                systemImage: viewModel.isPeeking ? "eye.fill" : "eye"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(viewModel.isPeeking ? Color.primary : Color.secondary)
            .lineLimit(1)

            Divider()

            Menu {
                ForEach(Language.allCases.filter { $0 != .auto }, id: \.self) { language in
                    Button(language.displayName) {
                        retranslateAction(
                            OverlayRetranslationRequest(
                                targetLanguage: language,
                                provider: viewModel.currentRequest.provider,
                                sourceLanguage: viewModel.currentRequest.sourceLanguage
                            )
                        )
                    }
                }
            } label: {
                toolbarLabel("Target", value: viewModel.currentRequest.targetLanguage.toolbarLabel)
            }

            Menu {
                Button("Auto-detect") {
                    retranslateAction(
                        OverlayRetranslationRequest(
                            targetLanguage: viewModel.currentRequest.targetLanguage,
                            provider: viewModel.currentRequest.provider,
                            sourceLanguage: nil
                        )
                    )
                }

                Divider()

                ForEach(Language.allCases.filter { $0 != .auto }, id: \.self) { language in
                    Button(language.displayName) {
                        retranslateAction(
                            OverlayRetranslationRequest(
                                targetLanguage: viewModel.currentRequest.targetLanguage,
                                provider: viewModel.currentRequest.provider,
                                sourceLanguage: language
                            )
                        )
                    }
                }
            } label: {
                toolbarLabel(
                    "Source",
                    value: viewModel.currentRequest.sourceLanguage?.toolbarLabel ?? "Auto"
                )
            }

            Menu {
                Button("Default Router") {
                    retranslateAction(
                        OverlayRetranslationRequest(
                            targetLanguage: viewModel.currentRequest.targetLanguage,
                            provider: nil,
                            sourceLanguage: viewModel.currentRequest.sourceLanguage
                        )
                    )
                }

                Divider()

                ForEach(TranslationProvider.allCases, id: \.self) { provider in
                    Button(provider.displayName) {
                        retranslateAction(
                            OverlayRetranslationRequest(
                                targetLanguage: viewModel.currentRequest.targetLanguage,
                                provider: provider,
                                sourceLanguage: viewModel.currentRequest.sourceLanguage
                            )
                        )
                    }
                }
            } label: {
                toolbarLabel("Provider", value: viewModel.providerDisplayLabel)
            }

            Divider()

            Picker(
                "Style",
                selection: Binding(
                    get: { viewModel.effectiveStyle(settings: settings) },
                    set: { newStyle in
                        styleAction(newStyle)
                    }
                )
            ) {
                Image(systemName: "rectangle.fill").tag(OverlayStyle.cleanPatch)
                Image(systemName: "drop.fill").tag(OverlayStyle.blurPatch)
                Image(systemName: "captions.bubble.fill").tag(OverlayStyle.subtitle)
            }
            .pickerStyle(.segmented)
            .frame(width: 132)

            if viewModel.isRetranslating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 16, y: 4)
        .opacity(viewModel.toolbarOpacity)
        .animation(.easeInOut(duration: 0.14), value: viewModel.toolbarOpacity)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toolbarLabel(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

extension TranslationProvider {
    var toolbarLabel: String {
        switch self {
        case .apple: return "Apple"
        case .deepL: return "DeepL"
        case .google: return "Google"
        case .openAI: return "OpenAI"
        }
    }
}

extension Language {
    var toolbarLabel: String {
        switch self {
        case .zhHans: return "ZH-Hans"
        case .zhHant: return "ZH-Hant"
        case .auto: return "Auto"
        default: return rawValue.uppercased()
        }
    }
}
