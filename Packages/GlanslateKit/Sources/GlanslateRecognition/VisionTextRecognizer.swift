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
        // Vision reads a subset of languages; hint only the ones it supports.
        let hints = Self.supportedHints(for: languages, supported: request.supportedRecognitionLanguages)
        if hints.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = hints
        }

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image, orientation: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch where !hints.isEmpty {
            // Retry without hints rather than failing the capture.
            var automatic = RecognizeTextRequest()
            automatic.recognitionLevel = .accurate
            automatic.usesLanguageCorrection = true
            automatic.automaticallyDetectsLanguage = true
            do {
                observations = try await automatic.perform(on: image, orientation: nil)
            } catch {
                throw GlanslateError.recognitionFailed(detail: String(describing: type(of: error)))
            }
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

    /// The requested languages that Vision can recognize, matched by language and script.
    static func supportedHints(for languages: [Language], supported: [Locale.Language]) -> [Locale.Language] {
        languages.compactMap { language in
            let wanted = Locale.Language(identifier: language.code)
            return supported.first { candidate in
                candidate.languageCode == wanted.languageCode
                    && (wanted.script == nil || candidate.script == nil || candidate.script == wanted.script)
            }
        }
    }
}
