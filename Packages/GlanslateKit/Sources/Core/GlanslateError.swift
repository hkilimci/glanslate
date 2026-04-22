import Foundation

public enum GlanslateError: Error, Sendable, Equatable, Hashable {
    case permissionDenied(PermissionKind)
    case capture(reason: String)
    case detection(reason: String)
    case noTextFound
    case translation(provider: TranslationProvider, reason: String)
    case unsupportedPair(TranslationProvider, from: Language?, to: Language)
    case missingAPIKey(TranslationProvider)
    case crossScreenSelectionRejected
    case displayTopologyChanged
    case disclosureNotAccepted(TranslationProvider)
    case cancelled

    public var localizedDescription: String {
        switch self {
        case .permissionDenied(let kind):
            return "\(kind.displayName) permission is required to continue."
        case .capture(let reason):
            return "Screen capture failed: \(reason)"
        case .detection(let reason):
            return "Text detection failed: \(reason)"
        case .noTextFound:
            return "No text found in the selected region."
        case .translation(let provider, let reason):
            return "\(provider.displayName) translation failed: \(reason)"
        case .unsupportedPair(let provider, let from, let to):
            let f = from?.displayName ?? "auto"
            return "\(provider.displayName) does not support \(f) → \(to.displayName)."
        case .missingAPIKey(let provider):
            return "Missing API key for \(provider.displayName). Add one in Settings."
        case .crossScreenSelectionRejected:
            return "Selection must stay on a single display."
        case .displayTopologyChanged:
            return "Display arrangement changed — please retry."
        case .disclosureNotAccepted(let provider):
            return "Cloud provider \(provider.displayName) requires explicit disclosure acceptance."
        case .cancelled:
            return "Translation cancelled."
        }
    }
}
