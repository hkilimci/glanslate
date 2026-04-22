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
            if from == nil {
                return .supported
            }
            let targetLang = Locale.Language(identifier: to.bcp47)
            let sourceLang = Locale.Language(identifier: from!.bcp47)
            let status = await appleAvailability.status(from: sourceLang, to: targetLang)
            return Self.map(status)
        }
        #endif
        return .unsupported
    }

    #if canImport(Translation)
    @available(macOS 26.0, *)
    static func map(_ status: LanguageAvailability.Status) -> AvailabilityStatus {
        switch status {
        case .installed:
            return .supported
        case .supported:
            return .needsDownload
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }
    #endif
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

            do {
                return try await AppleTranslationSessionBridge.shared.translate(
                    blocks,
                    from: from,
                    to: to,
                    needsDownload: status == .needsDownload
                )
            } catch let error as GlanslateError {
                throw error
            } catch {
                throw mapTranslationError(error, from: from, to: to)
            }
        }
        #endif
        throw GlanslateError.translation(provider: .apple, reason: "Apple Translation unavailable on this OS.")
    }

    #if canImport(Translation)
    @available(macOS 26.0, *)
    private func mapTranslationError(
        _ error: any Error,
        from: Language?,
        to: Language
    ) -> GlanslateError {
        if TranslationError.unsupportedLanguagePairing ~= error ||
            TranslationError.unsupportedSourceLanguage ~= error ||
            TranslationError.unsupportedTargetLanguage ~= error {
            return .unsupportedPair(.apple, from: from, to: to)
        }

        if TranslationError.notInstalled ~= error {
            return .translation(
                provider: .apple,
                reason: "Language models are not installed. Allow the download prompt and retry."
            )
        }

        return .translation(provider: .apple, reason: error.localizedDescription)
    }
    #endif
}
