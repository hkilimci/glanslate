import Foundation

public enum Language: String, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case en, tr, es, fr, de, it, pt, ru, ja, ko
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ar, hi, pl, nl, sv, cs, uk, he

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .en: return "English"
        case .tr: return "Türkçe"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ar: return "العربية"
        case .hi: return "हिन्दी"
        case .pl: return "Polski"
        case .nl: return "Nederlands"
        case .sv: return "Svenska"
        case .cs: return "Čeština"
        case .uk: return "Українська"
        case .he: return "עברית"
        }
    }

    public var bcp47: String { rawValue }

    public var isRightToLeft: Bool {
        switch self {
        case .ar, .he: return true
        default: return false
        }
    }
}
