import GlanslateCore
import GlanslatePersistence
import SwiftData
import SwiftUI

/// Browse, search, copy, and delete pinned translations.
struct SavedTranslationsView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        if let store = app.store {
            SavedTranslationsBrowser()
                .modelContainer(store.container)
        } else {
            ContentUnavailableView(
                "Saved Translations Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Glanslate couldn’t open its storage. Restart Glanslate to try again.")
            )
        }
    }
}

private struct SavedTranslationsBrowser: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedTranslation.createdAt, order: .reverse) private var items: [SavedTranslation]
    @State private var selection: UUID?
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [SavedTranslation] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        return items.filter {
            $0.translatedText.localizedStandardContains(term) || $0.originalText.localizedStandardContains(term)
        }
    }

    private var selectedItem: SavedTranslation? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { item in
                SavedTranslationRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Copy Translation") { Pasteboard.copy(item.translatedText) }
                        Button("Copy Original") { Pasteboard.copy(item.originalText) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(item) }
                    }
            }
            .overlay {
                if !items.isEmpty, filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search Translations")
            .onDeleteCommand {
                if let selectedItem { delete(selectedItem) }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            if let item = selectedItem {
                SavedTranslationDetail(item: item, onDelete: { delete(item) })
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Translations", systemImage: "pin")
                } description: {
                    Text("Pin a translation from the overlay toolbar to keep it here, along with the area it came from.")
                }
            } else {
                ContentUnavailableView("Select a Translation", systemImage: "text.bubble", description: Text("Choose a saved translation to see it in full."))
            }
        }
        .navigationTitle("Saved Translations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Clear All Saved Translations…", role: .destructive) { confirmClear = true }
                        .disabled(items.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .confirmationDialog("Delete all saved translations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive, action: deleteAll)
        } message: {
            Text("This removes \(items.count) saved translations from this Mac. This can’t be undone.")
        }
        .onAppear {
            if selection == nil { selection = items.first?.id }
        }
    }

    private func delete(_ item: SavedTranslation) {
        let index = filtered.firstIndex { $0.id == item.id }
        context.delete(item)
        try? context.save()
        if selection == item.id {
            let remaining = filtered.filter { $0.id != item.id }
            if let index, !remaining.isEmpty {
                selection = remaining[min(index, remaining.count - 1)].id
            } else {
                selection = nil
            }
        }
    }

    private func deleteAll() {
        try? context.delete(model: SavedTranslation.self)
        try? context.save()
        selection = nil
    }
}

private struct SavedTranslationRow: View {
    let item: SavedTranslation

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(data: item.thumbnail)
                .frame(width: 52, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.headline)
                    .lineLimit(2)
                Text("\(item.languagePairDescription) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct SavedTranslationDetail: View {
    let item: SavedTranslation
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if item.thumbnail != nil {
                    Thumbnail(data: item.thumbnail)
                        .frame(maxWidth: 560, maxHeight: 240)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TextSection(title: "Translation", text: item.translatedText, prominence: .primary) {
                    Pasteboard.copy(item.translatedText)
                }
                TextSection(title: "Original", text: item.originalText, prominence: .secondary) {
                    Pasteboard.copy(item.originalText)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Languages").foregroundStyle(.secondary)
                        Text(item.languagePairDescription)
                    }
                    GridRow {
                        Text("Provider").foregroundStyle(.secondary)
                        Text(item.provider.displayName)
                    }
                    GridRow {
                        Text("Saved").foregroundStyle(.secondary)
                        Text(item.createdAt.formatted(date: .long, time: .shortened))
                    }
                }
                .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy Translation", systemImage: "doc.on.doc") { Pasteboard.copy(item.translatedText) }
                    .help("Copy Translation")
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .help("Delete This Translation (⌫)")
            }
        }
    }
}

private struct TextSection: View {
    let title: String
    let text: String
    let prominence: HierarchicalShapeStyle
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy \(title)")
            }
            Text(text)
                .font(.body)
                .foregroundStyle(prominence)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Thumbnail: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "text.viewfinder")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
