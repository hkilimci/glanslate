import AppKit
import GlanslateCore
import SwiftUI

extension RGBAColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }
}

/// A `Binding<Color>` over a stored `RGBAColor`, for `ColorPicker`.
extension Binding where Value == RGBAColor {
    var color: Binding<Color> {
        Binding<Color>(get: { wrappedValue.color }, set: { wrappedValue = RGBAColor($0) })
    }
}

/// Animation that respects Reduce Motion.
struct MotionAwareAnimation {
    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }

    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

/// A compact icon button with hover, pressed, focus, and disabled states, used in floating toolbars.
struct ToolbarIconButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarControlBody(configuration: configuration, isActive: isActive, minWidth: 28, horizontalPadding: 0)
    }
}

/// A text-and-chevron control for toolbar menus.
struct ToolbarChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarControlBody(configuration: configuration, isActive: false, minWidth: 0, horizontalPadding: 8)
    }
}

private struct ToolbarControlBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    let minWidth: CGFloat
    let horizontalPadding: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: minWidth, minHeight: 28)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                if contrast == .increased && (isHovered || isActive) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: 8))
            .onHover { hovering in
                withAnimation(MotionAwareAnimation.quick(reduceMotion)) { isHovered = hovering }
            }
    }

    private var foreground: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(.tertiary) }
        if isActive { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(.primary)
    }

    private var fill: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return Color.primary.opacity(0.16) }
        if isActive { return Color.accentColor.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}

/// System Settings–style sidebar icon: a white SF Symbol on a small colored rounded square.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color, in: .rect(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small status capsule such as "Granted" or "Not Downloaded".
struct StatusBadge: View {
    enum Tone { case positive, neutral, attention }
    let text: String
    let tone: Tone

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(color)
    }

    private var symbol: String {
        switch tone {
        case .positive: return "checkmark.circle.fill"
        case .neutral: return "circle.dashed"
        case .attention: return "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .positive: return .green
        case .neutral: return .secondary
        case .attention: return .orange
        }
    }
}

/// Key-cap styled text for keyboard hints.
struct KeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            }
    }
}

extension TranslationProvider {
    var symbolName: String {
        switch self {
        case .apple: return "apple.logo"
        case .deepL: return "d.square"
        case .google: return "g.square"
        case .openAI: return "sparkles"
        }
    }
}
