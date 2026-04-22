import Foundation
import GlanslateCore
#if canImport(Translation)
import Translation
#endif

public protocol LanguageAvailabilityProviding: Sendable {
    func availability(from: Language?, to: Language) async -> AvailabilityStatus
}

public struct AppleLanguageAvailability: LanguageAvailabilityProviding {
    public init() {}

    #if canImport(Translation)
    private var appleAvailability: LanguageAvailability {
        LanguageAvailability()
    }
    #endif

    public func availability(from: Language?, to: Language) async -> AvailabilityStatus {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let targetLang = Locale.Language(identifier: to.bcp47)
            let sourceLang = Locale.Language(identifier: from?.bcp47 ?? "auto")
            let avail = await appleAvailability.status(from: sourceLang, to: targetLang)
            let caseName = String(describing: avail)
            if caseName == "installed" {
                return .supported
            } else if caseName == "notInstalled" {
                return .needsDownload
            } else {
                return .unsupported
            }
        }
        #endif
        return .unsupported
    }
}

public struct AppleTranslationEngine: TranslationEngine {
    public let identifier: TranslationProvider = .apple
    public let availability: any LanguageAvailabilityProviding

    public init(availability: any LanguageAvailabilityProviding) {
        self.availability = availability
    }
    
    public static func create() -> AppleTranslationEngine {
        AppleTranslationEngine(availability: AppleLanguageAvailability())
    }

    public func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus {
        await availability.availability(from: from, to: to)
    }

    public func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [Translation] {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let status = await canTranslate(from: from, to: to)
            guard status != .unsupported else {
                throw GlanslateError.unsupportedPair(.apple, from: from, to: to)
            }

            let targetLang = Locale.Language(identifier: to.bcp47)
            let sourceLang = Locale.Language(identifier: from?.bcp47 ?? "auto")

            let session = try await TranslationSession(
                installedSource: sourceLang,
                target: targetLang
            )

            var results: [Translation] = []
            results.reserveCapacity(blocks.count)

            for block in blocks {
                let response = try await session.translate(block.text)
                let translated = extractText(from: response)
                results.append(Translation(
                    block: block,
                    translatedText: translated,
                    targetLanguage: to,
                    provider: .apple
                ))
            }

            return results
        }
        #endif
        throw GlanslateError.translation(provider: .apple, reason: "Apple Translation unavailable on this OS.")
    }

    #if canImport(Translation)
    @available(macOS 26.0, *)
    private func extractText(from response: TranslationSession.Response) -> String {
        let mirror = Mirror(reflecting: response)
        for child in mirror.children {
            if let text = child.value as? String, !text.isEmpty {
                return text
            }
        }
        return ""
    }
    #endif
}
