import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI

struct UnifiedSearchView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("search.history") private var historyData = Data()
    @State private var query = ""
    @State private var selectedKind: LampModuleKind?
    @State private var selectedModuleID: String?
    @State private var selectedResultID: String?
    @State private var devotionalDate = ""
    @State private var devotionalTag = ""
    @State private var devotionalCategory = ""
    @State private var bookScope: BookSearchScope = .all
    @State private var strongsKey = ""
    @State private var highlightColor = ""

    let showImporter: () -> Void
    let openReference: (Int) -> Void
    let openBook: (LampModuleSearchResult) -> Void
    let openKind: (LampModuleKind) -> Void

    private var history: [LampSearchHistoryEntry] {
        LampSearchHistoryStore.decode(historyData)
    }

    private var hasActiveStrongsFilter: Bool {
        (selectedKind == .translation || selectedKind == .dictionary)
            && !strongsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasActiveHighlightColor: Bool {
        selectedKind == .highlights
            && !highlightColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedResult: LampModuleSearchResult? {
        model.moduleSearchResults.first { $0.id == selectedResultID }
            ?? model.moduleSearchResults.first
    }

    private var availableModules: [(id: String, name: String)] {
        var values: [(id: String, name: String)] = model.modules
            .filter { selectedKind == nil || $0.kind == selectedKind }
            .map { (id: $0.id, name: $0.name) }
        if selectedKind == nil || selectedKind == .notes {
            values.append(("personal-notes", "My Notes"))
        }
        if selectedKind == nil || selectedKind == .highlights {
            values += model.translations.map {
                ("personal-highlights:\($0.id)", "My \($0.abbreviation ?? $0.name) Highlights")
            }
        }
        if selectedKind == nil || selectedKind == .devotional {
            values.append(("personal-devotionals", "My Writing"))
        }
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !hasActiveStrongsFilter && !hasActiveHighlightColor {
                searchLanding
            } else if model.isModuleSearching && model.moduleSearchResults.isEmpty {
                ProgressView("Searching Library…")
            } else if model.moduleSearchResults.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty
                    ? (hasActiveStrongsFilter ? strongsKey : highlightColor) : query)
            } else {
                HSplitView {
                    resultsList
                    if let selectedResult {
                        resultDetail(selectedResult)
                    } else {
                        ContentUnavailableView("Choose a Result", systemImage: "text.magnifyingglass")
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Bibles and modules")
        .onSubmit(of: .search) { saveSearch() }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: selectedKind) { _, _ in
            selectedModuleID = nil
            runSearch()
        }
        .onChange(of: selectedModuleID) { _, _ in runSearch() }
        .onChange(of: devotionalDate) { _, _ in runSearch() }
        .onChange(of: devotionalTag) { _, _ in runSearch() }
        .onChange(of: devotionalCategory) { _, _ in runSearch() }
        .onChange(of: bookScope) { _, _ in runSearch() }
        .onChange(of: strongsKey) { _, _ in runSearch() }
        .onChange(of: highlightColor) { _, _ in runSearch() }
        .onChange(of: model.moduleSearchResults) { _, results in
            if !results.contains(where: { $0.id == selectedResultID }) {
                selectedResultID = results.first?.id
            }
        }
        .toolbar { searchToolbar }
        .overlay(alignment: .bottomTrailing) {
            if model.isModuleSearching && !model.moduleSearchResults.isEmpty {
                ProgressView("Updating Results…")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .padding()
            }
        }
    }

    private var searchLanding: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView {
                    Label("Search Your Library", systemImage: "text.magnifyingglass")
                } description: {
                    Text("Search scripture, dictionaries, commentaries, books, notes, devotionals, plans, quizzes, and highlighted verses.")
                } actions: {
                    if model.modules.isEmpty {
                        Button("Install Module…", action: showImporter)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    Section("Recent Searches") {
                        ForEach(history) { entry in
                            Button {
                                query = entry.query
                                selectedKind = entry.kind
                                selectedModuleID = entry.moduleID
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.query)
                                        Text(historyDescription(entry))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button("Clear Search History", role: .destructive) {
                            historyData = Data()
                        }
                    }
                    .padding()
                    .background(.bar)
                }
            }
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            if selectedKind == .devotional {
                HStack(spacing: 8) {
                    TextField("Date (YYYY-MM-DD or MM-DD)", text: $devotionalDate)
                        .frame(width: 170)
                    TextField("Tag", text: $devotionalTag)
                        .frame(width: 110)
                    TextField("Category", text: $devotionalCategory)
                        .frame(width: 110)
                }
                .textFieldStyle(.roundedBorder)
                .padding(10)
            }
            List(selection: $selectedResultID) {
                ForEach(model.moduleSearchResults) { result in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: result.kind))
                                .foregroundStyle(.tint)
                            if let highlightColor = color(for: result.highlightColor) {
                                Circle().fill(highlightColor).frame(width: 10, height: 10)
                            }
                            Text(result.title)
                                .font(.headline)
                                .lineLimit(2)
                            Spacer()
                            Text(result.kind.displayName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Text(result.moduleName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        snippetText(result.snippet)
                            .lineLimit(3)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 6)
                    .tag(Optional(result.id))
                    .contextMenu {
                        if let reference = result.startReference {
                            Button("Open \(result.referenceDescription ?? "Reference")") {
                                openReference(reference)
                            }
                        }
                        Button("Copy Result") { copy(result) }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 340, idealWidth: 440)
    }

    private func resultDetail(_ result: LampModuleSearchResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(result.kind.displayName, systemImage: icon(for: result.kind))
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Text(result.title)
                        .font(.largeTitle.bold())
                    if let subtitle = result.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text(result.moduleName)
                        .foregroundStyle(.secondary)
                }

                if let description = result.referenceDescription {
                    Label(description, systemImage: "book")
                        .foregroundStyle(.secondary)
                }

                Divider()

                snippetText(result.snippet)
                    .font(result.kind == .translation ? .system(.body, design: .serif) : .body)
                    .lineSpacing(5)
                    .textSelection(.enabled)

                HStack {
                    if let reference = result.startReference {
                        Button("Open in Reader", systemImage: "book") {
                            saveSearch()
                            openReference(reference)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if result.kind == .book {
                        Button("Open Book") {
                            saveSearch()
                            openBook(result)
                        }
                        .buttonStyle(.bordered)
                    } else if [.devotional, .plan, .quiz].contains(result.kind) {
                        Button("Open \(result.kind.displayName)") {
                            saveSearch()
                            openKind(result.kind)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Copy", systemImage: "doc.on.doc") { copy(result) }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ToolbarContentBuilder
    private var searchToolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Content", selection: $selectedKind) {
                Text("All Content").tag(LampModuleKind?.none)
                ForEach(LampModuleKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .frame(minWidth: 150)
        }

        ToolbarItem {
            Picker("Module", selection: $selectedModuleID) {
                Text("All Modules").tag(String?.none)
                ForEach(availableModules, id: \.id) { module in
                    Text(module.name).tag(Optional(module.id))
                }
            }
            .frame(minWidth: 170)
        }

        if selectedKind == .translation || selectedKind == .highlights {
            ToolbarItem {
                Picker("Books", selection: $bookScope) {
                    ForEach(BookSearchScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .frame(minWidth: 140)
            }
        }

        if selectedKind == .translation || selectedKind == .dictionary {
            ToolbarItem {
                TextField("Strong's key", text: $strongsKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
        }

        if selectedKind == .highlights {
            ToolbarItem {
                TextField("Highlight color", text: $highlightColor)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
        }
    }

    private func runSearch() {
        let date = devotionalDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = devotionalTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = devotionalCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let criteria = selectedKind == .devotional
            ? LampDevotionalSearchCriteria(
                date: date.count == 10 ? date : nil,
                monthDay: date.count == 5 ? date : nil,
                tags: tag.isEmpty ? nil : [tag],
                categories: category.isEmpty ? nil : [category]
            )
            : LampDevotionalSearchCriteria()
        model.searchModules(
            query, kind: selectedKind, moduleID: selectedModuleID,
            bookRange: (selectedKind == .translation || selectedKind == .highlights)
                ? bookScope.range : nil,
            strongsKey: (selectedKind == .translation || selectedKind == .dictionary)
                ? strongsKey : nil,
            highlightColors: hasActiveHighlightColor ? [highlightColor] : nil,
            devotionalCriteria: criteria
        )
    }

    private func saveSearch() {
        let entry = LampSearchHistoryEntry(
            query: query,
            kind: selectedKind,
            moduleID: selectedModuleID
        )
        historyData = LampSearchHistoryStore.encode(
            LampSearchHistoryStore.adding(entry, to: history)
        )
    }

    private func historyDescription(_ entry: LampSearchHistoryEntry) -> String {
        if let moduleID = entry.moduleID,
           let module = availableModules.first(where: { $0.id == moduleID }) {
            return module.name
        }
        return entry.kind?.displayName ?? "All Content"
    }

    private func copy(_ result: LampModuleSearchResult) {
        let text = [result.title, result.referenceDescription, result.snippet]
            .compactMap { $0 }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func snippetText(_ source: String) -> Text {
        var remaining = source[...]
        var rendered = Text("")
        while let opening = remaining.range(of: "<mark>"),
              let closing = remaining[opening.upperBound...].range(of: "</mark>") {
            rendered = rendered + Text(String(remaining[..<opening.lowerBound]))
            rendered = rendered + Text(String(remaining[opening.upperBound..<closing.lowerBound]))
                .bold().foregroundColor(.accentColor)
            remaining = remaining[closing.upperBound...]
        }
        return rendered + Text(String(remaining))
    }

    private func color(for hex: String?) -> Color? {
        guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private func icon(for kind: LampModuleKind) -> String {
        switch kind {
        case .translation: "books.vertical"
        case .dictionary: "character.book.closed"
        case .commentary: "text.book.closed"
        case .book: "book.closed"
        case .devotional: "sun.max"
        case .notes: "note.text"
        case .plan: "checklist"
        case .highlights: "highlighter"
        case .quiz: "questionmark.bubble"
        }
    }
}

private enum BookSearchScope: String, CaseIterable {
    case all = "All Books"
    case oldTestament = "Old Testament"
    case newTestament = "New Testament"

    var range: ClosedRange<Int>? {
        switch self {
        case .all: nil
        case .oldTestament: 1...39
        case .newTestament: 40...66
        }
    }
}

private extension LampModuleKind {
    static var allCases: [LampModuleKind] {
        [.translation, .dictionary, .commentary, .book, .devotional, .notes, .plan, .highlights, .quiz]
    }

    var displayName: String {
        switch self {
        case .translation: "Scripture"
        case .dictionary: "Dictionaries"
        case .commentary: "Commentaries"
        case .book: "Books"
        case .devotional: "Devotionals"
        case .notes: "Notes"
        case .plan: "Reading Plans"
        case .highlights: "Highlights"
        case .quiz: "Quizzes"
        }
    }
}
