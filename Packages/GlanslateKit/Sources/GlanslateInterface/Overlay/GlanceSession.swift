import AppKit
import GlanslateCapture
import GlanslateCore
import Observation

/// One capture on screen: its recognized text, current translation, and the
/// choices the user makes in the floating toolbar.
@MainActor
@Observable
final class GlanceSession: Identifiable {
    enum Phase: Equatable {
        case capturing
        case recognizing
        case translating
        case ready
        case failed
    }

    let id = UUID()
    let target: SelectionTarget
    let display: DisplayDescriptor
    let layout: DisplayLayout

    var phase: Phase = .capturing
    var capture: CapturedImage?
    var recognized: RecognizedText?
    /// The newest translation. Kept on screen while a retranslation is in progress.
    var result: GlanceResult?
    /// The latest failure; shown alongside an older result when retranslation fails.
    var error: GlanslateError?
    var isRetranslating = false

    var sourceLanguage: SourceLanguage
    var targetLanguage: Language
    var providerChoice: ProviderChoice
    var style: OverlayStyle

    var isRevealToggled = false
    var isRevealHeld = false
    var isPinned = false
    var didCopy = false

    var blockLayouts: [OverlayBlockLayout] = []
    var backdrops: [UUID: BlockBackdrop] = [:]

    init(
        target: SelectionTarget,
        display: DisplayDescriptor,
        layout: DisplayLayout,
        sourceLanguage: SourceLanguage,
        targetLanguage: Language,
        style: OverlayStyle
    ) {
        self.target = target
        self.display = display
        self.layout = layout
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.providerChoice = .automatic
        self.style = style
    }

    var region: ScreenRegion { target.region }

    var isRevealingOriginal: Bool { isRevealToggled || isRevealHeld }

    var isWorking: Bool {
        switch phase {
        case .capturing, .recognizing, .translating: return true
        case .ready, .failed: return isRetranslating
        }
    }

    /// The region in AppKit global coordinates.
    var appKitFrame: CGRect {
        ScreenCoordinateSpace(layout: layout).appKitRect(fromLocal: region.rect, on: display)
    }

    var detectedLanguage: Language? { recognized?.detectedLanguage?.language }

    var statusText: String? {
        switch phase {
        case .capturing, .recognizing: return "Reading text…"
        case .translating: return "Translating…"
        case .ready, .failed: return isRetranslating ? "Translating…" : nil
        }
    }

    var providerLabel: String {
        switch providerChoice {
        case .specific(let provider): return provider.displayName
        case .automatic: return result?.outcome.provider.displayName ?? "Automatic"
        }
    }

    var sourceLabel: String {
        switch sourceLanguage {
        case .specific(let language): return language.localizedName()
        case .automatic:
            if let language = result?.outcome.source ?? detectedLanguage { return language.localizedName() }
            return "Detect"
        }
    }
}
