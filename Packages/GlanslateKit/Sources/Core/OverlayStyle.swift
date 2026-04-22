import Foundation

public enum OverlayStyle: String, Sendable, Codable, Hashable, CaseIterable {
    case cleanPatch
    case blurPatch
    case subtitle

    public var displayName: String {
        switch self {
        case .cleanPatch: return "Clean Patch"
        case .blurPatch: return "Blur Patch"
        case .subtitle: return "Subtitle"
        }
    }
}

public enum PermissionKind: String, Sendable, Hashable, Codable {
    case screenRecording
    case accessibility
    case inputMonitoring

    public var displayName: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }
}
