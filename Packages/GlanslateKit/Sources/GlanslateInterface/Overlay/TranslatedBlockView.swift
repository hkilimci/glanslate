import GlanslateCore
import SwiftUI

/// One translated paragraph drawn over its original, in the chosen style.
struct TranslatedBlockView: View {
    let text: String
    let original: String
    let layout: OverlayBlockLayout
    let style: OverlayStyle
    let backdrop: BlockBackdrop?
    let subtitle: SubtitleAppearance
    let isRightToLeft: Bool
    let isSingleLine: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var cornerRadius: CGFloat {
        switch style {
        case .liquidGlass: return min(10, max(5, layout.fontSize * 0.55))
        case .blurPatch: return 4
        case .subtitle: return 6
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        styled(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityHint("Translation of: \(original)")
            .contextMenu {
                Button("Copy Translation") { Pasteboard.copy(text) }
                Button("Copy Original") { Pasteboard.copy(original) }
            }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: layout.fontSize))
            .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
            .minimumScaleFactor(0.8)
            .textSelection(.enabled)
            .padding(.horizontal, layout.padding.width)
            .padding(.vertical, layout.padding.height)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: isSingleLine ? (isRightToLeft ? .trailing : .leading) : (isRightToLeft ? .topTrailing : .topLeading)
            )
            .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder
    private func styled(_ content: some View) -> some View {
        switch style {
        case .liquidGlass: glass(content)
        case .blurPatch: blurPatch(content)
        case .subtitle: subtitleStyle(content)
        }
    }

    // MARK: Liquid Glass

    @ViewBuilder
    private func glass(_ content: some View) -> some View {
        let scheme: ColorScheme = (backdrop?.isLight ?? true) ? .light : .dark
        if reduceTransparency {
            content
                .foregroundStyle(.primary)
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
                .environment(\.colorScheme, scheme)
        } else {
            content
                .foregroundStyle(.primary)
                .background {
                    // The blurred original keeps source glyphs from showing through the glass.
                    if let image = backdrop?.blurred {
                        Image(decorative: image, scale: 1).resizable().opacity(0.55)
                    }
                }
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
                    }
                }
                .environment(\.colorScheme, scheme)
        }
    }

    // MARK: Blur Patch

    private func blurPatch(_ content: some View) -> some View {
        let isLight = backdrop?.isLight ?? true
        let tint = backdrop?.averageColor.color ?? Color(nsColor: .windowBackgroundColor)
        return content
            .foregroundStyle(isLight ? Color.black.opacity(0.88) : Color.white.opacity(0.95))
            .background {
                ZStack {
                    tint
                    if let image = backdrop?.blurred {
                        Image(decorative: image, scale: 1).resizable()
                    }
                    tint.opacity(contrast == .increased || reduceTransparency ? 0.75 : 0.5)
                }
            }
            .clipShape(shape)
    }

    // MARK: Subtitle

    private func subtitleStyle(_ content: some View) -> some View {
        var background = subtitle.backgroundColor
        if reduceTransparency || contrast == .increased { background.alpha = max(background.alpha, 0.95) }
        let outline = subtitle.outlineColor.color
        let width = max(0.6, layout.fontSize / 16)
        return content
            .foregroundStyle(subtitle.textColor.color)
            .fontWeight(.medium)
            .modifier(OutlineModifier(color: outline, width: width, isEnabled: subtitle.showsOutline))
            .background {
                // The blurred original sits under translucent backgrounds so source
                // glyphs never ghost through the caption.
                ZStack {
                    if background.alpha > 0, background.alpha < 1, let image = backdrop?.blurred {
                        Image(decorative: image, scale: 1).resizable()
                    }
                    background.color
                }
                .clipShape(shape)
            }
            .overlay {
                if subtitle.showsBorder {
                    shape.strokeBorder(subtitle.borderColor.color, lineWidth: 1)
                }
            }
    }
}

/// A crisp text outline drawn from eight hard-edged shadows.
private struct OutlineModifier: ViewModifier {
    let color: Color
    let width: CGFloat
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .shadow(color: color, radius: 0, x: width, y: 0)
                .shadow(color: color, radius: 0, x: -width, y: 0)
                .shadow(color: color, radius: 0, x: 0, y: width)
                .shadow(color: color, radius: 0, x: 0, y: -width)
                .shadow(color: color, radius: 0, x: width * 0.7, y: width * 0.7)
                .shadow(color: color, radius: 0, x: -width * 0.7, y: -width * 0.7)
                .shadow(color: color, radius: 0, x: width * 0.7, y: -width * 0.7)
                .shadow(color: color, radius: 0, x: -width * 0.7, y: width * 0.7)
        } else {
            content
        }
    }
}

@MainActor
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
