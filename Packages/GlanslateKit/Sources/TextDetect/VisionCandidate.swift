import CoreGraphics
import Foundation
import NaturalLanguage
import Vision
import GlanslateCore
import GlanslateGeometry
import GlanslateCapture

public struct VisionCandidate: Sendable {
    public init() {}

    public func detect(_ source: SourceVisualContext) async throws -> [TextBlock] {
        let observations: [VNRecognizedTextObservation]
        do {
            observations = try recognize(in: source, level: .accurate)
        } catch {
            // Accurate recognition can fail on platform-model errors; retry once at .fast.
            do {
                observations = try recognize(in: source, level: .fast)
            } catch {
                throw GlanslateError.detection(reason: "Vision perform failed: \(error.localizedDescription)")
            }
        }
        guard !observations.isEmpty else { return [] }

        let converter = GeometryConverter(snapshot: source.topology)
        let lines: [DetectedLine] = observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let rect = converter.displayLocal(
                visionNormalized: obs.boundingBox,
                capturedFrom: source.region.displayID,
                captureRegion: source.region
            )
            return DetectedLine(text: top.string, confidence: Double(top.confidence), rect: rect)
        }

        let grouped = groupIntoBlocks(lines: lines)
        return grouped.map { block in
            let langs = languages(from: block.text)
            let detected = langs.dominant(minConfidence: 0.6)
            return TextBlock(
                text: block.text,
                region: block.rect,
                detectedLanguage: detected,
                confidence: block.avgConfidence,
                source: .vision
            )
        }
    }

    private func recognize(
        in source: SourceVisualContext,
        level: VNRequestTextRecognitionLevel
    ) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(cgImage: source.image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0 as VNRecognizedTextObservation }
    }

    struct DetectedLine {
        let text: String
        let confidence: Double
        let rect: DisplayLocalRect
    }

    struct DetectedBlock {
        let text: String
        let rect: DisplayLocalRect
        let avgConfidence: Double
    }

    func groupIntoBlocks(lines: [DetectedLine]) -> [DetectedBlock] {
        guard !lines.isEmpty else { return [] }
        guard let displayID = lines.first?.rect.displayID else { return [] }
        let sorted = lines.sorted { $0.rect.rect.minY < $1.rect.rect.minY }

        // Median line height.
        let heights = sorted.map { $0.rect.rect.height }.sorted()
        let median = heights[heights.count / 2]
        let blockGap = median * 1.4

        var groups: [[DetectedLine]] = []
        var current: [DetectedLine] = []
        var lastMaxY: CGFloat = -.infinity

        for line in sorted {
            let y = line.rect.rect.minY
            if current.isEmpty {
                current = [line]
                lastMaxY = line.rect.rect.maxY
                continue
            }
            let gap = y - lastMaxY
            if gap < blockGap, hasHorizontalOverlap(current, line, threshold: 0.2) {
                current.append(line)
                lastMaxY = max(lastMaxY, line.rect.rect.maxY)
            } else {
                groups.append(current)
                current = [line]
                lastMaxY = line.rect.rect.maxY
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.map { lines in
            let unionRect = lines.reduce(CGRect.null) { $0.union($1.rect.rect) }
            let text = lines.map { $0.text }.joined(separator: "\n")
            let avg = lines.reduce(0.0) { $0 + $1.confidence } / Double(lines.count)
            return DetectedBlock(
                text: text,
                rect: DisplayLocalRect(displayID: displayID, rect: unionRect),
                avgConfidence: avg
            )
        }
    }

    private func hasHorizontalOverlap(_ group: [DetectedLine], _ line: DetectedLine, threshold: CGFloat) -> Bool {
        guard let u = group.map({ $0.rect.rect }).reduce(CGRect?.none, { acc, r in acc.map { $0.union(r) } ?? r }) else { return true }
        let inter = u.intersection(line.rect.rect)
        if inter.isNull { return false }
        let denom = min(u.width, line.rect.rect.width)
        guard denom > 0 else { return false }
        return inter.width / denom >= threshold
    }

    private func languages(from text: String) -> [(language: Language, prob: Double)] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        return hypotheses.compactMap { (code, prob) -> (Language, Double)? in
            guard let lang = Language.from(nlCode: code) else { return nil }
            return (lang, prob)
        }
    }
}

extension Array where Element == (language: Language, prob: Double) {
    func dominant(minConfidence: Double) -> Language? {
        let sorted = self.sorted { $0.prob > $1.prob }
        guard let top = sorted.first, top.prob >= minConfidence else { return nil }
        // Reject mixed (multiple above 0.2).
        let competing = sorted.dropFirst().filter { $0.prob >= 0.2 }
        if !competing.isEmpty { return nil }
        return top.language
    }
}

