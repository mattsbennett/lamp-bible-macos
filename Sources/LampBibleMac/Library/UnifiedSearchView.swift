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
    /// The searches this window is keeping, and which is shown. Owned by the
    /// window (`LibraryRootView`), which saves them per window session.
    ///
    /// These were nine `@SceneStorage` values. The scene was right about one
    /// thing — opening a result moves the window to the reader, which takes
    /// this view down and took the search with it, so coming back meant
    /// typing the query and setting every filter again. But a scene is wiped
    /// by a clean quit, so a search never saw the next launch, and one bag of
    /// values per scene meant one search at a time. Tabs and remembering are
    /// the same change because both were decided by where this lived.
    @Binding var tabs: SearchTabCollection


    /// What is being typed, until it settles.
    ///
    /// Every character used to go straight into `tabs`, which is state owned
    /// by `LibraryRootView`. One keystroke therefore invalidated the whole
    /// library interface, and the reader's chapters were rebuilt with it —
    /// off screen, behind the Search pane, for a search they have nothing to
    /// do with. Sampled on a release build while 29 characters were typed,
    /// the main thread was busy for 99% of the five seconds, and seven
    /// tenths of that was SwiftUI and the Swift runtime instantiating view
    /// values again: almost none of it was this app's own code.
    ///
    /// The tab still owns the query. This is only the gap between a
    /// keystroke and the tab hearing about it, so nothing downstream has to
    /// know: the pane reads the typed text, and the tab is told once the
    /// typing stops. Nil means nothing is in that gap and the tab's own
    /// value is the truth, which is what another tab shows.
    private struct Typing: Equatable {
        let tab: UUID
        let text: String
    }

    @State private var typing: Typing?
    /// The themes highlights are found by, read when the Highlights scope is.
    @State private var markThemes: [LampHighlightTheme] = []
    /// My highlight sets, whose highlights can be removed from here; an
    /// installed module's are not mine to remove.
    @State private var personalHighlightSetIDs: Set<String> = []
    /// Colours seen on highlights found, for colours no theme names.
    @State private var seenHighlightColors: Set<String> = []

    /// Settled deliberately at the same 250ms the search itself waits, and
    /// for the same reason. It costs no delay: the search is driven by the
    /// typed text rather than by the tab, so results arrive exactly when
    /// they did before — what waits is the tab's name and what is saved for
    /// the next launch, neither of which anybody watches mid-word.
    private static let querySettles = Duration.milliseconds(250)

    private var query: String {
        get {
            if let typing, typing.tab == tabs.selectedID { return typing.text }
            return tabs.selected.query
        }
        nonmutating set { typing = Typing(tab: tabs.selectedID, text: newValue) }
    }

    private var queryField: Binding<String> {
        Binding(get: { query }, set: { query = $0 })
    }

    /// Hands the typed text to the tab that was being typed in.
    ///
    /// Takes the tab by argument rather than reading the selected one: this
    /// also runs when the reader switches tabs, and by then the selected tab
    /// is not the one the words belong to.
    private func settleTyping() {
        guard let typing else { return }
        tabs.update(typing.tab) { $0.query = typing.text }
        self.typing = nil
    }

    /// Sets the query outright, for the changes that are not typing: the
    /// clear button, a history entry put back, a key taken up for analysis.
    ///
    /// These wait for nothing. There is no burst of them to coalesce, and
    /// waiting would put them at risk: the pane is mounted only while Search
    /// is the section on show, so leaving it within the settling time takes
    /// the pending text with it. A cleared field that came back filled would
    /// be the worst of them.
    private func setQuery(_ text: String) {
        typing = nil
        tabs.updateSelected { $0.query = text }
    }
    private var selectedKind: LampModuleKind? {
        get { tabs.selected.kind }
        nonmutating set { tabs.updateSelected { $0.kind = newValue } }
    }
    /// The module this tab searches in, as this library holds it.
    ///
    /// Resolved on the way out rather than rewritten in the tab: a session
    /// saved while a translation was called "ESVs" otherwise restored a
    /// picker with no matching tag, and changing the content kind then
    /// cleared the restriction as though the module were gone.
    private var selectedModuleID: String? {
        get { heldModuleID(tabs.selected.moduleID) }
        nonmutating set { tabs.updateSelected { $0.moduleID = newValue } }
    }
    private var devotionalDate: String {
        get { tabs.selected.devotionalDate }
        nonmutating set { tabs.updateSelected { $0.devotionalDate = newValue } }
    }
    private var devotionalTag: String {
        get { tabs.selected.devotionalTag }
        nonmutating set { tabs.updateSelected { $0.devotionalTag = newValue } }
    }
    private var devotionalCategory: String {
        get { tabs.selected.devotionalCategory }
        nonmutating set { tabs.updateSelected { $0.devotionalCategory = newValue } }
    }
    private var bookScope: BookSearchScope {
        get { BookSearchScope(rawValue: tabs.selected.bookScopeRawValue) ?? .all }
        nonmutating set { tabs.updateSelected { $0.bookScopeRawValue = newValue.rawValue } }
    }
    private var strongsKey: String {
        get { tabs.selected.strongsKey }
        nonmutating set { tabs.updateSelected { $0.strongsKey = newValue } }
    }
    private var highlightColors: Set<String> {
        get { tabs.selected.highlightColors }
        nonmutating set { tabs.updateSelected { $0.highlightColors = newValue } }
    }
    private var highlightStyles: Set<LampHighlightStyle> {
        get { tabs.selected.highlightStyles }
        nonmutating set { tabs.updateSelected { $0.highlightStyles = newValue } }
    }
    private var highlightThemes: Set<LampHighlightMark> {
        get { tabs.selected.highlightThemes }
        nonmutating set { tabs.updateSelected { $0.highlightThemes = newValue } }
    }

    /// A binding onto one of the selected tab's fields, for the controls that
    /// need to write as well as read. `$query` and its like are gone with the
    /// scene storage they belonged to; a computed property has no projected
    /// value, so the binding is made here.
    private func field<Value>(_ keyPath: WritableKeyPath<SearchTab, Value>) -> Binding<Value> {
        Binding(
            get: { tabs.selected[keyPath: keyPath] },
            set: { value in tabs.updateSelected { $0[keyPath: keyPath] = value } }
        )
    }

    /// The analysis filter, which is the tab's own like the rest of what it
    /// shows.
    private var strongsFilterField: Binding<LampStrongsFilter?> {
        Binding(
            get: { tabViewState[tabs.selectedID]?.strongsFilter },
            set: { value in tabViewState[tabs.selectedID, default: TabViewState()].strongsFilter = value }
        )
    }

    /// The book range, which the tab keeps as its `rawValue` so the scope
    /// stays this pane's own type.
    private var bookScopeField: Binding<BookSearchScope> {
        Binding(
            get: { BookSearchScope(rawValue: tabs.selected.bookScopeRawValue) ?? .all },
            set: { value in tabs.updateSelected { $0.bookScopeRawValue = value.rawValue } }
        )
    }

    /// A filter watched together with the tab it belongs to.
    ///
    /// Every filter below runs the search when it changes, and two do more
    /// than that — a new kind can clear the module and the devotional
    /// facets, a new Strong's key clears the trail and can move the search to
    /// scripture. Selecting another tab changes all nine at once, and a
    /// handler cannot otherwise tell that from the reader editing one, so
    /// without this the act of looking at a tab would edit it.
    ///
    /// `onChange` hands over the old value and the new, so the test is
    /// simply whether the tab is the same one: if it changed, the selection
    /// moved and nothing was edited. An earlier version compared against a
    /// tab id that caught up inside a `.task`, which needed the task to run
    /// after these handlers — nothing documents that it does, and a Codex
    /// review was right to call it unproven. This needs no ordering at all.
    private struct Tabbed<Value: Equatable>: Equatable {
        var tab: UUID
        var value: Value
    }

    private func tabbed<Value: Equatable>(_ value: Value) -> Tabbed<Value> {
        Tabbed(tab: tabs.selectedID, value: value)
    }
    /// What a tab is showing, as against what it is searching for: the row
    /// picked out, the previews open on it, the trail of keys followed in it,
    /// and the analysis filter set on it.
    ///
    /// Per tab and in memory only. Per tab because looking at another search
    /// and coming back should find this one as it was left — the alternative
    /// is that switching tabs quietly undoes your place in both. In memory
    /// because none of it outlives the results it points into: the rows are
    /// fetched afresh for whichever tab is shown, so a row id saved to disk
    /// would name a list that no launch has yet built.
    private struct TabViewState {
        var selectedResultID: String?
        /// The kind a "More in …" opened, so its header offers the way back
        /// to every kind, where the reader clicked to leave.
        var kindOpenedFromAll: LampModuleKind?
        var previewedOccurrence: Int?
        var strongsTrail: [String] = []
        var strongsFilter: LampStrongsFilter?
        /// The analysis the filter above was chosen for. A filter means
        /// nothing for another key or another book range; it means exactly
        /// what it said for the one it was set on.
        var strongsFilterRequest: StrongsAnalysisLoader.Request?
    }

    @State private var tabViewState: [UUID: TabViewState] = [:]
    /// The toolbar's search field, put in focus when the page is waiting for
    /// a search, so typing starts one without a click.
    @FocusState private var isSearchFieldFocused: Bool

    private var selectedResultID: String? {
        get { tabViewState[tabs.selectedID]?.selectedResultID }
        nonmutating set { tabViewState[tabs.selectedID, default: TabViewState()].selectedResultID = newValue }
    }
    /// The occurrence whose preview is open, by reference. A Strong's search
    /// shows these rows rather than the module results, which is why fixing
    /// the other list did nothing for it.
    private var previewedOccurrence: Int? {
        get { tabViewState[tabs.selectedID]?.previewedOccurrence }
        nonmutating set { tabViewState[tabs.selectedID, default: TabViewState()].previewedOccurrence = newValue }
    }
    @State private var strongsLoader = StrongsAnalysisLoader()
    private var strongsFilter: LampStrongsFilter? {
        get { tabViewState[tabs.selectedID]?.strongsFilter }
        nonmutating set { tabViewState[tabs.selectedID, default: TabViewState()].strongsFilter = newValue }
    }
    /// The keys a companion was followed from, the last most recent: Back
    /// returns to it. Any other change of key — typed, from history, from a
    /// dictionary hit — starts again, so Back never leads somewhere the reader
    /// did not come from.
    private var strongsTrail: [String] {
        get { tabViewState[tabs.selectedID]?.strongsTrail ?? [] }
        nonmutating set { tabViewState[tabs.selectedID, default: TabViewState()].strongsTrail = newValue }
    }
    /// Set while a change of key comes from following or going back, which
    /// keeps the trail; read and cleared by the key's change handler.
    @State private var isWalkingStrongsTrail = false
    private var kindOpenedFromAll: LampModuleKind? {
        get { tabViewState[tabs.selectedID]?.kindOpenedFromAll }
        nonmutating set { tabViewState[tabs.selectedID, default: TabViewState()].kindOpenedFromAll = newValue }
    }

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

    /// The Highlights scope lists one's highlights with nothing typed, by
    /// their marks or every one, where other scopes wait for words.
    private var listsHighlights: Bool { selectedKind == .highlights }

    private var hasHighlightMarks: Bool {
        selectedKind == .highlights && tabs.selected.hasHighlightMarks
    }

    /// The marks chosen, as one value to watch.
    private struct ChosenMarks: Equatable {
        let colors: Set<String>
        let styles: Set<LampHighlightStyle>
        let themes: Set<LampHighlightMark>
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
                TextField("Date (YYYY-MM-DD or MM-DD)", text: field(\.devotionalDate))
                    .frame(width: 170)
                TextField("Tag", text: field(\.devotionalTag))
                    .frame(width: 110)
                TextField("Category", text: field(\.devotionalCategory))
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
        // Above the filters, because the filters belong to the tab: the rank
        // reads as what each page of filters is for.
        LibraryTabBar(
            items: tabs.tabs.map {
                LibraryTabStripItem(id: $0.id, title: searchTabTitle($0), isNamed: $0.name != nil)
            },
            selectedID: tabs.selectedID,
            select: { tabs.select($0) },
            close: { id in
                tabs.close(id)
                // What that tab was showing goes with it, so the
                // dictionary holds the open tabs and not every tab this
                // window ever had.
                tabViewState[id] = nil
            },
            duplicate: { settleTyping(); tabs.duplicate($0) },
            rename: { tabs.rename($0, to: $1) },
            move: { tabs.move($0, to: $1) },
            clearNameTitle: "Use the Search's Words",
            newTabHelp: "New search tab (⌘T)",
            newTab: { tabs.open() }
        )
        refineFilters
        devotionalFilters
        Group {
            if showsStrongsAnalysis {
                strongsAnalysis
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !hasActiveStrongsFilter && !hasHighlightMarks
                && !hasActiveDevotionalFilter && !listsHighlights {
                searchLanding
            } else if model.isModuleSearching && model.moduleSearchResults.isEmpty {
                ProgressView("Searching Library…")
            } else if model.moduleSearchResults.isEmpty {
                // The offer belongs here too: a key searched as words may find
                // nothing at all, which is exactly when being told the
                // analysis exists is most use.
                // The offers sit at the top, where the hits they stand in
                // for would have been. Left to centre themselves with the
                // empty state they floated halfway down an empty pane, far
                // from the field just typed in and reading as part of the
                // nothing found rather than as the way on from it.
                VStack(spacing: 0) {
                    referenceOffer
                    strongsAnalysisOffer
                    nothingFound
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
        .searchable(text: queryField, placement: .toolbar, prompt: "Search Library")
        .searchFocused($isSearchFieldFocused)
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
        // Each of these guards on isSwitchingTabs: selecting another tab
        // changes every filter at once, and a handler cannot tell that from
        // the reader editing one. The tab being shown runs its own search,
        // once, in the .task below.
        .onChange(of: tabbed(query)) { old, new in
            guard old.tab == new.tab else { return }
            runSearch()
        }
        // The tab hears about the typing once it stops. `.task(id:)` cancels
        // the waiting one for us on the next character, so the tab is written
        // once a word, not once a letter.
        .task(id: typing) {
            guard typing != nil else { return }
            try? await Task.sleep(for: Self.querySettles)
            guard !Task.isCancelled else { return }
            settleTyping()
        }
        // Switching tabs within the settling time would otherwise leave the
        // last few letters in a tab nobody is looking at, to be dropped when
        // the next keystroke replaced them.
        .onChange(of: tabs.selectedID) { _, _ in settleTyping() }
        // The pane is mounted only while Search is the section being shown,
        // so stepping to the Reader within the settling time would otherwise
        // destroy the pending text along with the view. Quitting is the same
        // loss by another route, and nothing else is listening for it.
        .onDisappear { settleTyping() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification
        )) { _ in settleTyping() }
        .onChange(of: tabbed(selectedKind)) { old, new in
            guard old.tab == new.tab else { return }
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
        .onChange(of: tabbed(selectedModuleID)) { old, new in
            guard old.tab == new.tab else { return }
            runSearch()
        }
        .onChange(of: tabbed(devotionalDate)) { old, new in
            guard old.tab == new.tab else { return }
            runSearch()
        }
        .onChange(of: tabbed(devotionalTag)) { old, new in
            guard old.tab == new.tab else { return }
            runSearch()
        }
        .onChange(of: tabbed(devotionalCategory)) { old, new in
            guard old.tab == new.tab else { return }
            runSearch()
        }
        .onChange(of: tabbed(bookScope)) { old, new in
            guard old.tab == new.tab else { return }
            runSearch()
        }
        // The tab on screen catches up with the selection after the update
        // in which it changed, so the handlers above see the mismatch for
        // exactly that update. A .task rather than another .onChange,
        // because onChange order between modifiers is not defined and this
        // one has to be last.
        // The results belong to whichever search ran last, since the model
        // holds one list, so the tab being shown asks for its own. Nothing
        // is cleared: what a tab was showing — its row, its previews, its
        // trail, its filter — is the tab's own and waits in tabViewState for
        // it to be looked at again.
        .task(id: tabs.selectedID) {
            runSearch()
            // Nothing here starts the analysis: `showsStrongsAnalysis` is
            // derived from the tab's own kind and key, and the loader's task
            // is keyed on the request those make, so a tab holding a key
            // shows its analysis by being shown. Calling `analyse` would have
            // been worse than redundant — it *writes* the kind, the key and
            // an empty query, so looking at a tab would have edited it, which
            // is the very thing `isSwitchingTabs` is here to prevent.
        }
        .onChange(of: tabbed(strongsKey)) { old, new in
            guard old.tab == new.tab else { return }
            let key = new.value
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
        .onChange(of: tabbed(ChosenMarks(colors: highlightColors, styles: highlightStyles, themes: highlightThemes))) {
            old, new in
            guard old.tab == new.tab else { return }
            runSearch()
        }
        .task(id: listsHighlights) {
            let sets = Set(((try? await model.library.highlightSets()) ?? []).map(\.id))
            if sets != personalHighlightSetIDs { personalHighlightSetIDs = sets }
            guard listsHighlights else { return }
            let loaded = await model.highlightThemesForSearch()
            if loaded != markThemes { markThemes = loaded }
        }
        .onChange(of: model.moduleSearchResults) { _, results in
            let colors = Set(results.compactMap { $0.kind == .highlights ? $0.highlightColor : nil })
            if !colors.isSubset(of: seenHighlightColors) { seenHighlightColors.formUnion(colors) }
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
                || hasActiveStrongsFilter || hasHighlightMarks
                || hasActiveDevotionalFilter || listsHighlights {
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

    /// A search that found nothing, and the ways on from it: the filters
    /// that narrowed it, each a button that lifts it, and the words a
    /// misspelling was probably meant to be.
    private var nothingFound: some View {
        var widenings: [SearchNothingFound.Widening] = []
        if let kind = selectedKind {
            widenings.append(.init(title: "Search All Content", detail: kind.displayName) { selectedKind = nil })
        }
        if selectedModuleID != nil {
            widenings.append(.init(title: "Search All Modules", detail: nil) { selectedModuleID = nil })
        }
        if bookScope != .all {
            widenings.append(.init(title: "Search All Books", detail: nil) { bookScope = .all })
        }
        let shown = query.isEmpty ? (hasActiveStrongsFilter ? strongsKey : markSummary ?? "Highlights") : query
        return SearchNothingFound(
            query: shown,
            widenings: widenings,
            suggestions: query.isEmpty ? [] : SearchNothingFound.spellingSuggestions(for: query),
            search: { setQuery($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Where a search starts: what can be searched, a few searches to try,
    /// and the ones made before. A blank page with one sentence on it gave
    /// nothing to start from, and a returning reader's history sat alone in
    /// a plain list.
    private var searchLanding: some View {
        SearchLanding(
            chosenKind: selectedKind,
            kinds: landingKinds,
            recents: Array(history.entries.prefix(6)),
            describe: historyDescription,
            icon: icon(for:),
            choose: { selectedKind = selectedKind == $0 ? nil : $0 },
            search: { setQuery($0) },
            restore: restore,
            clearHistory: { historyData = Data() },
            installModule: model.modules.isEmpty ? showImporter : nil
        )
        .onAppear {
            // Only where nothing is being typed. The landing comes back
            // whenever a filter stops narrowing — a date half typed — and
            // taking focus then sent the rest of the date into the search
            // field. AppKit's responder, not a focus flag, says what has it.
            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
            isSearchFieldFocused = true
        }
    }

    /// The kinds the library holds something of, in the Content menu's order.
    /// Writing, notes, plans, highlights and quizzes are the reader's own and
    /// always offered; a kind of module only once one is installed.
    private var landingKinds: [LampModuleKind] {
        let installed = Set(model.modules.map(\.kind))
        return LampModuleKind.allCases.filter { kind in
            switch kind {
            case .translation, .dictionary, .commentary, .book: installed.contains(kind)
            default: true
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
                    filter: strongsFilterField
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

    /// The way out of an analysis.
    ///
    /// A key followed from another key goes back to that one. The first key
    /// has no earlier key, but it does have the search it was opened from,
    /// and before this that left the analysis with no way out at all: the
    /// only one was the key field's clear button, which reads as emptying a
    /// field rather than as leaving. Clearing the key is still all it does,
    /// so where it lands depends on how the analysis was reached: from the
    /// key field, the words searched are untouched and their hits come back;
    /// from the "Analyse G26" offer, which clears the words as it takes up
    /// the key, it is the search landing. Both are the search as it was
    /// left.
    private var backFromStrongsAnalysis: StrongsAnalysisPane.Back {
        if let previous = strongsTrail.last {
            return StrongsAnalysisPane.Back(title: previous, go: goBackAlongStrongsTrail)
        }
        return StrongsAnalysisPane.Back(title: "Search", go: { strongsKey = "" })
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
                filter: strongsFilterField,
                analyse: followCompanion,
                // Search's own module picker is the choice of translation,
                // so opening another one sets it, where it can be undone.
                openIn: { selectedModuleID = $0 },
                bookRange: bookScope.range,
                narrowedToTranslations: selectedModuleID != nil,
                fontSize: hitFontSize,
                back: backFromStrongsAnalysis
            )
            strongsOccurrences
        }
        .task(id: strongsRequest) {
            // A rendering or chapter chosen for the last key means nothing
            // for this one — but this task also restarts when the reader
            // comes back to a tab, because the request is built from that
            // tab's own key, module and books. Returning to an analysis is
            // not a different analysis, so the filter is cleared only when
            // the request really did change for this tab.
            if tabViewState[tabs.selectedID]?.strongsFilterRequest != strongsRequest {
                strongsFilter = nil
                tabViewState[tabs.selectedID, default: TabViewState()]
                    .strongsFilterRequest = strongsRequest
            }
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
        // Opened in the translation being read, so read and named by its
        // book names too.
        let bookNames = model.bookNames(of: model.selectedTranslationID)
        if let reference = LampSearchQuery(query).reference(bookNames: bookNames) {
            Button {
                saveSearch()
                openReference(reference.startReference, nil)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "book").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Go to \(reference.description(bookNames: bookNames))").font(.headline)
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
        setQuery("")
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
                kindJumpBar(proxy)
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
                                    .id("group:\(group.id)")
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
        // A kind chosen any other way was not opened from every kind, so it
        // offers no way back there; the Content menu is the way out.
        .onChange(of: selectedKind) { _, kind in
            if kind != kindOpenedFromAll { kindOpenedFromAll = nil }
        }
    }

    static func isOriginalLanguage(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value)
                || (0x0590...0x05FF).contains($0.value)
        }
    }

    /// Every kind the search found, with how much of it, each a jump to its
    /// shelf. Across all content the first shelf, usually Scripture, filled
    /// the list, and nothing on screen said a dictionary or a commentary had
    /// matched at all until it was scrolled to.
    @ViewBuilder
    private func kindJumpBar(_ proxy: ScrollViewProxy) -> some View {
        let shelves = resultGroups.reduce(into: [SearchResultGroup]()) { kept, group in
            if !kept.contains(where: { $0.kind == group.kind }) { kept.append(group) }
        }
        if selectedKind == nil, shelves.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Named for what they do: they go to a shelf of these
                    // results, and choose nothing. Unnamed they read as a
                    // third way of setting the scope.
                    Text("Found in")
                        .font(.callout)
                        .foregroundStyle(Color.lampSecondaryText)
                        .padding(.trailing, 2)
                    ForEach(shelves) { group in
                        let count = resultGroups.filter { $0.kind == group.kind }.reduce(0) { $0 + $1.results.count }
                        let isCut = model.moduleSearchCutKinds.contains(group.kind)
                        Button {
                            // The shelf's first hit comes with it, so the
                            // detail beside the list is about what is shown.
                            selectedResultID = group.results.first?.id
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("group:\(group.id)", anchor: .top)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: icon(for: group.kind)).imageScale(.small)
                                Text(group.kind.displayName)
                                // A count only where it is the count: a kind
                                // cut short has more than it shows, and "15+"
                                // said less than nothing.
                                if !isCut {
                                    Text("\(count)")
                                        .foregroundStyle(Color.lampSecondaryText)
                                        .monospacedDigit()
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.lampTileFill))
                            .overlay(Capsule().strokeBorder(Color.lampCardStroke))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Jump to \(group.kind.displayName)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.lampCardStroke).frame(height: 1)
            }
        }
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

    /// Whether a group's header offers the way back to every kind: the kind
    /// shown was opened from its "More in …", and this is its first shelf.
    /// Chosen from the Content menu instead, it was not come to from
    /// anywhere, and the menu is the way out.
    private func offersWayBack(_ group: SearchResultGroup) -> Bool {
        selectedKind != nil && kindOpenedFromAll == selectedKind
            && resultGroups.first?.id == group.id
    }

    /// Whether a group is its kind's only shelf. Scripture has one per
    /// translation, and a "+" on one of several would claim the more were
    /// that translation's; with one, they are.
    private func isOnlyShelf(of group: SearchResultGroup) -> Bool {
        resultGroups.filter { $0.kind == group.kind }.count == 1
    }

    private func resultGroupHeader(_ group: SearchResultGroup, offersMore: Bool) -> some View {
        // Two lines: what the shelf is and how much, with the way deeper or
        // back; then where it came from. On one line the count, the
        // translation note, More and the module ran together.
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(for: group.kind))
                    .foregroundStyle(.tint)
                    .imageScale(.small)
                Text(group.kind.displayName)
                    .lampSectionHeading()
                    .font(.subheadline.weight(.semibold))
                Text(resultCountDescription(
                    group, isCut: model.moduleSearchCutKinds.contains(group.kind) && isOnlyShelf(of: group)
                ))
                    .font(.subheadline)
                    .foregroundStyle(Color.lampSecondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 8)
                groupHeaderAction(group, offersMore: offersMore)
            }
            let source = [group.moduleName, scriptureNote(group).isEmpty ? nil : String(scriptureNote(group).dropFirst(3))]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !source.isEmpty {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
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

    @ViewBuilder
    private func groupHeaderAction(_ group: SearchResultGroup, offersMore: Bool) -> some View {
        if offersMore {
            // The kind filter is the deeper page: it searches that kind
            // alone, the whole page of it, rather than cutting from here.
            // A control, so the accent: the link blue is for what text
            // takes you to (ColorRules.md).
            Button {
                selectedKind = group.kind
                kindOpenedFromAll = group.kind
            } label: {
                HStack(spacing: 2) {
                    Text("More in \(group.kind.displayName)")
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.lampText)
            .help("Show only \(group.kind.displayName), searched in full")
        } else if offersWayBack(group) {
            // Where "More in …" was, so the way back is under the pointer
            // that came.
            Button {
                selectedKind = nil
                kindOpenedFromAll = nil
            } label: {
                Label("All Results", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Back to the results from every kind")
        }
    }

    /// After Scripture's count on the page of every kind, where its verses
    /// came from one translation: " · none in BSB" when that is not the
    /// reading translation, and " · also in 9 other translations".
    private func scriptureNote(_ group: SearchResultGroup) -> String {
        guard group.kind == .translation, let scripture = model.moduleSearchScripture,
              group.results.first?.moduleID == scripture.translationID else { return "" }
        var note = ""
        if let reading = scripture.readingTranslationID, reading != scripture.translationID {
            note += " · none in \(shortName(of: reading))"
        }
        switch scripture.alsoIn.count {
        case 0: break
        case 1: note += " · also in \(shortName(of: scripture.alsoIn[0]))"
        case let count: note += " · also in \(count) other translations"
        }
        return note
    }

    /// A translation's abbreviation where it has one, else its name.
    private func shortName(of id: String) -> String {
        let module = model.modules.first { $0.id == id }
        return module?.abbreviation ?? module?.name ?? id
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
                if result.kind == .highlights, let hex = result.highlightColor {
                    Image(nsImage: ReaderHighlighter.markImage(color: hex, style: result.highlightStyle ?? .highlight))
                }
                // A Greek or Hebrew headword in a face and size its points
                // read at: at 13.5pt a vav with its sheva read as "!".
                Text(result.title)
                    .font(Self.isOriginalLanguage(result.title)
                        ? .system(size: 17, weight: .regular, design: .serif)
                        : .system(size: isScripture ? 14 : 13.5, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if showsModule {
                    Text(shortName(of: result.moduleID) == result.moduleID ? result.moduleName : shortName(of: result.moduleID))
                        .help(result.moduleName)
                        .font(.subheadline)
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
            }
            snippetText(for: result)
                .font(.system(size: isScripture ? hitFontSize : max(13, hitFontSize - 3)))
                .lineSpacing(isScripture ? 2 : 5)
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
        // A click selects the result, and the detail pane beside the list
        // shows it, a verse among its neighbours. It opened a popover over
        // that pane as well, saying the same thing twice.
        .onTapGesture {
            selectedResultID = result.id
        }
        .contextMenu {
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
                    if result.kind == .dictionary, let key = lexiconKey(of: result) {
                        SearchDictionaryTitle(key: key, moduleID: result.moduleID, title: result.title)
                            .id(result.id)
                    } else {
                        Text(result.title)
                            .font(.system(size: 28, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    // Where the words stand in the entry, before the entry:
                    // a long article can hold them pages down, and without
                    // this the hit looked unrelated to what was searched.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Where \u{201C}\(query)\u{201D} appears")
                            .lampSectionHeading()
                            .font(.caption.weight(.semibold))
                        snippetText(for: result)
                            .font(.system(size: detailFontSize - 3, design: .serif))
                            .lineSpacing(3)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.lampCardFill))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.lampCardStroke))
                    SearchDictionaryEntry(key: key, moduleID: result.moduleID) {
                        snippetText(for: result)
                            .font(.system(size: detailFontSize - 1, design: detailDesign(for: result.kind)))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .environment(\.lampSearchHighlight, query)
                    .id(result.id)
                } else if result.kind == .commentary {
                    SearchCommentaryHit(result: result, query: query, fontSize: detailFontSize) {
                        snippetText(for: result)
                            .font(.system(size: detailFontSize - 1, design: .serif))
                            .lineSpacing(detailFontSize * 0.4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(result.id)
                } else {
                    snippetText(for: result)
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
            // A highlight found can be taken off here, without going to it.
            if result.kind == .highlights, personalHighlightSetIDs.contains(result.moduleID),
               let reference = result.startReference,
               let id = result.id.split(separator: ":").last.flatMap({ Int64($0) }) {
                Button("Remove Highlight", systemImage: "eraser") {
                    Task {
                        do {
                            try await model.deleteVerseHighlight(id: id, reference: reference)
                            runSearch()
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
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
            Button("Copy", systemImage: "doc.on.doc") { copy(result) }
                .buttonStyle(.bordered)
            // How much of the chapter the passage above shows, set here
            // where it is read; it was a button opening the same passage
            // again in a popover, which had the setting.
            if previewTranslation(of: result) != nil {
                Spacer(minLength: 12)
                Stepper(
                    "Context: \(previewContext) verse\(previewContext == 1 ? "" : "s")",
                    value: $previewContext,
                    in: 0...10
                )
                .controlSize(.large)
                .font(.body)
                .foregroundStyle(Color.lampSecondaryText)
                .fixedSize()
            }
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
                // A lexicon entry's key, named beside the lexicon it is in.
                if result.kind == .dictionary, let key = lexiconKey(of: result) {
                    Text("·")
                    Text(key).monospacedDigit()
                }
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
            Picker("Content", selection: field(\.kind)) {
                Text("All Content").tag(LampModuleKind?.none)
                ForEach(LampModuleKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .frame(minWidth: 130, maxWidth: 160)
        }

        ToolbarItem {
            Picker("Module", selection: field(\.moduleID)) {
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
                        Picker("Books", selection: bookScopeField) {
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
                        Text("Strong’s")
                            .foregroundStyle(Color.lampSecondaryText)
                        // A field drawn as one, inside the chip: as a bare
                        // placeholder it read as a label, not a place to type.
                        TextField(
                            "Strong's key",
                            text: field(\.strongsKey),
                            prompt: Text("G26 or H430")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
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
                    highlightMarkPicker
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
            highlightColors: hasHighlightMarks ? highlightColors : nil,
            highlightStyles: hasHighlightMarks ? highlightStyles : nil,
            highlightThemes: hasHighlightMarks ? highlightThemes : nil,
            listsHighlights: listsHighlights,
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
                highlightColors: hasHighlightMarks ? highlightColors : nil,
                highlightStyles: hasHighlightMarks ? highlightStyles : nil,
                highlightThemes: hasHighlightMarks ? highlightThemes : nil,
                devotionalCriteria: devotionalCriteria
            ),
            resultCount: showsStrongsAnalysis
                ? (strongsLoader.analyses.first?.occurrenceCount ?? 0)
                : model.moduleSearchResults.count
        )
        if kept { historyData = history.encoded() }
    }

    /// A stored module ID as this library holds it.
    ///
    /// Unresolvable ids are kept, not dropped. `held` answers nil for
    /// anything it cannot place, and a search's filter names more than
    /// installed modules — a highlight set's UUID, "personal-notes",
    /// "personal-devotionals" — so returning its answer directly threw those
    /// away and a restored search widened to everything.
    private func heldModuleID(_ stored: String?) -> String? {
        guard let stored else { return nil }
        return LampTranslationID.held(stored, among: model.installedTranslationIDs) ?? stored
    }

    /// Puts back every filter the search ran with, not only its words.
    ///
    /// A saved search holds the module IDs as they were when it ran, so an
    /// entry older than the translation rename names "ESVs". Resolved here,
    /// at the one place a saved entry enters the pane, rather than wherever
    /// the id is later compared.
    private func restore(_ entry: LampSearchHistory.Entry) {
        selectedKind = entry.kinds?.first
        selectedModuleID = heldModuleID(entry.moduleIDs?.first)
        strongsKey = entry.strongsKey ?? ""
        highlightColors = Set((entry.highlightColors ?? []).map(LampHighlightSearch.normalizedColor))
        highlightStyles = entry.highlightStyles ?? []
        highlightThemes = entry.highlightThemes ?? []
        if let range = entry.bookRange,
           let scope = BookSearchScope.allCases.first(where: { $0.range == range }) {
            bookScope = scope
        }
        devotionalDate = entry.devotionalCriteria?.date
            ?? entry.devotionalCriteria?.monthDay ?? ""
        devotionalTag = entry.devotionalCriteria?.tags?.first ?? ""
        devotionalCategory = entry.devotionalCriteria?.categories?.first ?? ""
        // Last, because every assignment above runs a search of its own.
        setQuery(entry.query)
    }

    private func historyDescription(_ entry: LampSearchHistory.Entry) -> String {
        if let moduleID = heldModuleID(entry.moduleIDs?.first),
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

    /// A result's words. A highlight's are marked as the highlight itself
    /// is, in its own colour and style: the yellow of a found word, over a
    /// green or pink highlight or a dotted line, said the opposite of what
    /// it was.
    private func snippetText(for result: LampModuleSearchResult) -> Text {
        guard result.kind == .highlights, let hex = result.highlightColor,
              let color = NSColor(Color(lampHex: hex) ?? .yellow).usingColorSpace(.sRGB) else {
            return snippetText(result.snippet)
        }
        let mark: LampTextMark = switch result.highlightStyle ?? .highlight {
        case .highlight: .ground(Color(nsColor: ReaderHighlightGrounds.ground(for: color)))
        case .underlineSolid: .underline(Color(nsColor: color), .solid)
        case .underlineDashed: .underline(Color(nsColor: color), .dash)
        case .underlineDotted: .underline(Color(nsColor: color), .dot)
        }
        return Text.lampMarked(result.snippet, mark: mark)
    }

    /// What highlights are found by: themes, colours and styles, several at
    /// once. Colours and styles narrow together; a theme is found besides
    /// them (`LampHighlightSearch.matches`). Many themes go in a menu of
    /// their own, as the reader's do.
    private var highlightMarkPicker: some View {
        Menu {
            if hasHighlightMarks {
                Button("Any Mark") {
                    highlightColors = []
                    highlightStyles = []
                    highlightThemes = []
                }
                Divider()
            }
            if !markThemes.isEmpty {
                if markThemes.count > 6 {
                    Menu("Themes") { themeToggles }
                } else {
                    Text("Themes")
                    themeToggles
                }
                Divider()
            }
            Text("Colours")
            ForEach(markColors, id: \.hex) { swatch in
                Toggle(isOn: chosen(swatch.hex, in: \.highlightColors)) {
                    Label {
                        Text(swatch.name)
                    } icon: {
                        Image(nsImage: ReaderHighlighter.markImage(color: swatch.hex, style: .highlight))
                    }
                }
            }
            Divider()
            Text("Styles")
            ForEach(LampHighlightStyle.allCases, id: \.self) { style in
                Toggle(isOn: chosen(style, in: \.highlightStyles)) {
                    Label {
                        Text(ReaderHighlightPalette.name(style))
                    } icon: {
                        Image(nsImage: ReaderHighlighter.markImage(color: "8E8E93", style: style))
                    }
                }
            }
        } label: {
            Label {
                Text(markSummary ?? "Any Mark")
            } icon: {
                if let image = markSummaryImage {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "highlighter")
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Find highlights by theme, colour or style")
    }

    @ViewBuilder
    private var themeToggles: some View {
        ForEach(markThemes) { theme in
            Toggle(isOn: chosen(LampHighlightMark(color: theme.color, style: theme.style), in: \.highlightThemes)) {
                Label {
                    Text(theme.name)
                } icon: {
                    Image(nsImage: ReaderHighlighter.themeImage(theme))
                }
            }
        }
    }

    /// Whether one mark is chosen, as a menu's toggle.
    private func chosen<Mark: Hashable>(_ mark: Mark, in field: WritableKeyPath<SearchTab, Set<Mark>>) -> Binding<Bool> {
        Binding(
            get: { tabs.selected[keyPath: field].contains(mark) },
            set: { isOn in
                tabs.updateSelected { tab in
                    if isOn { tab[keyPath: field].insert(mark) } else { tab[keyPath: field].remove(mark) }
                }
            }
        )
    }

    /// The palette's colours, then any other a theme is made in or a
    /// highlight found wears, each as core spells it.
    private var markColors: [(hex: String, name: String)] {
        var colors = StudyHighlightPalette.colors.map {
            (hex: LampHighlightSearch.normalizedColor($0.hex), name: $0.name)
        }
        let others = markThemes.map(\.color) + seenHighlightColors.sorted() + highlightColors.sorted()
        for other in others.map(LampHighlightSearch.normalizedColor) where !colors.contains(where: { $0.hex == other }) {
            colors.append((other, "#\(other)"))
        }
        return colors
    }

    /// The marks chosen, in words: one or two by name, more by count.
    private var markSummary: String? {
        guard hasHighlightMarks else { return nil }
        let themes = highlightThemes.map { mark in
            markThemes.first { $0.color == mark.color && $0.style == mark.style }?.name
                ?? ReaderHighlightPalette.name(mark.style)
        }.sorted()
        let colors = highlightColors.map { hex in
            markColors.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name ?? "#\(hex)"
        }.sorted()
        let styles = LampHighlightStyle.allCases.filter(highlightStyles.contains).map(ReaderHighlightPalette.name)
        let names = themes + colors + styles
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) Marks"
    }

    /// The one mark chosen, drawn; nil for none or several.
    private var markSummaryImage: NSImage? {
        guard hasHighlightMarks else { return nil }
        if highlightThemes.count == 1, highlightColors.isEmpty, highlightStyles.isEmpty, let mark = highlightThemes.first {
            return ReaderHighlighter.markImage(color: mark.color, style: mark.style)
        }
        guard highlightThemes.isEmpty, highlightColors.count <= 1, highlightStyles.count <= 1 else { return nil }
        return ReaderHighlighter.markImage(
            color: highlightColors.first ?? "8E8E93", style: highlightStyles.first ?? .highlight
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
    @Binding var context: Int
    let open: () -> Void
    /// The panel's text, as every verse preview has: see `StudyPanelText`.
    private var panel = StudyPanelText()
    private var fontSize: Double { panel.fontSize }

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
                            .font(panel.font())
                            .lineSpacing(panel.lineSpacing)
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
        font(.callout)
            .padding(.horizontal, 11)
            .frame(height: 30)
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

extension UnifiedSearchView {
    /// What a tab is called: the name the reader gave it, else the words it
    /// is searching for, else the key or colour it is filtered by, else the
    /// kind it is narrowed to — and "New Search" for a tab with nothing in
    /// it yet. A tab is named after what you would recognise it by.
    func searchTabTitle(_ tab: SearchTab) -> String {
        if let name = tab.name { return name }
        let words = tab.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { return words }
        let key = tab.strongsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        if tab.hasHighlightMarks { return "Highlights" }
        if !tab.devotionalDate.isEmpty { return tab.devotionalDate }
        if !tab.devotionalTag.isEmpty { return tab.devotionalTag }
        if !tab.devotionalCategory.isEmpty { return tab.devotionalCategory }
        if let kind = tab.kind { return kind.displayName }
        return "New Search"
    }
}



// MARK: - Landing, nothing found, and hits shown in full

/// The search page before anything is typed.
private struct SearchLanding: View {
    let chosenKind: LampModuleKind?
    let kinds: [LampModuleKind]
    let recents: [LampSearchHistory.Entry]
    let describe: (LampSearchHistory.Entry) -> String
    let icon: (LampModuleKind) -> String
    let choose: (LampModuleKind) -> Void
    let search: (String) -> Void
    let restore: (LampSearchHistory.Entry) -> Void
    let clearHistory: () -> Void
    let installModule: (() -> Void)?

    /// Searches that show what the field takes: a word, a passage, a
    /// Strong's number and a phrase. Each finds something in any library
    /// with a Bible in it.
    private static let examples: [(text: String, icon: String)] = [
        ("grace", "textformat"),
        ("John 3:16", "book"),
        ("G26", "number"),
        ("love one another", "text.quote"),
    ]

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(chosenKind.map { "Search \($0.displayName)" } ?? "Search Your Library")
                        .font(.system(size: 26, weight: .bold))
                    Text("Start typing to search: a word, a phrase, a passage or a Strong’s number.")
                        .font(.title3)
                        .foregroundStyle(Color.lampSecondaryText)
                }

                if let installModule {
                    Button("Install a Module…", action: installModule)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }

                if !recents.isEmpty {
                    section("Recent Searches", trailing: AnyView(
                        Button("Clear", action: clearHistory)
                            .buttonStyle(.lampText)
                            .font(.subheadline)
                            .help("Clear search history")
                    )) {
                        VStack(spacing: 0) {
                            ForEach(Array(recents.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider().padding(.leading, 44) }
                                LandingRow(
                                    icon: "clock.arrow.circlepath",
                                    title: entry.query.isEmpty ? describe(entry) : entry.query,
                                    detail: describe(entry)
                                ) { restore(entry) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.lampRaisedTile))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.13)))
                    }
                }

                section("Try") {
                    HStack(spacing: 8) {
                        ForEach(Self.examples, id: \.text) { example in
                            Button { search(example.text) } label: {
                                Label(example.text, systemImage: example.icon)
                                    .font(.callout)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.lampTileFill))
                                    .overlay(Capsule().strokeBorder(Color.lampCardStroke))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Search for \(example.text)")
                        }
                    }
                }

                section("Search In") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(kinds, id: \.self) { kind in
                            KindTile(
                                kind: kind,
                                icon: icon(kind),
                                blurb: Self.blurb(for: kind),
                                isChosen: chosenKind == kind
                            ) { choose(kind) }
                        }
                    }
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            // Centred in the pane where it fits, a little above the middle,
            // rather than hung from the top over an empty lower half.
            .frame(maxWidth: .infinity, minHeight: geometry.size.height * 0.88)
        }
        }
    }

    private func section<Content: View>(
        _ title: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .lampSectionHeading()
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    static func blurb(for kind: LampModuleKind) -> String {
        switch kind {
        case .translation: "Verses in every translation"
        case .dictionary: "Lexicons and Strong’s entries"
        case .commentary: "Notes on the passage"
        case .book: "The books in your library"
        case .devotional: "Studies you have written"
        case .notes: "Your notes on verses"
        case .plan: "Plans and their readings"
        case .highlights: "Verses you have marked"
        case .quiz: "Questions and answers"
        }
    }

    private struct LandingRow: View {
        let icon: String
        let title: String
        let detail: String
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .foregroundStyle(Color.lampSecondaryText)
                        .frame(width: 20)
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isHovered ? Color.lampRowHover : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }
    }

    private struct KindTile: View {
        let kind: LampModuleKind
        let icon: String
        let blurb: String
        let isChosen: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.lampTileFill))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.displayName)
                            .font(.body.weight(.semibold))
                        Text(blurb)
                            .font(.subheadline)
                            .foregroundStyle(Color.lampSecondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isHovered ? Color.lampRowHover : Color.lampRaisedTile)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isChosen ? Color.accentColor : Color.primary.opacity(0.13), lineWidth: isChosen ? 1.5 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(isChosen ? "Search everything again" : "Search only \(kind.displayName)")
            .accessibilityAddTraits(isChosen ? .isSelected : [])
        }
    }
}

/// A search that found nothing.
private struct SearchNothingFound: View {
    struct Widening: Identifiable {
        let title: String
        let detail: String?
        let action: () -> Void
        var id: String { title }
    }

    let query: String
    let widenings: [Widening]
    let suggestions: [String]
    let search: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.lampSecondaryText)
            Text("No Results for \u{201C}\(query)\u{201D}")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(hint)
                .font(.title3)
                .foregroundStyle(Color.lampSecondaryText)
                .multilineTextAlignment(.center)
            if !suggestions.isEmpty {
                HStack(spacing: 8) {
                    Text("Did you mean")
                        .foregroundStyle(Color.lampSecondaryText)
                    ForEach(suggestions, id: \.self) { word in
                        Button(word) { search(word) }
                            .buttonStyle(.lampText)
                            .fontWeight(.semibold)
                    }
                }
                .font(.title3)
            }
            if !widenings.isEmpty {
                HStack(spacing: 10) {
                    ForEach(widenings) { widening in
                        Button(widening.title, action: widening.action)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: 520)
        .padding(.top, 110)
        .padding(.horizontal, 32)
    }

    private var hint: String {
        if let kind = widenings.first?.detail {
            return "Nothing in \(kind) matched. Searching everything may find it."
        }
        if !widenings.isEmpty { return "Nothing matched with these filters." }
        return "Check the spelling, or try fewer or different words."
    }

    /// The system speller's guesses for a single misspelt word. A phrase,
    /// a reference or a number is not guessed at.
    static func spellingSuggestions(for query: String) -> [String] {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 3, !word.contains(" "), word.allSatisfy(\.isLetter) else { return [] }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = checker.guesses(forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: 0) ?? []
        return Array(guesses.filter { $0.caseInsensitiveCompare(word) != .orderedSame }.prefix(3))
    }
}

/// A dictionary hit's heading: the headword at a size its script reads at,
/// with how it is said and what it means. A Hebrew word of one letter and
/// its points, set as the title alone, read as a lone "!".
private struct SearchDictionaryTitle: View {
    let key: String
    let moduleID: String
    let title: String

    @EnvironmentObject private var model: LibraryModel
    @State private var entry: LampDictionaryResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: isShortHeadword ? .center : .firstTextBaseline, spacing: 14) {
                // A word of a letter or two set on a tile of its own, so it
                // has the weight of a heading rather than floating alone.
                if isShortHeadword {
                    Text(entry?.lemma ?? title)
                        .font(.system(size: 38, design: .serif))
                        .frame(width: 60, height: 60)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.lampTileFill))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.lampCardStroke))
                } else {
                    Text(entry?.lemma ?? title)
                        .font(.system(size: isOriginalLanguage ? 44 : 28, weight: isOriginalLanguage ? .regular : .bold, design: isOriginalLanguage ? .serif : .default))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let transliteration = entry?.transliteration, !transliteration.isEmpty {
                    Text(transliteration)
                        .font(.system(size: 20, design: .serif).italic())
                        .foregroundStyle(Color.lampSecondaryText)
                }

            }
            if let gloss {
                Text(gloss)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(moduleID)|\(key)") {
            entry = (try? await model.library.dictionaryEntries(keys: [key], moduleIDs: [moduleID]))?.first
        }
    }

    private var isShortHeadword: Bool {
        isOriginalLanguage && (entry?.lemma ?? title).count <= 3
    }

    private var isOriginalLanguage: Bool {
        (entry?.lemma ?? title).unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) || (0x0590...0x05FF).contains($0.value) }
    }

    private var gloss: String? {
        guard let sense = entry?.senses.first else { return nil }
        let text = sense.gloss ?? sense.shortDefinition
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A commentary hit in its whole comment: the passage it is on, then the
/// comment with the searched words marked. It showed the row's excerpt
/// again, larger, over an empty pane.
private struct SearchCommentaryHit<Fallback: View>: View {
    let result: LampModuleSearchResult
    let query: String
    let fontSize: Double
    @ViewBuilder let fallback: () -> Fallback

    @EnvironmentObject private var model: LibraryModel
    @State private var unit: LampCommentaryUnit?
    @State private var verse: String?
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let verse, let reference = result.startReference {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LampBibleReferenceFormatter.describeRange(from: reference, to: result.endReference ?? reference))
                        .lampSectionHeading()
                        .font(.caption.weight(.semibold))
                    Text(verse)
                        .font(.system(size: fontSize, design: .serif))
                        .lineSpacing(fontSize * 0.35)
                        .foregroundStyle(Color.lampSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.lampCardStroke).frame(width: 3)
                }
            }
            if let text = unitText {
                Text.lampMarked(LampSearchQuery(query).markedSnippet(text, limit: .max))
                    .font(.system(size: fontSize, design: .serif))
                    .lineSpacing(fontSize * 0.4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasLoaded {
                fallback()
            }
        }
        .task(id: result.id) { await load() }
    }

    private var unitText: String? {
        guard let unit else { return nil }
        let parts = [unit.introduction, unit.translation, unit.commentary, unit.footnotes]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func load() async {
        defer { hasLoaded = true }
        let prefix = "commentary:\(result.moduleID):"
        guard result.id.hasPrefix(prefix), let reference = result.startReference else { return }
        let unitID = String(result.id.dropFirst(prefix.count))
        let place = LampBibleReferenceFormatter.components(of: reference)
        let units = (try? await model.library.commentary(
            bookNumber: place.book, chapterNumber: place.chapter, moduleIDs: [result.moduleID]
        )) ?? []
        unit = units.first { $0.unitID == unitID }
        let parts = LampBibleReferenceFormatter.components(of: reference)
        let last = LampBibleReferenceFormatter.components(of: result.endReference ?? reference)
        if let translationID = model.selectedTranslationID,
           let chapterRead = try? await model.library.chapter(
            moduleID: translationID,
            bookNumber: parts.book,
            chapterNumber: parts.chapter
        ) {
            // The passage commented on, up to three verses of it.
            let upTo = last.chapter == parts.chapter ? min(last.verse, parts.verse + 2) : parts.verse + 2
            let shown = chapterRead.verses.filter { $0.number >= parts.verse && $0.number <= upTo }
            if !shown.isEmpty { verse = shown.map(\.text).joined(separator: " ") }
        }
    }
}


extension EnvironmentValues {
    /// The words a search detail is showing a hit for, which a dictionary
    /// entry marks where they stand in it. Nil everywhere else.
    @Entry var lampSearchHighlight: String? = nil
}

extension AttributedString {
    /// Marks each place `query` matches, as a find match, by core's rule
    /// for what a search's words match (`LampSearchQuery.matchRanges`): the
    /// words the hit's snippet marked, quoted, starred or typed.
    mutating func lampMarkMatches(of query: String) {
        let ranges = LampSearchQuery(query).matchRanges(in: String(characters))
        let count = characters.count
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= count && !range.isEmpty {
            let lower = characters.index(startIndex, offsetBy: range.lowerBound)
            let upper = characters.index(lower, offsetBy: range.count)
            self[lower..<upper].backgroundColor = .lampFindMatch
            // A link keeps its own colour, the role it is followed by;
            // only plain words take the match's ink.
            for run in self[lower..<upper].runs where run.link == nil {
                self[run.range].foregroundColor = .lampOnFindMatch
            }
        }
    }
}
