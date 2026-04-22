import Foundation
#if canImport(Translation)
import Translation
#endif

@available(macOS 26.0, *)
@Observable
final class AppleLanguageManager: @unchecked Sendable {
    struct Item: Identifiable {
        let id = UUID()
        let language: Locale.Language
        let status: LanguageAvailability.Status
    }

    var items: [Item] = []
    var isLoading = false

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages

        var newItems: [Item] = []
        let source = Locale.Language(identifier: "en")
        for lang in supported {
            let status = await availability.status(from: source, to: lang)
            newItems.append(Item(language: lang, status: status))
        }

        items = newItems.sorted {
            displayName(for: $0.language) < displayName(for: $1.language)
        }
    }

    func download(language: Locale.Language) async {
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: "en"),
            target: language
        )
        do {
            try await session.prepareTranslation()
            await refresh()
        } catch {
            // Ignore per-item errors; refresh will show current state.
        }
    }

    func downloadAll() async {
        let toDownload = items.filter { $0.status == .supported }
        for item in toDownload {
            await download(language: item.language)
        }
    }

    private func displayName(for language: Locale.Language) -> String {
        Locale.current.localizedString(
            forLanguageCode: language.languageCode?.identifier ?? ""
        ) ?? language.languageCode?.identifier ?? "Unknown"
    }
}
