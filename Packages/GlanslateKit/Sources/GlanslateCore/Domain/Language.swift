import Foundation

/// A written language identified by a BCP 47 code such as `en`, `zh-Hans`, or `pt`.
///
/// Codes are normalized on creation so that every provider-specific spelling
/// (`EN-US`, `zh_TW`, `iw`, `no`) maps onto one canonical value.
public struct Language: Hashable, Sendable, Identifiable {
    public let code: String

    public init(_ code: String) {
        self.code = Language.normalize(code)
    }

    public var id: String { code }

    /// The language subtag without script or region (`zh` for `zh-Hant`).
    public var baseCode: String {
        String(code.split(separator: "-").first ?? Substring(code))
    }

    public func localizedName(in locale: Locale = .current) -> String {
        if let name = locale.localizedString(forIdentifier: code), !name.isEmpty {
            return name.prefix(1).uppercased(with: locale) + name.dropFirst()
        }
        return code
    }

    /// The name of the language in English, used in provider prompts.
    public var englishName: String {
        localizedName(in: Locale(identifier: "en"))
    }

    public var isRightToLeft: Bool {
        ["ar", "he", "fa", "ur", "yi", "ps"].contains(baseCode)
    }

    /// Languages that are written without spaces between words.
    public var usesInterwordSpacing: Bool {
        !["zh", "ja", "th", "lo", "km", "my"].contains(baseCode)
    }

    public var isInCatalog: Bool { Language.catalog.contains(self) }

    // MARK: Normalization

    static func normalize(_ raw: String) -> String {
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { String($0) }
        guard let first = parts.first?.lowercased(), !first.isEmpty else { return "und" }
        let rest = parts.dropFirst().map { $0.lowercased() }

        switch first {
        case "zh":
            let traditional = rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo")
            return traditional ? "zh-Hant" : "zh-Hans"
        case "iw": return "he"
        case "in": return "id"
        case "no", "nn": return "nb"
        case "ji": return "yi"
        default: return first
        }
    }
}

extension Language: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

public extension Language {
    static let english = Language("en")
    static let arabic = Language("ar")
    static let bulgarian = Language("bg")
    static let chineseSimplified = Language("zh-Hans")
    static let chineseTraditional = Language("zh-Hant")
    static let czech = Language("cs")
    static let danish = Language("da")
    static let dutch = Language("nl")
    static let finnish = Language("fi")
    static let french = Language("fr")
    static let german = Language("de")
    static let greek = Language("el")
    static let hebrew = Language("he")
    static let hindi = Language("hi")
    static let hungarian = Language("hu")
    static let indonesian = Language("id")
    static let italian = Language("it")
    static let japanese = Language("ja")
    static let korean = Language("ko")
    static let malay = Language("ms")
    static let norwegian = Language("nb")
    static let polish = Language("pl")
    static let portuguese = Language("pt")
    static let romanian = Language("ro")
    static let russian = Language("ru")
    static let slovak = Language("sk")
    static let spanish = Language("es")
    static let swedish = Language("sv")
    static let thai = Language("th")
    static let turkish = Language("tr")
    static let ukrainian = Language("uk")
    static let vietnamese = Language("vi")

    /// Languages offered in pickers. Every provider supports most of them;
    /// unsupported pairs are reported by the provider at translation time.
    static let catalog: [Language] = [
        .arabic, .bulgarian, .chineseSimplified, .chineseTraditional, .czech, .danish,
        .dutch, .english, .finnish, .french, .german, .greek, .hebrew, .hindi,
        .hungarian, .indonesian, .italian, .japanese, .korean, .malay, .norwegian,
        .polish, .portuguese, .romanian, .russian, .slovak, .spanish, .swedish,
        .thai, .turkish, .ukrainian, .vietnamese,
    ]

    /// The catalog sorted by the user's localized names.
    static func sortedCatalog(locale: Locale = .current) -> [Language] {
        catalog.sorted {
            $0.localizedName(in: locale).localizedStandardCompare($1.localizedName(in: locale)) == .orderedAscending
        }
    }

    /// A sensible default target: the user's preferred language when it is in
    /// the catalog, English otherwise.
    static func preferredTarget(preferredLanguages: [String] = Locale.preferredLanguages) -> Language {
        for identifier in preferredLanguages {
            let language = Language(identifier)
            if language.isInCatalog { return language }
        }
        return .english
    }
}

/// The source language of a translation: detected automatically or chosen by the user.
public enum SourceLanguage: Hashable, Sendable {
    case automatic
    case specific(Language)

    public var language: Language? {
        if case .specific(let language) = self { return language }
        return nil
    }

    public func displayName(in locale: Locale = .current) -> String {
        switch self {
        case .automatic: return "Automatic"
        case .specific(let language): return language.localizedName(in: locale)
        }
    }
}

extension SourceLanguage: Codable {
    private static let automaticToken = "auto"

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == Self.automaticToken ? .automatic : .specific(Language(value))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic: try container.encode(Self.automaticToken)
        case .specific(let language): try container.encode(language.code)
        }
    }
}

/// A language identified from recognized text, with the detector's confidence (0...1).
public struct DetectedLanguage: Hashable, Sendable {
    public let language: Language
    public let confidence: Double

    public init(language: Language, confidence: Double) {
        self.language = language
        self.confidence = confidence
    }
}

/// Identifies the language of a piece of text. Implemented with NaturalLanguage on macOS.
public protocol LanguageDetecting: Sendable {
    func detectLanguage(of text: String) -> DetectedLanguage?
}
