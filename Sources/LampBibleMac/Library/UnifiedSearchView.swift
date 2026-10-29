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
    @State private var strongsLoader = StrongsAnalysisLoader()
    @State private var strongsFilter: LampStrongsFilter?

    let showImporter: () -> Void
    /// Opens a reference, in the translation it was found in when the result
    /// came from one. A verse found in the WEB for its particular wording is
    /// not that verse in whatever translation the reader happens to be on.
    let openReference: (Int, String?) -> Void
    let openBook: (LampModuleSearchResult) -> Void
    let openKind: (LampModuleKind) -> Void

    private var history: [LampSearchHistoryEntry] {
        LampSearchHistoryStore.decode(historyData)
    }

    private var hasActiveStrongsFilter: Bool {
        (selectedKind == .translation || selectedKind == .dictionary)
            && !strongsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The analysis belongs to a key on translations. The same field over
    /// dictionaries is a lexicon lookup, which has no occurrences to count.
    private var showsStrongsAnalysis: Bool {
        selectedKind == .translation
            && !strongsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Analysing the translation on screen, then the rest.
    ///
    /// Narrowed to one module when the module picker names one, so the picker
    /// means the same thing here as it does for a search.
    private var strongsRequest: StrongsAnalysisLoader.Request {
        StrongsAnalysisLoader.Request(
            key: strongsKey.trimmingCharacters(in: .whitespacesAndNewlines),
            activeTranslationID: selectedModuleID ?? model.selectedTranslationID,
            bookRange: bookScope.range,
            translationIDs: selectedModuleID.map { [$0] } ?? model.translations.map(\.id)
        )
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
            if showsStrongsAnalysis {
                HSplitView {
                    strongsOccurrences
                    StrongsAnalysisPane(
                        key: strongsRequest.key,
                        loader: strongsLoader,
                        filter: $strongsFilter,
                        analyse: { strongsKey = $0 }
                    )
                }
                .task(id: strongsRequest) {
                    // A rendering or chapter chosen for the last key means
                    // nothing for this one.
                    strongsFilter = nil
                    strongsLoader.load(strongsRequest, library: model.library)
                }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !hasActiveStrongsFilter && !hasActiveHighlightColor {
                searchLanding
            } else if model.isModuleSearching && model.moduleSearchResults.isEmpty {
                ProgressView("Searching Library…")
            } else if model.moduleSearchResults.isEmpty {
                // The offer belongs here too: a key searched as words may find
                // nothing at all, which is exactly when being told the
                // analysis exists is most use.
                VStack(spacing: 0) {
                    strongsAnalysisOffer
                    ContentUnavailableView.search(text: query.isEmpty
                        ? (hasActiveStrongsFilter ? strongsKey : highlightColor) : query)
                }
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
        .onSubmit(of: .search) {
            // On submit rather than as it is typed: "H7" is a plausible key
            // while someone is still typing "H7225", and moving the text out
            // of the box mid-word would be maddening.
            if let typed = LampStrongsQuery.key(in: query) {
                analyse(typed)
            } else {
                saveSearch()
            }
        }
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

    /// Every occurrence of the key in range, narrowed to whatever the pane has
    /// chosen.
    ///
    /// Taken from the analysis rather than from a search. A search stops at a
    /// page of hits — 250 — which is fewer than a common key has, so filtering
    /// a search's results by a rendering would show a subset of a subset, and
    /// the list would disagree with the figure that was clicked to narrow it.
    /// The analysis already holds every occurrence in range, which is why
    /// choosing a rendering needs no second query.
    private var strongsOccurrences: some View {
        let analysis = strongsLoader.analyses.first
        let occurrences = analysis?.occurrences(matching: strongsFilter) ?? []
        return VStack(spacing: 0) {
            if let analysis {
                HStack(spacing: 6) {
                    Text(strongsFilter == nil
                        ? "\(occurrences.count) occurrences"
                        : "\(occurrences.count) of \(analysis.occurrenceCount) occurrences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(analysis.translationAbbreviation ?? analysis.translationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            if strongsLoader.isLoadingFirst {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // By position, because one verse can carry the key twice
                    // and a reference would not tell those two rows apart.
                    ForEach(Array(occurrences.enumerated()), id: \.offset) { _, occurrence in
                        Button {
                            openReference(occurrence.reference, analysis?.translationID)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(strongsReference(occurrence.reference))
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    if let form = occurrence.form, !form.isEmpty {
                                        Text(form)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let verse = analysis?.verseTexts[occurrence.reference] {
                                    // The outer style is the default for spans
                                    // that set none, so the tagged word keeps
                                    // the tint it was given.
                                    strongsSnippet(of: verse, at: occurrence)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                } else if !occurrence.text.isEmpty {
                                    // No verse kept for this translation, so
                                    // the rendered words on their own.
                                    Text("“\(occurrence.text)”")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(strongsReference(occurrence.reference))")
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 300, idealWidth: 380)
    }

    /// The verse with the tagged word picked out, so a row reads as the
    /// sentence it came from rather than as a word on its own.
    private func strongsSnippet(
        of verse: String,
        at occurrence: LampStrongsAnalysis.Occurrence
    ) -> Text {
        let snippet = LampStrongsContext.snippet(
            of: verse,
            from: occurrence.startOffset,
            to: occurrence.endOffset
        )
        return Text(snippet.isTrimmedAtStart ? "…" : "")
            + Text(snippet.before)
            + Text(snippet.word).bold().foregroundStyle(.tint)
            + Text(snippet.after)
            + Text(snippet.isTrimmedAtEnd ? "…" : "")
    }

    private func strongsReference(_ reference: Int) -> String {
        let parts = LampBibleReferenceFormatter.components(of: reference)
        return "\(LampBibleReferenceFormatter.bookName(parts.book)) \(parts.chapter):\(parts.verse)"
    }

    /// Offers the analysis when the search box holds a Strong's key.
    ///
    /// The analysis has its own toolbar field, which only appears once the
    /// content picker is on Scripture — so someone who types a key into the
    /// search box gets a text search and no sign the analysis is there at all.
    /// This is the signpost. Choosing it fills the toolbar in, which is also
    /// how you find the controls the second time.
    @ViewBuilder
    private var strongsAnalysisOffer: some View {
        if let typed = LampStrongsQuery.key(in: query) {
            Button {
                analyse(typed)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyse \(typed)").font(.headline)
                        Text("Where it is found, how translators rendered it, "
                            + "and the keys it keeps company with.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
        }
    }

    /// Moves a key into the field that drives the analysis.
    ///
    /// The query is cleared rather than left behind, so the toolbar alone says
    /// what is being shown: Scripture, and the key in its own field.
    private func analyse(_ key: String) {
        selectedKind = .translation
        strongsKey = key
        query = ""
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            strongsAnalysisOffer
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
                                openReference(reference, translationID(of: result))
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
                            openReference(reference, translationID(of: result))
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

    /// A translation result's module is the translation. Everything else — a
    /// commentary, a note — points at scripture without being scripture, so it
    /// opens in whatever is being read.
    private func translationID(of result: LampModuleSearchResult) -> String? {
        result.kind == .translation ? result.moduleID : nil
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
            rendered = rendered
                + Text.lampFindMatch(remaining[opening.upperBound..<closing.lowerBound])
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
