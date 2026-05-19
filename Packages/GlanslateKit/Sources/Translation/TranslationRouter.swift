import Foundation
import NaturalLanguage
import GlanslateCore
import GlanslatePlatform
import GlanslateSettings

public actor TranslationRouter: TranslationRouting {
    public let engines: [TranslationProvider: any TranslationEngine]
    public let settings: SettingsStore
    public let keychain: KeychainStore

    public init(
        engines: [TranslationProvider: any TranslationEngine],
        settings: SettingsStore,
        keychain: KeychainStore
    ) {
        self.engines = engines
        self.settings = settings
        self.keychain = keychain
    }

    public func translate(
        _ blocks: [TextBlock],
        to target: Language,
        invocationOverride: InvocationRoutingOverride? = nil
    ) async throws -> [Translation] {
        guard !blocks.isEmpty else { return [] }

        let preferred = await resolvePreferred(invocationOverride?.provider)
        let fallback = await MainActor.run { settings.fallbackProvider }

        let sourceLang = invocationOverride?.sourceLanguage
            ?? dominantLanguage(from: blocks)
            ?? combinedTextLanguage(from: blocks)

        let order: [TranslationProvider]
        if invocationOverride?.provider != nil {
            order = [preferred]
        } else {
            order = (preferred == fallback) ? [preferred] : [preferred, fallback]
        }

        var lastError: GlanslateError?
        for provider in order {
            do {
                let result = try await attempt(provider: provider, blocks: blocks, from: sourceLang, to: target)
                return result
            } catch let err as GlanslateError {
                lastError = err
                GlanslateLog.translate.info("Provider \(String(describing: provider)) failed: \(String(describing: err))")
                continue
            } catch is CancellationError {
                throw GlanslateError.cancelled
            } catch {
                lastError = .translation(provider: provider, reason: error.localizedDescription)
                continue
            }
        }
        throw lastError ?? .unsupportedPair(preferred, from: sourceLang, to: target)
    }

    private func resolvePreferred(_ override: TranslationProvider?) async -> TranslationProvider {
        if let o = override { return o }
        return await MainActor.run { settings.preferredProvider }
    }

    private func attempt(
        provider: TranslationProvider,
        blocks: [TextBlock],
        from: Language?,
        to: Language
    ) async throws -> [Translation] {
        guard let engine = engines[provider] else {
            throw GlanslateError.unsupportedPair(provider, from: from, to: to)
        }
        if provider.sendsTextOffDevice {
            let accepted = await MainActor.run { settings.hasAcceptedDisclosure(for: provider) }
            guard accepted else { throw GlanslateError.disclosureNotAccepted(provider) }
        }
        let avail = await engine.canTranslate(from: from, to: to)
        switch avail {
        case .supported, .needsDownload:
            return try await engine.translate(blocks, from: from, to: to)
        case .unsupported:
            throw GlanslateError.unsupportedPair(provider, from: from, to: to)
        }
    }

    /// Fallback source detection: combine every block's text and run NLLanguageRecognizer
    /// once. Used when per-block `detectedLanguage` is absent or inconclusive — notably it
    /// gives Apple Translation a concrete source, avoiding its blocking "Choose Language" dialog.
    private func combinedTextLanguage(from blocks: [TextBlock]) -> Language? {
        let combined = blocks
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(combined)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return Language.from(nlCode: dominant)
    }

    private func dominantLanguage(from blocks: [TextBlock]) -> Language? {
        var counts: [Language: Double] = [:]
        for b in blocks {
            guard let lang = b.detectedLanguage else { continue }
            counts[lang, default: 0] += max(0.5, b.confidence)
        }
        let sum = counts.values.reduce(0, +)
        guard let top = counts.max(by: { $0.value < $1.value }), sum > 0 else { return nil }
        return (top.value / sum) >= 0.7 ? top.key : nil
    }
}
