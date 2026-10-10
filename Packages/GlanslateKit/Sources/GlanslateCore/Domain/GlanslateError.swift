import Foundation

/// Every failure the user can see, phrased so they know what to do next.
public enum GlanslateError: Error, Hashable, Sendable {
    // Permissions and capture
    case screenRecordingNotAuthorized
    case selectionTooSmall
    case displayChanged
    case captureFailed(detail: String)

    // Recognition
    case noTextFound
    case recognitionFailed(detail: String)

    // Language
    case sourceLanguageUndetermined
    case alreadyInTargetLanguage(Language)

    // Providers
    case unsupportedLanguagePair(TranslationProvider, source: Language?, target: Language)
    case languageModelsNotInstalled(source: Language, target: Language)
    case missingCredential(TranslationProvider)
    case invalidCredential(TranslationProvider)
    case consentDeclined(TranslationProvider)
    case rateLimited(TranslationProvider, retryAfter: TimeInterval?)
    case quotaExceeded(TranslationProvider)
    case serviceNotEnabled(TranslationProvider)
    case modelUnavailable(TranslationProvider, model: String)
    case network(TranslationProvider, NetworkFailure)
    case providerFailure(TranslationProvider, detail: String)
    case incompleteResponse(TranslationProvider)
    case noProviderAvailable

    // Saved Translations
    case saveFailed

    case cancelled

    public enum NetworkFailure: String, Hashable, Sendable {
        case offline
        case timedOut
        case unreachable
    }

    /// What the user can do about the failure. The interface turns these into buttons.
    public enum Recovery: Hashable, Sendable {
        case openScreenRecordingSettings
        case openProviderSettings(TranslationProvider)
        case downloadLanguages(source: Language, target: Language)
        case chooseSourceLanguage
        case chooseTargetLanguage
        case chooseProvider
        case retry
        case selectAgain
    }
}

extension GlanslateError: LocalizedError {
    public var errorDescription: String? { title }

    public var title: String {
        switch self {
        case .screenRecordingNotAuthorized: return "Screen Recording is off"
        case .selectionTooSmall: return "Selection is too small"
        case .displayChanged: return "Displays changed"
        case .captureFailed: return "Couldn’t capture the selection"
        case .noTextFound: return "No text found"
        case .recognitionFailed: return "Couldn’t read the text"
        case .sourceLanguageUndetermined: return "Language not recognized"
        case .alreadyInTargetLanguage(let language): return "Already in \(language.localizedName())"
        case .unsupportedLanguagePair(let provider, _, _): return "\(provider.displayName) can’t translate this pair"
        case .languageModelsNotInstalled: return "Languages not downloaded"
        case .missingCredential(let provider): return "\(provider.displayName) isn’t set up"
        case .invalidCredential(let provider): return "\(provider.displayName) rejected the API key"
        case .consentDeclined(let provider): return "\(provider.displayName) wasn’t used"
        case .rateLimited(let provider, _): return "\(provider.displayName) is busy"
        case .quotaExceeded(let provider): return "\(provider.displayName) quota reached"
        case .serviceNotEnabled(let provider): return "\(provider.displayName) needs setup"
        case .modelUnavailable(_, let model): return "Model “\(model)” unavailable"
        case .network(let provider, let failure):
            switch failure {
            case .offline: return "You’re offline"
            case .timedOut: return "\(provider.displayName) didn’t respond"
            case .unreachable: return "Can’t reach \(provider.displayName)"
            }
        case .providerFailure(let provider, _): return "\(provider.displayName) couldn’t translate"
        case .incompleteResponse(let provider): return "\(provider.displayName) returned an incomplete result"
        case .noProviderAvailable: return "No translation provider available"
        case .saveFailed: return "Couldn’t save the translation"
        case .cancelled: return "Cancelled"
        }
    }

    public var message: String {
        switch self {
        case .screenRecordingNotAuthorized:
            return "Allow Glanslate in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .selectionTooSmall:
            return "Drag a larger area that contains the text you want to translate."
        case .displayChanged:
            return "The display arrangement changed. Select the text again."
        case .captureFailed:
            return "The selected area couldn’t be captured. Try selecting it again."
        case .noTextFound:
            return "Try a larger area, or zoom in so the text is easier to read."
        case .recognitionFailed:
            return "Text recognition failed for this area. Try selecting it again."
        case .sourceLanguageUndetermined:
            return "Choose the source language from the toolbar."
        case .alreadyInTargetLanguage:
            return "Choose a different target language to translate this text."
        case .unsupportedLanguagePair(_, let source, let target):
            let from = source?.localizedName() ?? "the detected language"
            return "Translating \(from) to \(target.localizedName()) isn’t supported. Choose another provider or language."
        case .languageModelsNotInstalled(let source, let target):
            return "Download \(source.localizedName()) and \(target.localizedName()) for on-device translation, or choose a cloud provider."
        case .missingCredential(let provider):
            return "Add your \(provider.credentialName) in Settings › Translation."
        case .invalidCredential(let provider):
            return "Check the \(provider.credentialName) in Settings › Translation."
        case .consentDeclined(let provider):
            return "You chose not to send text to \(provider.displayName). Choose another provider from the toolbar."
        case .rateLimited(_, let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "Too many requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            }
            return "Too many requests. Wait a moment and try again."
        case .quotaExceeded(let provider):
            return "Your \(provider.displayName) usage limit has been reached. Check your plan or choose another provider."
        case .serviceNotEnabled(let provider):
            if provider == .google {
                return "Enable the Cloud Translation API and billing for your Google Cloud project, then try again."
            }
            return "Finish setting up your \(provider.displayName) account, then try again."
        case .modelUnavailable(let provider, _):
            return "Your \(provider.credentialName) can’t use this model. Choose another model in Settings › Translation."
        case .network(_, let failure):
            switch failure {
            case .offline: return "Connect to the internet or use Apple Translation on this Mac."
            case .timedOut: return "The request took too long. Try again."
            case .unreachable: return "Check your connection and try again."
            }
        case .providerFailure:
            return "The service reported an error. Try again or choose another provider."
        case .incompleteResponse:
            return "Some text wasn’t translated. Try again or choose another provider."
        case .noProviderAvailable:
            return "Set up a provider in Settings › Translation."
        case .saveFailed:
            return "Saved Translations isn’t available right now. Try again, or restart Glanslate."
        case .cancelled:
            return ""
        }
    }

    public var recovery: Recovery? {
        switch self {
        case .screenRecordingNotAuthorized: return .openScreenRecordingSettings
        case .selectionTooSmall, .displayChanged, .captureFailed, .noTextFound, .recognitionFailed: return .selectAgain
        case .sourceLanguageUndetermined: return .chooseSourceLanguage
        case .alreadyInTargetLanguage: return .chooseTargetLanguage
        case .unsupportedLanguagePair, .consentDeclined, .quotaExceeded: return .chooseProvider
        case .languageModelsNotInstalled(let source, let target): return .downloadLanguages(source: source, target: target)
        case .missingCredential(let provider), .invalidCredential(let provider),
             .serviceNotEnabled(let provider), .modelUnavailable(let provider, _):
            return .openProviderSettings(provider)
        case .rateLimited, .network, .providerFailure, .incompleteResponse: return .retry
        case .noProviderAvailable: return .openProviderSettings(.deepL)
        case .saveFailed: return nil
        case .cancelled: return nil
        }
    }

    /// Whether the router may try the next provider after this failure.
    public var allowsFallback: Bool {
        switch self {
        case .cancelled, .alreadyInTargetLanguage:
            return false
        default:
            return true
        }
    }
}
