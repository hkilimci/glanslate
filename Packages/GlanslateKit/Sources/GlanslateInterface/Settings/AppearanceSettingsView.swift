import GlanslateCore
import GlanslateSystem
import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var previewIsDark = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                OverlayPreview(
                    style: settings.overlayStyle,
                    subtitle: settings.subtitle,
                    textScale: settings.textScale,
                    isDark: previewIsDark
                )
                Picker("Style", selection: $settings.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Preview on", selection: $previewIsDark) {
                    Text("Light Content").tag(false)
                    Text("Dark Content").tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent("Text size") {
                    Slider(value: $settings.textScale, in: 0.85...1.3, step: 0.05) {
                        Text("Text size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller").accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger").accessibilityHidden(true)
                    }
                    .frame(maxWidth: 280)
                }
            } header: {
                Text("Overlay")
            } footer: {
                Text(settings.overlayStyle.summary + " You can switch styles for a single translation from its toolbar.")
            }

            Section {
                ColorPicker("Background", selection: $settings.subtitle.backgroundColor.colorBinding, supportsOpacity: true)
                ColorPicker("Text", selection: $settings.subtitle.textColor.colorBinding, supportsOpacity: false)
                Toggle("Outline text", isOn: $settings.subtitle.showsOutline)
                if settings.subtitle.showsOutline {
                    ColorPicker("Outline", selection: $settings.subtitle.outlineColor.colorBinding, supportsOpacity: false)
                }
                Toggle("Border", isOn: $settings.subtitle.showsBorder)
                if settings.subtitle.showsBorder {
                    ColorPicker("Border color", selection: $settings.subtitle.borderColor.colorBinding, supportsOpacity: true)
                }
            } header: {
                Text("Subtitle Style")
            } footer: {
                if subtitleContrast < 4.5 {
                    Label("Text and background have low contrast (\(subtitleContrast.formatted(.number.precision(.fractionLength(1)))):1). Choose colors that differ more for easier reading.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Applies when the Subtitle style is selected.")
                }
            }

            Section {
                Button("Restore Default Appearance") { settings.resetAppearance() }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: settings.subtitle)
    }

    /// Contrast of the subtitle text over its background composited on black.
    private var subtitleContrast: Double {
        let subtitle = app.settings.subtitle
        let background = subtitle.backgroundColor
        let composited = RGBAColor(
            red: background.red * background.alpha,
            green: background.green * background.alpha,
            blue: background.blue * background.alpha
        )
        return subtitle.textColor.withAlpha(1).contrastRatio(with: composited)
    }
}

/// A live sample of the overlay: French source text with its English
/// translation drawn in the selected style.
struct OverlayPreview: View {
    let style: OverlayStyle
    let subtitle: SubtitleAppearance
    let textScale: Double
    let isDark: Bool

    @State private var backdrops: [UUID: BlockBackdrop] = [:]

    private struct Sample: Identifiable {
        let id: UUID
        let source: String
        let translation: String
        let frame: CGRect
        let fontSize: CGFloat
        let weight: Font.Weight
        let lines: Int
    }

    private static let samples = [
        Sample(id: UUID(), source: "Bienvenue", translation: "Welcome", frame: CGRect(x: 22, y: 20, width: 130, height: 30), fontSize: 22, weight: .semibold, lines: 1),
        Sample(id: UUID(), source: "Sélectionnez du texte n’importe où sur l’écran pour le lire dans votre langue.", translation: "Select text anywhere on your screen to read it in your language.", frame: CGRect(x: 22, y: 62, width: 340, height: 42), fontSize: 15, weight: .regular, lines: 2),
        Sample(id: UUID(), source: "Annuler", translation: "Cancel", frame: CGRect(x: 22, y: 122, width: 70, height: 22), fontSize: 13, weight: .regular, lines: 1),
    ]

    private static let canvasSize = CGSize(width: 420, height: 164)

    var body: some View {
        ZStack(alignment: .topLeading) {
            source
            ForEach(Self.samples) { sample in
                let layout = layoutFor(sample)
                TranslatedBlockView(
                    text: sample.translation,
                    original: sample.source,
                    layout: layout,
                    style: style,
                    backdrop: backdrops[sample.id],
                    subtitle: subtitle,
                    isRightToLeft: false,
                    isSingleLine: sample.lines == 1
                )
                .frame(width: layout.frame.width, height: layout.frame.height)
                .offset(x: layout.frame.minX, y: layout.frame.minY)
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .task(id: isDark) { await renderBackdrops() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(style.displayName) style")
    }

    private var source: some View {
        ZStack(alignment: .topLeading) {
            (isDark ? Color(white: 0.12) : Color.white)
            ForEach(Self.samples) { sample in
                Text(sample.source)
                    .font(.system(size: sample.fontSize, weight: sample.weight))
                    .foregroundStyle(isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.85))
                    .frame(width: sample.frame.width, height: sample.frame.height, alignment: .topLeading)
                    .offset(x: sample.frame.minX, y: sample.frame.minY)
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    private func layoutFor(_ sample: Sample) -> OverlayBlockLayout {
        let engine = OverlayLayoutEngine()
        let base = engine.baseFontSize(forLineHeight: sample.fontSize / engine.fontToLineHeight, textScale: CGFloat(textScale))
        let padding = CGSize(width: max(3, (base * 0.32).rounded()), height: max(1.5, (base * 0.14).rounded()))
        let frame = sample.frame.insetBy(dx: -padding.width, dy: -padding.height)
        let width = sample.lines == 1 ? frame.width * 1.25 : frame.width
        return OverlayBlockLayout(
            id: sample.id,
            frame: CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height + (sample.lines > 1 ? 6 : 0)),
            fontSize: base,
            padding: padding,
            isCompressed: false
        )
    }

    @MainActor
    private func renderBackdrops() async {
        let renderer = ImageRenderer(content: source)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        var result: [UUID: BlockBackdrop] = [:]
        for sample in Self.samples {
            let rect = layoutFor(sample).frame
            let pixels = CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2).integral
            guard let crop = image.cropping(to: pixels) else { continue }
            result[sample.id] = BackdropRenderer.makeBackdrop(from: crop, scale: 2, lineHeight: sample.fontSize)
        }
        backdrops = result
    }
}
