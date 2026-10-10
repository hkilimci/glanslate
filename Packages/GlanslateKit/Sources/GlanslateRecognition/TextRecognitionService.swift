import CoreGraphics
import Foundation
import GlanslateCore
import NaturalLanguage

/// Identifies languages with the NaturalLanguage framework.
public struct NaturalLanguageDetector: LanguageDetecting {
    public init() {}

    public func detectLanguage(of text: String) -> DetectedLanguage? {
        let sample = String(text.prefix(4_000))
        guard sample.contains(where: \.isLetter) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              language != .undetermined else { return nil }
        return DetectedLanguage(language: Language(language.rawValue), confidence: probability)
    }
}

/// Recognizes the text in a capture: Vision OCR, optionally refined with
/// Accessibility text, grouped into paragraphs in reading order.
public struct TextRecognitionService: Sendable {
    private let vision = VisionTextRecognizer()
    private let accessibility = AccessibilityTextReader()
    private let assembler = TextAssembler(detector: NaturalLanguageDetector())

    public init() {}

    /// - Parameters:
    ///   - quartzRect: The region in Quartz global space, used to query Accessibility. `nil` skips it.
    ///   - sourceHint: A user-chosen source language to steer OCR.
    public func recognize(
        image: CGImage,
        geometry: CaptureGeometry,
        region: ScreenRegion,
        quartzRect: CGRect?,
        sourceHint: Language?
    ) async throws -> RecognizedText {
        // `CGImage` is immutable; hand it to the OCR task explicitly.
        nonisolated(unsafe) let image = image
        async let ocrLines = vision.recognizeLines(in: image, geometry: geometry, languages: sourceHint.map { [$0] } ?? [])
        async let axFragments = accessibilityFragments(in: quartzRect)

        let lines = try await ocrLines
        let fragments = await axFragments
        try Task.checkCancellation()

        // Accessibility reports Quartz global frames; OCR lines are display-local.
        let origin = quartzRect.map { CGPoint(x: $0.minX - region.rect.minX, y: $0.minY - region.rect.minY) } ?? .zero
        let local = fragments.map {
            AccessibleTextFragment(text: $0.text, frame: $0.quartzFrame.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        return assembler.assemble(region: region, ocrLines: lines, accessibilityFragments: local)
    }

    private func accessibilityFragments(in quartzRect: CGRect?) async -> [(text: String, quartzFrame: CGRect)] {
        guard let quartzRect else { return [] }
        return await accessibility.fragments(in: quartzRect)
    }
}
