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
    /// The reader's own text size. A search hit is scripture, and was drawn
    /// at caption size whatever the reader had chosen — the one place in the
    /// app where their setting did not reach.
    @AppStorage("reader.fontSize") private var readerFontSize = LampTextScale.readerText.defaultValue
    /// Verses either side of a hit in its preview.
    @AppStorage("search.previewContext") private var previewContext = 2
    // Held by the scene rather than the view. Opening a result moves the
    // window to the reader, which takes this view down and took the search
    // with it — so coming back meant typing the query and setting every
    // filter again, having gone to look at one of its own results.
    @SceneStorage("search.query") private var query = ""
    @SceneStorage("search.kind") private var selectedKind: LampModuleKind?
    @SceneStorage("search.moduleID") private var selectedModuleID: String?
    @SceneStorage("search.devotionalDate") private var devotionalDate = ""
    @SceneStorage("search.devotionalTag") private var devotionalTag = ""
    @SceneStorage("search.devotionalCategory") private var devotionalCategory = ""
    @SceneStorage("search.bookScope") private var bookScope: BookSearchScope = .all
    @SceneStorage("search.strongsKey") private var strongsKey = ""
    @SceneStorage("search.highlightColor") private var highlightColor = ""
    /// Not kept: which row was selected belongs to a list that no longer
    /// exists, and the search is run again on return anyway.
    @State private var selectedResultID: String?
    /// The occurrence whose preview is open, by reference. A Strong's search
    /// shows these rows rather than the module results, which is why fixing
    /// the other list did nothing for it.
    @State private var previewedOccurrence: Int?
    @State private var strongsLoader = StrongsAnalysisLoader()
    @State private var strongsFilter: LampStrongsFilter?
    /// The keys a companion was followed from, the last most recent: Back
    /// returns to it. Any other change of key — typed, from history, from a
    /// dictionary hit — starts again, so Back never leads somewhere the reader
    /// did not come from.
    @State private var strongsTrail: [String] = []
    /// Set while a change of key comes from following or going back, which
    /// keeps the trail; read and cleared by the key's change handler.
    @State private var isWalkingStrongsTrail = false
    /// The hit being previewed, if any.
    @State private var previewedResult: LampModuleSearchResult?

    let showImporter: () -> Void
    /// Opens a reference, in the translation it was found in when the result
    /// came from one. A verse found in the WEB for its particular wording is
    /// not that verse in whatever translation the reader happens to be on.
    let openReference: (Int, String?) -> Void
    let openBook: (LampModuleSearchResult) -> Void
    /// Opens the section a result belongs to, on that result.
    let openKind: (LampModuleSearchResult) -> Void
    /// Looks a lexicon entry up in the Dictionary pane.
    let openDictionaryEntry: (_ key: String, _ word: String?) -> Void

    /// Core's history, reading the Mac's older entries once.
    private var history: LampSearchHistory {
        LampSearchHistoryMigration.history(from: historyData)
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
            ?? resultGroups.first?.results.first
    }

    private var availableModules: [(id: String, name: String)] {
        // Hidden modules are left out: a module the reader has hidden is not
        // searched, so offering it as a filter promises results it can never
        // return.
        var values: [(id: String, name: String)] = model.modules
            .filter { selectedKind == nil || $0.kind == selectedKind }
            .filter { !model.hiddenModuleIDs.contains($0.id) }
            .map { (id: $0.id, name: $0.name) }
        if selectedKind == nil || selectedKind == .notes {
            values.append(("personal-notes", "My Notes"))
        }
        if selectedKind == nil || selectedKind == .highlights {
            values += model.translations.map {
                ("personal-highlights:\($0.id)", "My \($0.abbreviation ?? $0.name) Highlights")
            }
            // A set the reader made. Its module ID is a UUID, so without this
            // it could not be chosen at all — only its translation's default
            // set could.
            values += model.highlightSets.map { ($0.id, $0.name) }
        }
        if selectedKind == nil || selectedKind == .devotional {
            values.append(("personal-devotionals", "My Writing"))
        }
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The date, tag and category fields.
    ///
    /// Above the results rather than inside them. Drawn within the results
    /// list, they vanished the moment a filter matched nothing — which is
    /// exactly when you need to reach them, because the filter you cannot see
    /// is the one you want to clear.
    @ViewBuilder
    private var devotionalFilters: some View {
        if selectedKind == .devotional {
            HStack(spacing: 8) {
                TextField("Date (YYYY-MM-DD or MM-DD)", text: $devotionalDate)
                    .frame(width: 170)
                TextField("Tag", text: $devotionalTag)
                    .frame(width: 110)
                TextField("Category", text: $devotionalCategory)
                    .frame(width: 110)
                if hasActiveDevotionalFilter {
                    Button("Clear", action: clearDevotionalFilters)
                        .help("Clear the date, tag and category")
                }
                Spacer(minLength: 0)
            }
            .textFieldStyle(.roundedBorder)
            .padding(10)
            Divider()
        }
    }

    private var hasActiveDevotionalFilter: Bool {
        selectedKind == .devotional && devotionalCriteria != LampDevotionalSearchCriteria()
    }

    /// The criteria the fields describe, built once and used both to search
    /// and to tell whether anything is filtered at all.
    private var devotionalCriteria: LampDevotionalSearchCriteria {
        guard selectedKind == .devotional else { return .init() }
        let date = devotionalDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = devotionalTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = devotionalCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        return LampDevotionalSearchCriteria(
            date: date.count == 10 ? date : nil,
            monthDay: date.count == 5 ? date : nil,
            tags: tag.isEmpty ? nil : [tag],
            categories: category.isEmpty ? nil : [category]
        )
    }

    private func clearDevotionalFilters() {
        devotionalDate = ""
        devotionalTag = ""
        devotionalCategory = ""
    }

    var body: some View {
        VStack(spacing: 0) {
        refineFilters
        devotionalFilters
        Group {
            if showsStrongsAnalysis {
                strongsAnalysis
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !hasActiveStrongsFilter && !hasActiveHighlightColor
                && !hasActiveDevotionalFilter {
                searchLanding
            } else if model.isModuleSearching && model.moduleSearchResults.isEmpty {
                ProgressView("Searching Library…")
            } else if model.moduleSearchResults.isEmpty {
                // The offer belongs here too: a key searched as words may find
                // nothing at all, which is exactly when being told the
                // analysis exists is most use.
                VStack(spacing: 0) {
                    referenceOffer
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
        // The landing and the empty states are only as tall as their text, so
        // without this the stack was centred in the pane and the filter bar
        // above them sat halfway down the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Search")
        // Short enough to stay whole once the Strong's key field joins the
        // toolbar: the longer "Search Bibles and modules" was cut to
        // "Search Bibles and n…" at the default window size.
        .searchable(text: $query, placement: .toolbar, prompt: "Search Library")
        .onSubmit(of: .search) {
            // On submit rather than as it is typed: "H7" is a plausible key
            // while someone is still typing "H7225", and moving the text out
            // of the box mid-word would be maddening.
            if let typed = LampStrongsKey.typedKey(query) {
                analyse(typed)
            } else {
                saveSearch()
            }
        }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: selectedKind) { _, _ in
            // Only when it no longer belongs. Clearing unconditionally threw
            // away the module a history entry had just restored, because
            // restoring an entry sets the kind as well.
            if let id = selectedModuleID,
               !availableModules.contains(where: { $0.id == id }) {
                selectedModuleID = nil
            }
            if selectedKind != .devotional { clearDevotionalFilters() }
            runSearch()
        }
        .onChange(of: selectedModuleID) { _, _ in runSearch() }
        .onChange(of: devotionalDate) { _, _ in runSearch() }
        .onChange(of: devotionalTag) { _, _ in runSearch() }
        .onChange(of: devotionalCategory) { _, _ in runSearch() }
        .onChange(of: bookScope) { _, _ in runSearch() }
        .onChange(of: strongsKey) { _, key in
            if isWalkingStrongsTrail {
                isWalkingStrongsTrail = false
            } else {
                strongsTrail = []
            }
            // A key is a key on scripture or in a lexicon. Any other content
            // chosen (Books, say) has no analysis to show, so the key moves
            // the search to scripture; a lexicon keeps that choice.
            if selectedKind != .translation, selectedKind != .dictionary,
               !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedKind = .translation
            }
            runSearch()
        }
        .onChange(of: highlightColor) { _, _ in runSearch() }
        .onChange(of: model.moduleSearchResults) { _, results in
            if !results.contains(where: { $0.id == selectedResultID }) {
                // The first row on screen, which grouping may have moved
                // from the first result core returned.
                selectedResultID = resultGroups.first?.results.first?.id
            }
        }
        .toolbar { searchToolbar }
        .task {
            // The filters come back with the scene, but nothing has changed,
            // so no observer fires and the results on the model may be from
            // whatever was searched last. Run the restored search once.
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasActiveStrongsFilter || hasActiveHighlightColor
                || hasActiveDevotionalFilter {
                runSearch()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isModuleSearching && !model.moduleSearchResults.isEmpty {
                ProgressView("Updating Results…")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .padding()
            }
        }
        }
    }

    private var searchLanding: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView {
                    Label("Search Your Library", systemImage: "text.magnifyingglass")
                } description: {
                    Text("Search scripture, dictionaries, commentaries, books, notes, writing, plans, quizzes, and highlighted verses.")
                } actions: {
                    if model.modules.isEmpty {
                        Button("Install Module…", action: showImporter)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    Section("Recent Searches") {
                        ForEach(history.entries) { entry in
                            Button {
                                restore(entry)
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
                // The list says what it holds, and what narrowed it, here
                // rather than in the pane whose bar was clicked: the reader
                // clicks over there and reads the effect over here. The row
                // keeps one height with or without the chip, so the list
                // under it doesn't move when a bar is chosen.
                StrongsOccurrenceHeading(
                    analysis: analysis,
                    shown: occurrences.count,
                    filter: $strongsFilter
                )
                Divider()
            }
            if strongsLoader.isLoadingFirst {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // By position, because one verse can carry the key twice
                    // and a reference would not tell those two rows apart.
                    ForEach(Array(occurrences.enumerated()), id: \.offset) { _, occurrence in
                        let index = occurrences.firstIndex { $0 == occurrence } ?? 0
                        Button {
                            previewedOccurrence = occurrence.reference
                        } label: {
                            StrongsOccurrenceLabel(
                                occurrence: occurrence,
                                verse: analysis?.verseTexts[occurrence.reference],
                                fontSize: hitFontSize
                            )
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .popover(
                            isPresented: Binding(
                                get: { previewedOccurrence == occurrence.reference },
                                set: { if !$0 { previewedOccurrence = nil } }
                            ),
                            // Toward the analysis: the list is the right-hand
                            // column, so a preview opened past its trailing
                            // edge would have no room.
                            arrowEdge: .leading
                        ) {
                            if let analysis {
                                let translationID = analysis.translationID
                                SearchHitPreview(
                                    reference: occurrence.reference,
                                    heading: strongsReference(occurrence.reference),
                                    moduleName: analysis.translationName,
                                    translationID: translationID,
                                    query: occurrence.text,
                                    fontSize: hitFontSize,
                                    context: $previewContext,
                                    open: {
                                        previewedOccurrence = nil
                                        saveSearch()
                                        openReference(occurrence.reference, translationID)
                                    }
                                )
                            }
                        }
                        .contextMenu {
                            Button("Preview in Context") {
                                previewedOccurrence = occurrence.reference
                            }
                            Button("Open \(strongsReference(occurrence.reference))") {
                                saveSearch()
                                openReference(occurrence.reference, analysis?.translationID)
                            }
                            Button("Copy Verse") {
                                let verse = analysis?.verseTexts[occurrence.reference] ?? occurrence.text
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(
                                    "\(strongsReference(occurrence.reference)) \(verse)",
                                    forType: .string
                                )
                            }
                        }
                        .help("Show \(strongsReference(occurrence.reference)) in context")
                        .id(index)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 300, idealWidth: 380)
    }

    private func strongsReference(_ reference: Int) -> String {
        StrongsOccurrenceLabel.reference(reference)
    }

    /// Analyses a companion, keeping the key it was followed from to go back to.
    private func followCompanion(_ key: String) {
        let current = strongsRequest.key
        guard LampStrongsKey.normalized(key) != LampStrongsKey.normalized(current) else { return }
        if !current.isEmpty { strongsTrail.append(current) }
        isWalkingStrongsTrail = true
        strongsKey = key
    }

    private func goBackAlongStrongsTrail() {
        guard let previous = strongsTrail.popLast() else { return }
        isWalkingStrongsTrail = true
        strongsKey = previous
    }

    /// The word on the left, its occurrences on the right: the word is what
    /// was searched for, so it leads, and the list it narrows reads as the
    /// result of choosing in it.
    ///
    /// Held apart from `body` because the view builder's type checking gives
    /// up once one expression carries this much: the error it reports lands
    /// on whatever line it was reading at the time, which is rarely the one
    /// at fault.
    private var strongsAnalysis: some View {
        HSplitView {
            StrongsAnalysisPane(
                key: strongsRequest.key,
                loader: strongsLoader,
                filter: $strongsFilter,
                analyse: followCompanion,
                // Search's own module picker is the choice of translation,
                // so opening another one sets it, where it can be undone.
                openIn: { selectedModuleID = $0 },
                bookRange: bookScope.range,
                fontSize: hitFontSize,
                back: strongsTrail.last.map { previous in
                    StrongsAnalysisPane.Back(title: previous, go: goBackAlongStrongsTrail)
                }
            )
            strongsOccurrences
        }
        .task(id: strongsRequest) {
            // A rendering or chapter chosen for the last key means nothing
            // for this one.
            strongsFilter = nil
            // A key is typed a character at a time, and "G", "G2", "G26"
            // would each start reading whole translations — about a tenth of
            // a second each, per translation. Waiting for a pause means one
            // analysis rather than three. Cancellation is the point: a new
            // keystroke replaces this task before the sleep ends.
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            strongsLoader.load(strongsRequest, library: model.library)
        }
    }

    /// Offers the passage when the search box names one.
    ///
    /// Above the results rather than instead of them: "John 3" is a passage
    /// to open and also a phrase that appears in commentaries, and only the
    /// reader knows which they meant.
    @ViewBuilder
    private var referenceOffer: some View {
        if let reference = LampSearchQuery(query).reference {
            Button {
                saveSearch()
                openReference(reference.startReference, nil)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "book").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Go to \(reference.description)").font(.headline)
                        Text("Open the passage in the reader.")
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

    /// Offers the analysis when the search box holds a Strong's key.
    ///
    /// The analysis has its own toolbar field, which only appears once the
    /// content picker is on Scripture — so someone who types a key into the
    /// search box gets a text search and no sign the analysis is there at all.
    /// This is the signpost. Choosing it fills the toolbar in, which is also
    /// how you find the controls the second time.
    @ViewBuilder
    private var strongsAnalysisOffer: some View {
        if let typed = LampStrongsKey.typedKey(query) {
            Button {
                analyse(typed)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyse \(typed)").font(.headline)
                        Text("Where it is found, how it is translated, "
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

    /// The results, shelved by what they are: scripture first, then the
    /// reader's own notes and writing, then reference works and books.
    ///
    /// Each group says once what it is, and once which module its hits came
    /// from when they all came from one — which is what every row repeated
    /// before, in a badge and a caption, until the repetition was most of
    /// what a row said. Within a group the results keep the order core gave
    /// them.
    private var resultGroups: [SearchResultGroup] {
        SearchResultGroup.groups(
            from: model.moduleSearchResults,
            readerTranslationID: model.selectedTranslationID
        )
    }

    /// Every result in the order it is shown, for moving through them by key.
    private var shownResults: [LampModuleSearchResult] {
        resultGroups.flatMap(\.results)
    }

    /// The results, drawn as a stack rather than a List so the selected row
    /// can be marked the way the passage pane marks the hit verse — a soft
    /// ground and an accent rule — instead of the List's broad grey block,
    /// which outweighed everything around it. The arrow keys still move
    /// through the results.
    private var resultsList: some View {
        VStack(spacing: 0) {
            referenceOffer
            strongsAnalysisOffer
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(resultGroups) { group in
                            Section {
                                ForEach(Array(group.results.enumerated()), id: \.element.id) { index, result in
                                    if index > 0 {
                                        // Not against the selected row,
                                        // whose own ground already marks it.
                                        let touchesSelection = result.id == selectedResult?.id
                                            || group.results[index - 1].id == selectedResult?.id
                                        Divider()
                                            .overlay(Color.lampCardStroke)
                                            .padding(.horizontal, 16)
                                            .opacity(touchesSelection ? 0 : 1)
                                    }
                                    resultRow(result, showsModule: group.moduleName == nil)
                                        .id(result.id)
                                }
                            } header: {
                                resultGroupHeader(group, offersMore: offersMore(group))
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1, proxy: proxy)
                    return .handled
                }
            }
        }
        .frame(minWidth: 340, idealWidth: 440)
    }

    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) {
        let results = shownResults
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedResult?.id } ?? 0
        let next = min(max(current + offset, 0), results.count - 1)
        selectedResultID = results[next].id
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(results[next].id, anchor: nil)
        }
    }

    /// Whether a group's header offers "More in …": its kind found more than
    /// the search across every kind kept, and it is that kind's first shelf
    /// (Scripture has one per translation; the offer is the kind's).
    private func offersMore(_ group: SearchResultGroup) -> Bool {
        model.moduleSearchKindsWithMore.contains(group.kind)
            && resultGroups.first { $0.kind == group.kind }?.id == group.id
    }

    /// Whether a group is its kind's only shelf. Scripture has one per
    /// translation, and a "+" on one of several would claim the more were
    /// that translation's; with one, they are.
    private func isOnlyShelf(of group: SearchResultGroup) -> Bool {
        resultGroups.filter { $0.kind == group.kind }.count == 1
    }

    private func resultGroupHeader(_ group: SearchResultGroup, offersMore: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon(for: group.kind))
                .foregroundStyle(.tint)
                .imageScale(.small)
            // The shared heading style a size up: at caption size, over a
            // list this long, it was the one thing on the page judged too
            // small to find.
            Text(group.kind.displayName)
                .lampSectionHeading()
                .font(.subheadline.weight(.semibold))
            // The count in words and in the readable grey, not tracked into
            // the heading's capitals where "SCRIPTURE 19" read as one label.
            Text(resultCountDescription(group, isCut: offersMore && isOnlyShelf(of: group)))
                .font(.subheadline)
                .foregroundStyle(Color.lampSecondaryText)
                .monospacedDigit()
            Spacer(minLength: 8)
            if offersMore {
                // The kind filter is the deeper page: it searches that kind
                // alone, the whole page of it, rather than cutting from here.
                Button {
                    selectedKind = group.kind
                } label: {
                    HStack(spacing: 2) {
                        Text("More in \(group.kind.displayName)")
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.lampLink)
                }
                .buttonStyle(.plain)
                .help("Show only \(group.kind.displayName), searched in full")
            }
            if let moduleName = group.moduleName {
                Text(moduleName)
                    .font(.subheadline)
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.lampCardStroke).frame(height: 1)
        }
    }

    /// "12 results", or "20+ results" for a kind cut short: more were found
    /// than shown, and how many more isn't known, so no number claims it.
    private func resultCountDescription(_ group: SearchResultGroup, isCut: Bool) -> String {
        let count = group.results.count
        let noun = switch group.kind {
        case .translation, .highlights: count == 1 && !isCut ? "verse" : "verses"
        default: count == 1 && !isCut ? "result" : "results"
        }
        return "\(count)\(isCut ? "+" : "") \(noun)"
    }

    /// Scripture is read for its words, so the verse leads and the reference
    /// is its label. Everything else is found by its title, so the title
    /// leads and the excerpt steps down a size beneath it.
    private func resultRow(_ result: LampModuleSearchResult, showsModule: Bool) -> some View {
        let isScripture = result.kind == .translation || result.kind == .highlights
        let isSelected = result.id == selectedResult?.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let highlightColor = color(for: result.highlightColor) {
                    Circle().fill(highlightColor).frame(width: 9, height: 9)
                }
                Text(result.title)
                    .font(.system(size: isScripture ? 14 : 13.5, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if showsModule {
                    Text(result.moduleName)
                        .font(.subheadline)
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
            snippetText(result.snippet)
                .font(.system(size: isScripture ? hitFontSize : max(13, hitFontSize - 3)))
                .lineSpacing(isScripture ? 2 : 3)
                .lineLimit(3)
                .foregroundStyle(isScripture ? Color.primary : Color.lampSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .background {
            LampListSelection(isSelected: isSelected)
        }
        // The whole row, not just the ink, so a click or right-click in the
        // space beside a short snippet still lands on it.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // A click selects the result, so the detail pane follows, and shows
        // a verse in its context, which is what the preview is for. The
        // first result is selected by itself when results arrive; that
        // opens nothing, because it is not a click.
        .onTapGesture {
            selectedResultID = result.id
            if previewTranslation(of: result) != nil {
                previewedResult = result
            }
        }
        .popover(isPresented: previewBinding(for: result), arrowEdge: .trailing) {
            preview(for: result)
        }
        .contextMenu {
            if previewTranslation(of: result) != nil {
                Button("Preview in Context") { previewedResult = result }
            }
            if let reference = result.startReference {
                Button("Open \(result.referenceDescription ?? "Reference")") {
                    saveSearch()
                    openReference(reference, translationID(of: result))
                }
            }
            if result.kind == .dictionary, let key = lexiconKey(of: result) {
                Button("Look Up \(key)") {
                    saveSearch()
                    openDictionaryEntry(key, result.title)
                }
            }
            if let key = analysableKey(of: result) {
                Button("Analyse \(key)") {
                    saveSearch()
                    analyse(key)
                }
            }
            Button("Copy Result") { copy(result) }
        }
    }

    /// The preview, anchored on the row it is about.
    ///
    /// Attached per row rather than to the list: a popover presented from the
    /// whole list has no particular place to point at, and presenting one as
    /// a context menu dismisses is unreliable. Bound by id so the detail
    /// pane's button opens the same popover, on that result's own row.
    @ViewBuilder
    private func preview(for result: LampModuleSearchResult) -> some View {
        if let translationID = previewTranslation(of: result) {
            SearchHitPreview(
                reference: result.startReference ?? 0,
                heading: result.referenceDescription,
                moduleName: result.moduleName,
                translationID: translationID,
                query: query,
                fontSize: hitFontSize,
                context: $previewContext,
                open: {
                    previewedResult = nil
                    saveSearch()
                    openReference(result.startReference ?? 0, translationID)
                }
            )
        }
    }

    private func previewBinding(for result: LampModuleSearchResult) -> Binding<Bool> {
        Binding(
            get: { previewedResult?.id == result.id },
            set: { if !$0 { previewedResult = nil } }
        )
    }

    /// The selected result, read properly.
    ///
    /// A verse is shown where it stands, with the verses either side at the
    /// reader's own size, so the pane answers "is this the one I meant?" on
    /// its own — it showed the same snippet as the row, smaller, over a
    /// column of empty space. Anything else gets its excerpt at a reading
    /// size, in the face its kind is read in.
    private func resultDetail(_ result: LampModuleSearchResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(result.kind.displayName, systemImage: icon(for: result.kind))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(result.title)
                        .font(.system(size: 28, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    detailByline(result)
                }

                if result.kind == .dictionary {
                    detailActions(result)
                }

                Divider()

                if let translationID = previewTranslation(of: result),
                   let reference = result.startReference {
                    SearchContextPassage(
                        reference: reference,
                        translationID: translationID,
                        query: query,
                        fontSize: detailFontSize,
                        context: previewContext
                    )
                    .id("\(result.id)|\(previewContext)")
                } else if result.kind == .dictionary, let key = lexiconKey(of: result) {
                    SearchDictionaryEntry(key: key, moduleID: result.moduleID) {
                        snippetText(result.snippet)
                            .font(.system(size: detailFontSize - 1, design: detailDesign(for: result.kind)))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(result.id)
                } else {
                    snippetText(result.snippet)
                        .font(.system(size: detailFontSize - 1, design: detailDesign(for: result.kind)))
                        .lineSpacing(detailFontSize * 0.4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Below whatever is shown, except an entry: a lexicon's
                // article can run to pages, and the way on from it — analyse
                // the word, or look it up beside the reader — belongs where
                // the reader starts, not where they would have to scroll to.
                if result.kind != .dictionary {
                    detailActions(result)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// What can be done with the selected result.
    private func detailActions(_ result: LampModuleSearchResult) -> some View {
        HStack(spacing: 8) {
            if let reference = result.startReference {
                Button("Open in Reader", systemImage: "book") {
                    saveSearch()
                    openReference(reference, translationID(of: result))
                }
                .buttonStyle(.borderedProminent)
            }
            if result.kind == .book {
                Button("Open Book", systemImage: "book.closed") {
                    saveSearch()
                    openBook(result)
                }
                .buttonStyle(.borderedProminent)
            } else if result.kind == .dictionary, let key = lexiconKey(of: result) {
                if let analysable = analysableKey(of: result) {
                    Button("Analyse \(analysable)", systemImage: "chart.bar.xaxis") {
                        saveSearch()
                        analyse(analysable)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Look Up", systemImage: "character.book.closed") {
                    saveSearch()
                    openDictionaryEntry(key, result.title)
                }
                .buttonStyle(.bordered)
            } else if [.devotional, .plan, .quiz].contains(result.kind) {
                Button("Open \(result.kind.displayName)", systemImage: icon(for: result.kind)) {
                    saveSearch()
                    openKind(result)
                }
                .buttonStyle(.borderedProminent)
            }
            if previewTranslation(of: result) != nil {
                Button("Preview in Context", systemImage: "text.magnifyingglass") {
                    previewedResult = result
                }
                .buttonStyle(.bordered)
            }
            Button("Copy", systemImage: "doc.on.doc") { copy(result) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    /// Where the result came from, said once: the module, and the passage a
    /// non-scripture result is about.
    @ViewBuilder
    private func detailByline(_ result: LampModuleSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subtitle = result.subtitle, !subtitle.isEmpty,
               subtitle != result.title, subtitle != result.moduleName,
               result.kind != .translation {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(result.moduleName)
                if let description = result.referenceDescription, description != result.title {
                    Text("·")
                    Label(description, systemImage: "book")
                }
            }
            .font(.callout)
            .foregroundStyle(Color.lampSecondaryText)
        }
    }

    /// A reading size for the pane: the reader's own setting, where a verse
    /// read in the reader is set.
    private var detailFontSize: Double {
        max(15, readerFontSize)
    }

    private func detailDesign(for kind: LampModuleKind) -> Font.Design {
        switch kind {
        case .translation, .highlights, .book, .commentary, .devotional: .serif
        default: .default
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
            .frame(minWidth: 130, maxWidth: 160)
        }

        ToolbarItem {
            Picker("Module", selection: $selectedModuleID) {
                Text("All Modules").tag(String?.none)
                if selectedKind == .translation {
                    // By language, as every translation picker lists them.
                    let offered = Set(availableModules.map(\.id))
                    TranslationPickerOptions(
                        translations: model.translations.filter { offered.contains($0.id) },
                        tag: { Optional($0.id) }
                    )
                } else {
                    ForEach(availableModules, id: \.id) { module in
                        Text(module.name).tag(Optional(module.id))
                    }
                }
            }
            // Capped, so a long module name cannot take the search
            // field's room: uncapped, "All Modules" grew to a third of the
            // toolbar and the field beside it shrank until it truncated.
            .frame(minWidth: 150, maxWidth: 220)
        }
    }

    /// The filters that refine one kind of content — which books, a Strong's
    /// key, a highlight colour — as a row of chips under the toolbar.
    ///
    /// Out of the toolbar, where five same-weight controls in a row could not
    /// be parsed; and drawn as one family of soft chips rather than a mix of
    /// a filled popup and a bordered field, which read as a second, smaller
    /// toolbar bolted under the first. Each chip says what it filters.
    @ViewBuilder
    private var refineFilters: some View {
        let showsBooks = selectedKind == .translation || selectedKind == .highlights
        let showsStrongs = selectedKind == .translation || selectedKind == .dictionary
        let showsColour = selectedKind == .highlights
        if showsBooks || showsStrongs || showsColour {
            HStack(spacing: 8) {
                if showsBooks {
                    Menu {
                        Picker("Books", selection: $bookScope) {
                            ForEach(BookSearchScope.allCases, id: \.self) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Label(bookScope.rawValue, systemImage: "book")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .filterChip()
                    .help("Which books of the Bible to search")
                }
                if showsStrongs {
                    HStack(spacing: 6) {
                        Image(systemName: "number")
                            .foregroundStyle(Color.lampSecondaryText)
                        TextField(
                            "Strong's key",
                            text: $strongsKey,
                            prompt: Text("Strong’s number, e.g. G26")
                                .foregroundStyle(Color.lampSecondaryText)
                        )
                        .textFieldStyle(.plain)
                        .frame(width: 168)
                        if !strongsKey.isEmpty {
                            Button("Clear Strong's Key", systemImage: "xmark.circle.fill") {
                                strongsKey = ""
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.lampSecondaryText)
                        }
                    }
                    .filterChip()
                    .help("A Strong's number such as G26 or H430, to find every place it is translated")
                }
                if showsColour {
                    // The palette for the colours highlights are actually made
                    // in, and the field kept beside it for anything else: a
                    // highlight imported from elsewhere, or made before a palette
                    // colour changed, has a hex nothing in the menu matches.
                    HStack(spacing: 6) {
                        Menu {
                            Button("Any Colour") { highlightColor = "" }
                            Divider()
                            ForEach(StudyHighlightPalette.colors) { swatch in
                                Button {
                                    highlightColor = swatch.hex
                                } label: {
                                    Label {
                                        Text(swatch.name)
                                    } icon: {
                                        Image(systemName: "circle.fill")
                                            .foregroundStyle(swatch.color)
                                    }
                                }
                            }
                        } label: {
                            Label {
                                Text(highlightName ?? "Any Colour")
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(
                                        color(for: highlightColor) ?? Color.secondary.opacity(0.4)
                                    )
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(highlightName ?? "Filter by highlight colour")

                        TextField(
                            "Hex",
                            text: $highlightColor,
                            prompt: Text("Hex").foregroundStyle(Color.lampSecondaryText)
                        )
                        .textFieldStyle(.plain)
                        .frame(width: 64)
                        .help("Six hex digits, for a colour not in the palette")
                    }
                    .filterChip()
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    private func runSearch() {
        // Nothing to search for while the analysis is driving: the list it
        // shows comes from the analysis, which already holds every
        // occurrence. The module search ran anyway — a 250-result query per
        // keystroke whose results were never displayed.
        guard !showsStrongsAnalysis else {
            model.clearModuleSearch()
            return
        }
        let criteria = devotionalCriteria
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

    /// Keeps the search, with every filter that shaped it.
    ///
    /// Core decides what is worth keeping: a search that found nothing, or
    /// that says nothing, is not recorded. That is why the result count goes
    /// in rather than being judged here.
    private func saveSearch() {
        var history = history
        let kept = history.record(
            LampSearchHistory.Entry(
                query: query,
                kinds: selectedKind.map { [$0] },
                moduleIDs: selectedModuleID.map { [$0] },
                bookRange: bookScope.range,
                strongsKey: strongsKey.isEmpty ? nil : strongsKey,
                highlightColors: hasActiveHighlightColor ? [highlightColor] : nil,
                devotionalCriteria: devotionalCriteria
            ),
            resultCount: showsStrongsAnalysis
                ? (strongsLoader.analyses.first?.occurrenceCount ?? 0)
                : model.moduleSearchResults.count
        )
        if kept { historyData = history.encoded() }
    }

    /// Puts back every filter the search ran with, not only its words.
    private func restore(_ entry: LampSearchHistory.Entry) {
        selectedKind = entry.kinds?.first
        selectedModuleID = entry.moduleIDs?.first
        strongsKey = entry.strongsKey ?? ""
        highlightColor = entry.highlightColors?.first ?? ""
        if let range = entry.bookRange,
           let scope = BookSearchScope.allCases.first(where: { $0.range == range }) {
            bookScope = scope
        }
        devotionalDate = entry.devotionalCriteria?.date
            ?? entry.devotionalCriteria?.monthDay ?? ""
        devotionalTag = entry.devotionalCriteria?.tags?.first ?? ""
        devotionalCategory = entry.devotionalCriteria?.categories?.first ?? ""
        // Last, because every assignment above runs a search of its own.
        query = entry.query
    }

    private func historyDescription(_ entry: LampSearchHistory.Entry) -> String {
        if let moduleID = entry.moduleIDs?.first,
           let module = availableModules.first(where: { $0.id == moduleID }) {
            return module.name
        }
        return entry.kinds?.first?.displayName ?? "All Content"
    }

    /// A translation result's module is the translation. Everything else — a
    /// commentary, a note — points at scripture without being scripture, so it
    /// opens in whatever is being read.
    /// Whether a result can be shown in its surroundings: it needs a verse
    /// to be surrounded by, and a translation to read them from.
    private func previewTranslation(of result: LampModuleSearchResult) -> String? {
        guard result.startReference != nil else { return nil }
        return translationID(of: result)
    }

    /// The lexicon key a dictionary result stands for, as core names it.
    ///
    /// Not the title, which is the lemma — the Greek or Hebrew word, not
    /// something the dictionary pane can look up — and not the entry part of
    /// the id, which is the row's own id: a number for a bundled dictionary,
    /// so a lookup by it found nothing.
    private func lexiconKey(of result: LampModuleSearchResult) -> String? {
        guard result.kind == .dictionary else { return nil }
        return result.entryKey
    }

    /// The Strong's key a dictionary hit is the entry for, when it has one:
    /// the way from a word found by its meaning ("propitiation") to where it
    /// stands in scripture and how it is rendered. An entry keyed some other
    /// way, as BDB's are, has no analysis to open.
    private func analysableKey(of result: LampModuleSearchResult) -> String? {
        lexiconKey(of: result).flatMap(LampStrongsKey.typedKey)
    }

    /// The translation a result should open in.
    ///
    /// A highlight's module is `personal-highlights:<translation>`, and that
    /// translation is the one it was made in. Returning nil for it opened the
    /// verse in whatever translation happened to be on screen, where the
    /// highlight is not.
    private func translationID(of result: LampModuleSearchResult) -> String? {
        switch result.kind {
        case .translation:
            return result.moduleID
        case .highlights:
            let prefix = "\(LampModuleKind.highlights.rawValue):"
            guard result.moduleID.hasPrefix(prefix) else { return nil }
            let id = String(result.moduleID.dropFirst(prefix.count))
            return id.isEmpty ? nil : id
        default:
            return nil
        }
    }

    private func copy(_ result: LampModuleSearchResult) {
        // Without the marks. Core wraps each matched term in <mark> so the
        // list can highlight it; pasting that markup into someone's notes is
        // not what Copy means.
        let text = [result.title, result.referenceDescription, LampSearchSnippet.plainText(result.snippet)]
            .compactMap { $0 }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The size a hit's own words are drawn at.
    ///
    /// The reader's setting, a little smaller: a result is a glimpse of the
    /// text rather than the text itself, and a list of them at full reading
    /// size shows two results on a screen. It still moves with the setting,
    /// which is what was asked for, and never goes below the scale's floor.
    private var hitFontSize: Double {
        LampTextScale.studyText(readerSize: readerFontSize)
    }

    private func snippetText(_ source: String) -> Text {
        Text.lampMarked(source)
    }

    /// The palette's name for the chosen colour, where it has one.
    private var highlightName: String? {
        StudyHighlightPalette.colors
            .first { $0.hex.caseInsensitiveCompare(highlightColor) == .orderedSame }?
            .name
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

/// One shelf of search results: one kind, and within scripture, one
/// translation.
///
/// Grouping only. The order of results inside a group is core's, untouched,
/// and so is which results there are; this decides which shelf comes first
/// and what each shelf says about itself.
private struct SearchResultGroup: Identifiable {
    let kind: LampModuleKind
    /// The module every result in the group came from, when there is one.
    let moduleName: String?
    let results: [LampModuleSearchResult]
    let id: String

    /// The order shelves are shown in: core's, which both apps follow.
    private static let kindOrder = LampModuleSearch.shelfOrder

    static func groups(
        from results: [LampModuleSearchResult],
        readerTranslationID: String?
    ) -> [SearchResultGroup] {
        let byKind = Dictionary(grouping: results, by: \.kind)
        let kinds = kindOrder + byKind.keys.filter { !kindOrder.contains($0) }
        return kinds.flatMap { kind -> [SearchResultGroup] in
            guard let hits = byKind[kind], !hits.isEmpty else { return [] }
            guard kind == .translation else {
                return [SearchResultGroup(
                    kind: kind, moduleName: commonModule(of: hits), results: hits, id: kind.rawValue
                )]
            }
            // Scripture, a shelf per translation, the one being read first:
            // the same verse in four translations is four hits, and they read
            // better side by side within a translation than interleaved.
            var order: [String] = []
            var byModule: [String: [LampModuleSearchResult]] = [:]
            for hit in hits {
                if byModule[hit.moduleID] == nil { order.append(hit.moduleID) }
                byModule[hit.moduleID, default: []].append(hit)
            }
            if let readerTranslationID, let index = order.firstIndex(of: readerTranslationID) {
                order.insert(order.remove(at: index), at: 0)
            }
            return order.compactMap { moduleID in
                guard let moduleHits = byModule[moduleID] else { return nil }
                return SearchResultGroup(
                    kind: kind,
                    moduleName: moduleHits.first?.moduleName,
                    results: moduleHits,
                    id: "\(kind.rawValue):\(moduleID)"
                )
            }
        }
    }

    private static func commonModule(of results: [LampModuleSearchResult]) -> String? {
        guard let first = results.first?.moduleID,
              results.allSatisfy({ $0.moduleID == first }) else { return nil }
        return results.first?.moduleName
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
}

extension LampModuleKind {
    /// A kind's name as a heading over its results, in Search and the ⌘K
    /// palette alike.
    var displayName: String {
        switch self {
        case .translation: "Scripture"
        case .dictionary: "Dictionaries"
        case .commentary: "Commentaries"
        case .book: "Books"
        case .devotional: "Writing"
        case .notes: "Notes"
        case .plan: "Reading Plans"
        case .highlights: "Highlights"
        case .quiz: "Quizzes"
        }
    }
}

/// A scripture hit in its surroundings, before deciding to go there.
///
/// Opening a result moves the whole window to the reader. A glance at the
/// verses either side answers "is this the one I meant?" without that, and
/// the Open button is there for when the answer is yes.
private struct SearchHitPreview: View {
    @EnvironmentObject private var model: LibraryModel
    let reference: Int
    let heading: String?
    let moduleName: String
    let translationID: String
    let query: String
    let fontSize: Double
    @Binding var context: Int
    let open: () -> Void

    @State private var verses: [LampVerse] = []
    @State private var bookName = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// Tall enough for the verses asked for, within what a popover should
    /// take up on screen.
    private var scrollHeight: Double {
        let lines = Double(max(1, verses.count))
        return min(380, max(90, lines * (fontSize * 1.5 + 14)))
    }

    private var hitVerse: Int {
        LampBibleReferenceFormatter.components(of: reference).verse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(heading ?? bookName)
                    .font(.headline)
                Spacer()
                Text(moduleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(verses) { verse in
                            (
                                Text("\(verse.number) ")
                                    .font(.system(size: max(9, fontSize - 4)))
                                    .foregroundStyle(.secondary)
                                    + markedText(verse.text)
                            )
                            .font(.system(size: fontSize, design: .serif))
                            // The hit itself, so the eye lands on it among
                            // its neighbours. The words that matched are
                            // marked within it as find matches.
                            .fontWeight(verse.number == hitVerse ? .semibold : .regular)
                        }
                    }
                    .textSelection(.enabled)
                }
                // A definite height, not a maximum. A ScrollView has no
                // ideal height of its own, so inside a popover — which sizes
                // itself to its content — it collapsed to a single clipped
                // line, which is what made the preview look broken.
                .frame(height: scrollHeight)
            }

            Divider()

            HStack {
                Stepper(
                    "Context: \(context) verse\(context == 1 ? "" : "s")",
                    value: $context,
                    in: 0...10
                )
                .font(.caption)
                Spacer()
                Button("Open in Reader", systemImage: "book", action: open)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 420)
        .task(id: context) { await load() }
    }

    /// The verse with the searched words marked, as the result list marks
    /// them — so the preview and the row agree about what was found.
    private func markedText(_ text: String) -> Text {
        searchMarkedText(text, query: query)
    }

    private func load() async {
        guard reference > 0 else {
            errorMessage = "This result has no verse to show."
            isLoading = false
            return
        }
        let parts = LampBibleReferenceFormatter.components(of: reference)
        do {
            let chapter = try await model.library.chapter(
                moduleID: translationID,
                bookNumber: parts.book,
                chapterNumber: parts.chapter
            )
            bookName = chapter.book.name
            // Clamped to the chapter: a hit in verse 1 has nothing above it,
            // and asking for it would simply show fewer verses, not fail.
            verses = chapter.verses.filter {
                abs($0.number - parts.verse) <= context
            }
            errorMessage = verses.isEmpty ? "That verse is not in this translation." : nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// A verse with the searched words marked, as the result list marks them —
/// so the preview, the detail pane and the row agree about what was found.
private func searchMarkedText(_ text: String, query: String) -> Text {
    Text.lampMarked(LampSearchQuery(query).markedSnippet(text, limit: .max))
}

/// A scripture hit set in its passage, in the detail pane.
///
/// The verse that matched is in the text's full colour and the verses
/// around it a step quieter, so the eye lands on the hit and can still read
/// on either side of it.
private struct SearchContextPassage: View {
    @EnvironmentObject private var model: LibraryModel
    let reference: Int
    let translationID: String
    let query: String
    let fontSize: Double
    let context: Int

    @State private var verses: [LampVerse] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var hitVerse: Int {
        LampBibleReferenceFormatter.components(of: reference).verse
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: fontSize * 0.5) {
                    ForEach(verses) { verse in
                        let isHit = verse.number == hitVerse
                        (
                            Text("\(verse.number)")
                                .font(.system(size: max(10, fontSize * 0.62), weight: .semibold))
                                .foregroundStyle(Color.lampVerseNumber)
                                .baselineOffset(fontSize * 0.28)
                                + Text("\u{2009}")
                                + searchMarkedText(verse.text, query: query)
                        )
                        .font(.system(size: fontSize, design: .serif))
                        .lineSpacing(fontSize * 0.32)
                        // The verses around the hit are there to be read, so
                        // they keep a reading colour; the hit is told apart by
                        // a rule and a ground of its own rather than by
                        // fading everything else, which left the context
                        // washed out.
                        .foregroundStyle(isHit ? Color.primary : Color.lampProse.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, isHit ? 8 : 0)
                        .padding(.leading, 14)
                        .padding(.trailing, isHit ? 10 : 0)
                        .background(alignment: .leading) {
                            if isHit {
                                // The chosen row's tile (`LampListSelection`),
                                // with no bar beside it.
                                RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous)
                                    .fill(Color.lampSelectionFill)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .task(id: "\(reference)|\(translationID)|\(context)") { await load() }
    }

    private func load() async {
        let parts = LampBibleReferenceFormatter.components(of: reference)
        do {
            let chapter = try await model.library.chapter(
                moduleID: translationID,
                bookNumber: parts.book,
                chapterNumber: parts.chapter
            )
            guard !Task.isCancelled else { return }
            // Clamped to the chapter, as the popover is.
            verses = chapter.verses.filter { abs($0.number - parts.verse) <= context }
            errorMessage = verses.isEmpty ? "That verse is not in this translation." : nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private extension View {
    /// One search filter: a soft capsule on the card ground, the same height
    /// for a menu as for a field, so a row of them reads as one family.
    func filterChip() -> some View {
        padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.lampTileFill))
            .overlay(Capsule().strokeBorder(Color.lampCardStroke))
    }
}

/// A dictionary hit's whole entry, in the search's detail pane.
///
/// The hit itself carries only a snippet cut around the match, which read as
/// the entry broken off mid-sentence. The entry is read again by its key
/// from the hit's own dictionary, and shown the way the study pane shows it;
/// until it arrives, or if it cannot be found, the snippet stands in.
private struct SearchDictionaryEntry<Fallback: View>: View {
    let key: String
    let moduleID: String
    @ViewBuilder let fallback: () -> Fallback

    @EnvironmentObject private var model: LibraryModel
    @AppStorage("commentary.fontSize") private var fontSize = LampTextScale.commentaryText.defaultValue
    @AppStorage("commentary.lineSpacing") private var lineSpacing = LampTextScale.commentaryLineSpacing.defaultValue
    @AppStorage("commentary.typeface") private var typeface = ProseTypeface.commentaryDefault
    @State private var entries: [LampDictionaryResult] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if entries.isEmpty {
                fallback()
            } else {
                ForEach(entries) { entry in
                    DictionaryResultView(
                        result: entry,
                        isExpanded: true,
                        // The pane's heading already names the word; only
                        // several entries under one key need telling apart.
                        showsSummary: entries.count > 1,
                        fontSize: LampTextScale.commentaryText.clamped(fontSize),
                        lineSpacing: LampTextScale.commentaryLineSpacing.clamped(lineSpacing),
                        typeface: typeface
                    )
                }
            }
        }
        .task(id: "\(moduleID)|\(key)") {
            entries = (try? await model.library.dictionaryEntries(keys: [key], moduleIDs: [moduleID])) ?? []
        }
    }
}
