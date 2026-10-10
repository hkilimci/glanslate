import Foundation

/// How translated text is drawn over the original.
public enum OverlayStyle: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// Translated text on subtle Liquid Glass surfaces.
    case liquidGlass
    /// The source text is blurred away beneath each translated block.
    case blurPatch
    /// High-contrast caption text with a configurable background.
    case subtitle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .blurPatch: return "Blur Patch"
        case .subtitle: return "Subtitle"
        }
    }

    public var symbolName: String {
        switch self {
        case .liquidGlass: return "square.on.square.intersection.dashed"
        case .blurPatch: return "drop.halffull"
        case .subtitle: return "captions.bubble"
        }
    }

    public var summary: String {
        switch self {
        case .liquidGlass: return "Translations float on glass surfaces aligned with the original text."
        case .blurPatch: return "The original text is blurred away beneath each translation."
        case .subtitle: return "High-contrast captions with your choice of colors."
        }
    }
}

/// A color stored as sRGB components so it can live in preferences.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA`.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        red = Double((value >> (16 + shift)) & 0xFF) / 255
        green = Double((value >> (8 + shift)) & 0xFF) / 255
        blue = Double((value >> shift) & 0xFF) / 255
        alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
    }

    public var hex: String {
        func component(_ value: Double) -> String {
            let byte = Int((min(max(value, 0), 1) * 255).rounded())
            let text = String(byte, radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + component(red) + component(green) + component(blue) + (alpha < 1 ? component(alpha) : "")
    }

    /// WCAG relative luminance (0 = black, 1 = white).
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two opaque colors (1...21).
    public func contrastRatio(with other: RGBAColor) -> Double {
        let a = luminance + 0.05, b = other.luminance + 0.05
        return max(a, b) / min(a, b)
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
}

/// Colors and decorations for the Subtitle style.
public struct SubtitleAppearance: Codable, Hashable, Sendable {
    public var backgroundColor: RGBAColor
    public var textColor: RGBAColor
    public var showsOutline: Bool
    public var outlineColor: RGBAColor
    public var showsBorder: Bool
    public var borderColor: RGBAColor

    public init(
        backgroundColor: RGBAColor = RGBAColor.black.withAlpha(0.78),
        textColor: RGBAColor = .white,
        showsOutline: Bool = false,
        outlineColor: RGBAColor = .black,
        showsBorder: Bool = false,
        borderColor: RGBAColor = RGBAColor.white.withAlpha(0.35)
    ) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.showsOutline = showsOutline
        self.outlineColor = outlineColor
        self.showsBorder = showsBorder
        self.borderColor = borderColor
    }

    public static let `default` = SubtitleAppearance()
}

/// The modifier key that temporarily reveals the original content while held.
public enum RevealModifier: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case option, command, control, shift

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    public var displayName: String {
        switch self {
        case .option: return "Option"
        case .command: return "Command"
        case .control: return "Control"
        case .shift: return "Shift"
        }
    }
}
