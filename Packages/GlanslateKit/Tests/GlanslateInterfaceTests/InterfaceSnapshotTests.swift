import AppKit
import Foundation
import GlanslateCore
import GlanslatePersistence
import GlanslateSystem
import SwiftUI
import Testing
@testable import GlanslateInterface

/// Renders the real windows and overlay in light and dark appearance to PNG
/// files for visual review. Runs only when `GLANSLATE_SNAPSHOTS` names an
/// output directory (CI uploads the result as an artifact).
@Suite("Interface snapshots", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GLANSLATE_SNAPSHOTS"] != nil))
@MainActor
struct InterfaceSnapshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLANSLATE_SNAPSHOTS"] ?? NSTemporaryDirectory())

    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    @Test func settingsSections() throws {
        for dark in [false, true] {
            for section in SettingsSection.allCases {
                let environment = try Fixtures.environment()
                environment.settingsSection = section
                try render(SettingsView().environment(environment), size: CGSize(width: 760, height: 580), dark: dark, name: "settings-\(section.rawValue)")
            }
        }
    }

    @Test func softwareUpdate() async throws {
        for dark in [false, true] {
            let environment = try Fixtures.environment(update: .success(.available(.sample())))
            await environment.updates?.runCheck(userInitiated: true)
            environment.settingsSection = .about
            try render(SettingsView().environment(environment), size: CGSize(width: 760, height: 580), dark: dark, name: "settings-about-update")
        }
    }

    @Test func onboardingSteps() throws {
        for dark in [false, true] {
            for step in OnboardingView.Step.allCases {
                let environment = try Fixtures.environment()
                try render(
                    OnboardingView(initialStep: step).environment(environment),
                    size: CGSize(width: 620, height: 600),
                    dark: dark,
                    name: "onboarding-\(step.rawValue)",
                    transparentTitlebar: true
                )
            }
        }
    }

    @Test func savedTranslations() throws {
        for dark in [false, true] {
            let empty = try Fixtures.environment()
            try render(SavedTranslationsView().environment(empty), size: CGSize(width: 880, height: 560), dark: dark, name: "saved-empty")

            let populated = try Fixtures.environment()
            try Fixtures.populate(populated.store!)
            try render(SavedTranslationsView().environment(populated), size: CGSize(width: 880, height: 560), dark: dark, name: "saved-list")
        }
    }

    @Test func overlayStyles() throws {
        for darkContent in [false, true] {
            for style in OverlayStyle.allCases {
                let environment = try Fixtures.environment()
                let scene = OverlayScene.make(style: style, darkContent: darkContent, settings: environment.settings)
                try render(scene.view, size: scene.size, dark: darkContent, name: "overlay-\(style.rawValue)", titled: false)
            }
            // A light-mode Mac reading dark content, and the reverse.
            let mixedEnvironment = try Fixtures.environment()
            let mixed = OverlayScene.make(style: .liquidGlass, darkContent: darkContent, settings: mixedEnvironment.settings)
            try render(mixed.view, size: mixed.size, dark: !darkContent, name: "overlay-liquidGlass-\(darkContent ? "darkcontent" : "lightcontent")-mixed", titled: false)

            let rtlEnvironment = try Fixtures.environment()
            let rtl = OverlayScene.make(style: .liquidGlass, darkContent: darkContent, settings: rtlEnvironment.settings, target: .arabic)
            try render(rtl.view, size: rtl.size, dark: darkContent, name: "overlay-rtl", titled: false)

            let environment = try Fixtures.environment()
            let failing = OverlayScene.make(style: .liquidGlass, darkContent: darkContent, settings: environment.settings, error: .languageModelsNotInstalled(source: .french, target: .english))
            try render(failing.view, size: failing.size, dark: darkContent, name: "overlay-error", titled: false)
        }
    }

    @Test func selectionHints() throws {
        for message in [nil, "Drag a larger area to translate."] {
            let model = SelectionHintModel()
            model.message = message
            let view = ZStack {
                Color.black.opacity(0.28)
                SelectionHintView(model: model)
            }
            .background(Color(white: 0.85))
            try render(view, size: CGSize(width: 560, height: 120), dark: false, name: message == nil ? "selection-hint" : "selection-message", titled: false)
        }
    }

    // MARK: Rendering

    private func render(
        _ view: some View,
        size: CGSize,
        dark: Bool,
        name: String,
        titled: Bool = true,
        transparentTitlebar: Bool = false
    ) throws {
        let controller = NSHostingController(rootView: AnyView(view))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = transparentTitlebar
        if transparentTitlebar { window.titleVisibility = .hidden }
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let target = window.contentView?.superview ?? window.contentView!
        let bounds = target.bounds
        let representation = try #require(target.bitmapImageRepForCachingDisplay(in: bounds))
        target.cacheDisplay(in: bounds, to: representation)
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.orderOut(nil)
        window.close()
        print("Rendered \(name)-\(dark ? "dark" : "light")")
    }
}

// MARK: - Fixtures

@MainActor
enum Fixtures {
    static func environment(
        update: Result<UpdateCheckResult, UpdateError> = .success(.upToDate(latest: nil))
    ) throws -> AppEnvironment {
        let suite = "glanslate.snapshots.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.targetLanguage = .english
        return AppEnvironment(
            settings: settings,
            permissions: PermissionMonitor(),
            credentials: PreviewCredentialStore(),
            store: try SavedTranslationStore(inMemory: true),
            updates: UpdateController(
                currentVersion: AppVersion("1.0.0")!,
                settings: settings,
                checker: StubUpdateChecker(update),
                installer: StubUpdateInstaller()
            )
        )
    }

    static func populate(_ store: SavedTranslationStore) throws {
        let samples: [(String, String, Language, TranslationProvider, TimeInterval)] = [
            ("Les cafés du quartier ouvrent tôt et ferment tard.", "The neighborhood cafés open early and close late.", .french, .apple, -120),
            ("Bitte halten Sie Ihre Fahrkarte bereit.", "Please have your ticket ready.", .german, .deepL, -3_600),
            ("出口は左側です。", "The exit is on the left.", .japanese, .google, -86_400 * 2),
        ]
        for (original, translated, source, provider, offset) in samples {
            try store.save(SavedTranslationDraft(
                id: UUID(),
                createdAt: Date().addingTimeInterval(offset),
                originalText: original,
                translatedText: translated,
                sourceLanguage: source,
                targetLanguage: .english,
                provider: provider,
                thumbnail: thumbnail(text: original)
            ))
        }
    }

    static func thumbnail(text: String) -> Data? {
        let renderer = ImageRenderer(content:
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.black)
                .padding(16)
                .frame(width: 360, height: 120, alignment: .topLeading)
                .background(Color.white)
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// A fake screen region with French text, its English overlay, and the toolbar.
@MainActor
struct OverlayScene {
    let view: AnyView
    let size: CGSize

    private struct Source {
        let text: String
        let translation: String
        let frame: CGRect
        let fontSize: CGFloat
        let weight: Font.Weight
    }

    private static let region = CGRect(x: 0, y: 0, width: 520, height: 180)

    private static let sources = [
        Source(text: "Un nouveau regard sur la ville", translation: "A new look at the city", frame: CGRect(x: 24, y: 20, width: 330, height: 28), fontSize: 22, weight: .semibold),
        Source(text: "Les cafés du quartier ouvrent tôt et ferment tard, et les", translation: "", frame: CGRect(x: 24, y: 64, width: 440, height: 19), fontSize: 15, weight: .regular),
        Source(text: "rues restent animées jusqu’à minuit.", translation: "", frame: CGRect(x: 24, y: 86, width: 270, height: 19), fontSize: 15, weight: .regular),
        Source(text: "Lire la suite", translation: "Read more", frame: CGRect(x: 24, y: 132, width: 92, height: 17), fontSize: 13, weight: .medium),
    ]

    static func make(
        style: OverlayStyle,
        darkContent: Bool,
        settings: AppSettings,
        error: GlanslateError? = nil,
        target: Language = .english
    ) -> OverlayScene {
        let content = sourceContent(dark: darkContent)

        let lines = sources.map { RecognizedLine(text: $0.text, frame: $0.frame) }
        let blocks = TextGrouper().group(lines)
        let regionModel = ScreenRegion(displayID: 1, rect: region)
        let recognized = RecognizedText(region: regionModel, blocks: blocks, detectedLanguage: DetectedLanguage(language: .french, confidence: 0.98))
        let arabic = target == .arabic
        let translations = blocks.map { block -> String in
            switch block.text {
            case let text where text.hasPrefix("Un nouveau"): return arabic ? "نظرة جديدة على المدينة" : "A new look at the city"
            case let text where text.hasPrefix("Les cafés"):
                return arabic
                    ? "تفتح مقاهي الحي مبكرًا وتغلق متأخرًا، وتبقى الشوارع مفعمة بالحياة حتى منتصف الليل."
                    : "The neighborhood cafés open early and close late, and the streets stay lively until midnight."
            default: return arabic ? "اقرأ المزيد" : "Read more"
            }
        }

        let display = DisplayDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        let session = GlanceSession(
            target: .area(regionModel),
            display: display,
            layout: DisplayLayout(displays: [display]),
            sourceLanguage: .automatic,
            targetLanguage: target,
            style: style
        )
        session.recognized = recognized
        if let error {
            session.error = error
            session.phase = .failed
        } else {
            session.result = GlanceResult(
                recognized: recognized,
                outcome: TranslationOutcome(provider: .apple, texts: translations, source: .french, target: target, fallback: nil)
            )
            session.phase = .ready
            session.blockLayouts = OverlayLayoutEngine().layout(
                zip(blocks, translations).map { OverlayLayoutInput(block: $0, translation: $1) },
                in: region,
                measurer: AppKitTextMeasurer()
            )
        }

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.cgImage {
            var backdrops: [UUID: BlockBackdrop] = [:]
            for block in blocks {
                let padding = max(3, block.lineHeight * 0.3)
                let rect = block.frame.insetBy(dx: -padding, dy: -padding).intersection(region)
                let pixels = CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2).integral
                if let crop = image.cropping(to: pixels) {
                    backdrops[block.id] = BackdropRenderer.makeBackdrop(from: crop, scale: 2, lineHeight: block.lineHeight)
                }
            }
            session.backdrops = backdrops
        }

        let context = ToolbarContext()
        context.configuredProviders = [.apple, .deepL]
        let actions = GlanceToolbarActions(
            dismiss: {}, translateRegion: {}, copy: {}, togglePin: {}, toggleReveal: {},
            setSource: { _ in }, setTarget: { _ in }, setProvider: { _ in }, setStyle: { _ in }, recover: { _ in }
        )

        let view = VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                content
                OverlayCanvas(session: session, settings: settings)
            }
            .frame(width: region.width, height: region.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            GlanceToolbar(session: session, context: context, actions: actions)
        }
        .padding(24)
        .frame(width: 720, height: 360)
        .background(darkContent ? Color(white: 0.2) : Color(white: 0.9))

        return OverlayScene(view: AnyView(view), size: CGSize(width: 720, height: 360))
    }

    private static func sourceContent(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            (dark ? Color(white: 0.11) : Color.white)
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                Text(source.text)
                    .font(.system(size: source.fontSize, weight: source.weight))
                    .foregroundStyle(source.text == "Lire la suite" ? Color.accentColor : (dark ? Color.white.opacity(0.9) : Color.black.opacity(0.85)))
                    .fixedSize()
                    .frame(width: source.frame.width, height: source.frame.height, alignment: .topLeading)
                    .offset(x: source.frame.minX, y: source.frame.minY)
            }
        }
        .frame(width: region.width, height: region.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
