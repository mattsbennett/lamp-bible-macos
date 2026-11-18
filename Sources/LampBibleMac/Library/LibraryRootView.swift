import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

private enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case reader = "Reader"
    case books = "Books"
    case plans = "Reading Plans"
    case devotionals = "Writing"
    case quizzes = "Quizzes"
    case search = "Search"
    case modules = "Modules"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .today: "calendar"
        case .reader: "book"
        case .books: "book.closed"
        case .plans: "checklist"
        case .devotionals: "sun.max"
        case .quizzes: "questionmark.bubble"
        case .search: "magnifyingglass"
        case .modules: "square.stack.3d.up"
        }
    }
}

private extension LampDeepLinkSection {
    var displayName: String {
        switch self {
        case .today: "Today"
        case .reader: "Reader"
        case .books: "Books"
        case .plans: "Reading Plans"
        case .devotionals: "Writing"
        case .quizzes: "Quizzes"
        case .search: "Search"
        case .modules: "Modules"
        }
    }
}

/// Where the sidebar is pointing.
///
/// Translations were listed here too, and choosing one simply switched the
/// reader's translation — the same thing the reader's own picker does, in a
/// list whose other rows are places to go rather than things to set.
private enum LibrarySelection: Hashable {
    case section(LibrarySection)
}

struct LibraryRootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// ⌘K: the palette that goes anywhere in Lamp, over this window.
    @State private var showingCommandPalette = false
    /// The decks the palette can open by name, read as it opens.
    @State private var paletteDecks: [LampPresentationDeck] = []
    /// Whether this window is the one being used, which is how the library
    /// knows whose place to hand to the writing editor and Slide Studio.
    @Environment(\.controlActiveState) private var controlActiveState
    @EnvironmentObject private var model: LibraryModel
    /// This window's own place in scripture. Each reader window has one, which
    /// is what lets two of them sit on different chapters.
    // The reader's settings, for the window's reader toolbar.
    @AppStorage("reader.fontSize") private var fontSize = LampTextScale.readerText.defaultValue
    @AppStorage("reader.lineSpacing") private var lineSpacing = LampTextScale.readerLineSpacing.defaultValue
    @AppStorage("reader.typeface") private var typeface = ProseTypeface.readerDefault
    @AppStorage("reader.layoutMode") private var readerLayoutMode = ReaderLayoutMode.continuousParagraphs
    @AppStorage("reader.layoutModeBeforeSideBySide") private var layoutModeBeforeSideBySide =
        ReaderLayoutMode.continuousParagraphs
    @AppStorage("reader.readAloud.rate") private var readAloudRate = 0.5
    /// The window's reader tabs kept laid out (`ReaderTabPool`). The window's
    /// reader is the current tab's.
    @StateObject private var readerPool = ReaderTabPool()
    private var workspace: ReaderWorkspace { readerPool.current }
    @EnvironmentObject private var syncController: LibrarySyncController
    /// The window's own: its reader and its study pane scroll together,
    /// and another window's must not move them.
    @StateObject private var scrollLink = ReaderScrollLink()
    @State private var selection: LibrarySelection? = .section(.reader)
    /// The search's own query, so the reader's reference field can hand words
    /// to it. The same key the search reads, in the same scene.
    /// A passage waiting for the reader to say which Bible app to open it in,
    /// because they chose "Ask Each Time".
    @State private var externalBibleRequest: ExternalBibleRequest?
    @State private var showingImporter = false
    @State private var showingStudyDataImporter = false
    @State private var readerTabs = ReaderTabCollection()
    @State private var hasRestoredReaderTabs = false
    /// The window's searches, kept under the same session as its reader tabs
    /// (`SearchTabSessionStore`). Not `@SceneStorage`, which a clean quit
    /// wipes — remembering them past a relaunch is most of the point.
    @State private var searchTabs = SearchTabCollection()
    @State private var hasRestoredSearchTabs = false
    /// Whether this window is picking up where the app left off, which decides
    /// whether it opens on the last tabs any window saved or on a fresh one.
    @State private var isResumingReaderSession = false
    @State private var readerSidebar: ReaderSidebar?
    /// Whether AI features are shown (`AIFeatures`). Off, the reader's chat
    /// has no button, no shortcut and no pane, and no conversation is taken
    /// up or started; the chats on disk are kept for when it is on again.
    @AppStorage(AIFeatures.key) private var aiFeaturesEnabled = AIFeatures.defaultValue
    /// Whether this window has taken up the chats its tabs remember. Once
    /// only: they stay this window's while AI is off, and taking them again
    /// would find them held — by this window — and forget them.
    @State private var hasAdoptedRestoredChats = false
    @State private var lastReaderSidebar = ReaderSidebar.study
    /// The session this window keeps its tabs under, taken up once the library
    /// has been read. The chats are the tabs' own; see `ReaderTab.chatID`.
    ///
    /// This was `@SceneStorage`, which AppKit keeps in saved application state.
    /// That state is deleted on a clean quit unless the reader has turned off
    /// "Close windows when quitting an application", so on most Macs every
    /// launch invented an identifier, and with it an empty workspace, while the
    /// conversation from before sat in a folder nothing would ever open again.
    @State private var readerSession: UUID?
    @State private var requestedBookID: String?
    /// The item a search result asked for, handed to the section that shows
    /// it. Cleared by that view once taken, so returning later does not jump
    /// back to it.
    @State private var requestedDevotionalID: String?
    @State private var requestedPlanID: String?
    @State private var requestedQuizModuleID: String?
    @State private var requestedBookSectionID: String?
    @State private var isReaderSidebarMounted = false
    /// How much of the study column is on screen, in points. The single animated
    /// value behind the whole transition: it sets the reader's width, the gap, and
    /// the pane's opacity, so those three cannot disagree.
    @State private var readerSidebarRevealedWidth: Double = 0
    @State private var isReaderSidebarContentReady = false
    @State private var isReaderSidebarTransitioning = false
    @State private var planReadingMode: PlanReadingMode?
    // Keep hover mutations out of this view's observation graph. Only the small
    // readout observes the store, so moving between words cannot rebuild the
    // reader's selectable text hierarchy underneath the pointer.
    @State private var readerLexicalHoverStore = ReaderLexicalHoverStore()
    @AppStorage("studyInspector.width") private var studyInspectorWidth = StudyInspectorMetrics.defaultWidth
    /// The study tool last chosen in any tab, which a tab that has never
    /// chosen one starts on. Each tab's own is kept with the tab.
    @AppStorage("studyInspector.tab") private var lastStudyTool = "commentary"
    /// The open tab's study pane, written back to the tab as it changes.
    /// The window's study pane: the current tab's, kept with it.
    private var studyPane: StudyPaneState { readerPool.currentStudyPane }
    /// Set when moving to a tab whose column is open where this one's was
    /// shut, or the reverse: the column is that tab's, so it is simply there
    /// or not, rather than sliding in as if just asked for.
    @State private var readerSidebarSwitchesInstantly = false

    private var showingStudyInspector: Binding<Bool> {
        Binding(
            get: { readerSidebar == .study },
            set: { if $0 { readerSidebar = .study } else if readerSidebar == .study { readerSidebar = nil } }
        )
    }

    private var showingReaderChat: Binding<Bool> {
        Binding(
            get: { aiFeaturesEnabled && readerSidebar == .chat },
            set: {
                if $0, aiFeaturesEnabled { readerSidebar = .chat } else if readerSidebar == .chat { readerSidebar = nil }
            }
        )
    }

    var body: some View {
        // The interface arrives at once, under the splash, and only the splash
        // fades. An animation on the switch itself also animated the
        // interface's first layout: the reader's text slid out from under the
        // sidebar and its tab in from nothing, so the tab had no title until
        // the slide was over.
        ZStack {
            if model.hasLoadedInitialContent {
                libraryInterface
            } else {
                LampSplashView()
                    .transition(.opacity.animation(.easeInOut(duration: 0.28)))
                    // Above the interface while it fades, not behind it.
                    .zIndex(1)
            }
        }
        // Kept outside the branch above so the library still loads while the
        // splash is what's on screen.
        .onAppear {
            model.start()
        }
        .onDisappear {
            // The window is closing: its session is free for the next one to
            // take up, which is how opening a window again returns to what it
            // was reading, and its tabs' conversations are free to be opened
            // again — in this window or another.
            if let readerSession { OpenReaderWindows.release(readerSession) }
            for chat in readerTabs.chatIDs { OpenReaderChats.release(chat) }
        }
        .onChange(of: model.hasReadLibrary, initial: true) { _, read in
            guard read else { return }
            // Before the tabs take up the chats they remember, so one that has
            // outstayed the reader's retention is let go of rather than opened.
            // Not with AI off: nothing is opened then, and turning it on
            // again sweeps what has outstayed retention in one pass.
            if aiFeaturesEnabled {
                ReaderChatHousekeeping.letGoOfOldChats(libraryRootURL: model.library.rootURL)
            }
            // Before the tabs, which are kept under the session taken up here.
            if readerSession == nil {
                let claimed = OpenReaderWindows.claim()
                readerSession = claimed.session
                isResumingReaderSession = claimed.resuming
            }
            restoreReaderTabs()
            restoreSearchTabs()
        }
        .onChange(of: model.hasLoadedInitialContent, initial: true) { _, loaded in
            guard loaded else { return }
            // A writing editor waiting from the start, so the first writing
            // opened shows at once rather than after its web view loads.
            TipTapEditorPool.shared.prewarm(libraryRootURL: model.library.rootURL, compact: false)
        }
        .onChange(of: model.isRefreshing) { _, refreshing in
            if !refreshing { restoreReaderTabs() }
        }
        .onChange(of: readerTabs) { _, tabs in
            guard hasRestoredReaderTabs, let readerSession else { return }
            ReaderTabSessionStore.save(tabs, session: readerSession)
        }
        .onChange(of: searchTabs) { _, tabs in
            guard hasRestoredSearchTabs, let readerSession else { return }
            SearchTabSessionStore.save(tabs, session: readerSession)
        }
        .onChange(of: readerSidebar) { _, _ in ensureSelectedTabHasChat() }
        // Turned off, the chat's column closes; turned on, old chats are
        // swept and the tabs take up theirs, as they would at launch.
        .onChange(of: aiFeaturesEnabled) { _, enabled in
            if enabled {
                guard hasRestoredReaderTabs else { return }
                // Swept only before this window first takes up its chats, as
                // at launch: once taken, they are this window's to keep.
                if !hasAdoptedRestoredChats {
                    ReaderChatHousekeeping.letGoOfOldChats(libraryRootURL: model.library.rootURL)
                }
                adoptRestoredChats()
                ensureSelectedTabHasChat()
            } else if readerSidebar == .chat {
                readerSidebar = nil
            }
        }
        .environmentObject(workspace)
        .environmentObject(scrollLink)
        .task {
            // Read again only when a pass ran, since only then can anything
            // have changed underneath.
            if await syncController.syncAutomaticallyIfNeeded(library: model.library) {
                model.refresh()
            }
        }
        // The library chooses a translation when it has read itself and this
        // window has nowhere of its own — the first translation installed
        // into an empty library. A window already reading something ignores
        // it.
        .onChange(of: model.selectedTranslationID) { _, _ in
            workspace.adoptIfUnplaced()
        }
        // A kept tab out of sight may be reading a translation just removed:
        // let them go, and each opens afresh when chosen.
        .onChange(of: model.translations.map(\.id)) { _, _ in
            readerPool.releaseHidden()
        }
        .onChange(of: controlActiveState) { _, state in
            // The reader last used is the one other windows mean by "the
            // current verse". Set as this window comes forward rather than as
            // another goes back, so closing one does not leave the library
            // pointing at a window that has gone.
            guard state == .key, hasRestoredReaderTabs else { return }
            workspace.becomeActive(in: model)
        }
        // Publishing what is done here, without being asked for it. Checking
        // costs a couple of aggregates and a small blob, and only a change
        // since the last pass starts one — so this is quiet while nothing is
        // happening, and a few seconds behind a tick when something is.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                await syncController.syncLocalWorkIfAppeared(library: model.library)
            }
        }
        // And taking in what another device has done. Less often than the
        // local check, because this one asks the server rather than this
        // Mac's own database.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                if await syncController.syncRemoteChangesIfAny(library: model.library) {
                    model.refresh()
                }
            }
        }
    }

    /// A sidebar group's name, in the readable secondary grey: the system's
    /// own sidebar headings were the faintest text in the window, most of all
    /// in dark.
    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.lampSecondaryText)
    }

    private var libraryInterface: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(LibrarySection.allCases.filter { $0 != .modules }) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(LibrarySelection.section(section))
                    }
                } header: {
                    sidebarHeading("Study")
                }

                Section {
                    Label(LibrarySection.modules.rawValue, systemImage: LibrarySection.modules.systemImage)
                        .tag(LibrarySelection.section(.modules))
                } header: {
                    sidebarHeading("Library")
                }
            }
            .navigationTitle("Lamp Bible")
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
            .safeAreaInset(edge: .bottom) {
                Button {
                    openWindow(id: "add-to-library")
                } label: {
                    Label("Import or Create…", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding()
                .background(.bar)
            }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .focusedValue(\.installModuleAction, { showingImporter = true })
        .focusedValue(\.importStudyDataAction, { showingStudyDataImporter = true })
        // ⌘T opens a tab in the pane being used, which is what it means
        // everywhere else on this Mac. The reader's asks which passage first;
        // a search tab has nothing to choose, so it opens and waits for
        // words. In any other section there is no rank of tabs to add to, so
        // the command is offered where it does something.
        .focusedValue(\.newTabAction, newTabAction)
        // Window-wide rather than focus-bound: ⌘K must work whatever in the
        // window has focus, the reader's text or nothing at all.
        .focusedSceneValue(\.commandPaletteAction, { showingCommandPalette.toggle() })
        .modifier(CommandPaletteToggleReceiver(isPalettePresented: $showingCommandPalette))
        .overlay(alignment: .top) {
            if showingCommandPalette {
                ZStack(alignment: .top) {
                    // A click outside closes it, as with a menu.
                    Color.lampPanelScrim
                        .ignoresSafeArea()
                        .onTapGesture { showingCommandPalette = false }
                    CommandPaletteView(
                        typedItems: paletteTypedItems,
                        namedItems: paletteNamedItems(decks: paletteDecks),
                        recentItems: paletteRecentItems(),
                        searchLibrary: { await paletteLibraryResults($0, level: $1) },
                        close: { showingCommandPalette = false }
                    )
                    .padding(.top, 72)
                }
                .transition(.opacity)
            }
        }
        .task(id: showingCommandPalette) {
            guard showingCommandPalette else { return }
            let root = model.library.rootURL
            paletteDecks = await Task.detached(priority: .userInitiated) {
                ((try? LampPresentationDeckStore(rootURL: root).decks()) ?? [])
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }.value
        }
        .environment(\.readerReferenceActions, ReaderReferenceActions(
            // Any object this view keeps for as long as it lives will do.
            owner: ObjectIdentifier(readerLexicalHoverStore),
            openInCurrent: { openReferenceInCurrentTab($0) },
            openInNewTab: { openReferenceInNewTab($0) }
        ))
        .onOpenURL { handleOpenURL($0) }
        .confirmationDialog(
            "Open this passage in which Bible?",
            isPresented: Binding(
                get: { externalBibleRequest != nil },
                set: { if !$0 { externalBibleRequest = nil } }
            ),
            presenting: externalBibleRequest
        ) { request in
            ForEach(ExternalBibleApplication.openableOnThisMac) { application in
                Button(application.rawValue) {
                    if let destination = application.url(
                        startReference: request.startReference,
                        endReference: request.endReference
                    ) {
                        NSWorkspace.shared.open(destination)
                    }
                    externalBibleRequest = nil
                }
            }
            Button("Open in Lamp Bible") {
                workspace.openReference(request.startReference, translationID: nil)
                selection = .section(.reader)
                externalBibleRequest = nil
            }
            Button("Cancel", role: .cancel) { externalBibleRequest = nil }
        } message: { _ in
            Text("Choose a default in Settings to stop being asked.")
        }
        .onChange(of: workspace.requestedSearch) { _, words in
            guard let words else { return }
            // Words, not a key: a key left from an analysis would keep the
            // analysis on screen in place of the search.
            showSearch(SearchTab(query: words))
            workspace.requestedSearch = nil
        }
        .onChange(of: workspace.requestedSearchTab) { _, tab in
            guard let tab else { return }
            showSearch(tab)
            workspace.requestedSearchTab = nil
        }
        .onChange(of: workspace.requestedStrongsKey) { _, key in
            guard let key else { return }
            // Scripture is named here rather than left to the pane. The pane
            // moves the search to scripture when a key is typed into it, but
            // a key arriving with the tab is not typed into anything, and
            // the analysis only shows on scripture.
            showSearch(SearchTab(query: key, kind: .translation, strongsKey: key))
            workspace.requestedStrongsKey = nil
        }
        .onChange(of: selection) { _, newValue in
            // The study or chat column stays open out of sight, and is open
            // when the reader comes back. Closing it on the way out looked
            // like losing the chat in it (user, 2026-11-05).
        }
        .onChange(of: workspace.currentLocation) { _, location in
            if hasRestoredReaderTabs, let location {
                readerTabs.updateSelected(location: location)
            }
            updateActivePlanReading(for: location)
        }
        .onChange(of: readerSidebar) { _, sidebar in
            if let sidebar { lastReaderSidebar = sidebar }
            recordTabSidebar()
        }
        .onChange(of: studyPane.tool) { _, tool in
            lastStudyTool = tool
            recordTabSidebar()
        }
        .onChange(of: studyPane.dictionaryLookup) { _, _ in
            recordTabSidebar()
        }
        .onChange(of: studyPane.analysisKeys) { _, _ in
            recordTabSidebar()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.install(urls)
            }
        }
        .fileImporter(
            isPresented: $showingStudyDataImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importPersonalStudyData(urls)
            }
        }
        .alert(
            "Lamp Bible",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "An unexpected error occurred.")
        }
        .alert(
            "Study Data Imported",
            isPresented: Binding(
                get: { model.studyImportMessage != nil },
                set: { if !$0 { model.studyImportMessage = nil } }
            )
        ) {
            Button("OK") { model.studyImportMessage = nil }
        } message: {
            Text(model.studyImportMessage ?? "The study data was imported.")
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isImporting || model.isImportingStudyData || model.isRefreshing {
                ProgressView(progressDescription)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
    }

    private var progressDescription: String {
        if model.isImporting { return "Installing Module…" }
        if model.isImportingStudyData { return "Importing Study Data…" }
        return "Refreshing Library…"
    }

    private func isReaderSelection(_ selection: LibrarySelection?) -> Bool {
        switch selection {
        case .section(.reader):
            true
        default:
            false
        }
    }

    private func handleOpenURL(_ url: URL) {
        if url.pathExtension.lowercased() == "lampdeck" {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let store = LampPresentationDeckStore(rootURL: model.library.rootURL)
                let deck = try store.decode(Data(contentsOf: url))
                try store.save(deck)
                openWindow(
                    id: "slide-studio",
                    value: SlideStudioRequest(deckID: deck.id)
                )
            } catch {
                model.errorMessage = error.localizedDescription
            }
            return
        }
        // Links the palette makes: a writing, a plan, a quiz, a deck, an
        // analysis. Core reads a writing link too, which an import writes
        // between writings; it is the same link and lands here first.
        if let link = LampMacLink(url: url) {
            switch link {
            case .writing(let id): go(to: .writing(id))
            case .plan(let id): go(to: .plan(id))
            case .quiz(let id): go(to: .quiz(id))
            case .deck(let id): go(to: .deck(id))
            case .analysis(let key): go(to: .analysis(key))
            }
            return
        }
        guard let deepLink = LampDeepLink(url: url) else { return }
        switch deepLink {
        case .reader(let reference, let translationID):
            workspace.openReference(reference, translationID: translationID)
            selection = .section(.reader)
        case .reading(let reference, let endReference, let openExternal):
            let chosenApp = UserDefaults.standard.string(forKey: "plans.externalBibleApp")
                .flatMap(ExternalBibleApplication.init(rawValue:))
                .flatMap { ExternalBibleApplication.openableOnThisMac.contains($0) ? $0 : nil }
            if openExternal, chosenApp == nil {
                // "Ask Each Time" is the empty default, so there is no app to
                // resolve. This used to fall through and open Lamp's own
                // reader, which is the one thing the link was asking not to do.
                externalBibleRequest = ExternalBibleRequest(
                    startReference: reference, endReference: endReference
                )
            } else if openExternal,
               let application = chosenApp,
               let destination = application.url(
                   startReference: reference, endReference: endReference
               ) {
                NSWorkspace.shared.open(destination)
            } else {
                workspace.openReference(reference, translationID: nil)
                selection = .section(.reader)
            }
        case .strongs(let key):
            go(to: .dictionary(key, word: nil))
        case .book(let moduleID, let sectionID):
            // Through go(to:), which asks afresh, so a link to the book last
            // asked for still opens it after going back to the shelf. A link
            // naming no book is a link to the shelf.
            if let moduleID {
                go(to: .book(moduleID: moduleID, sectionID: sectionID))
            } else {
                selection = .section(.books)
            }
        case .writing(let id):
            // A link from one imported writing to another.
            requestedDevotionalID = id
            selection = .section(.devotionals)
        case .section(let section):
            selection = .section(LibrarySection(rawValue: section.displayName) ?? .reader)
        case .moduleFile(let url):
            model.install([url])
            selection = .section(.modules)
        case .dataFile(let url):
            model.openDataFile(url)
        }
    }

    /// Shows a search asked for from somewhere else — the reader's ⌘L, a
    /// word looked up, a Strong's key followed, the palette's Search route.
    /// Which tab it lands in is `SearchTabCollection.show`.
    ///
    /// These used to be written to `@SceneStorage("search.query")` and its
    /// key, which the pane read. The pane reads its tabs now, so those
    /// writes went nowhere and every search asked for from the reader was
    /// silently dropped — found by a Codex review of the tabs, 2026-11-11.
    private func showSearch(_ tab: SearchTab) {
        searchTabs.show(tab)
        selection = .section(.search)
    }

    /// What ⌘T does here, or nil where it does nothing.
    private var newTabAction: (() -> Void)? {
        switch selection {
        case .section(.search):
            return { searchTabs.open() }
        case .section(.reader), .none:
            return { presentNewReaderTabChooser() }
        default:
            // A tab bar the section does not have: Books, Decks, Settings and
            // the rest. Returning nil greys the menu item rather than opening
            // a reader tab behind the pane being looked at.
            return nil
        }
    }

    /// The window's searches, once it holds a session. The reader's own
    /// restore waits for the library to have been read, because a tab names
    /// a place in a translation that has to still exist; a search names
    /// nothing that needs checking, so this only needs the session.
    private func restoreSearchTabs() {
        guard !hasRestoredSearchTabs, let readerSession else { return }
        searchTabs = SearchTabSessionStore.load(
            session: readerSession,
            resumingLastSession: isResumingReaderSession
        )
        hasRestoredSearchTabs = true
    }

    /// Opens this window's tabs, and its reader at the tab chosen in them,
    /// once the library has been read: which translations remain, for the
    /// tabs, and which note and highlight modules the chapter is read with.
    private func restoreReaderTabs() {
        guard !hasRestoredReaderTabs, let readerSession,
              model.hasReadLibrary, !model.isRefreshing else { return }
        // A failed library load must not replace saved tabs with an empty session.
        guard model.errorMessage == nil || !model.modules.isEmpty else { return }
        readerTabs = ReaderTabSessionStore.load(
            session: readerSession,
            resumingLastSession: isResumingReaderSession,
            translationIDs: Set(model.translations.map(\.id)),
            fallbackLocation: model.readerLocation
        )
        hasRestoredReaderTabs = true
        adoptRestoredChats()
        adoptTabSidebar()
        ensureSelectedTabHasChat()
        // A place asked for while no reader was open goes in the chosen tab,
        // at its verse: ⌥↩ on John 3:16 in the palette opens a new window
        // there, not at the top of John 3.
        let pending = model.takePendingReaderLocation()
        // The workspace the window started with is the open tab's.
        readerPool.claimFirst(for: readerTabs.selectedID)
        // The open tab as it was left: where it was scrolled, and its
        // selected verse. A place asked for instead goes to its verse.
        if pending == nil {
            workspace.scrollMemory.prepare(tab: readerTabs.selectedID)
        } else {
            workspace.scrollMemory.track(tab: readerTabs.selectedID)
        }
        studyPane.scrollMemory.prepare(tab: readerTabs.selectedID)
        // The library's reader before it starts, so what it reads is
        // mirrored: if this window is in front, or no reader is yet. A window
        // behind finishing its restore last must not take the library from
        // the one being used.
        if model.activeReader == nil || controlActiveState == .key {
            model.activeReader = workspace
        }
        if pending == nil, readerTabs.selectedTab?.isBlank == true {
            // A new tab left empty reopens empty.
            workspace.startBlank(model: model)
            return
        }
        workspace.start(model: model, at: pending ?? readerTabs.selectedTab?.location)
        if let verse = (pending ?? readerTabs.selectedTab?.location)?.verseReference {
            workspace.focusVerse(verse)
        }
    }

    /// A new tab at once, empty, as Safari's and Finder's open before
    /// anything is chosen: its page is the passage chooser
    /// (`NewReaderTabPage`) until a passage is chosen in it. A copy of the
    /// chapter being read, with the picker over it, read as a duplicated
    /// tab; and a popover hanging from the new-tab button sat at the
    /// window's edge, where macOS pushed its arrow into its corner.
    private func presentNewReaderTabChooser() {
        readerTabs.updateSelected(location: workspace.currentLocation)
        workspace.scrollMemory.save(tab: readerTabs.selectedID)
        studyPane.scrollMemory.save(tab: readerTabs.selectedID)
        recordTabSidebar()
        let added = readerTabs.addBlank()
        showReaderTab(added, at: nil)
        selection = .section(.reader)
    }

    /// Copies the tab that was asked for, which is not always the open one.
    ///
    /// The open tab's place lives in the workspace until it is written back,
    /// so it is written back first; otherwise duplicating the tab you are
    /// reading copies where it was when you left it rather than where you
    /// are.
    private func duplicateReaderTab(_ id: UUID) {
        readerTabs.updateSelected(location: workspace.currentLocation)
        workspace.scrollMemory.save(tab: readerTabs.selectedID)
        studyPane.scrollMemory.save(tab: readerTabs.selectedID)
        recordTabSidebar()
        guard let location = readerTabs.duplicate(id) else { return }
        showReaderTab(readerTabs.selectedID, at: location)
        selection = .section(.reader)
    }

    private func renameReaderTab(_ id: UUID, to name: String?) {
        readerTabs.rename(id, to: name)
    }

    private func openReaderTab(at location: ReaderLocation) {
        readerTabs.updateSelected(location: workspace.currentLocation)
        workspace.scrollMemory.save(tab: readerTabs.selectedID)
        studyPane.scrollMemory.save(tab: readerTabs.selectedID)
        recordTabSidebar()
        let added = readerTabs.add(location: location)
        showReaderTab(added, at: location)
        selection = .section(.reader)
    }

    /// Puts a tab on screen. A kept tab is shown as it was left, at once; any
    /// other gets a workspace of its own, opened at the tab's place and put
    /// back where it was scrolled. Either way the library's reader is it.
    private func showReaderTab(_ id: UUID, at location: ReaderLocation?) {
        // What a tab going out of sight should stop, done here: its reader is
        // kept as it is, not told, so as not to redraw it on the way out.
        let leaving = workspace
        // Only a change is published, here as everywhere a switch writes:
        // a set of the same value still lays out every view that watches.
        leaving.readAloud.stop()
        if leaving.isChoosingPassage { leaving.isChoosingPassage = false }
        if readerLexicalHoverStore.details != nil { readerLexicalHoverStore.details = nil }
        let (shown, isNew) = readerPool.show(id)
        // The window's shared stores, for the tab now on screen.
        scrollLink.reset()
        readerLexicalHoverStore.configure(isDetailsEnabled: StrongsKey.hasAnnotations(
            (shown.chapter?.verses ?? []).lazy.flatMap { $0.annotations }.map(\.strongs)
        ))
        // The tab's column, open or shut, on its pane. Its pane's state is
        // its own and kept with it; a tab new to the pool takes it up from
        // what the tab saved.
        adoptTabSidebar(adoptingPane: isNew)
        // The library's reader before it reads, since only that one is
        // mirrored: if this window's reader was it, or the window is in
        // front, or no reader is yet — not a window behind.
        if model.activeReader == nil || model.activeReader === leaving || controlActiveState == .key {
            model.activeReader = shown
        }
        if isNew, readerTabs.tabs.first(where: { $0.id == id })?.isBlank == true {
            // Nothing to put back: a new tab has not been read or scrolled.
            shown.scrollMemory.track(tab: id)
            studyPane.scrollMemory.track(tab: id)
            shown.startBlank(model: model)
        } else if isNew {
            shown.scrollMemory.prepare(tab: id)
            studyPane.scrollMemory.prepare(tab: id)
            shown.start(model: model, at: location)
            if let verse = location?.verseReference { shown.focusVerse(verse) }
        } else {
            // Kept out of sight, it may have missed a highlight or a note:
            // read again quietly, and tell the library where the window is.
            shown.refreshQuietly()
        }
    }

    private func selectReaderTab(_ id: UUID) {
        guard id != readerTabs.selectedID else { return }
        readerTabs.updateSelected(location: workspace.currentLocation)
        workspace.scrollMemory.save(tab: readerTabs.selectedID)
        studyPane.scrollMemory.save(tab: readerTabs.selectedID)
        recordTabSidebar()
        let location = readerTabs.select(id)
        showReaderTab(id, at: location)
        selection = .section(.reader)
    }

    private func closeReaderTab(_ id: UUID) {
        guard readerTabs.tabs.count > 1 else { return }
        let wasSelected = readerTabs.selectedID == id
        let chat = readerTabs.tabs.first { $0.id == id }?.chatID
        if wasSelected { readerTabs.updateSelected(location: workspace.currentLocation) }
        let destination = readerTabs.close(id)
        readerPool.workspace(for: id)?.scrollMemory.forget(tab: id)
        readerPool.studyPane(for: id)?.scrollMemory.forget(tab: id)
        if let chat { letGoOfChat(chat) }
        if wasSelected {
            showReaderTab(readerTabs.selectedID, at: destination)
        }
        readerPool.close(id)
    }

    /// Frees a closed tab's conversation, and takes the workspace with it
    /// where nothing was ever said in it.
    ///
    /// The transcript is what a conversation is, so one that was spoken in
    /// stays in the library for the list to offer. One that was not is a
    /// folder a pane was opened over, and is no more than that.
    private func letGoOfChat(_ chat: UUID) {
        OpenReaderChats.release(chat)
        let workspace = ReaderChatWorkspaceStore.workspaceURL(
            libraryRootURL: model.library.rootURL, chatID: chat
        )
        // And the chat itself, whichever provider it is on, which is kept for
        // the life of the app otherwise. Held off while a reply is arriving or
        // a pane shows it, and let go once neither is so. Only here, where the
        // tab is going: a kept reader let go (`ReaderTabPool`) keeps its chat.
        for provider in AIProviderCLI.allCases {
            KeptAgentChats.release(provider: provider, workspace: workspace)
        }
        guard ReaderChatWorkspaceStore.lastSpoken(in: workspace) == nil else { return }
        try? FileManager.default.removeItem(at: workspace)
    }

    /// Gives the open tab a conversation where its pane is on chat and it has
    /// none, which is how a chat is taken up: on opening the pane, never on
    /// making a tab, so a tab nobody chats in leaves nothing behind.
    private func ensureSelectedTabHasChat() {
        guard aiFeaturesEnabled, hasRestoredReaderTabs, readerSidebar == .chat,
              readerTabs.selectedTab?.chatID == nil else { return }
        readerTabs.updateSelected(
            chatID: OpenReaderChats.start(libraryRootURL: model.library.rootURL)
        )
    }

    /// Puts the open tab on another conversation, chosen from the list.
    ///
    /// The one it leaves is let go of, so another tab can take it up, and goes
    /// from the library where nothing was ever said in it. Nil starts a new
    /// conversation, which is the list's "New Chat".
    private func resumeChat(_ chat: UUID?) {
        let root = model.library.rootURL
        let left = readerTabs.selectedTab?.chatID
        guard chat != left else { return }
        let taken = chat.map { OpenReaderChats.take($0, libraryRootURL: root) } ?? false
        if let chat, !taken { return }
        if let left { letGoOfChat(left) }
        readerTabs.updateSelected(chatID: taken ? chat : OpenReaderChats.start(libraryRootURL: root))
    }

    /// Takes up the conversations the restored tabs remember, and forgets the
    /// ones this window cannot have.
    ///
    /// A chat another window holds is one of them: the last window's tabs are
    /// a fallback for a window resuming, so two windows can arrive holding the
    /// same identifiers, and sharing one transcript between two panes is worse
    /// than opening a new one. A chat a scrub has taken is the other.
    private func adoptRestoredChats() {
        // With AI off the tabs keep the chats they remember, untaken, so they
        // are theirs again when it is turned on.
        guard aiFeaturesEnabled, !hasAdoptedRestoredChats else { return }
        hasAdoptedRestoredChats = true
        let root = model.library.rootURL
        var lost: Set<UUID> = []
        for chat in readerTabs.chatIDs where !OpenReaderChats.take(chat, libraryRootURL: root) {
            lost.insert(chat)
        }
        readerTabs.forgetChats(lost)
    }

    /// A tab's side pane: its chat, or its study tools on its own pane state.
    /// Asked only for the tab on screen (`ReaderTabHosts`), so the window's
    /// column state is that tab's.
    private func tabSidebarContent(for id: UUID) -> AnyView {
        guard let reader = readerPool.workspace(for: id),
              let pane = readerPool.studyPane(for: id) else { return AnyView(EmptyView()) }
        if aiFeaturesEnabled,
           (readerSidebar ?? lastReaderSidebar) == .chat,
           let chat = readerTabs.tabs.first(where: { $0.id == id })?.chatID {
            return AnyView(ReaderChatSidebarView(
                chatID: chat,
                resume: resumeChat,
                close: { readerSidebar = nil },
                reader: reader
            ))
        }
        return AnyView(
            StudyInspectorView(
                isPresented: showingStudyInspector,
                recordTypedQuery: recordTabSidebar,
                readerTranslationID: reader.selectedTranslationID
            )
            .environmentObject(model)
            .environmentObject(scrollLink)
            // The tab's, over the window's: its chapter and verse are what
            // the pane shows, on screen or kept out of sight.
            .environmentObject(reader)
            .environment(pane)
        )
    }

    /// Writes the column as it stands into the open tab.
    private func recordTabSidebar() {
        guard hasRestoredReaderTabs else { return }
        readerTabs.updateSelected(sidebar: studyPane.sidebar(pane: readerSidebar))
    }

    /// Shows the open tab's column: open or shut, on its pane and its tool.
    private func adoptTabSidebar(adoptingPane: Bool = true) {
        let sidebar = readerTabs.selectedTab?.sidebar ?? ReaderTabSidebar()
        if adoptingPane { studyPane.adopt(sidebar, defaultTool: lastStudyTool) }
        // A tab left on chat opens with its column shut while AI is off.
        let pane = sidebar.pane == .chat && !aiFeaturesEnabled ? nil : sidebar.pane
        if (pane != nil) != (readerSidebar != nil) {
            readerSidebarSwitchesInstantly = true
        }
        readerSidebar = pane
    }

    private func openReferenceInCurrentTab(_ reference: Int) {
        workspace.openReference(reference)
        selection = .section(.reader)
    }

    private func openReferenceInNewTab(_ reference: Int) {
        guard let location = readerLocation(for: reference) else { return }
        openReaderTab(at: location)
    }

    private func openPlanReading(_ mode: PlanReadingMode) {
        guard let reading = mode.activeReading else { return }
        planReadingMode = mode
        openReferenceInCurrentTab(reading.startReference)
    }

    private func openAllPlanReadings(_ mode: PlanReadingMode) {
        readerTabs.updateSelected(location: workspace.currentLocation)
        var lastLocation: ReaderLocation?
        var lastReadingID = mode.activeReadingID
        for reading in mode.readings {
            guard let location = readerLocation(for: reading.startReference) else { continue }
            readerTabs.add(location: location)
            lastLocation = location
            lastReadingID = reading.id
        }
        guard let lastLocation else { return }
        var activatedMode = mode
        activatedMode.activeReadingID = lastReadingID
        planReadingMode = activatedMode
        showReaderTab(readerTabs.selectedID, at: lastLocation)
        selection = .section(.reader)
    }

    private func updateActivePlanReading(for location: ReaderLocation?) {
        guard var mode = planReadingMode, let location else { return }
        let reference = location.verseReference
            ?? location.bookNumber * 1_000_000 + location.chapterNumber * 1_000 + 1
        guard let reading = mode.readings.first(where: {
            reference >= $0.startReference && reference <= $0.endReference
        }), reading.id != mode.activeReadingID else { return }
        mode.activeReadingID = reading.id
        planReadingMode = mode
    }

    private func readerLocation(for reference: Int) -> ReaderLocation? {
        guard let translationID = workspace.selectedTranslationID ?? model.translations.first?.id else {
            return nil
        }
        let components = LampBibleReferenceFormatter.components(of: reference)
        return ReaderLocation(
            translationID: translationID,
            bookNumber: components.book,
            chapterNumber: components.chapter,
            verseReference: reference
        )
    }

    /// The reader is built once and kept, out of sight, while another section
    /// is shown: coming back is then showing it, not typesetting the passage
    /// and laying it out again. `TranslationReaderView.readerDidLeave()` and
    /// `readerDidReturn()` hold what being rebuilt used to do for it.
    private var detail: some View {
        let showsReader = isReaderSelection(selection)
        return ZStack {
            OutOfSightUpdates(isShown: showsReader) {
                readerDetail(isShown: showsReader)
            }
            .equatable()
            .environment(studyPane)
            .opacity(showsReader ? 1 : 0)
            // Never faded: opacity part way puts a window of text through an
            // offscreen buffer on every frame.
            .animation(nil, value: showsReader)
            .allowsHitTesting(showsReader)
            .disabled(!showsReader)
            .accessibilityHidden(!showsReader)
            if !showsReader {
                sectionDetail
            }
        }
    }


    // MARK: Reader toolbar

    /// The passage picker's flag, the current tab's.
    private var readerLocationPickerBinding: Binding<Bool> {
        Binding(get: { workspace.isChoosingPassage }, set: { workspace.isChoosingPassage = $0 })
    }

    private var activePlanReadingIndex: Int? {
        guard let mode = planReadingMode else { return nil }
        return mode.readings.firstIndex { $0.id == mode.activeReadingID }
    }

    private var canNavigateReaderBackward: Bool {
        if planReadingMode != nil {
            return activePlanReadingIndex.map { $0 > 0 } ?? false
        }
        return workspace.canNavigateBackward
    }

    private var canNavigateReaderForward: Bool {
        if let mode = planReadingMode {
            return activePlanReadingIndex.map { $0 < mode.readings.index(before: mode.readings.endIndex) } ?? false
        }
        return workspace.canNavigateForward
    }

    private var canNavigateBookBackward: Bool {
        guard planReadingMode == nil,
              let bookNumber = workspace.selectedBookNumber,
              let index = workspace.books.firstIndex(where: { $0.id == bookNumber }) else { return false }
        return index > workspace.books.startIndex
    }

    private var canNavigateBookForward: Bool {
        guard planReadingMode == nil,
              let bookNumber = workspace.selectedBookNumber,
              let index = workspace.books.firstIndex(where: { $0.id == bookNumber }) else { return false }
        return index < workspace.books.index(before: workspace.books.endIndex)
    }

    private var backwardNavigationTitle: String {
        planReadingMode == nil ? "Previous Chapter" : "Previous Plan Reading"
    }

    private var forwardNavigationTitle: String {
        planReadingMode == nil ? "Next Chapter" : "Next Plan Reading"
    }

    /// Moves the plan's open reading to `reading`, in the current tab.
    private func openPlanReadingStep(_ reading: LampPlanReading) {
        guard var mode = planReadingMode else { return }
        mode.activeReadingID = reading.id
        planReadingMode = mode
        workspace.openReference(reading.startReference)
    }

    private func navigateReaderBackward() {
        guard let mode = planReadingMode else {
            workspace.navigateBackward()
            return
        }
        guard let index = activePlanReadingIndex, index > mode.readings.startIndex else { return }
        openPlanReadingStep(mode.readings[mode.readings.index(before: index)])
    }

    private func navigateReaderForward() {
        guard let mode = planReadingMode else {
            workspace.navigateForward()
            return
        }
        guard let index = activePlanReadingIndex,
              index < mode.readings.index(before: mode.readings.endIndex) else { return }
        openPlanReadingStep(mode.readings[mode.readings.index(after: index)])
    }

    /// Goes where the passage picker was pointed. A reference that named a
    /// verse is opened as a reference, so the reader lands on the verse; a
    /// chapter is a passage, which the history records as one move.
    private func goToPassage(_ location: ReaderLocation) {
        if let verse = location.verseReference {
            workspace.openReference(verse, translationID: location.translationID)
        } else {
            workspace.selectPassage(
                translationID: location.translationID,
                bookNumber: location.bookNumber,
                chapterNumber: location.chapterNumber
            )
        }
    }

    private func navigateBookBackward() {
        guard canNavigateBookBackward,
              let bookNumber = workspace.selectedBookNumber,
              let index = workspace.books.firstIndex(where: { $0.id == bookNumber }) else { return }
        workspace.selectBook(workspace.books[workspace.books.index(before: index)].id)
    }

    private func navigateBookForward() {
        guard canNavigateBookForward,
              let bookNumber = workspace.selectedBookNumber,
              let index = workspace.books.firstIndex(where: { $0.id == bookNumber }) else { return }
        workspace.selectBook(workspace.books[workspace.books.index(after: index)].id)
    }

    private var readerLocationTitle: String {
        if workspace.isBlank { return "New Tab" }
        // This window's translation, not the library's, which follows
        // whichever reader was used last.
        let translation = model.translations
            .first { $0.id == workspace.selectedTranslationID }?.abbreviation ?? "Translation"
        if let reading = planReadingMode?.activeReading {
            return "\(translation) \u{00B7} \(reading.displayDescription)"
        }
        // A book the translation lacks is still named: it is where the
        // reader was sent, and the page under the title says it is missing.
        let book = workspace.selectedBook?.name
            ?? workspace.selectedBookNumber.map { model.bookName($0, in: nil) } ?? "Book"
        return "\(translation) \u{00B7} \(book) \(workspace.selectedChapterNumber)"
    }

    private func historyLabel(_ location: ReaderLocation) -> String {
        let book = model.bookName(location.bookNumber, in: location.translationID)
        let translation = model.translations.first { $0.id == location.translationID }
        let name = translation?.abbreviation ?? translation?.name ?? location.translationID
        return "\(book) \(location.chapterNumber) (\(name))"
    }

    private var readAloudButtonTitle: String {
        switch workspace.readAloud.state {
        case .stopped: "Read Aloud"
        case .playing: "Pause Read Aloud"
        case .paused: "Resume Read Aloud"
        }
    }

    private var readAloudButtonImage: String {
        switch workspace.readAloud.state {
        case .stopped: "play.fill"
        case .playing: "pause.fill"
        case .paused: "play.fill"
        }
    }

    private func toggleReadAloud() {
        let verses = readAloudVerses
        guard !verses.isEmpty else { return }
        workspace.readAloud.toggle(
            items: verses.map {
                ReadAloudItem(reference: $0.id, verseNumber: $0.number, text: $0.text)
            },
            startingAt: workspace.selectedVerseReference,
            language: readAloudLanguage,
            rate: readAloudRate
        )
    }

    private func startReadAloud(at reference: Int?) {
        let verses = readAloudVerses
        guard !verses.isEmpty else { return }
        workspace.readAloud.play(
            items: verses.map {
                ReadAloudItem(reference: $0.id, verseNumber: $0.number, text: $0.text)
            },
            startingAt: reference,
            language: readAloudLanguage,
            rate: readAloudRate
        )
    }

    /// Bumped when the speech voices change: read again in the background
    /// after a return to the app, or dropped because the system said they
    /// changed. The Read Aloud button
    /// reads it, so a voice just installed in System Settings enables it
    /// without waiting for some other redraw.
    @State private var speechVoicesRevision = 0

    private var readAloudHasVoice: Bool {
        _ = speechVoicesRevision
        return SpeechVoices.hasVoice(for: readAloudLanguage)
    }

    /// The language the verses read aloud are written in: their chapter's
    /// translation's, not the one chosen, which runs ahead of the chapter
    /// while another translation loads.
    private var readAloudLanguage: String {
        let id = readAloudChapters.first?.translationID
        return SpeechVoices.language(of: model.translations.first { $0.id == id })
    }

    /// The verses on screen.
    private var readAloudVerses: [LampVerse] {
        readAloudChapters.flatMap(\.verses)
    }

    /// The chapters on screen: a plan reading's, or the chapter.
    private var readAloudChapters: [LampChapter] {
        if let translationID = workspace.selectedTranslationID,
           let reading = planReadingMode?.activeReading,
           workspace.loadedPlanReadingRequest == PlanReadingChapterRequest(
               translationID: translationID,
               readingID: reading.id,
               startReference: reading.startReference,
               endReference: reading.endReference
           ),
           !workspace.planReadingChapters.isEmpty {
            return workspace.planReadingChapters
        }
        return workspace.chapter.map { [$0] } ?? []
    }

    /// The reader's layout, remembering the one side by side is chosen from.
    private var readerLayoutSelection: Binding<ReaderLayoutMode> {
        Binding(
            get: { readerLayoutMode },
            set: { mode in
                if mode == .sideBySide, readerLayoutMode != .sideBySide {
                    layoutModeBeforeSideBySide = readerLayoutMode
                }
                readerLayoutMode = mode
            }
        )
    }

    /// Whether the reader is side by side, for the toolbar's toggle: off, it
    /// goes back to the layout side by side was chosen from.
    private var readsSideBySide: Binding<Bool> {
        Binding(
            get: { readerLayoutMode == .sideBySide },
            set: { isOn in
                if isOn {
                    readerLayoutSelection.wrappedValue = .sideBySide
                } else if readerLayoutMode == .sideBySide {
                    readerLayoutMode = layoutModeBeforeSideBySide == .sideBySide
                        ? .continuousParagraphs
                        : layoutModeBeforeSideBySide
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        // One capsule for the whole of where you are and how to move from it,
        // rather than five: the passage reads as the control, and the steps
        // either side of it as its own. The chapter steps stay one click
        // away; the book steps beside them are quieter.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                Button {
                    navigateBookBackward()
                } label: {
                    Image(systemName: "chevron.left.2")
                }
                .disabled(!canNavigateBookBackward || workspace.isLoadingChapter || workspace.isLoadingPlanReading)
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .help("Previous Book")
                .accessibilityLabel("Previous Book")

                Button {
                    navigateReaderBackward()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canNavigateReaderBackward || workspace.isLoadingChapter || workspace.isLoadingPlanReading)
                .keyboardShortcut("[", modifiers: .command)
                .help(backwardNavigationTitle)
                .accessibilityLabel(backwardNavigationTitle)

                Button {
                    workspace.isChoosingPassage.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "books.vertical")
                        Text(readerLocationTitle)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                // Says what the field behind it takes, since the button
                // itself cannot show that it now accepts a reference, a
                // Strong's key or words to search for.
                .help("Go to a passage, or search (⌘L)")
                .accessibilityLabel("Go to a passage, or search")
                .popover(isPresented: readerLocationPickerBinding, arrowEdge: .bottom) {
                    PassagePickerPopover(
                        isPresented: readerLocationPickerBinding,
                        open: { goToPassage($0) },
                        openSearch: { workspace.requestedSearch = $0 },
                        openAnalysis: { workspace.requestedStrongsKey = $0 }
                    )
                        .environmentObject(model)
                }

                Button {
                    navigateReaderForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canNavigateReaderForward || workspace.isLoadingChapter || workspace.isLoadingPlanReading)
                .keyboardShortcut("]", modifiers: .command)
                .help(forwardNavigationTitle)
                .accessibilityLabel(forwardNavigationTitle)

                Button {
                    navigateBookForward()
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .disabled(!canNavigateBookForward || workspace.isLoadingChapter || workspace.isLoadingPlanReading)
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .help("Next Book")
                .accessibilityLabel("Next Book")
            }
            .buttonStyle(.accessoryBar)
            .controlSize(.regular)
        }

        ToolbarItemGroup(placement: .navigation) {
            Button("Back in Reading History", systemImage: "arrow.uturn.backward") {
                workspace.goBackInHistory()
            }
            .disabled(!workspace.canGoBackInHistory)
            .keyboardShortcut("[", modifiers: [.command, .option])

            Button("Forward in Reading History", systemImage: "arrow.uturn.forward") {
                workspace.goForwardInHistory()
            }
            .disabled(!workspace.canGoForwardInHistory)
            .keyboardShortcut("]", modifiers: [.command, .option])

            Menu("Reading History", systemImage: "clock.arrow.circlepath") {
                if workspace.recentLocations.isEmpty {
                    Text("No Reading History")
                } else {
                    ForEach(workspace.recentLocations, id: \.self) { location in
                        Button(historyLabel(location)) {
                            workspace.openHistoryLocation(location)
                        }
                    }
                    Divider()
                    Button("Clear History", role: .destructive) {
                        workspace.clearHistory()
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }

        ToolbarItemGroup {
            Toggle(isOn: readsSideBySide) {
                Label(ReaderLayoutMode.sideBySide.title, systemImage: ReaderLayoutMode.sideBySide.systemImage)
            }
            .toggleStyle(.button)
            .disabled(readerLayoutMode != .sideBySide && model.translations.count < 2)
            .help(
                readerLayoutMode == .sideBySide
                    ? "Read this translation on its own"
                    : "Read another translation beside this one"
            )

            Menu("Reader Appearance", systemImage: "textformat") {
                Picker("Layout", selection: readerLayoutSelection) {
                    ForEach(ReaderLayoutMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                TextSizeMenuItems(
                    fontSize: $fontSize,
                    lineSpacing: $lineSpacing,
                    typeface: $typeface,
                    defaultTypeface: .readerDefault,
                    fontScale: .readerText,
                    lineSpacingScale: .readerLineSpacing,
                    usesKeyboardShortcuts: true
                )

                Divider()
                Section("Verse marks") {
                    Text("Bar in the margin — selected verse")
                    Text("Orange note in the margin — your note")
                    Text("Purple book in the margin — study notes")
                    Text("Blue letter in the text — translator’s note")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose the reader layout, typeface, and text size, and see what the verse marks mean")

            // One control, as Music's play button is: a click plays or pauses,
            // and the arrow beside it holds where to start from and stop.
            Menu {
                Button(
                    planReadingMode == nil ? "Read Chapter from Beginning" : "Read Reading from Beginning",
                    systemImage: "text.book.closed"
                ) {
                    startReadAloud(at: nil)
                }
                if workspace.selectedVerseReference != nil {
                    Button("Read from Selected Verse", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        startReadAloud(at: workspace.selectedVerseReference)
                    }
                }
                if workspace.readAloud.state == .playing {
                    Button("Pause", systemImage: "pause") { workspace.readAloud.pause() }
                } else if workspace.readAloud.state == .paused {
                    Button("Resume", systemImage: "play") { workspace.readAloud.resume() }
                }
                Button("Stop", systemImage: "stop") { workspace.readAloud.stop() }
                    .disabled(workspace.readAloud.state == .stopped)
            } label: {
                Label(readAloudButtonTitle, systemImage: readAloudButtonImage)
            } primaryAction: {
                toggleReadAloud()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(readAloudVerses.isEmpty || !readAloudHasVoice)
            .help(readAloudHasVoice
                ? "\(readAloudButtonTitle) — the arrow has where to start from"
                : "No \(SpeechVoices.languageName(readAloudLanguage)) voice is installed, so this translation can’t be read aloud")
            .onReceive(NotificationCenter.default.publisher(for: SpeechVoices.didChange)) { _ in
                speechVoicesRevision &+= 1
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // With AI off there is no button and no ⇧⌘J: nothing about the
            // reader mentions a chat at all.
            if aiFeaturesEnabled {
                Button {
                    showingReaderChat.wrappedValue.toggle()
                } label: {
                    Label("Reader Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .help(showingReaderChat.wrappedValue ? "Hide Reader Chat" : "Show Reader Chat")
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }

            Button {
                showingStudyInspector.wrappedValue.toggle()
            } label: {
                Label("Study Tools", systemImage: "sidebar.trailing")
            }
            .help(showingStudyInspector.wrappedValue ? "Hide Study Tools" : "Show Study Tools")
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }


    private func readerDetail(isShown: Bool) -> some View {
        VStack(spacing: 0) {
            if planReadingMode == nil {
                ReaderTabBar(
                    tabs: readerTabs.tabs,
                    selectedID: readerTabs.selectedID,
                    select: selectReaderTab,
                    close: closeReaderTab,
                    duplicate: duplicateReaderTab,
                    rename: renameReaderTab,
                    move: { readerTabs.move($0, to: $1) },
                    newTab: presentNewReaderTabChooser,
                    bookName: { model.bookName($0, in: $1) }
                )
            }
            // Laid out beside the reader rather than with `.inspector`, whose
            // column is chrome for the whole window: it rounds its top corners
            // for the titlebar it expects to meet, and takes the tab bar's
            // divider with it. Here the tab bar spans the window and the study
            // column starts underneath it.
            //
            // Every frame between here and the reader's ScrollView is measured
            // in exact points, and that is what keeps the app responsive. A
            // flexible frame (`maxWidth: .infinity`) has to ask its child how
            // big it wants to be, and a ScrollView answers that by measuring its
            // content — which makes the lazy passage lay out every paragraph.
            // Several nested flexible stacks each re-asking turns one layout
            // pass into minutes of spinning on the main thread.
            //
            // The GeometryReader supplies the real numbers: it reports its own
            // size without consulting its children, so sizing stops here and
            // everything below is told its size rather than asked for it.
            GeometryReader { geometry in
                let columnWidth = StudyInspectorMetrics.totalWidth(studyInspectorWidth)
                // The animated value only governs while the column is actually
                // moving. Once it has settled the width tracks the column
                // exactly, so dragging the resize handle widens the column
                // rather than leaving a stale reveal behind it — which showed
                // the pane spilling over the quiz panel, half faded, with the
                // handle no longer hit-testable because the reveal was short of
                // its own width.
                let revealedWidth = isReaderSidebarTransitioning
                    ? min(max(readerSidebarRevealedWidth, 0), columnWidth)
                    : (readerSidebar != nil ? columnWidth : 0)
                let revealProgress = columnWidth > 0 ? revealedWidth / columnWidth : 0
                // A plain row, not an overlay: the column is a sibling of the
                // reader so the layout itself decides where it sits.
                let readerSize = CGSize(
                    width: max(geometry.size.width - revealedWidth, 0),
                    height: geometry.size.height
                )
                // Noted, not published: the size a tab is laid out at when it
                // goes out of sight.
                let _ = (readerPool.liveSize = readerSize)
                HStack(spacing: 0) {
                    // A reader per kept tab (`ReaderTabPool`), each in a
                    // hosting view of its own (`ReaderTabHosts`): the one on
                    // screen shown, the rest hidden at the AppKit level and
                    // left out of layout, so choosing one shows a view already
                    // laid out. Not told when hidden: the window stops what a
                    // tab leaving should stop (`showReaderTab`), and a hidden
                    // reader neither hears nor speaks to what is shared
                    // (`isActiveReader`).
                    ReaderTabHosts(
                        keptIDs: readerPool.keptIDs,
                        currentID: readerPool.currentID
                    ) { id in
                        guard let kept = readerPool.workspace(for: id) else { return AnyView(EmptyView()) }
                        if kept.isBlank {
                            return AnyView(
                                NewReaderTabPage(
                                    workspace: kept,
                                    recent: readerPool.recentChapters.places
                                )
                                .environmentObject(kept)
                            )
                        }
                        return AnyView(
                            TranslationReaderView(
                                model: model,
                                workspace: kept,
                                isShown: isShown,
                                planReadingMode: $planReadingMode,
                                readerSidebar: $readerSidebar,
                                lexicalHoverStore: readerLexicalHoverStore,
                                isSidebarTransitioning: isReaderSidebarTransitioning,
                                showImporter: { showingImporter = true }
                            )
                            .equatable()
                            .environmentObject(kept)
                            .environment(readerPool.studyPane(for: id) ?? studyPane)
                        )
                    }
                    .frame(width: readerSize.width, height: readerSize.height, alignment: .topLeading)
                    // No blur or opacity on the reader. Both force a full window
                    // of text into an offscreen buffer for every frame they are
                    // animated over.

                    if isReaderSidebarMounted {
                        StudyInspectorColumn(width: $studyInspectorWidth) {
                            if !isShown {
                                // Out of sight, the column keeps its place
                                // and nothing in it. What it holds observes
                                // the library, and would redraw for every
                                // change made in another section — beneath
                                // the reader's gate, which only stops what
                                // the reader is handed. The chat is kept by
                                // `KeptAgentChats`, a reply still arriving
                                // included, and is shown again on return.
                                Color.clear
                            } else if isReaderSidebarContentReady {
                                // A pane per kept tab, each in a hosting view of
                                // its own, as the readers are: the one shown is
                                // already laid out on its entry, chat or notes.
                                ReaderTabHosts(
                                    keptIDs: readerPool.keptIDs,
                                    currentID: readerPool.currentID
                                ) { id in
                                    tabSidebarContent(for: id)
                                }
                            } else {
                                ProgressView("Opening Study Tools…")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        // Laid out at full width and pinned to the trailing edge,
                        // so the pane itself never moves — the gap opens around
                        // it and it fades up in place.
                        //
                        // It must not move. This column contains `ScrollView`s,
                        // which on macOS are `NSScrollView`s, and SwiftUI sets a
                        // hosted AppKit view's frame once at the end of an
                        // animation rather than on each frame. Slide the column
                        // by any means — offset, padding, or its position in this
                        // row — and the chrome travels while the entries snap
                        // straight to where they will finish. Opacity has no such
                        // problem: it is a layer property, and the hosted views
                        // inherit it.
                        .frame(width: columnWidth, height: geometry.size.height)
                        .frame(width: revealedWidth, alignment: .trailing)
                        .opacity(revealProgress)
                        .allowsHitTesting(revealProgress > 0.99)
                    }
                }
                // Owned by the view rather than driven by `withAnimation` at the
                // call site: the change happens inside an async `.task`, and a
                // transaction opened there does not reliably reach the update
                // that renders it.
                // Only while the column is opening or closing. Otherwise the
                // width is a resize being dragged, or a tab switch that shows
                // that tab's column as it is, and both should simply land.
                .animation(
                    isReaderSidebarTransitioning
                        ? .smooth(duration: StudyInspectorMetrics.revealDuration)
                        : nil,
                    value: revealedWidth
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    ReaderLexicalHoverDetailsView(store: readerLexicalHoverStore)
                }
                // One animated width drives the whole transition: the reader
                // slides aside as the gap opens, and the pane fades up in the
                // space without moving.
                .task(id: readerSidebar != nil) {
                    let columnWidth = StudyInspectorMetrics.totalWidth(studyInspectorWidth)
                    if readerSidebarSwitchesInstantly {
                        readerSidebarSwitchesInstantly = false
                        let isOpen = readerSidebar != nil
                        isReaderSidebarTransitioning = false
                        isReaderSidebarMounted = isOpen
                        isReaderSidebarContentReady = isOpen
                        readerSidebarRevealedWidth = isOpen ? columnWidth : 0
                        return
                    }
                    if readerSidebar == nil,
                       !isReaderSidebarMounted,
                       readerSidebarRevealedWidth == 0 {
                        isReaderSidebarTransitioning = false
                        return
                    }
                    let duration = StudyInspectorMetrics.revealDuration
                    isReaderSidebarTransitioning = true
                    if readerSidebar != nil {
                        // Mount before moving. SwiftUI does not animate a view's
                        // first layout, so mounting and revealing in one pass
                        // would always look like a jump.
                        isReaderSidebarMounted = true
                        // Mount the real inspector immediately so a lookup made by
                        // the click that opens this column is adopted while the
                        // column arrives, rather than after the animation ends.
                        isReaderSidebarContentReady = true
                        await Task.yield()
                        guard !Task.isCancelled, readerSidebar != nil else { return }

                        // No `withAnimation`: the row carries its own.
                        readerSidebarRevealedWidth = columnWidth
                        do {
                            try await Task.sleep(for: .seconds(duration))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled, readerSidebar != nil else { return }
                        isReaderSidebarTransitioning = false
                    } else {
                        readerSidebarRevealedWidth = 0
                        do {
                            try await Task.sleep(for: .seconds(duration))
                        } catch {
                            return
                        }
                        guard readerSidebar == nil else { return }
                        isReaderSidebarMounted = false
                        isReaderSidebarContentReady = false
                        isReaderSidebarTransitioning = false
                    }
                }
            }
        }
        // The window's toolbar and menus belong to whichever section is
        // shown. Here, the window's own, not in each tab's reader: kept tabs'
        // readers would each bring theirs, and the toolbar was rebuilt on
        // every switch — a third of a switch's work.
        .toolbar { if isShown { readerToolbar } }
        // On the view, not on the toolbar button: a toolbar item is not in
        // the focus chain, so a focused value published from one never
        // reaches the menu and the command stays greyed out.
        .focusedSceneValue(\.goToPassageAction, isShown ? { workspace.isChoosingPassage = true } : nil)
        .toolbar(removing: isShown ? .title : nil)
        .focusedObject(isShown ? scrollLink : nil)
    }

    /// The passage this window's reader is on, for Today's way back to it:
    /// the verse being studied, or else the chapter's first.
    private var todayReaderPlace: TodayReaderPlace? {
        guard let chapter = workspace.chapter else { return nil }
        let verse = chapter.verses.first { $0.id == workspace.selectedVerseReference }
            ?? chapter.verses.first { $0.number > 0 }
        let translation = model.translations.first { $0.id == chapter.translationID }
        return TodayReaderPlace(
            title: "\(chapter.book.name) \(chapter.number)",
            // The full name: a short one like "BSBs", with its s for
            // Strong's, read as a cryptic code at a card's foot.
            translation: translation?.name ?? translation?.abbreviation ?? "",
            verseNumber: verse?.number,
            verseText: verse?.text
        )
    }

    @ViewBuilder
    private var sectionDetail: some View {
        switch selection {
        case .section(.reader):
            EmptyView()
        case .section(.today):
            TodayView(
                readerPlace: todayReaderPlace,
                showImporter: { showingImporter = true },
                showPlans: { selection = .section(.plans) },
                openReading: openPlanReading,
                openAllReadings: openAllPlanReadings,
                continueReading: { selection = .section(.reader) },
                openQuiz: { moduleID in
                    requestedQuizModuleID = moduleID
                    selection = .section(.quizzes)
                },
                openWriting: { id in
                    requestedDevotionalID = id
                    selection = .section(.devotionals)
                }
            )
        case .section(.plans):
            ReadingPlansView(
                initialPlanID: $requestedPlanID,
                showImporter: { showingImporter = true },
                openReading: openPlanReading,
                openAllReadings: openAllPlanReadings
            )
        case .section(.books):
            BookModulesView(
                initialBookID: requestedBookID,
                initialSectionID: requestedBookSectionID,
                showImporter: { showingImporter = true },
                openReference: { reference in
                    workspace.openReference(reference)
                    selection = .section(.reader)
                }
            )
        case .section(.devotionals):
            DevotionalsView(
                initialDevotionalID: $requestedDevotionalID,
                showImporter: { showingImporter = true },
                openReference: { reference in
                    workspace.openReference(reference)
                    selection = .section(.reader)
                }
            )
        case .section(.quizzes):
            QuizzesView(
                initialModuleID: $requestedQuizModuleID,
                showImporter: { showingImporter = true },
                openReference: { reference in
                    workspace.openReference(reference)
                    selection = .section(.reader)
                }
            )
        case .section(.search):
            UnifiedSearchView(
                tabs: $searchTabs,
                showImporter: { showingImporter = true },
                openReference: { reference, translationID in
                    workspace.openReference(reference, translationID: translationID)
                    selection = .section(.reader)
                },
                // The same routes the palette and links take, so a result
                // opens alike from Search and from ⌘K.
                openBook: { result in go(to: libraryRoute(for: result, placement: .here)) },
                openKind: { result in go(to: libraryRoute(for: result, placement: .here)) },
                openDictionaryEntry: { key, word in go(to: .dictionary(key, word: word)) }
            )
        case .section(.modules):
            InstalledModulesView(showImporter: { showingImporter = true })
        case nil:
            ContentUnavailableView("Choose a Section", systemImage: "sidebar.left")
        }
    }

}

/// The column open beside the reader, when one is. Kept with each tab.
typealias ReaderSidebar = ReaderTabSidebar.Pane

/// Content that takes no updates while it is out of sight, and is brought up to
/// date as it comes back into view. Without it the reader's tab bar and frame
/// were rebuilt, unseen, on every library change made from another section.
private struct OutOfSightUpdates<Content: View>: View, Equatable {
    let isShown: Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !lhs.isShown && !rhs.isShown
    }
}

/// The study column beside the reader, with a draggable leading edge.
///
/// Square-cornered and flush to the top of the reader area: it sits below the tab
/// bar rather than against the titlebar, so rounded corners would read as a
/// floating panel rather than a column of the window.
enum StudyInspectorMetrics {
    /// Wide enough that the Strong's analysis shows its tabs as tabs rather
    /// than a pop-up menu, at their most: Overview to Verses, the Septuagint
    /// for a Greek key it uses, and the chart button beside them, which
    /// measured 483pt (Nov 2026). It was 410, where the analysis's row gave
    /// up its tabs once the chart button joined it.
    static let defaultWidth = 484.0
    /// Narrow enough to leave the reader its page, wide enough for the study
    /// panes' own controls. The tab bar shows its five tabs from about 390pt,
    /// and below that the same choice as a pop-up menu.
    static let minimumWidth = 364.0
    static let maximumWidth = 580.0

    /// How long the column takes to arrive or leave.
    static let revealDuration: Double = 0.3

    static func clamped(_ width: Double) -> Double {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func totalWidth(_ width: Double) -> Double {
        clamped(width) + 1
    }
}

private struct StudyInspectorColumn<Content: View>: View {
    @Binding var width: Double
    @ViewBuilder let content: Content

    @State private var widthAtDragStart: Double?
    @State private var isShowingResizeCursor = false

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            content
                .frame(width: clampedWidth)
        }
        // A step off the reader's page, as an inspector is, so the two panes
        // part along their edge rather than along a hairline alone, which on
        // the dark window all but vanished.
        .background(Color.lampInspectorFill)
    }

    private var clampedWidth: Double {
        StudyInspectorMetrics.clamped(width)
    }

    private func setResizeCursor(_ isShowing: Bool) {
        guard isShowing != isShowingResizeCursor else { return }
        isShowingResizeCursor = isShowing
        if isShowing {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
    }

    private var resizeHandle: some View {
        Divider()
            .overlay {
                // Wider than the divider it sits on, because a one-point drag
                // target is a one-point drag target.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        setResizeCursor(isHovering)
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtDragStart ?? clampedWidth
                                widthAtDragStart = start
                                width = StudyInspectorMetrics.clamped(start - value.translation.width)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
                    // Hiding the column mid-hover would otherwise leave the resize
                    // cursor pushed with nothing left to pop it.
                    .onDisappear { setResizeCursor(false) }
            }
    }
}

/// A passage waiting for its reader to choose a Bible app.
struct ExternalBibleRequest: Identifiable, Equatable {
    let startReference: Int
    let endReference: Int?

    var id: String { "\(startReference)-\(endReference ?? startReference)" }
}

// MARK: - Go anywhere

/// Somewhere in Lamp a window can go. One route for the ⌘K palette, the
/// links Lamp is opened with and the Search pane, so each way in arrives at
/// the same place by the same steps.
fileprivate enum LibraryRoute {
    case passage(start: Int, end: Int?, translationID: String?, placement: CommandPalettePlacement)
    case location(ReaderLocation, placement: CommandPalettePlacement)
    case analysis(String)
    case dictionary(String, word: String?)
    case search(String)
    case section(LibrarySection)
    case book(moduleID: String, sectionID: String?)
    case writing(String)
    case plan(String)
    case quiz(String)
    case deck(String)
    case settings(ReaderSettingsSection?)
    case searchResult(LampModuleSearchResult, placement: CommandPalettePlacement)
}

extension LibraryRootView {
    fileprivate func go(to route: LibraryRoute) {
        switch route {
        case .passage(let start, let end, let translationID, let placement):
            let translation = translationID ?? workspace.selectedTranslationID
                ?? model.selectedTranslationID ?? model.translations.first?.id
            guard let translation else { return }
            go(to: .location(
                ReaderLocation.typed(reference: start, through: end ?? start, in: translation),
                placement: placement
            ))
        case .location(let location, let placement):
            switch placement {
            case .here:
                workspace.openHistoryLocation(location)
                selection = .section(.reader)
            case .newTab:
                openReaderTab(at: location)
            case .newWindow:
                // The new window opens at it: a reader window takes a place
                // held for it as it starts.
                model.holdForNextReader(location)
                openWindow(id: "reader")
            }
        case .analysis(let key):
            workspace.requestedStrongsKey = key
        case .dictionary(let key, let word):
            model.requestDictionaryLookup(keys: [key], word: word)
            studyPane.tool = "dictionary"
            readerSidebar = .study
            selection = .section(.reader)
        case .search(let words):
            workspace.requestedSearch = words
        case .section(let section):
            selection = .section(section)
        case .book(let moduleID, let sectionID):
            // Cleared, then asked for on the next turn: Books follows a
            // change in what is asked for, and asking for the book it was
            // last asked for — another chosen by hand since — changes nothing.
            requestedBookID = nil
            requestedBookSectionID = nil
            selection = .section(.books)
            DispatchQueue.main.async {
                requestedBookID = moduleID
                requestedBookSectionID = sectionID
            }
        case .writing(let id):
            requestedDevotionalID = id
            selection = .section(.devotionals)
        case .plan(let id):
            requestedPlanID = id
            selection = .section(.plans)
        case .quiz(let moduleID):
            requestedQuizModuleID = moduleID
            selection = .section(.quizzes)
        case .deck(let id):
            openWindow(id: "slide-studio", value: SlideStudioRequest(deckID: id))
        case .settings(let section):
            SettingsDestination.shared.section = section
            openSettings()
        case .searchResult(let result, let placement):
            go(to: libraryRoute(for: result, placement: placement))
        }
    }

    /// Where a library search result goes, as the Search pane opens it.
    fileprivate func libraryRoute(for result: LampModuleSearchResult, placement: CommandPalettePlacement) -> LibraryRoute {
        switch result.kind {
        case .devotional:
            guard let id = LampSearchResultIdentity.entryID(
                in: result.id, kind: "devotional", moduleID: result.moduleID
            ) else { return .section(.devotionals) }
            return .writing(id)
        case .plan:
            return .plan(result.moduleID)
        case .quiz:
            return .quiz(result.moduleID)
        case .book:
            let prefix = "book:\(result.moduleID):"
            return .book(
                moduleID: result.moduleID,
                sectionID: result.id.hasPrefix(prefix) ? String(result.id.dropFirst(prefix.count)) : result.id
            )
        case .dictionary:
            if let key = result.entryKey { return .dictionary(key, word: result.title) }
            return .search(result.title)
        default:
            guard let start = result.startReference else { return .search(result.title) }
            let translationID: String? = switch result.kind {
            case .translation: result.moduleID
            case .highlights:
                result.moduleID.hasPrefix("highlights:")
                    ? String(result.moduleID.dropFirst("highlights:".count)).nonEmpty
                    : nil
            default: nil
            }
            return .passage(start: start, end: result.endReference, translationID: translationID, placement: placement)
        }
    }

    // MARK: Palette rows

    /// Rows for what has been typed: a passage, a Strong's key, words.
    fileprivate func paletteTypedItems(_ typed: String) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        // Opened in the translation being read, so read and named by its
        // book names too.
        let bookNames = model.bookNames(of: model.selectedTranslationID)
        if let reference = LampSearchQuery(typed).reference(bookNames: bookNames) {
            items.append(CommandPaletteItem(
                id: "go:\(reference.startReference)-\(reference.endReference)",
                group: .suggested,
                title: "Go to \(reference.description(bookNames: bookNames))",
                systemImage: "book",
                opensPlaces: true,
                perform: { placement in
                    go(to: .passage(
                        start: reference.startReference, end: reference.endReference,
                        translationID: nil, placement: placement
                    ))
                }
            ))
        }
        if let key = LampStrongsKey.typedKey(typed) {
            items.append(CommandPaletteItem(
                id: "analyse:\(key)", group: .suggested, title: "Analyse \(key)",
                systemImage: "chart.bar.xaxis", perform: { _ in go(to: .analysis(key)) }
            ))
            items.append(CommandPaletteItem(
                id: "lookup:\(key)", group: .suggested, title: "Look Up \(key)",
                detail: "Dictionary",
                systemImage: "character.book.closed", perform: { _ in go(to: .dictionary(key, word: nil)) }
            ))
        }
        items.append(CommandPaletteItem(
            id: "search:\(typed)", group: .search, title: "Search for “\(typed)”",
            detail: "Everything, in Search",
            systemImage: "magnifyingglass", perform: { _ in go(to: .search(typed)) }
        ))
        return items
    }

    /// Matches in the library, a few of each kind, as Search would open them.
    /// The library's matches for the palette, by kind: on the main page the
    /// best few of every kind that matched, so a common word shows each kind
    /// rather than whichever won a merged list's ties; on one kind's page, a
    /// page of that kind, searched afresh rather than cut from the few.
    fileprivate func paletteLibraryResults(
        _ words: String, level: CommandPaletteLibraryLevel?
    ) async -> [CommandPaletteLibraryGroup] {
        // A module's short name where it has one: "NIC", not its full title.
        let abbreviations = Dictionary(
            model.modules.compactMap { module in module.abbreviation.map { (module.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let kind = level.flatMap { LampModuleKind(rawValue: $0.id) }
        let kinds: Set<LampModuleKind>? = kind.map { [$0] }
        // The main page is shared among the kinds that matched, a few each,
        // and the palette shows what fits; a kind's page is all one kind's.
        // Hidden modules are left out of the search itself, as Search leaves
        // them: filtered afterwards, their matches had already taken places.
        // Nil is every module: nothing is hidden.
        let searchable: Set<String>?
        do { searchable = try await model.searchableModuleIDs() } catch { return [] }
        // Scripture on the main page from the reading translation, as
        // Search's page of every kind takes it; Scripture's own page has
        // every translation.
        let groups = (try? await model.library.searchModulesByKind(
            query: words, kinds: kinds, moduleIDs: searchable,
            preferredTranslationID: kind == nil ? model.readingTranslationID : nil,
            limit: kind == nil ? Self.paletteMainPage : Self.paletteKindPage
        )) ?? []
        // Sections in the order Search shelves them, which both apps follow.
        let shelved = groups.sorted {
            (LampModuleSearch.shelfOrder.firstIndex(of: $0.kind) ?? .max)
                < (LampModuleSearch.shelfOrder.firstIndex(of: $1.kind) ?? .max)
        }
        return shelved.map { group in
            CommandPaletteLibraryGroup(
                level: CommandPaletteLibraryLevel(id: group.kind.rawValue, title: group.kind.displayName),
                items: group.results.map { result in
                    let opensPlace = result.startReference != nil
                        && ![.devotional, .plan, .quiz, .book, .dictionary].contains(result.kind)
                    return CommandPaletteItem(
                        id: "result:\(result.id)",
                        group: .results,
                        title: result.title,
                        subtitle: result.snippet,
                        detail: abbreviations[result.moduleID] ?? result.moduleName,
                        systemImage: Self.paletteIcon(for: result.kind),
                        opensPlaces: opensPlace,
                        perform: { placement in go(to: .searchResult(result, placement: placement)) }
                    )
                },
                // Scripture from one translation offers the others.
                hasMore: group.hasMore || !group.alsoInTranslationIDs.isEmpty
            )
        }
    }

    /// The main page's matches, shared among the kinds; the palette shows
    /// one of each and more while there is room (CommandPaletteView's fill).
    private static let paletteMainPage = 36
    /// One kind's own page.
    private static let paletteKindPage = 50

    /// Things to open by name, commands, sections and settings.
    fileprivate func paletteNamedItems(decks: [LampPresentationDeck]) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        for book in model.modules where book.kind == .book && !model.hiddenModuleIDs.contains(book.id) {
            items.append(CommandPaletteItem(
                id: "book:\(book.id)", group: .open, title: book.name, detail: "Book",
                systemImage: "book.closed", perform: { _ in go(to: .book(moduleID: book.id, sectionID: nil)) }
            ))
        }
        for writing in model.devotionals {
            items.append(CommandPaletteItem(
                id: "writing:\(writing.id)", group: .open, title: writing.title,
                detail: writing.isEditable ? "Writing" : "Writing · \(writing.moduleName)",
                systemImage: "sun.max", perform: { _ in go(to: .writing(writing.id)) }
            ))
        }
        for deck in decks {
            items.append(CommandPaletteItem(
                id: "deck:\(deck.id)", group: .open, title: deck.title, detail: "Presentation deck",
                systemImage: "rectangle.on.rectangle", perform: { _ in go(to: .deck(deck.id)) }
            ))
        }
        for plan in model.plans {
            items.append(CommandPaletteItem(
                id: "plan:\(plan.id)", group: .open, title: plan.name, detail: "Reading plan",
                systemImage: "checklist", perform: { _ in go(to: .plan(plan.id)) }
            ))
        }
        for quiz in model.quizModules {
            items.append(CommandPaletteItem(
                id: "quiz:\(quiz.id)", group: .open, title: quiz.name, detail: "Quiz",
                systemImage: "questionmark.bubble", perform: { _ in go(to: .quiz(quiz.id)) }
            ))
        }
        items += paletteCommands()
        for section in LibrarySection.allCases {
            items.append(CommandPaletteItem(
                id: "section:\(section.rawValue)", group: .sections, title: section.rawValue,
                systemImage: section.systemImage, perform: { _ in go(to: .section(section)) }
            ))
        }
        for section in ReaderSettingsSection.allCases {
            items.append(CommandPaletteItem(
                id: "settings:\(section.rawValue)", group: .settings, title: "Settings › \(section.title)",
                systemImage: section.systemImage, keywords: section.paletteKeywords,
                perform: { _ in go(to: .settings(section)) }
            ))
        }
        return items
    }

    private func paletteCommands() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = [
            CommandPaletteItem(
                id: "command:new-writing", group: .commands, title: "New Writing",
                systemImage: "square.and.pencil", keywords: ["Write", "Devotional", "Note"],
                perform: { _ in openWindow(id: "devotional-editor", value: DevotionalEditorRequest(devotionalID: nil)) }
            ),
            CommandPaletteItem(
                id: "command:new-deck", group: .commands, title: "New Presentation Deck",
                systemImage: "rectangle.stack.badge.plus", keywords: ["Slides", "Slide Studio"],
                perform: { _ in openWindow(id: "slide-studio", value: SlideStudioRequest(newDeckID: UUID().uuidString)) }
            ),
            CommandPaletteItem(
                id: "command:new-tab", group: .commands, title: "New Reader Tab",
                systemImage: "plus.square.on.square", perform: { _ in presentNewReaderTabChooser() }
            ),
            CommandPaletteItem(
                id: "command:new-window", group: .commands, title: "New Reader Window",
                systemImage: "macwindow.badge.plus", perform: { _ in openWindow(id: "reader") }
            ),
            CommandPaletteItem(
                id: "command:install", group: .commands, title: "Install Module…",
                systemImage: "square.and.arrow.down", keywords: ["Add Translation", "Import Module"],
                perform: { _ in showingImporter = true }
            ),
            CommandPaletteItem(
                id: "command:import-study-data", group: .commands, title: "Import Personal Study Data…",
                systemImage: "tray.and.arrow.down", perform: { _ in showingStudyDataImporter = true }
            ),
            CommandPaletteItem(
                id: "command:back", group: .commands, title: "Go Back",
                systemImage: "chevron.backward", keywords: ["Previous place", "History"],
                perform: { _ in workspace.goBackInHistory(); selection = .section(.reader) }
            ),
            CommandPaletteItem(
                id: "command:forward", group: .commands, title: "Go Forward",
                systemImage: "chevron.forward", perform: { _ in workspace.goForwardInHistory(); selection = .section(.reader) }
            ),
            CommandPaletteItem(
                id: "command:hide-study", group: .commands, title: "Hide Study Tools",
                systemImage: "sidebar.trailing", perform: { _ in readerSidebar = nil }
            ),
        ]
        for (tool, title, image) in [
            ("commentary", "Commentary", "text.book.closed"), ("verse", "Verse", "text.quote"),
            ("notes", "Notes", "note.text"), ("dictionary", "Dictionary", "character.book.closed"),
        ] {
            items.append(CommandPaletteItem(
                id: "command:study-\(tool)", group: .commands, title: "Show \(title)",
                detail: "Study tools", systemImage: image, keywords: ["Study Tools"],
                perform: { _ in
                    studyPane.tool = tool
                    readerSidebar = .study
                    selection = .section(.reader)
                }
            ))
        }
        // Only with AI features on: off, nothing in Lamp mentions a chat.
        if aiFeaturesEnabled {
            items.append(CommandPaletteItem(
                id: "command:reader-chat", group: .commands, title: "Reader Chat",
                systemImage: "bubble.left.and.bubble.right", keywords: ["AI", "Ask", "Chat"],
                perform: { _ in
                    readerSidebar = .chat
                    selection = .section(.reader)
                }
            ))
        }
        for translation in model.translations where !model.hiddenModuleIDs.contains(translation.id) {
            let name = translation.abbreviation ?? translation.name
            items.append(CommandPaletteItem(
                id: "command:translation-\(translation.id)", group: .commands, title: "Read in \(name)",
                detail: translation.abbreviation == nil ? nil : translation.name,
                systemImage: "character.book.closed", keywords: [translation.name, "Translation", "Switch"],
                perform: { _ in
                    workspace.selectTranslation(translation.id)
                    selection = .section(.reader)
                }
            ))
        }
        return items
    }

    /// Before anything is typed: where you were, what you searched for, the
    /// books you are reading and the writing you were last in.
    fileprivate func paletteRecentItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        for location in workspace.recentLocations.prefix(5) {
            items.append(CommandPaletteItem(
                id: "recent:\(location.translationID):\(location.bookNumber):\(location.chapterNumber):\(location.verseReference ?? 0)",
                group: .recent, title: paletteLabel(location), systemImage: "clock.arrow.circlepath",
                opensPlaces: true, perform: { placement in go(to: .location(location, placement: placement)) }
            ))
        }
        let history = LampSearchHistoryMigration.history(
            from: UserDefaults.standard.data(forKey: "search.history") ?? Data()
        )
        for entry in history.entries.prefix(3) {
            let words = entry.strongsKey ?? entry.query
            items.append(CommandPaletteItem(
                id: "recent-search:\(entry.id)", group: .recent, title: "Search for “\(words)”",
                systemImage: "magnifyingglass", perform: { _ in go(to: .search(words)) }
            ))
        }
        let positions = LampBookReadingStateStore().positions()
        let reading = positions.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(2)
        for (moduleID, position) in reading {
            guard let book = model.modules.first(where: { $0.id == moduleID }) else { continue }
            items.append(CommandPaletteItem(
                id: "recent-book:\(moduleID)", group: .recent, title: book.name, detail: "Continue reading",
                systemImage: "book.closed",
                perform: { _ in go(to: .book(moduleID: moduleID, sectionID: position.sectionID)) }
            ))
        }
        let writings = model.devotionals
            .filter(\.isEditable)
            .sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
            .prefix(2)
        for writing in writings {
            items.append(CommandPaletteItem(
                id: "recent-writing:\(writing.id)", group: .recent, title: writing.title, detail: "Writing",
                systemImage: "sun.max", perform: { _ in go(to: .writing(writing.id)) }
            ))
        }
        return items
    }

    /// "John 3 (BSB)", as the reader's history menu names a place.
    private func paletteLabel(_ location: ReaderLocation) -> String {
        let book = model.bookName(location.bookNumber, in: location.translationID)
        let translation = model.translations.first { $0.id == location.translationID }
        let name = translation?.abbreviation ?? translation?.name ?? location.translationID
        return "\(book) \(location.chapterNumber) (\(name))"
    }

    private static func paletteIcon(for kind: LampModuleKind) -> String {
        switch kind {
        case .translation: "book"
        case .dictionary: "character.book.closed"
        case .commentary: "text.book.closed"
        case .book: "book.closed"
        case .devotional: "sun.max"
        case .notes: "note.text"
        case .plan: "checklist"
        case .highlights: "highlighter"
        case .quiz: "questionmark.bubble"
        default: "doc.text"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// ⌘K when the menu found no focused value to call (see LampBibleCommands):
/// the library window it names answers, so one press opens one palette.
private struct CommandPaletteToggleReceiver: ViewModifier {
    @Binding var isPalettePresented: Bool
    @State private var host = CommandPaletteWindows.Host()

    func body(content: Content) -> some View {
        content
            .background {
                CommandPaletteWindows.Registrar(host: host)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .lampToggleCommandPalette)) { note in
                if let target = note.object as? NSWindow, target === host.window {
                    isPalettePresented.toggle()
                }
            }
    }
}

/// The library windows open now, so ⌘K can name one when the menu has no
/// focused value to call: the key window if it is a library, otherwise the
/// frontmost library, brought forward; with none open, the next one to
/// open (`paletteRequestedForNextWindow`). Never nobody — an enabled ⌘K that
/// does nothing is worse than a greyed one.
@MainActor
enum CommandPaletteWindows {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    /// When ⌘K, finding no library window, opened one: the first to
    /// register within a few seconds opens its palette. Past that the
    /// request is stale, so a window opened later for another reason
    /// doesn't inherit it.
    static var paletteRequestedForNextWindow: Date?

    static func target() -> NSWindow? {
        if let key = NSApp.keyWindow, windows.contains(key) { return key }
        return NSApp.orderedWindows.first { windows.contains($0) && $0.isVisible }
    }

    final class Host {
        weak var window: NSWindow?
    }

    struct Registrar: NSViewRepresentable {
        let host: Host

        final class Probe: NSView {
            var host: Host?
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                host?.window = window
                guard let window else { return }
                CommandPaletteWindows.windows.add(window)
                if let requested = CommandPaletteWindows.paletteRequestedForNextWindow {
                    CommandPaletteWindows.paletteRequestedForNextWindow = nil
                    guard Date().timeIntervalSince(requested) < 5 else { return }
                    // A turn later, once the receiver is listening.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .lampToggleCommandPalette, object: window)
                    }
                }
            }
        }

        func makeNSView(context: Context) -> Probe {
            let probe = Probe()
            probe.host = host
            return probe
        }

        func updateNSView(_ probe: Probe, context: Context) {}
    }
}
