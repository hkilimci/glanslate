import CoreGraphics
import Foundation
import GlanslateCore
import Vision

/// Reads lines of text from a captured image with Vision, entirely on this Mac.
public struct VisionTextRecognizer: Sendable {
    public init() {}

    /// Recognized lines in display-local points.
    /// - Parameter languages: Expected languages. Empty enables automatic detection.
    public func recognizeLines(in image: CGImage, geometry: CaptureGeometry, languages: [Language] = []) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0.code) }
        }

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image, orientation: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GlanslateError.recognitionFailed(detail: String(describing: type(of: error)))
        }
        try Task.checkCancellation()

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, candidate.confidence >= 0.2 else { return nil }
            return RecognizedLine(
                text: text,
                frame: geometry.localRect(fromNormalized: observation.boundingBox.cgRect),
                confidence: Double(candidate.confidence),
                source: .ocr
            )
        }
    }
}
