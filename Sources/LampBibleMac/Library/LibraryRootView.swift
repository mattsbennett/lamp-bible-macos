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
    /// Whether this window is the one being used, which is how the library
    /// knows whose place to hand to the writing editor and Slide Studio.
    @Environment(\.controlActiveState) private var controlActiveState
    @EnvironmentObject private var model: LibraryModel
    /// This window's own place in scripture. Each reader window has one, which
    /// is what lets two of them sit on different chapters.
    @StateObject private var workspace = ReaderWorkspace()
    @EnvironmentObject private var syncController: LibrarySyncController
    @EnvironmentObject private var scrollLink: ReaderScrollLink
    @State private var selection: LibrarySelection? = .section(.reader)
    /// The search's own query, so the reader's reference field can hand words
    /// to it. The same key the search reads, in the same scene.
    @SceneStorage("search.query") private var searchQuery = ""
    @SceneStorage("search.strongsKey") private var searchStrongsKey = ""
    /// A passage waiting for the reader to say which Bible app to open it in,
    /// because they chose "Ask Each Time".
    @State private var externalBibleRequest: ExternalBibleRequest?
    @State private var showingImporter = false
    @State private var showingStudyDataImporter = false
    @State private var readerTabs = ReaderTabCollection()
    @SceneStorage("reader.tabs") private var savedReaderTabs: Data?
    @State private var hasRestoredReaderTabs = false
    @State private var showingNewReaderTab = false
    @State private var readerSidebar: ReaderSidebar?
    @State private var lastReaderSidebar = ReaderSidebar.study
    @SceneStorage("reader.chat.windowID") private var readerChatWindowID = UUID().uuidString
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
    /// Set when leaving the reader closed its study column. The reader takes no
    /// updates while it's out of sight, so the column is still drawn open there,
    /// and the close reaches it only as it's shown again: where it mustn't
    /// animate, or the column would be seen closing.
    @State private var readerSidebarClosedOutOfSight = false
    @State private var planReadingMode: PlanReadingMode?
    // Keep hover mutations out of this view's observation graph. Only the small
    // readout observes the store, so moving between words cannot rebuild the
    // reader's selectable text hierarchy underneath the pointer.
    @State private var readerLexicalHoverStore = ReaderLexicalHoverStore()
    @AppStorage("studyInspector.width") private var studyInspectorWidth = StudyInspectorMetrics.defaultWidth
    @AppStorage("studyInspector.tab") private var selectedStudyTab = "commentary"

    private var showingStudyInspector: Binding<Bool> {
        Binding(
            get: { readerSidebar == .study },
            set: { if $0 { readerSidebar = .study } else if readerSidebar == .study { readerSidebar = nil } }
        )
    }

    private var showingReaderChat: Binding<Bool> {
        Binding(
            get: { readerSidebar == .chat },
            set: { if $0 { readerSidebar = .chat } else if readerSidebar == .chat { readerSidebar = nil } }
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
            if UUID(uuidString: readerChatWindowID) == nil {
                readerChatWindowID = UUID().uuidString
            }
            model.start()
        }
        .onChange(of: model.hasReadLibrary, initial: true) { _, read in
            if read { restoreReaderTabs() }
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
            guard hasRestoredReaderTabs else { return }
            savedReaderTabs = ReaderTabSessionStore.save(tabs)
        }
        .environmentObject(workspace)
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
        .onChange(of: controlActiveState) { _, state in
            // The reader last used is the one other windows mean by "the
            // current verse". Set as this window comes forward rather than as
            // another goes back, so closing one does not leave the library
            // pointing at a window that has gone.
            guard state == .key, hasRestoredReaderTabs else { return }
            model.activeReader = workspace
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

    private var libraryInterface: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Study") {
                    ForEach(LibrarySection.allCases.filter { $0 != .modules }) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(LibrarySelection.section(section))
                    }
                }

                Section("Library") {
                    Label(LibrarySection.modules.rawValue, systemImage: LibrarySection.modules.systemImage)
                        .tag(LibrarySelection.section(.modules))
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
        .focusedValue(\.newReaderTabAction, { presentNewReaderTabChooser() })
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
            searchQuery = words
            selection = .section(.search)
            workspace.requestedSearch = nil
        }
        .onChange(of: workspace.requestedStrongsKey) { _, key in
            guard let key else { return }
            // The key and the box; the search sets its own content filter
            // from the key, since it owns that setting and two writers of
            // one scene key do not agree.
            searchQuery = key
            searchStrongsKey = key
            selection = .section(.search)
            workspace.requestedStrongsKey = nil
        }
        .onChange(of: selection) { _, newValue in
            if !isReaderSelection(newValue) {
                if readerSidebar != nil || isReaderSidebarMounted {
                    readerSidebarClosedOutOfSight = true
                }
                // Closed outright rather than by the column's animated task,
                // which would run only once the reader is shown again.
                readerSidebar = nil
                isReaderSidebarMounted = false
                isReaderSidebarContentReady = false
                isReaderSidebarTransitioning = false
                readerSidebarRevealedWidth = 0
                // Its popover hangs from the reader's tab bar.
                showingNewReaderTab = false
            } else if readerSidebarClosedOutOfSight {
                // Shown again, and the update that showed it closed the column.
                readerSidebarClosedOutOfSight = false
            }
        }
        .onChange(of: workspace.currentLocation) { _, location in
            if hasRestoredReaderTabs, let location {
                readerTabs.updateSelected(location: location)
            }
            updateActivePlanReading(for: location)
        }
        .onChange(of: readerSidebar) { _, sidebar in
            if let sidebar { lastReaderSidebar = sidebar }
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
            model.requestDictionaryLookup(keys: [key])
            selectedStudyTab = "dictionary"
            readerSidebar = .study
            selection = .section(.reader)
        case .book(let moduleID, let sectionID):
            requestedBookID = moduleID
            requestedBookSectionID = sectionID
            selection = .section(.books)
        case .section(let section):
            selection = .section(LibrarySection(rawValue: section.displayName) ?? .reader)
        case .moduleFile(let url):
            model.install([url])
            selection = .section(.modules)
        case .dataFile(let url):
            model.openDataFile(url)
        }
    }

    /// Opens this window's tabs, and its reader at the tab chosen in them,
    /// once the library has been read: which translations remain, for the
    /// tabs, and which note and highlight modules the chapter is read with.
    private func restoreReaderTabs() {
        guard !hasRestoredReaderTabs, model.hasReadLibrary, !model.isRefreshing else { return }
        // A failed library load must not replace saved tabs with an empty session.
        guard model.errorMessage == nil || !model.modules.isEmpty else { return }
        readerTabs = ReaderTabSessionStore.load(
            sceneData: savedReaderTabs,
            translationIDs: Set(model.translations.map(\.id)),
            fallbackLocation: model.readerLocation
        )
        hasRestoredReaderTabs = true
        // A place asked for while no reader was open goes in the chosen tab.
        workspace.start(
            model: model,
            at: model.takePendingReaderLocation() ?? readerTabs.selectedTab?.location
        )
        model.activeReader = workspace
    }

    private func presentNewReaderTabChooser() {
        selection = .section(.reader)
        showingNewReaderTab = true
    }

    private func duplicateCurrentReaderTab() {
        guard let location = workspace.currentLocation else { return }
        openReaderTab(at: location)
    }

    private func openReaderTab(at location: ReaderLocation) {
        readerTabs.updateSelected(location: workspace.currentLocation)
        readerTabs.add(location: location)
        workspace.openTab(at: location)
        selection = .section(.reader)
    }

    private func selectReaderTab(_ id: UUID) {
        guard id != readerTabs.selectedID else { return }
        readerTabs.updateSelected(location: workspace.currentLocation)
        if let location = readerTabs.select(id) {
            workspace.openTab(at: location)
        }
        selection = .section(.reader)
    }

    private func closeReaderTab(_ id: UUID) {
        guard readerTabs.tabs.count > 1 else { return }
        let wasSelected = readerTabs.selectedID == id
        if wasSelected { readerTabs.updateSelected(location: workspace.currentLocation) }
        let destination = readerTabs.close(id)
        if wasSelected, let destination {
            workspace.openTab(at: destination)
        }
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
        workspace.openTab(at: lastLocation)
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

    private func readerDetail(isShown: Bool) -> some View {
        VStack(spacing: 0) {
            if planReadingMode == nil {
                ReaderTabBar(
                    tabs: readerTabs.tabs,
                    selectedID: readerTabs.selectedID,
                    currentLocation: workspace.currentLocation,
                    showingNewTab: $showingNewReaderTab,
                    select: selectReaderTab,
                    close: closeReaderTab,
                    duplicate: duplicateCurrentReaderTab,
                    openLocation: { openReaderTab(at: $0) }
                )
                Divider()
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
                HStack(spacing: 0) {
                    TranslationReaderView(
                        model: model,
                        workspace: workspace,
                        isShown: isShown,
                        planReadingMode: $planReadingMode,
                        readerSidebar: $readerSidebar,
                        lexicalHoverStore: readerLexicalHoverStore,
                        isSidebarTransitioning: isReaderSidebarTransitioning,
                        showImporter: { showingImporter = true }
                    )
                    .equatable()
                    // Animated, and the passage re-wraps as it goes — the same
                    // thing the plan-reading quiz panel does, which is smooth.
                    // The reflow was never the expensive part; measuring the
                    // passage to *derive* a width was, and the exact frames here
                    // and around the ScrollView are what stop that happening.
                    .frame(
                        width: max(geometry.size.width - revealedWidth, 0),
                        height: geometry.size.height
                    )
                    // No blur or opacity on the reader. Both force a full window
                    // of text into an offscreen buffer for every frame they are
                    // animated over.

                    if isReaderSidebarMounted {
                        StudyInspectorColumn(width: $studyInspectorWidth) {
                            if isReaderSidebarContentReady {
                                if (readerSidebar ?? lastReaderSidebar) == .chat,
                                   let windowID = UUID(uuidString: readerChatWindowID) {
                                    ReaderChatSidebarView(
                                        windowID: windowID,
                                        close: { readerSidebar = nil }
                                    )
                                } else {
                                    StudyInspectorView(isPresented: showingStudyInspector)
                                        .environmentObject(model)
                                        .environmentObject(scrollLink)
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
                .animation(
                    readerSidebarClosedOutOfSight
                        ? nil
                        : .smooth(duration: StudyInspectorMetrics.revealDuration),
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
    }

    @ViewBuilder
    private var sectionDetail: some View {
        switch selection {
        case .section(.reader):
            EmptyView()
        case .section(.today):
            TodayPlansView(
                showImporter: { showingImporter = true },
                showPlans: { selection = .section(.plans) },
                openReading: openPlanReading,
                openAllReadings: openAllPlanReadings
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
                showImporter: { showingImporter = true },
                openReference: { reference, translationID in
                    workspace.openReference(reference, translationID: translationID)
                    selection = .section(.reader)
                },
                openBook: { result in
                    requestedBookID = result.moduleID
                    let prefix = "book:\(result.moduleID):"
                    requestedBookSectionID = result.id.hasPrefix(prefix)
                        ? String(result.id.dropFirst(prefix.count))
                        : result.id
                    selection = .section(.books)
                },
                openKind: { result in
                    // The section *and* the item. Switching section alone
                    // landed the reader in a list of everything, with the
                    // result they had just chosen nowhere in particular.
                    switch result.kind {
                    case .devotional:
                        requestedDevotionalID = LampSearchResultIdentity.entryID(
                            in: result.id, kind: "devotional", moduleID: result.moduleID
                        )
                        selection = .section(.devotionals)
                    case .plan:
                        requestedPlanID = result.moduleID
                        selection = .section(.plans)
                    case .quiz:
                        requestedQuizModuleID = result.moduleID
                        selection = .section(.quizzes)
                    case .book:
                        selection = .section(.books)
                    default:
                        break
                    }
                },
                openDictionaryEntry: { key, word in
                    // The Dictionary pane lives in the reader's study column,
                    // so the lookup is asked for and the reader shown; the
                    // pane picks the request up when it mounts.
                    model.requestDictionaryLookup(keys: [key], word: word)
                    selection = .section(.reader)
                }
            )
        case .section(.modules):
            InstalledModulesView(showImporter: { showingImporter = true })
        case nil:
            ContentUnavailableView("Choose a Section", systemImage: "sidebar.left")
        }
    }

}

/// The column open beside the reader, when one is.
private enum ReaderSidebar { case study, chat }

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

/// Shown while the library is being read, in place of an interface that would
/// otherwise assemble itself around an empty reader and a progress spinner in the
/// corner.
private struct LampSplashView: View {
    @State private var isShowingSlowStartMessage = false

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 108, height: 108)
                .accessibilityHidden(true)

            Text("Lamp Bible")
                .font(.title2.weight(.semibold))

            ProgressView()
                .controlSize(.small)

            Text(isShowingSlowStartMessage
                ? "Preparing your library. This happens once after an update."
                : "Opening your library…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // The bundled modules are unpacked and verified on a first run or after an
        // update, which takes long enough to be worth explaining.
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { isShowingSlowStartMessage = true }
        }
    }
}

/// The study column beside the reader, with a draggable leading edge.
///
/// Square-cornered and flush to the top of the reader area: it sits below the tab
/// bar rather than against the titlebar, so rounded corners would read as a
/// floating panel rather than a column of the window.
enum StudyInspectorMetrics {
    static let defaultWidth = 410.0
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
        .background(.background)
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

private struct ReaderTabBar: View {
    let tabs: [ReaderTab]
    let selectedID: UUID
    let currentLocation: ReaderLocation?
    @Binding var showingNewTab: Bool
    let select: (UUID) -> Void
    let close: (UUID) -> Void
    let duplicate: () -> Void
    let openLocation: (ReaderLocation) -> Void

    @State private var hoveredTabID: UUID?
    @State private var isHoveringNewTab = false

    private static let height: CGFloat = 30

    var body: some View {
        ScrollView(.horizontal) {
            // Contiguous full-height cells divided by hairlines, so the row reads
            // as a rank of tabs rather than a row of floating buttons. The new-tab
            // button rides at the end of the rank instead of across the window,
            // which means it scrolls away with the tabs it belongs to.
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabCell(tab)
                    separator
                }
                newTabButton
                separator
            }
            .frame(height: Self.height)
        }
        .scrollIndicators(.hidden)
        .frame(height: Self.height)
        .background(.bar)
    }

    private var separator: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
    }

    private func tabCell(_ tab: ReaderTab) -> some View {
        let isSelected = tab.id == selectedID
        let isHovered = hoveredTabID == tab.id
        // Siblings rather than a close button nested inside the tab button: a
        // Button inside another Button's label is a fight over the click.
        return HStack(spacing: 5) {
            Button {
                select(tab.id)
            } label: {
                Text(tabTitle(tab))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if tabs.count > 1 {
                Button("Close \(tabTitle(tab))", systemImage: "xmark") {
                    close(tab.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                // Revealed on approach, so idle tabs stay titles rather than a
                // row of crosses.
                .opacity(isSelected || isHovered ? 1 : 0)
                .help("Close tab")
            }
        }
        .font(.subheadline)
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .frame(minWidth: 104, maxWidth: 190)
        .frame(height: Self.height)
        // A shape style fills the safe area too unless told not to, and the
        // bar sits right under the toolbar: the open tab's fill would rise
        // up behind it.
        .background(cellBackground(isSelected: isSelected, isHovered: isHovered), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .opacity(isSelected ? 1 : 0)
        }
        .onHover { isHovering in
            hoveredTabID = isHovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
        }
        .help(tabTitle(tab))
    }

    private func cellBackground(isSelected: Bool, isHovered: Bool) -> some ShapeStyle {
        if isSelected {
            // The content colour, so the open tab reads as the page below it.
            return AnyShapeStyle(.background)
        }
        return isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }

    private var newTabButton: some View {
        Button {
            showingNewTab = true
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: Self.height)
                .background(
                    isHoveringNewTab ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    ignoresSafeAreaEdges: []
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNewTab = $0 }
        .help("New reader tab (⌘T)")
        // The reader's own passage picker, less the two things a tab cannot
        // do: a tab opens a chapter, so words to search for and Strong's
        // keys have nowhere to go here.
        .popover(isPresented: $showingNewTab) {
            PassagePickerPopover(
                isPresented: $showingNewTab,
                open: openLocation,
                headline: "Open in a new tab",
                duplicate: currentLocation == nil ? nil : duplicate
            )
        }
    }

    private func tabTitle(_ tab: ReaderTab) -> String {
        guard let location = tab.location else { return "Reader" }
        return "\(LampBibleReferenceFormatter.bookName(location.bookNumber)) \(location.chapterNumber)"
    }
}

private struct PlanReadingModeBar: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var mode: PlanReadingMode?
    @Binding var showingQuiz: Bool
    let openReading: (LampPlanReading) -> Void

    var body: some View {
        if let mode {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Plan Reading", systemImage: "checklist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("\(mode.planName) · \(formattedDate(for: mode))")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(minWidth: 160, alignment: .leading)

                Divider()
                    .frame(height: 30)

                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(mode.readings) { reading in
                            HStack(spacing: 4) {
                                Button {
                                    model.toggleReading(
                                        planID: mode.planID,
                                        day: mode.day,
                                        readingIndex: reading.id,
                                        year: mode.year
                                    )
                                } label: {
                                    Image(systemName: isCompleted(reading, in: mode)
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(isCompleted(reading, in: mode) ? Color.accentColor : .secondary)
                                .help(isCompleted(reading, in: mode) ? "Mark incomplete" : "Mark complete")

                                Button(reading.displayDescription) {
                                    openReading(reading)
                                }
                                .buttonStyle(.plain)
                                .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                reading.id == mode.activeReadingID
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(
                                    reading.id == mode.activeReadingID
                                        ? Color.accentColor.opacity(0.5)
                                        : Color.secondary.opacity(0.18)
                                )
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)

                Button(showingQuiz ? "Hide Quiz" : "Show Quiz", systemImage: "questionmark.bubble") {
                    showingQuiz.toggle()
                }
                .buttonStyle(.bordered)

                Button("Exit Reading Mode", systemImage: "xmark.circle") {
                    self.mode = nil
                }
                .buttonStyle(.borderless)
                .help("Exit plan reading mode")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func isCompleted(_ reading: LampPlanReading, in mode: PlanReadingMode) -> Bool {
        model.completedReadingIDs.contains(
            reading.completionID(planID: mode.planID, day: mode.day, year: mode.year)
        )
    }

    private func formattedDate(for mode: PlanReadingMode) -> String {
        LampPlanCalendar.date(forDayNumber: mode.day, year: mode.year)?
            .formatted(date: .abbreviated, time: .omitted)
            ?? "Day \(mode.day)"
    }
}

private struct PlanReadingQuizPanel: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
    @AppStorage("quiz.alwaysShowAnswers") private var alwaysShowAnswers = false
    let mode: PlanReadingMode
    let close: () -> Void
    let openReference: (Int) -> Void
    @State private var selectedQuizID: String?
    @State private var selectedAgeGroupID: String?
    @State private var questions: [LampQuizQuestion] = []
    @State private var revealedAnswers: Set<Int64> = []
    @State private var isLoading = false
    @StateObject private var readAloud = QuizReadAloudController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading Quiz")
                        .font(.headline)
                    Text(mode.activeReading?.displayDescription ?? "Day \(mode.day)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                QuizOptionsMenu()
                Button("Close Quiz", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(14)

            Divider()

            if matchingQuizzes.isEmpty {
                ContentUnavailableView(
                    "No Plan Quiz Installed",
                    systemImage: "questionmark.bubble",
                    description: Text("Install a quiz linked to \(mode.planName) to use it while reading.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let quiz = selectedQuiz {
                VStack(spacing: 10) {
                    if matchingQuizzes.count > 1 {
                        Picker("Quiz", selection: $selectedQuizID) {
                            ForEach(matchingQuizzes) { item in
                                Text(item.name).tag(Optional(item.id))
                            }
                        }
                    }

                    Picker("Age Group", selection: $selectedAgeGroupID) {
                        ForEach(quiz.ageGroups) { ageGroup in
                            Text("\(ageGroup.label) (\(ageGroup.ageRange))")
                                .tag(Optional(ageGroup.id))
                        }
                    }
                }
                .padding(12)

                Divider()

                quizContent
            } else {
                ProgressView("Loading quiz…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .onAppear { configureSelection() }
        .onChange(of: matchingQuizIDs) { _, _ in configureSelection() }
        .onChange(of: selectedQuizID) { _, _ in configureAgeGroup() }
        .onChange(of: loadKey) { _, _ in readAloud.stop() }
        .onChange(of: alwaysShowAnswers) { _, _ in readAloud.stop() }
        .onChange(of: selectedAgeGroupID) { _, ageGroupID in
            if let ageGroupID { defaultQuizAgeGroup = ageGroupID }
        }
        .task(id: loadKey) { await loadQuestions() }
        .onDisappear { readAloud.stop() }
    }

    @ViewBuilder
    private var quizContent: some View {
        if isLoading {
            ProgressView("Loading questions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedQuestions.isEmpty {
            ContentUnavailableView(
                "No Questions for This Reading",
                systemImage: "questionmark.bubble",
                description: Text("Try another age group or reading.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(displayedQuestions) { question in
                        questionCard(question)
                    }
                }
                .padding(14)
            }
        }
    }

    private func questionCard(_ question: LampQuizQuestion) -> some View {
        QuizQuestionCard(
            question: question,
            answerVisible: alwaysShowAnswers || revealedAnswers.contains(question.id),
            allowsAnswerToggle: !alwaysShowAnswers,
            showsTheme: false,
            readAloud: readAloud,
            openReference: openReference,
            toggleAnswer: {
                readAloud.stop()
                if revealedAnswers.contains(question.id) {
                    revealedAnswers.remove(question.id)
                } else {
                    revealedAnswers.insert(question.id)
                }
            }
        )
    }

    private var matchingQuizzes: [LampQuizModule] {
        model.quizModules.filter { $0.planID == mode.planID }
    }

    private var matchingQuizIDs: [String] {
        matchingQuizzes.map(\.id)
    }

    private var selectedQuiz: LampQuizModule? {
        matchingQuizzes.first { $0.id == selectedQuizID } ?? matchingQuizzes.first
    }

    private var loadKey: String {
        "\(selectedQuiz?.id ?? "none"):\(selectedAgeGroupID ?? "none"):\(mode.day)"
    }

    private var displayedQuestions: [LampQuizQuestion] {
        guard let reading = mode.activeReading else { return questions }
        let exact = questions.filter {
            $0.startReference == reading.startReference && $0.endReference == reading.endReference
        }
        if !exact.isEmpty { return exact }
        let overlapping = questions.filter {
            $0.startReference <= reading.endReference && $0.endReference >= reading.startReference
        }
        return overlapping.isEmpty ? questions : overlapping
    }

    private func configureSelection() {
        if !matchingQuizzes.contains(where: { $0.id == selectedQuizID }) {
            selectedQuizID = matchingQuizzes.first?.id
        }
        configureAgeGroup()
    }

    private func configureAgeGroup() {
        guard let quiz = selectedQuiz else {
            selectedAgeGroupID = nil
            return
        }
        if !quiz.ageGroups.contains(where: { $0.id == selectedAgeGroupID }) {
            selectedAgeGroupID = quiz.ageGroups.first { $0.id == defaultQuizAgeGroup }?.id
                ?? quiz.ageGroups.first?.id
        }
    }

    private func loadQuestions() async {
        guard let quiz = selectedQuiz, let ageGroupID = selectedAgeGroupID else {
            questions = []
            return
        }
        isLoading = true
        revealedAnswers = []
        let loaded = await model.quizQuestions(
            moduleID: quiz.id,
            day: mode.day,
            ageGroup: ageGroupID
        )
        guard !Task.isCancelled else { return }
        questions = loaded
        isLoading = false
    }
}

enum ReaderLayoutMode: String, CaseIterable, Identifiable {
    case continuousParagraphs
    case versePerLine
    /// The translation being read and a companion, verse by verse in rows.
    case sideBySide

    var id: Self { self }

    var title: String {
        switch self {
        case .versePerLine: "Verse per Line"
        case .continuousParagraphs: "Continuous Paragraph Flow"
        case .sideBySide: "Side by Side"
        }
    }

    var systemImage: String {
        switch self {
        case .versePerLine: "text.line.first.and.arrowtriangle.forward"
        case .continuousParagraphs: "text.justify.leading"
        case .sideBySide: "rectangle.split.2x1"
        }
    }

    /// Whether each verse is a row of its own, scrolled to by its reference.
    var drawsVerseRows: Bool { self != .continuousParagraphs }
}

/// Which column a verse is drawn in, and so what it carries with it.
private enum ReaderVerseColumn: Equatable {
    /// The translation being read, on its own: its marks in the margin beside it.
    case reading
    /// The translation being read, beside companions. The row marks it, since
    /// any column can hold a verse the others lack.
    case main
    /// A companion, by translation: its own highlights and translator's
    /// notes, and none of the reading's notes or marks.
    case companion(String)
    /// A companion set beneath each verse, where columns would be too narrow:
    /// the same, in smaller and quieter type.
    case companionBelow(String)

    var companionID: String? {
        switch self {
        case .companion(let id), .companionBelow(let id): id
        case .reading, .main: nil
        }
    }

    var isCompanion: Bool { companionID != nil }

    var isBelow: Bool {
        if case .companionBelow = self { true } else { false }
    }
}

/// The companions' text for the chapters on screen side by side.
private struct ReaderCompanionText {
    /// The companions, in the order of their columns.
    var translationIDs: [String] = []
    /// How the translation being read numbers its verses, for pairing them
    /// with each companion's.
    var mainVersification: LampVersification?
    var columns: [String: ReaderCompanionColumn] = [:]
    /// Every chapter on screen asked for, including those a companion
    /// doesn't have.
    var asked: Set<String> = []

    static func key(book: Int, chapter: Int) -> String { "\(book):\(chapter)" }
}

/// One companion's text.
private struct ReaderCompanionColumn {
    /// How the companion numbers its verses.
    var versification: LampVersification
    /// The verses each chapter on screen pairs with, keyed by that chapter:
    /// the companion's own chapter of that number, and any other a verse of
    /// it converts to.
    var chapters: [String: [LampVerse]] = [:]
    var highlights: [Int: [LampVerseHighlight]] = [:]
    /// Its own translator's notes, by verse.
    var footnotes: [Int: LampVerseStudyData] = [:]
}

/// A translator's note the reader has opened: which verse, and which of that
/// verse's notes.
struct ReaderFootnoteKey: Equatable {
    let verse: Int
    let index: Int
    /// The companion whose note it is, or nil for the reading's: side by side,
    /// each translation can mark notes on one verse, each with letters from a.
    var companionID: String?
}

struct ReaderParagraph: Identifiable {
    let verses: [LampVerse]

    var id: Int { verses[0].id }
    var firstVerse: LampVerse { verses[0] }
}

/// The reader and every compact scripture preview use this one grouping rule so
/// paragraph markers, headings, and poetry produce the same breaks everywhere.
enum ReaderParagraphPlanner {
    static func paragraphs(in chapter: LampChapter) -> [ReaderParagraph] {
        let headingVerses = Set(chapter.headings.map(\.beforeVerse))
        var result: [ReaderParagraph] = []
        var current: [LampVerse] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            result.append(ReaderParagraph(verses: current))
            current = []
        }

        for verse in chapter.verses {
            let isPoetry = verse.poetry != nil
            let followsPoetry = current.last?.poetry != nil
            let startsParagraph = current.isEmpty
                || verse.beginsParagraph
                || headingVerses.contains(verse.number)
                || isPoetry
                || followsPoetry
            if startsParagraph { flushCurrent() }
            current.append(verse)
            if isPoetry { flushCurrent() }
        }
        flushCurrent()
        return result
    }
}

/// Where each continuously laid-out paragraph currently sits, and which verses it
/// contains, for the scroll link's sub-paragraph anchor.
///
/// Deliberately a plain class rather than a `PreferenceKey` or an observable
/// object. Gathering per-row geometry through the preference system from inside a
/// `LazyVStack` rewrites the key every time a row is materialised — several times
/// in a single pass — which is what SwiftUI reports as "Bound preference
/// ReaderParagraphFramesKey tried to update multiple times per frame", and each of
/// those writes used to re-plan every paragraph in the passage before the frame
/// could finish. Recording into a reference type invalidates no views, so the
/// reader can note positions as often as it likes and read them once per scroll.
@MainActor
private final class ReaderParagraphAnchorStore {
    private var frames: [Int: CGRect] = [:]
    private var segmentsByParagraph: [Int: [ReaderParagraphSegment]] = [:]
    private var paragraphsByChapter: [String: [ReaderParagraph]] = [:]

    func record(_ frame: CGRect, for reference: Int) {
        frames[reference] = frame
    }

    func forget(_ reference: Int) {
        frames.removeValue(forKey: reference)
    }

    /// The paragraphs of a chapter, planned once and kept.
    ///
    /// The reader's body rebuilds this list every time it re-evaluates, and it
    /// re-evaluates whenever its frame changes — which is exactly what opening the
    /// study column does. Re-planning every paragraph of a multi-chapter passage
    /// on the main thread, mid-transition, is enough to starve the animation of
    /// frames so completely that it renders only its first and last.
    ///
    /// Filling a cache during a body evaluation is safe here precisely because
    /// this is a plain class: nothing observes it, so nothing is invalidated.
    func paragraphs(in chapter: LampChapter) -> [ReaderParagraph] {
        let key = "\(chapter.translationID):\(chapter.book.id):\(chapter.number)"
        if let cached = paragraphsByChapter[key] { return cached }
        let planned = ReaderParagraphPlanner.paragraphs(in: chapter)
        paragraphsByChapter[key] = planned
        return planned
    }

    /// Plans the passage's paragraphs once, when the passage changes, instead of
    /// on every geometry report.
    func prepare(for chapters: [LampChapter]) {
        frames.removeAll(keepingCapacity: true)
        segmentsByParagraph = Dictionary(
            uniqueKeysWithValues: chapters
                .flatMap { paragraphs(in: $0) }
                .map { paragraph in
                    (paragraph.id, paragraph.verses.map { verse in
                        ReaderParagraphSegment(
                            reference: verse.id,
                            characterCount: verse.text.count + String(verse.number).count + 1
                        )
                    })
                }
        )
    }

    /// The verse at the reader's top edge: the highest paragraph still on screen,
    /// then the verse that far into it.
    var topEdgeReference: Int? {
        guard let (reference, frame) = frames
            .filter({ $0.value.maxY > 0 })
            .min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        guard let segments = segmentsByParagraph[reference], !segments.isEmpty else {
            return reference
        }
        let progress = -frame.minY / max(frame.height, 1)
        return ReaderParagraphAnchorResolver.reference(at: progress, in: segments)
    }
}

private struct ReaderPassageChapter: Identifiable {
    let chapter: LampChapter

    var id: String {
        "reader-chapter:\(chapter.translationID):\(chapter.book.id):\(chapter.number)"
    }
}

/// The fonts the reader has asked for. Every paragraph asks for several, and
/// making one from a descriptor each time is a third of what building a
/// paragraph costs. A handful of sizes and weights is all there ever is.
@MainActor
private enum ReaderFonts {
    struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let traits: UInt
        let serif: Bool
    }

    static var made: [Key: NSFont] = [:]
}

/// The heights reader text sets to, kept. SwiftUI asks a row its size several
/// times a layout, and again each time the reader is shown, and typesetting
/// the text to answer was most of what showing the reader cost. A height
/// depends only on the text, attributes included, and the width.
private enum ReaderTextHeights {
    private final class Key: NSObject {
        let text: NSAttributedString
        let width: CGFloat

        init(text: NSAttributedString, width: CGFloat) {
            // A copy, so a mutable string changed later can't change a key
            // already in the cache. An immutable one copies as itself.
            self.text = text.copy() as! NSAttributedString
            self.width = width
        }

        override var hash: Int {
            text.string.hash ^ width.hashValue
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return width == other.width && (text === other.text || text.isEqual(to: other.text))
        }
    }

    /// Each key keeps its text alive, and only what's on screen or near it
    /// is ever asked about again, so a few hundred is plenty.
    private static let cache: NSCache<Key, NSNumber> = {
        let cache = NSCache<Key, NSNumber>()
        cache.countLimit = 500
        return cache
    }()

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let key = Key(text: text, width: width)
        if let height = cache.object(forKey: key) {
            return CGFloat(height.doubleValue)
        }
        // Measurement must be observational. Resizing the live text container
        // causes NSTextView to invalidate its hosted size while SwiftUI's
        // LazyVStack is still asking for that size. The lazy stack then places
        // the row again, which measures it again, and so on without settling.
        // NSAttributedString's bounding calculation uses an independent layout
        // context and cannot feed back into the represented view.
        let bounds = text.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = max(ceil(bounds.height), 1)
        cache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }
}

/// Reader scripture uses AppKit selection directly. SwiftUI's `.textSelection`
/// installs a `SelectionOverlay` that can enter an unbounded update loop when a
/// lazy scroll view materialises attributed text containing many metadata runs.
/// An ordinary non-editable `NSTextView` provides the same native selection and
/// contextual menu without involving that overlay.
/// Verse text, with the reader's margin beside it.
///
/// The text view reaches back past any indent and into the margin, so that
/// every mark sits in one column at the left of the reader, however the
/// poetry beside it is indented.
private struct ReaderSelectableText: View {
    let attributedText: NSAttributedString
    var marks: ReaderMarginMarks = .none
    /// How far the text is set in from the reader's column.
    var indent: CGFloat = 0
    /// Whether the text carries the reader's margin. Side by side, the row
    /// draws the marks, and a margin on the right-hand column would reach
    /// back over the left.
    var showsMargin = true
    let openLink: (URL) -> Void
    var openNote: (Int) -> Void = { _ in }

    private var textLeading: CGFloat { (showsMargin ? ReaderMargin.width : 0) + indent }

    var body: some View {
        ReaderTextRepresentable(
            attributedText: attributedText,
            marks: marks,
            textLeading: textLeading,
            openLink: openLink,
            openNote: openNote
        )
        .padding(.leading, -textLeading)
    }
}

private enum ReaderParallel {
    /// Between the columns side by side.
    static let columnGap: CGFloat = 28
    /// A companion set beneath each verse, in from the verse it follows.
    static let stackedIndent: CGFloat = 14
    /// Under this, a column wraps every few words, and the companions move
    /// beneath each verse instead.
    static let minimumColumnWidth: CGFloat = 280
    /// Four columns: more leave too little width for prose on most windows.
    static let maximumCompanions = 3
    /// The widest a column grows, about the measure one has on its own.
    static let maximumColumnWidth: CGFloat = 620

    /// Whether a passage this wide sets the companions beneath each verse,
    /// from the room each column would have.
    static func stacks(passageWidth: CGFloat, columns: Int) -> Bool {
        let gaps = columnGap * CGFloat(max(columns - 1, 0))
        // The rows' own padding, either side.
        return (passageWidth - 16 - gaps) / CGFloat(max(columns, 1)) < minimumColumnWidth
    }
}

private enum ReaderMargin {
    /// Room for two note icons and the selection bar, left of the column.
    static let width: CGFloat = 52
}

private struct ReaderTextRepresentable: NSViewRepresentable {
    let attributedText: NSAttributedString
    let marks: ReaderMarginMarks
    let textLeading: CGFloat
    let openLink: (URL) -> Void
    let openNote: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openLink: openLink)
    }

    func makeNSView(context: Context) -> ReaderTextView {
        // TextKit 1: the margin reads its lines from the layout manager, and
        // asking a TextKit 2 view for one switches it over there and then.
        let textView = ReaderTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Sized by the view, less the margin, rather than tracking its width.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.linkTextAttributes = [:]
        textView.textLeading = textLeading
        textView.textStorage?.setAttributedString(attributedText)
        textView.marks = marks
        textView.openNote = openNote
        return textView
    }

    func updateNSView(_ textView: ReaderTextView, context: Context) {
        context.coordinator.openLink = openLink
        textView.openNote = openNote
        textView.textLeading = textLeading
        if textView.attributedString() != attributedText {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributedText)
            if selection.location != NSNotFound,
               NSMaxRange(selection) <= attributedText.length {
                textView.setSelectedRange(selection)
            }
        }
        // After the text, which the marks' locations count in.
        textView.marks = marks
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: ReaderTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > textLeading else { return nil }

        return CGSize(
            width: width,
            height: ReaderTextHeights.height(of: attributedText, width: width - textLeading)
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openLink: (URL) -> Void

        init(openLink: @escaping (URL) -> Void) {
            self.openLink = openLink
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url else { return false }
            openLink(url)
            return true
        }
    }
}

/// The reader's text view, with a margin left of the text where the reader
/// marks verses: a bar beside the selected verse's lines, and an icon beside
/// the line where a verse with notes begins.
///
/// Placed from the view's own layout, so a mark always sits on the line it
/// belongs to, at whatever width the text has wrapped to, and a change of
/// marks costs a redraw of the margin rather than a layout of the text.
private final class ReaderTextView: NSTextView {
    var marks = ReaderMarginMarks.none {
        didSet {
            guard marks != oldValue else { return }
            margin.needsDisplay = true
            window?.invalidateCursorRects(for: margin)
        }
    }
    /// Where the text starts: past the margin and any indent.
    var textLeading: CGFloat = ReaderMargin.width {
        didSet {
            guard textLeading != oldValue else { return }
            sizeTextContainer()
        }
    }
    var openNote: ((Int) -> Void)?

    /// The strip the marks are drawn in. Drawn in the text view's own pass,
    /// after its text, they never reached the screen.
    private let margin = ReaderMarginView()

    override var textContainerOrigin: NSPoint { NSPoint(x: textLeading, y: 0) }

    override func mouseDown(with event: NSEvent) {
        // Here rather than in the margin view: SwiftUI hands a click anywhere
        // in the text view to the text view, never asking its subviews.
        if let icon = icon(at: convert(event.locationInWindow, from: nil)) {
            openNote?(icon.reference)
            return
        }
        super.mouseDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeTextContainer()
    }

    private func sizeTextContainer() {
        if margin.superview !== self { addSubview(margin) }
        margin.frame = NSRect(x: 0, y: 0, width: min(ReaderMargin.width, textLeading), height: bounds.height)
        guard let textContainer else { return }
        let width = max(frame.width - textLeading, 0)
        guard textContainer.size.width != width else { return }
        textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    fileprivate func drawMarks() {
        guard !marks.isEmpty else { return }
        if let bar = selectionBar() {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
        for icon in placedIcons() {
            icon.image.draw(in: icon.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The note icon at a point in the margin, if one is there.
    fileprivate func icon(at point: NSPoint) -> PlacedIcon? {
        placedIcons().first { $0.hitRect.contains(point) }
    }

    // MARK: Placing the marks

    fileprivate struct PlacedIcon {
        let rect: NSRect
        let image: NSImage
        let reference: Int
        let help: String

        var hitRect: NSRect { rect.insetBy(dx: -4, dy: -4) }
    }

    /// The bar beside the selected verse's lines, a little in from the text.
    private func selectionBar() -> NSRect? {
        guard let range = marks.selectedRange,
              let first = lineBand(at: range.location),
              let last = lineBand(at: max(NSMaxRange(range) - 1, range.location))
        else { return nil }
        return NSRect(
            x: ReaderMargin.width - 10,
            y: first.minY + 1,
            width: 2.5,
            height: max(last.maxY - first.minY - 2, 3)
        )
    }

    fileprivate func placedIcons() -> [PlacedIcon] {
        guard !marks.notes.isEmpty else { return [] }
        var bands: [Int: LineBand] = [:]
        let lines = marks.notes.compactMap { note -> (line: Int, note: ReaderMarginMarks.Note)? in
            guard let band = lineBand(at: note.location) else { return nil }
            let line = Int(band.minY.rounded())
            bands[line] = band
            return (line, note)
        }
        var placed: [PlacedIcon] = []
        var slotsUsed: [Int: Int] = [:]
        for icon in ReaderMarginMarks.icons(for: lines) {
            guard let band = bands[icon.line] else { continue }
            let slot = slotsUsed[icon.line, default: 0]
            slotsUsed[icon.line] = slot + 1
            let size = (band.fontSize * 0.72).rounded()
            let image = Self.icon(for: icon.kind, size: size)
            // The reader's own note nearest the text, a little clear of the
            // strip the selection bar is drawn in.
            let centerX = ReaderMargin.width - 15 - size / 2 - CGFloat(slot) * (size + 4)
            let rect = NSRect(
                x: centerX - image.size.width / 2,
                y: band.midText - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            // Naming the verse: two icons beside one line can open two.
            let verse = LampBibleReferenceFormatter.components(of: icon.reference).verse
            placed.append(PlacedIcon(
                rect: rect,
                image: image,
                reference: icon.reference,
                help: icon.kind == .personal
                    ? "Your note on verse \(verse)"
                    : "Study notes on verse \(verse)"
            ))
        }
        return placed
    }

    private struct LineBand {
        let minY: CGFloat
        let maxY: CGFloat
        /// Halfway up the text's small letters, where an icon looks level with it.
        let midText: CGFloat
        let fontSize: CGFloat
    }

    /// The line a character is set on: from the top of its glyphs to the foot
    /// of their descenders, leaving out the space set below the line.
    private func lineBand(at characterIndex: Int) -> LineBand? {
        guard let layoutManager, let textStorage, textStorage.length > 0 else { return nil }
        let index = min(max(characterIndex, 0), textStorage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        var lineGlyphs = NSRange()
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        // The body text of the line, not the raised verse number at its start.
        let bodyCharacter = layoutManager.characterIndexForGlyph(at: max(NSMaxRange(lineGlyphs) - 1, lineGlyphs.location))
        let font = textStorage.attribute(.font, at: min(bodyCharacter, textStorage.length - 1), effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: 17)
        let baseline = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: min(bodyCharacter, textStorage.length - 1))).y
        let originY = fragment.minY + textContainerOrigin.y
        return LineBand(
            minY: originY + baseline - font.ascender,
            maxY: originY + baseline - font.descender,
            midText: originY + baseline - font.xHeight / 2,
            fontSize: font.pointSize
        )
    }

    private static var icons: [String: NSImage] = [:]

    /// A note icon, coloured for its kind: each kind its own symbol as well as
    /// its own colour, so neither depends on telling the colours apart.
    private static func icon(for kind: ReaderMarginMarks.NoteKinds, size: CGFloat) -> NSImage {
        let name = kind == .personal ? "note.text" : "book.closed"
        let key = "\(name)-\(size)"
        if let image = icons[key] { return image }
        let color: NSColor = kind == .personal ? .systemOrange : .systemPurple
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        icons[key] = image
        return image
    }
}

/// The reader's margin beside its text, drawing what the text view places.
/// Clicks pass through it to the text view, which opens a note.
private final class ReaderMarginView: NSView {
    private var textView: ReaderTextView? { superview as? ReaderTextView }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        textView?.drawMarks()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        removeAllToolTips()
        for icon in textView?.placedIcons() ?? [] {
            addCursorRect(icon.hitRect, cursor: .pointingHand)
            addToolTip(icon.hitRect, owner: icon.help as NSString, userData: nil)
        }
    }
}

private struct PlanReadingChapterRequest: Equatable, Hashable {
    let translationID: String
    let readingID: Int
    let startReference: Int
    let endReference: Int
}

private struct ReaderLexicalHoverDetails: Equatable {
    enum Kind: Equatable {
        case mapped(keys: [String])
        case unmapped
    }

    let word: String
    let kind: Kind

    var systemImage: String {
        switch kind {
        case .mapped: "character.book.closed"
        case .unmapped: "text.badge.xmark"
        }
    }

    var message: String {
        switch kind {
        case .mapped(let keys):
            "\(word)  ·  \(keys.joined(separator: " · "))"
        case .unmapped:
            "\(word)  ·  No direct original-language match"
        }
    }
}

@MainActor
private final class ReaderLexicalHoverStore: ObservableObject {
    @Published var details: ReaderLexicalHoverDetails?
    let linkActivations = PassthroughSubject<URL, Never>()
    private weak var readerWindow: NSWindow?
    private var eventMonitor: Any?
    private var isDetailsEnabled = false
    private var isScrollFrozen = false
    private var clickTrackingGeneration = 0

    init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown]
        ) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func configure(isScrollFrozen: Bool) {
        if isScrollFrozen, !self.isScrollFrozen {
            cancelClickTracking()
        }
        self.isScrollFrozen = isScrollFrozen
    }

    func configure(isDetailsEnabled: Bool) {
        guard self.isDetailsEnabled != isDetailsEnabled else { return }
        self.isDetailsEnabled = isDetailsEnabled
        guard !isDetailsEnabled else { return }
        cancelClickTracking()
        details = nil
    }

    func attach(to window: NSWindow?) {
        guard let window else { return }
        if readerWindow !== window {
            cancelClickTracking()
        }
        readerWindow = window
        window.acceptsMouseMovedEvents = true
    }

    func clearForScrolling() {
        cancelClickTracking()
        if details != nil {
            details = nil
        }
    }

    private func observe(_ event: NSEvent) {
        guard isDetailsEnabled,
              let readerWindow,
              event.window === readerWindow else { return }

        switch event.type {
        case .mouseMoved:
            guard !isScrollFrozen else { return }
            updateDetails(for: textHit(at: event.locationInWindow, in: readerWindow))
        case .leftMouseDown:
            beginLinkClickTracking(for: event, in: readerWindow)
        default:
            break
        }
    }

    /// AppKit's selectable text enters its own mouse-tracking loop after mouse-down,
    /// so a local event monitor never sees the matching mouse-up. A block queued in
    /// the default run-loop mode resumes after that tracking loop has completed,
    /// without intercepting or replaying any native text event.
    private func beginLinkClickTracking(for event: NSEvent, in window: NSWindow) {
        cancelClickTracking()
        guard !isScrollFrozen,
              event.clickCount == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let url = textHit(at: event.locationInWindow, in: window)?.link,
              LexiconLookupLink(url: url) != nil,
              let startPoint = event.cgEvent?.location ?? CGEvent(source: nil)?.location else {
            return
        }

        clickTrackingGeneration &+= 1
        let generation = clickTrackingGeneration
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.clickTrackingGeneration == generation else { return }
                let movedBeyondClickTolerance = (CGEvent(source: nil)?.location).map { point in
                    let deltaX = point.x - startPoint.x
                    let deltaY = point.y - startPoint.y
                    return (deltaX * deltaX) + (deltaY * deltaY) > 36
                } ?? false
                guard !movedBeyondClickTolerance,
                      !self.isScrollFrozen else { return }
                self.linkActivations.send(url)
            }
        }
    }

    private func cancelClickTracking() {
        clickTrackingGeneration &+= 1
    }

    private func updateDetails(for hit: ReaderTextHit?) {
        let newDetails: ReaderLexicalHoverDetails?
        if let hit,
           let link = hit.link,
           let lookup = LexiconLookupLink(url: link) {
            newDetails = ReaderLexicalHoverDetails(
                word: lookup.word ?? hit.word ?? lookup.keys.joined(separator: " · "),
                kind: .mapped(keys: lookup.keys)
            )
        } else if let hit, hit.link == nil, let word = hit.word {
            newDetails = ReaderLexicalHoverDetails(word: word, kind: .unmapped)
        } else {
            newDetails = nil
        }
        guard details != newDetails else { return }
        details = newDetails
    }

    private func textHit(at windowPoint: NSPoint, in window: NSWindow) -> ReaderTextHit? {
        for candidate in ReaderLexicalHoverRowRegistry.registeredRows(in: window) {
            guard let row = candidate as?
                    ReaderNativeContextMenuAugmenter.ContextMenuObservationView,
                  Self.isEffectivelyVisible(row) else { continue }
            let localPoint = row.convert(windowPoint, from: nil)
            guard row.visibleRect.insetBy(dx: -2, dy: -2).contains(localPoint) else { continue }
            if let hit = row.textHit(at: windowPoint, in: window) {
                return hit
            }
        }
        return nil
    }

    /// Whether `view` can be seen. SwiftUI hides a view at zero opacity, as the
    /// reader is while another section is shown, by setting a container's
    /// alpha, so the view itself still says it's visible.
    static func isEffectivelyVisible(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current.isHidden || current.alphaValue <= 0 { return false }
            candidate = current.superview
        }
        return true
    }

}

private struct ReaderLexicalHoverDetailsView: View {
    @ObservedObject var store: ReaderLexicalHoverStore

    var body: some View {
        if let details = store.details {
            Label(details.message, systemImage: details.systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.bar, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                }
                .padding(.leading, 14)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isStaticText)
                .transition(.opacity)
        }
    }
}

struct ReaderContextMenuEntry {
    enum Kind {
        case action(() -> Void)
        case submenu([ReaderContextMenuEntry])
        case separator
    }

    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let kind: Kind

    static func action(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) -> Self {
        Self(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            kind: .action(perform)
        )
    }

    static func submenu(
        _ title: String,
        systemImage: String? = nil,
        entries: [ReaderContextMenuEntry]
    ) -> Self {
        Self(
            title: title,
            systemImage: systemImage,
            isEnabled: true,
            kind: .submenu(entries)
        )
    }

    static var separator: Self {
        Self(title: "", systemImage: nil, isEnabled: false, kind: .separator)
    }
}

@MainActor
private enum ReaderLexicalHoverRowRegistry {
    private static let rows = NSHashTable<NSView>.weakObjects()

    static func update(_ view: NSView, participates: Bool) {
        rows.remove(view)
        if participates, view.window != nil {
            rows.add(view)
        }
    }

    static func registeredRows(in window: NSWindow) -> [NSView] {
        rows.allObjects.filter { $0.window === window }
    }
}

/// SwiftUI's selectable Text owns selection and the native contextual menu. This
/// non-intercepting sibling only augments that menu and marks lexical reader rows.
struct ReaderNativeContextMenuAugmenter: NSViewRepresentable {
    let entries: [ReaderContextMenuEntry]
    let openLink: (URL) -> Void
    let participatesInLexicalHover: Bool
    let showsLinkCursor: Bool

    init(
        entries: [ReaderContextMenuEntry],
        openLink: @escaping (URL) -> Void,
        participatesInLexicalHover: Bool = false,
        showsLinkCursor: Bool = false
    ) {
        self.entries = entries
        self.openLink = openLink
        self.participatesInLexicalHover = participatesInLexicalHover
        self.showsLinkCursor = showsLinkCursor
    }

    func makeCoordinator() -> Coordinator { Coordinator(entries: entries) }

    func makeNSView(context: Context) -> ContextMenuObservationView {
        let view = ContextMenuObservationView()
        view.menuAugmenter = context.coordinator.augment(menu:)
        view.linkHandler = openLink
        view.participatesInLexicalHover = participatesInLexicalHover
        view.showsLinkCursor = showsLinkCursor
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ContextMenuObservationView, context: Context) {
        context.coordinator.entries = entries
        view.menuAugmenter = context.coordinator.augment(menu:)
        view.linkHandler = openLink
        view.participatesInLexicalHover = participatesInLexicalHover
        view.showsLinkCursor = showsLinkCursor
    }

    final class Coordinator: NSObject {
        private static let injectedIdentifierPrefix = "lamp.reader-context-menu."

        var entries: [ReaderContextMenuEntry]
        private var actions: [() -> Void] = []

        init(entries: [ReaderContextMenuEntry]) {
            self.entries = entries
        }

        func augment(menu nativeMenu: NSMenu) {
            actions = []
            for item in nativeMenu.items.reversed() where
                item.identifier?.rawValue.hasPrefix(Self.injectedIdentifierPrefix) == true {
                nativeMenu.removeItem(item)
            }

            let customMenu = menu(title: "Reader", entries: entries)
            var insertionIndex = 0
            while let item = customMenu.items.first {
                customMenu.removeItem(item)
                item.identifier = NSUserInterfaceItemIdentifier(
                    "\(Self.injectedIdentifierPrefix)item-\(insertionIndex)"
                )
                nativeMenu.insertItem(item, at: insertionIndex)
                insertionIndex += 1
            }
            if insertionIndex > 0 {
                let separator = NSMenuItem.separator()
                separator.identifier = NSUserInterfaceItemIdentifier(
                    "\(Self.injectedIdentifierPrefix)native-boundary"
                )
                nativeMenu.insertItem(separator, at: insertionIndex)
            }
        }

        private func menu(title: String, entries: [ReaderContextMenuEntry]) -> NSMenu {
            let menu = NSMenu(title: title)
            for entry in entries {
                switch entry.kind {
                case .separator:
                    menu.addItem(.separator())
                case .submenu(let children):
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.image = entry.systemImage.flatMap {
                        NSImage(systemSymbolName: $0, accessibilityDescription: entry.title)
                    }
                    item.submenu = self.menu(title: entry.title, entries: children)
                    menu.addItem(item)
                case .action(let perform):
                    let index = actions.count
                    actions.append(perform)
                    let item = NSMenuItem(
                        title: entry.title,
                        action: #selector(performMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = index
                    item.isEnabled = entry.isEnabled
                    item.image = entry.systemImage.flatMap {
                        NSImage(systemSymbolName: $0, accessibilityDescription: entry.title)
                    }
                    menu.addItem(item)
                }
            }
            return menu
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }

    final class ContextMenuObservationView: NSView {
        var menuAugmenter: ((NSMenu) -> Void)?
        var linkHandler: ((URL) -> Void)?
        var showsLinkCursor = false {
            didSet {
                guard oldValue != showsLinkCursor else { return }
                if !showsLinkCursor { restoreLinkCursor() }
                enableMouseMovedEventsIfNeeded()
                updateTrackingAreas()
            }
        }
        var participatesInLexicalHover = false {
            didSet {
                guard oldValue != participatesInLexicalHover else { return }
                ReaderLexicalHoverRowRegistry.update(
                    self,
                    participates: participatesInLexicalHover
                )
            }
        }
        private var eventMonitor: Any?
        private var hasPendingContextClick = false
        private var pendingInternalContextLink = false
        private var pendingContextClickGeneration = 0
        private var linkTrackingArea: NSTrackingArea?
        private var isShowingLinkCursor = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(menuDidBeginTracking(_:)),
                name: NSMenu.didBeginTrackingNotification,
                object: nil
            )
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]
            ) { [weak self] event in
                self?.observeMouseEvent(event)
                return event
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            restoreLinkCursor()
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { restoreLinkCursor() }
            enableMouseMovedEventsIfNeeded()
            ReaderLexicalHoverRowRegistry.update(
                self,
                participates: participatesInLexicalHover
            )
        }

        /// `NSTrackingArea.mouseMoved` is only continuous when its window opts in
        /// to moved events. Without this, AppKit still sends occasional enter and
        /// cursor-update events, which makes link cursors appear to work for one
        /// run and then stop as the pointer moves within the same text field.
        private func enableMouseMovedEventsIfNeeded() {
            guard showsLinkCursor else { return }
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let linkTrackingArea {
                removeTrackingArea(linkTrackingArea)
                self.linkTrackingArea = nil
            }
            guard showsLinkCursor else { return }
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [
                    .activeInKeyWindow,
                    .inVisibleRect,
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .cursorUpdate,
                ],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            linkTrackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            updateLinkCursor(for: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateLinkCursor(for: event)
        }

        override func cursorUpdate(with event: NSEvent) {
            updateLinkCursor(for: event)
        }

        override func mouseExited(with event: NSEvent) {
            restoreLinkCursor()
        }

        private func observeMouseEvent(_ event: NSEvent) {
            guard let window,
                  event.window === window else {
                return
            }

            switch event.type {
            case .rightMouseDown:
                guard contains(event.locationInWindow) else { return }
                rememberContextClick(
                    hit: textHit(at: event.locationInWindow, in: window)
                )
            case .leftMouseDown:
                guard contains(event.locationInWindow) else { return }
                if event.modifierFlags.contains(.control) {
                    rememberContextClick(
                        hit: textHit(at: event.locationInWindow, in: window)
                    )
                }
            default:
                break
            }
        }

        /// Only where the row can be seen: a hidden reader's rows lie under
        /// whatever section is shown, and must not take its clicks or add to
        /// its context menus.
        private func contains(_ windowPoint: NSPoint) -> Bool {
            bounds.contains(convert(windowPoint, from: nil))
                && ReaderLexicalHoverStore.isEffectivelyVisible(self)
        }

        private func updateLinkCursor(for event: NSEvent) {
            guard showsLinkCursor, let window, event.window === window,
                  contains(event.locationInWindow) else {
                restoreLinkCursor()
                return
            }
            let isOverLink = textHit(at: event.locationInWindow, in: window)?.link != nil
            if isOverLink {
                if !isShowingLinkCursor {
                    NSCursor.pointingHand.push()
                    isShowingLinkCursor = true
                } else {
                    NSCursor.pointingHand.set()
                }
            } else {
                restoreLinkCursor()
            }
        }

        private func restoreLinkCursor() {
            guard isShowingLinkCursor else { return }
            NSCursor.pop()
            isShowingLinkCursor = false
        }

        private func rememberContextClick(hit: ReaderTextHit?) {
            hasPendingContextClick = true
            pendingInternalContextLink = hit?.link.map { LexiconLookupLink(url: $0) != nil } ?? false
            pendingContextClickGeneration &+= 1
            let generation = pendingContextClickGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard self?.pendingContextClickGeneration == generation else { return }
                self?.hasPendingContextClick = false
                self?.pendingInternalContextLink = false
            }
        }

        func textHit(at windowPoint: NSPoint, in window: NSWindow) -> ReaderTextHit? {
            guard let contentView = window.contentView else { return nil }
            let contentPoint = contentView.convert(windowPoint, from: nil)
            var candidate = contentView.hitTest(contentPoint)
            while let view = candidate {
                if let textView = view as? NSTextView,
                   let hit = ReaderTextLinkHitTester.hit(
                        at: textView.convert(windowPoint, from: nil),
                        in: textView
                   ) {
                    return hit
                }
                if let textField = view as? NSTextField,
                   let hit = ReaderTextLinkHitTester.hit(
                        at: textField.convert(windowPoint, from: nil),
                        in: textField
                   ) {
                    return hit
                }
                candidate = view.superview
            }

            // SwiftUI's selectable Text and this non-intercepting representable
            // are sibling branches. Walk outward until their smallest common
            // ancestor is found, rather than searching the entire window first.
            // This also keeps unrelated labels (including the hover readout)
            // from being mistaken for passage text.
            var searchRoot = superview
            while let root = searchRoot {
                if let hit = descendantTextHit(
                    at: windowPoint,
                    in: root,
                    excluding: self
                ) {
                    return hit
                }
                guard root !== contentView else { break }
                searchRoot = root.superview
            }
            return nil
        }

        private func descendantTextHit(
            at windowPoint: NSPoint,
            in root: NSView,
            excluding excludedView: NSView
        ) -> ReaderTextHit? {
            for subview in root.subviews.reversed() where
                subview !== excludedView
                    && !subview.isHidden
                    && subview.alphaValue > 0 {
                let localPoint = subview.convert(windowPoint, from: nil)
                guard subview.bounds.insetBy(dx: -2, dy: -2).contains(localPoint) else {
                    continue
                }
                if let hit = descendantTextHit(
                    at: windowPoint,
                    in: subview,
                    excluding: excludedView
                ) {
                    return hit
                }
                if let textView = subview as? NSTextView,
                   let hit = ReaderTextLinkHitTester.hit(at: localPoint, in: textView) {
                    return hit
                }
                if let textField = subview as? NSTextField,
                   let hit = ReaderTextLinkHitTester.hit(at: localPoint, in: textField) {
                    return hit
                }
            }
            return nil
        }

        @objc private func menuDidBeginTracking(_ notification: Notification) {
            guard hasPendingContextClick,
                  let menu = notification.object as? NSMenu else { return }
            hasPendingContextClick = false
            if pendingInternalContextLink {
                for item in menu.items.reversed() where isNativeLinkCommand(item) {
                    menu.removeItem(item)
                }
            }
            pendingInternalContextLink = false
            menuAugmenter?(menu)
        }

        private func isNativeLinkCommand(_ item: NSMenuItem) -> Bool {
            let action = item.action.map(NSStringFromSelector) ?? ""
            let identifier = item.identifier?.rawValue ?? ""
            let description = "\(item.title) \(action) \(identifier)"
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
            return description.contains("openlink") || description.contains("copylink")
        }
    }
}

/// One hover tracker for the reader. Passage rows remain lightweight markers;
/// the single observer resolves the row and its text immediately on mouse move.
struct ReaderLexicalHoverObserver: NSViewRepresentable {
    fileprivate let interactionStore: ReaderLexicalHoverStore

    func makeNSView(context: Context) -> HoverObservationView {
        let view = HoverObservationView()
        view.interactionStore = interactionStore
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: HoverObservationView, context: Context) {
        view.interactionStore = interactionStore
    }

    final class HoverObservationView: NSView {
        fileprivate var interactionStore: ReaderLexicalHoverStore? {
            didSet {
                interactionStore?.attach(to: window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            interactionStore?.attach(to: window)
        }
    }
}

/// What the field is offering to do with what has been typed.
private struct PassagePickerOffer {
    let icon: String
    let title: String
    let action: () -> Void
}

/// The picker behind the reader's passage button, and behind a new tab's plus.
///
/// What the field takes differs between the two. From the reader it also takes
/// words to search for and Strong's keys, which go to the search and to the
/// analysis; a tab opens a chapter and nothing else, so there a reference or a
/// book's name is all it can offer to do.
///
/// Everything here can be reached from the keyboard: Tab and ⇧Tab move through
/// the field, the offer, the translation, the two columns and the duplicate
/// row, the arrows move within whichever has focus, and Return takes it. See
/// `LampPassagePickerKeys` for why the ring is kept rather than left to macOS.
private struct PassagePickerPopover: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var workspace: ReaderWorkspace
    @Binding var isPresented: Bool
    /// Where a chosen passage goes: this window's reader, or a new tab.
    let open: (ReaderLocation) -> Void
    /// Named above the field when the passage is not for the reader in front
    /// of you, so a picker that opens a tab says so.
    var headline: String?
    /// Hands words that are not a reference to the search, so one field
    /// answers both "take me to John 3" and "where does it say that". Nil in a
    /// picker that can only open scripture.
    var openSearch: ((String) -> Void)?
    /// And a Strong's key to the analysis, which is where that goes.
    var openAnalysis: ((String) -> Void)?
    /// Opens a second tab at the passage this one is already at.
    var duplicate: (() -> Void)?
    @State private var translationID = ""
    @State private var books: [LampTranslationBook] = []
    @State private var bookNumber = 0
    @State private var chapterNumber = 1
    @State private var isLoadingBooks = false
    @State private var errorMessage: String?
    @State private var typed = ""
    /// Set when an arrow key moves the selection, so the column scrolls to
    /// what was reached. A click needs no scrolling — it landed on something
    /// already in view — so the two are kept apart.
    @State private var scrollToBook: Int?
    @State private var scrollToChapter: Int?
    @FocusState private var focus: LampPassagePickerStop?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headline {
                Text(headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            TextField(fieldPrompt, text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .field)
                .onSubmit(commitTyped)

            if let offer {
                offerRow(offer, stop: .offer)
            }

            // The picker itself cannot hold keyboard focus without the system
            // setting that is off by default, so the focus sits on a plain
            // view around it, where the arrow keys can be heard.
            HStack(spacing: 0) {
                Picker("Translation", selection: $translationID) {
                    ForEach(model.translations) { translation in
                        Text(translation.name).tag(translation.id)
                    }
                }
                .labelsHidden()
            }
            .focusable()
            .focused($focus, equals: .translation)
            .focusEffectDisabled()
            .overlay { focusRing(.translation, cornerRadius: 7) }

            Divider()

            if isLoadingBooks {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading books…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    booksList
                    Divider()
                    chapterGrid
                }
                .frame(height: 260)
            }

            if duplicate != nil, workspace.currentLocation != nil {
                offerRow(
                    PassagePickerOffer(
                        icon: "plus.square.on.square",
                        title: "Duplicate this tab",
                        action: { duplicate?(); isPresented = false }
                    ),
                    stop: .duplicate
                )
            }
        }
        // Wide enough for what is inside it. The books column, the divider,
        // the chapter grid and the padding add up to this; a narrower frame
        // squeezed the padding away on one side, so the field's focus ring
        // sat against the popover's edge while the other side kept its
        // margin.
        .padding(20)
        .frame(width: Self.booksColumnWidth + Self.chaptersColumnWidth + 65)
        .onAppear {
            resetSelection()
            focus = .field
        }
        .onKeyPress(keys: [.tab, Self.backTab]) { press in
            let backwards = press.key == Self.backTab || press.modifiers.contains(.shift)
            focus = LampPassagePickerKeys.stepping(from: focus, by: backwards ? -1 : 1, through: ring)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            arrow(press.key)
        }
        .onKeyPress(.return) { commitFocused() }
        // A stop can leave while it has focus: the offer row goes as soon as
        // what was typed stops being an offer, and the columns go while the
        // next translation's books load. Focus would otherwise be left on
        // nothing, with the keys doing nothing until Tab was pressed.
        .onChange(of: ring) { _, stops in
            guard let focus, !stops.contains(focus) else { return }
            self.focus = .field
        }
        .onChange(of: translationID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            // Keep the draft passage while the new translation's books load.
            // Most translations use the same canonical book numbers, so the
            // existing book and chapter can carry straight across.
            isLoadingBooks = true
            errorMessage = nil
        }
        .onChange(of: bookNumber) { oldValue, newValue in
            guard oldValue != newValue else { return }
            chapterNumber = translationID == workspace.selectedTranslationID
                    && newValue == workspace.selectedBookNumber
                ? workspace.selectedChapterNumber
                : 1
            clampChapterNumber()
        }
        .task(id: translationID) { await loadBooks() }
    }

    private var selectedBook: LampTranslationBook? {
        books.first { $0.id == bookNumber }
    }

    /// The two columns, named so the popover's width can be worked out from
    /// them rather than guessed.
    private static let booksColumnWidth: Double = 168
    private static let chaptersColumnWidth: Double = 236
    /// ⇧Tab arrives as this, not as Tab with a shift: a Mac keyboard sends
    /// the back-tab character for it.
    private static let backTab = KeyEquivalent("\u{19}")

    private var fieldPrompt: String {
        openSearch == nil ? "Reference, or a book" : "Reference, or words to search for"
    }

    private var trimmedTyped: String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the field holds, if it is a passage. The search's own parser, so
    /// the two fields understand the same things.
    private var typedReference: LampSearchReference? {
        trimmedTyped.isEmpty ? nil : LampSearchQuery(trimmedTyped).reference
    }

    /// A Strong's key, which is neither a passage nor words to search for.
    /// The same reading the search box uses, so typing H7225 here means what
    /// it means there.
    private var typedStrongsKey: String? {
        LampStrongsKey.typedKey(trimmedTyped)
    }

    /// The one thing Return would do with what has been typed, which the row
    /// under the field offers to do with a click.
    private var offer: PassagePickerOffer? {
        if let reference = typedReference {
            return PassagePickerOffer(
                icon: "book",
                title: "Go to \(reference.description)",
                action: { go(to: reference) }
            )
        }
        if let key = typedStrongsKey, let openAnalysis {
            return PassagePickerOffer(
                icon: "chart.bar.xaxis",
                title: "Analyse \(key)",
                action: {
                    isPresented = false
                    openAnalysis(key)
                }
            )
        }
        if !trimmedTyped.isEmpty, matchingBooks.isEmpty, let openSearch {
            let words = trimmedTyped
            return PassagePickerOffer(
                icon: "magnifyingglass",
                title: "Search for “\(words)”",
                action: {
                    isPresented = false
                    openSearch(words)
                }
            )
        }
        return nil
    }

    /// The stops Tab moves through, as this picker stands.
    private var ring: [LampPassagePickerStop] {
        LampPassagePickerKeys.ring(
            offer: offer != nil,
            passages: !isLoadingBooks && errorMessage == nil,
            duplicate: duplicate != nil && workspace.currentLocation != nil
        )
    }

    /// The books the typed text narrows to. Anything that parses as a
    /// reference is handled above, so this is the half-typed case: "jo"
    /// while you are still deciding between John and Joshua.
    private var matchingBooks: [LampTranslationBook] {
        guard !trimmedTyped.isEmpty, typedReference == nil else { return books }
        return books.filter { $0.name.localizedCaseInsensitiveContains(trimmedTyped) }
    }

    private var booksList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(matchingBooks) { book in
                        Button {
                            focus = .books
                            bookNumber = book.id
                        } label: {
                            Text(book.name)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    book.id == bookNumber ? AnyShapeStyle(.selection)
                                        : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(book.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: Self.booksColumnWidth)
            .focusable()
            .focused($focus, equals: .books)
            .focusEffectDisabled()
            .overlay { focusRing(.books, cornerRadius: 8) }
            // Open on the book being read, rather than at Genesis with the
            // reader somewhere in Kings.
            .onAppear { proxy.scrollTo(bookNumber, anchor: .center) }
            .onChange(of: scrollToBook) { _, book in
                guard let book else { return }
                proxy.scrollTo(book, anchor: .center)
            }
        }
    }

    private var chapterGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let selectedBook {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(38), spacing: 6),
                            count: LampPassagePickerKeys.chapterColumns
                        ),
                        spacing: 6
                    ) {
                        ForEach(1...selectedBook.chapterCount, id: \.self) { chapter in
                            Button {
                                commit(book: selectedBook.id, chapter: chapter)
                            } label: {
                                Text(chapter.formatted())
                                    .monospacedDigit()
                                    .frame(width: 38, height: 30)
                                    .background(
                                        isCurrent(book: selectedBook.id, chapter: chapter)
                                            ? AnyShapeStyle(.tint.opacity(0.25))
                                            : AnyShapeStyle(.quaternary),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .overlay {
                                        // Which chapter Return would open,
                                        // shown only while the grid has the
                                        // keyboard: with a mouse it is the
                                        // one under the pointer.
                                        if focus == .chapters, chapter == chapterNumber {
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(chapter)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("Choose a book")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(width: Self.chaptersColumnWidth)
            .focusable()
            .focused($focus, equals: .chapters)
            .focusEffectDisabled()
            .overlay { focusRing(.chapters, cornerRadius: 8) }
            .onChange(of: scrollToChapter) { _, chapter in
                guard let chapter else { return }
                proxy.scrollTo(chapter, anchor: .center)
            }
        }
    }

    private func offerRow(_ offer: PassagePickerOffer, stop: LampPassagePickerStop) -> some View {
        Button(action: offer.action) {
            HStack(spacing: 8) {
                Image(systemName: offer.icon).foregroundStyle(.tint)
                Text(offer.title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "return").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: stop)
        .focusEffectDisabled()
        .overlay { focusRing(stop, cornerRadius: 6) }
    }

    /// What has the keyboard. Drawn here rather than left to the system,
    /// which rings a text field but leaves a plain focusable view unmarked.
    private func focusRing(_ stop: LampPassagePickerStop, cornerRadius: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(focus == stop ? 1 : 0)
    }

    private func isCurrent(book: Int, chapter: Int) -> Bool {
        translationID == workspace.selectedTranslationID
            && book == workspace.selectedBookNumber
            && chapter == workspace.selectedChapterNumber
    }

    // MARK: - The keyboard

    /// An arrow key, meaning whatever the focused stop says it means.
    private func arrow(_ key: KeyEquivalent) -> KeyPress.Result {
        switch focus {
        // Arrows reach the books from the field too, so a book can be typed
        // at and then stepped through without leaving what was typed.
        case .field, .books:
            guard key == .upArrow || key == .downArrow else { return .ignored }
            let rows = matchingBooks
            let current = rows.firstIndex { $0.id == bookNumber }
            guard let destination = LampPassagePickerKeys.row(
                from: current,
                by: key == .upArrow ? -1 : 1,
                of: rows.count
            ) else { return .ignored }
            bookNumber = rows[destination].id
            scrollToBook = bookNumber
            return .handled

        case .chapters:
            guard let selectedBook else { return .ignored }
            let offset: Int
            switch key {
            case .upArrow: offset = -LampPassagePickerKeys.chapterColumns
            case .downArrow: offset = LampPassagePickerKeys.chapterColumns
            case .leftArrow: offset = -1
            default: offset = 1
            }
            chapterNumber = LampPassagePickerKeys.chapter(
                from: chapterNumber,
                by: offset,
                of: selectedBook.chapterCount
            )
            scrollToChapter = chapterNumber
            return .handled

        case .translation:
            guard key == .upArrow || key == .downArrow else { return .ignored }
            let ids = model.translations.map(\.id)
            guard let destination = LampPassagePickerKeys.row(
                from: ids.firstIndex(of: translationID),
                by: key == .upArrow ? -1 : 1,
                of: ids.count
            ) else { return .ignored }
            translationID = ids[destination]
            return .handled

        default:
            return .ignored
        }
    }

    /// Return, meaning whatever the focused stop says it means. The field
    /// keeps its own: it submits, and `commitTyped` reads what was typed.
    private func commitFocused() -> KeyPress.Result {
        switch focus {
        case .offer:
            offer?.action()
            return .handled
        case .duplicate:
            duplicate?()
            isPresented = false
            return .handled
        case .translation, .books, .chapters:
            guard let selectedBook else { return .ignored }
            commit(book: selectedBook.id, chapter: chapterNumber)
            return .handled
        default:
            return .ignored
        }
    }

    /// Return in the field: whatever it is offering, the one book it has
    /// narrowed to if it has narrowed to one, or the words themselves.
    private func commitTyped() {
        if let offer {
            offer.action()
        } else if matchingBooks.count == 1, let only = matchingBooks.first {
            bookNumber = only.id
            typed = ""
        } else if !trimmedTyped.isEmpty, let openSearch {
            isPresented = false
            openSearch(trimmedTyped)
        }
    }

    // MARK: - Going there

    private func go(to reference: LampSearchReference) {
        isPresented = false
        open(ReaderLocation.typed(
            reference: reference.startReference,
            through: reference.endReference,
            in: translationID
        ))
    }

    private func commit(book: Int, chapter: Int) {
        isPresented = false
        open(ReaderLocation(
            translationID: translationID,
            bookNumber: book,
            chapterNumber: chapter
        ))
    }

    private func resetSelection() {
        translationID = workspace.selectedTranslationID ?? model.translations.first?.id ?? ""
        books = translationID == workspace.selectedTranslationID ? workspace.books : []
        bookNumber = workspace.selectedBookNumber ?? books.first?.id ?? 0
        chapterNumber = workspace.selectedChapterNumber
        clampChapterNumber()
        errorMessage = nil
    }

    @MainActor
    private func loadBooks() async {
        guard !translationID.isEmpty else {
            books = []
            return
        }

        let requestedTranslationID = translationID
        if requestedTranslationID == workspace.selectedTranslationID, !workspace.books.isEmpty {
            books = workspace.books
            if !books.contains(where: { $0.id == bookNumber }) {
                bookNumber = books.first?.id ?? 0
            }
            clampChapterNumber()
            isLoadingBooks = false
            errorMessage = nil
            return
        }

        isLoadingBooks = true
        errorMessage = nil
        do {
            let loaded = try await model.library.translationBooks(moduleID: requestedTranslationID)
            guard translationID == requestedTranslationID else { return }
            books = loaded
            if !loaded.contains(where: { $0.id == bookNumber }) {
                bookNumber = loaded.first?.id ?? 0
            }
            clampChapterNumber()
        } catch {
            guard translationID == requestedTranslationID else { return }
            books = []
            errorMessage = error.localizedDescription
        }
        if translationID == requestedTranslationID { isLoadingBooks = false }
    }

    private func clampChapterNumber() {
        guard let selectedBook else {
            chapterNumber = 1
            return
        }
        chapterNumber = min(max(chapterNumber, 1), selectedBook.chapterCount)
    }
}

private struct TranslationReaderView: View, Equatable {
    /// Handed in rather than observed: the reader takes the library's changes
    /// from the view above it, which lets a hidden reader decline them (see
    /// `==`). Shown, it updates whenever the library does, as before.
    let model: LibraryModel
    /// This window's place in scripture. Handed in for the same reason as the
    /// model above: observed here, a hidden reader could not decline its
    /// changes.
    let workspace: ReaderWorkspace
    @EnvironmentObject private var scrollLink: ReaderScrollLink
    @AppStorage("reader.fontSize") private var fontSize = LampTextScale.readerText.defaultValue
    @AppStorage("reader.lineSpacing") private var lineSpacing = LampTextScale.readerLineSpacing.defaultValue
    @AppStorage("reader.typeface") private var typeface = ProseTypeface.readerDefault
    @AppStorage("reader.layoutMode") private var readerLayoutMode = ReaderLayoutMode.continuousParagraphs
    /// The layout side by side was chosen from, which leaving it returns to.
    @AppStorage("reader.layoutModeBeforeSideBySide") private var layoutModeBeforeSideBySide =
        ReaderLayoutMode.continuousParagraphs
    /// The translations read beside the selected one, side by side, in column
    /// order, comma-separated. Empty, or only translations no longer there,
    /// means the first other one installed.
    @AppStorage("reader.companionTranslationIDs") private var companionTranslationIDList = ""
    /// The one companion chosen before several could be, read while the list
    /// above is empty.
    @AppStorage("reader.companionTranslationID") private var singleCompanionTranslationID = ""
    @State private var companionText = ReaderCompanionText()
    @AppStorage("reader.readAloud.voice") private var readAloudVoice = ""
    @AppStorage("reader.readAloud.rate") private var readAloudRate = 0.5
    @AppStorage("reader.readAloud.followAlong") private var followReadAloud = true
    @AppStorage("studyInspector.tab") private var selectedStudyTab = "commentary"
    @StateObject private var readAloud = ReadAloudController()
    @State private var showingPlanQuiz = false
    /// Mount and reveal are separate so the panel exists before it is asked to
    /// appear — SwiftUI does not animate a view's first layout.
    @State private var isQuizPanelMounted = false
    @State private var quizRevealedWidth: Double = 0
    @State private var isQuizTransitioning = false

    /// True while either side panel is opening or closing. The reader suspends its
    /// scroll reporting throughout, so a position measured mid-re-wrap can never
    /// become the anchor the next transition restores to.
    private var isPanelTransitioning: Bool {
        isSidebarTransitioning || isQuizTransitioning
    }

    /// The quiz panel and its leading divider.
    private static let quizPanelWidth: Double = 411

    private var showingStudyInspector: Bool {
        get { readerSidebar == .study }
        nonmutating set {
            if newValue { readerSidebar = .study } else if readerSidebar == .study { readerSidebar = nil }
        }
    }

    private var showingReaderChat: Bool {
        get { readerSidebar == .chat }
        nonmutating set {
            if newValue { readerSidebar = .chat } else if readerSidebar == .chat { readerSidebar = nil }
        }
    }
    /// The translator's notes for the passage on screen: what each says, and
    /// where in its verse it belongs. Fetched after the text is drawn, since
    /// most reading never opens one.
    @State private var chapterFootnotes: [Int: LampVerseStudyData] = [:]
    /// The note the reader has opened, by verse and by its place in that verse.
    @State private var revealedFootnote: ReaderFootnoteKey?
    @State private var showingReaderLocationPicker = false
    @State private var highlightVerse: LampVerse?
    @State private var planReadingChapters: [LampChapter] = []
    @State private var loadedPlanReadingRequest: PlanReadingChapterRequest?
    @State private var isLoadingPlanReading = false
    @State private var planReadingError: String?
    /// Set by the reader's own click handlers, so the selection they make does not
    /// come back as an instruction to scroll to it.
    @State private var isSelectingVerseFromReader = false
    /// The verse the reader was showing when its side-by-side columns changed,
    /// and the passage it was in, until the new columns' text is in.
    @State private var heldColumnsAnchor: (passage: String, reference: Int)?
    @State private var linkActivationGate = ReaderLinkActivationGate()
    @State private var paragraphAnchors = ReaderParagraphAnchorStore()
    @Namespace private var readerScrollCoordinateSpace
    /// False while another section of the library is shown in its place.
    let isShown: Bool
    @Binding var planReadingMode: PlanReadingMode?
    /// The state itself, not a binding per column made from closures: SwiftUI
    /// can't see that a made binding is unchanged, so it counts as a change on
    /// every update, and the reader was redrawn under every section.
    @Binding var readerSidebar: ReaderSidebar?
    let lexicalHoverStore: ReaderLexicalHoverStore
    let isSidebarTransitioning: Bool
    let showImporter: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if planReadingMode != nil {
                PlanReadingModeBar(
                    mode: $planReadingMode,
                    showingQuiz: $showingPlanQuiz,
                    openReading: openPlanReading
                )
                Divider()
            }

            // The same transition as the study column, for the same reasons: one
            // animated width so the reader and the panel cannot disagree, and a
            // panel that fades up in place rather than sliding, because its
            // contents are AppKit-hosted and would not travel with it.
            GeometryReader { geometry in
                let revealed = min(max(quizRevealedWidth, 0), Self.quizPanelWidth)
                let progress = revealed / Self.quizPanelWidth
                HStack(spacing: 0) {
                    readerContent
                        .frame(
                            width: max(geometry.size.width - revealed, 0),
                            height: geometry.size.height
                        )

                    if let planReadingMode, isQuizPanelMounted {
                        HStack(spacing: 0) {
                            Divider()
                            PlanReadingQuizPanel(
                                mode: planReadingMode,
                                close: { showingPlanQuiz = false },
                                openReference: { workspace.openReference($0) }
                            )
                        }
                        .frame(width: Self.quizPanelWidth, height: geometry.size.height)
                        .frame(width: revealed, alignment: .trailing)
                        .opacity(progress)
                        .allowsHitTesting(progress > 0.99)
                    }
                }
                .animation(
                    .smooth(duration: StudyInspectorMetrics.revealDuration),
                    value: revealed
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .task(id: showingPlanQuiz) {
            isQuizTransitioning = true
            if showingPlanQuiz {
                isQuizPanelMounted = true
                await Task.yield()
                guard !Task.isCancelled, showingPlanQuiz else { return }
                quizRevealedWidth = Self.quizPanelWidth
                do {
                    try await Task.sleep(for: .seconds(StudyInspectorMetrics.revealDuration))
                } catch {
                    return
                }
                guard !Task.isCancelled, showingPlanQuiz else { return }
            } else {
                quizRevealedWidth = 0
                do {
                    try await Task.sleep(for: .seconds(StudyInspectorMetrics.revealDuration))
                } catch {
                    return
                }
                guard !showingPlanQuiz else { return }
                isQuizPanelMounted = false
            }
            isQuizTransitioning = false
        }
        // The window's toolbar and menus belong to whichever section is shown.
        .toolbar { if isShown { readerToolbar } }
        // On the view, not on the toolbar button: a toolbar item is not in
        // the focus chain, so a focused value published from one never
        // reaches the menu and the command stays greyed out.
        .focusedSceneValue(\.goToPassageAction, isShown ? { showingReaderLocationPicker = true } : nil)
        .toolbar(removing: isShown ? .title : nil)
        .focusedObject(isShown ? scrollLink : nil)
        .onChange(of: isShown) { _, isShown in
            if isShown { readerDidReturn() } else { readerDidLeave() }
        }
        .sheet(item: $highlightVerse) { verse in
            VerseHighlightEditorView(verse: verse)
                .environmentObject(model)
        }
        .onChange(of: readAloud.currentReference) { _, reference in
            guard followReadAloud, let reference else { return }
            workspace.focusVerse(reference)
        }
        .onChange(of: workspace.selectedTranslationID) { _, _ in
            readAloud.stop()
            // Do not leave details from the previous translation visible while
            // the replacement passage is loading. The new passage opts back in
            // after confirming it contains Strong's annotations.
            lexicalHoverStore.configure(isDetailsEnabled: false)
        }
        .onChange(of: workspace.selectedBookNumber) { _, _ in readAloud.stop() }
        .onChange(of: workspace.selectedChapterNumber) { _, _ in readAloud.stop() }
        .onChange(of: planReadingMode) { _, mode in
            if mode == nil { showingPlanQuiz = false }
        }
        .task(id: planReadingChapterRequest) {
            await loadPlanReadingChapters(for: planReadingChapterRequest)
        }
        .onDisappear {
            readAloud.stop()
            lexicalHoverStore.details = nil
        }
        .environment(\.openURL, OpenURLAction { url in
            handleReaderLink(url) ? .handled : .systemAction
        })
    }

    /// A hidden reader ignores everything handed to it until it is shown again.
    /// Every library change would otherwise rebuild a passage nobody can see:
    /// writing's autosave is one, and drawing the reader under it doubled what
    /// each cost. Shown, or coming or going, it updates as any view does.
    static func == (lhs: Self, rhs: Self) -> Bool {
        !lhs.isShown && !rhs.isShown
    }

    /// While another section is shown the reader is kept, not rebuilt, so what
    /// rebuilding used to reset is reset here. Anything added to the reader that
    /// shouldn't outlast its being left belongs in this list:
    /// - reading aloud stops, as it does when the window closes;
    /// - no word's details stay on screen;
    /// - the location picker closes, as its toolbar button is going;
    /// - a click's note not to scroll to its own selection is dropped, or the
    ///   next verse opened from another section would never be scrolled to.
    ///
    /// The reader's rows answer the pointer only while they can be seen (see
    /// `ReaderLexicalHoverStore.isEffectivelyVisible`), so nothing is needed for
    /// hover, links or context menus. The quiz panel and its transition are the
    /// reader's own state, which updates it even while hidden, so the panel is
    /// left as it was and an animation under way finishes out of sight.
    ///
    /// `.onDisappear` repeats the first two for the window closing, which is the
    /// one way the reader still goes away.
    private func readerDidLeave() {
        readAloud.stop()
        lexicalHoverStore.details = nil
        showingReaderLocationPicker = false
        isSelectingVerseFromReader = false
    }

    /// Coming back, the reader is drawn from the library as it is now, which
    /// takes in whatever changed while it was hidden: the passage, highlights,
    /// notes, a verse chosen from search. A plan reading is the reader's own copy
    /// of the library's text, so it is read again; the copy on screen stays until
    /// the new one is in.
    private func readerDidReturn() {
        guard let request = planReadingChapterRequest,
              loadedPlanReadingRequest == request else { return }
        Task { await loadPlanReadingChapters(for: request, rereading: true) }
    }

    @ViewBuilder
    private var readerContent: some View {
        if model.translations.isEmpty {
            ContentUnavailableView {
                Label("No Translation Installed", systemImage: "books.vertical")
            } description: {
                Text("Install a translation .lamp module, or build one in Module Studio.")
            } actions: {
                Button("Install Module…", action: showImporter)
                    .buttonStyle(.borderedProminent)
            }
        } else if let request = planReadingChapterRequest {
            if loadedPlanReadingRequest == request, !planReadingChapters.isEmpty {
                passageView(planReadingChapters)
                    .id("plan:\(request.translationID):\(request.readingID)")
                    .task(id: footnoteLoadKey(for: planReadingChapters)) {
                        await loadFootnotes(for: planReadingChapters)
                    }
            } else if let planReadingError, !isLoadingPlanReading {
                ContentUnavailableView(
                    "Reading Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(planReadingError)
                )
            } else {
                ProgressView("Loading Reading…")
            }
        } else if let chapter = workspace.chapter {
            passageView([chapter])
                .id("\(chapter.book.id):\(chapter.number)")
                .task(id: footnoteLoadKey(for: [chapter])) {
                    await loadFootnotes(for: [chapter])
                }
        } else if workspace.isLoadingChapter {
            ProgressView("Loading Chapter…")
        } else {
            ContentUnavailableView(
                "Choose a Translation",
                systemImage: "book",
                description: Text("Select an installed translation in the sidebar.")
            )
        }
    }

    private var planReadingChapterRequest: PlanReadingChapterRequest? {
        guard let translationID = workspace.selectedTranslationID,
              let reading = planReadingMode?.activeReading else { return nil }
        return PlanReadingChapterRequest(
            translationID: translationID,
            readingID: reading.id,
            startReference: reading.startReference,
            endReference: reading.endReference
        )
    }

    private var displayedChapters: [LampChapter] {
        if let request = planReadingChapterRequest,
           loadedPlanReadingRequest == request,
           !planReadingChapters.isEmpty {
            return planReadingChapters
        }
        return workspace.chapter.map { [$0] } ?? []
    }

    /// `rereading` reads again a reading already on screen, which stays there
    /// until the new copy is in.
    private func loadPlanReadingChapters(
        for request: PlanReadingChapterRequest?,
        rereading: Bool = false
    ) async {
        guard let request else {
            planReadingChapters = []
            loadedPlanReadingRequest = nil
            isLoadingPlanReading = false
            planReadingError = nil
            return
        }
        if !rereading {
            if loadedPlanReadingRequest == request, !planReadingChapters.isEmpty { return }
            isLoadingPlanReading = true
            planReadingError = nil
        }
        do {
            let books = try await model.library.translationBooks(moduleID: request.translationID)
            try Task.checkCancellation()
            let locations = ReaderPassageChapterPlanner.locations(
                from: request.startReference,
                to: request.endReference,
                books: books.map {
                    ReaderBookStructure(bookNumber: $0.id, chapterCount: $0.chapterCount)
                }
            )
            guard !locations.isEmpty else {
                planReadingChapters = []
                loadedPlanReadingRequest = nil
                planReadingError = "The plan contains an invalid scripture range."
                isLoadingPlanReading = false
                return
            }

            var loaded: [LampChapter] = []
            for location in locations {
                try Task.checkCancellation()
                let chapter = try await model.library.chapter(
                    moduleID: request.translationID,
                    bookNumber: location.bookNumber,
                    chapterNumber: location.chapterNumber
                )
                let verses = chapter.verses.filter {
                    $0.id >= request.startReference && $0.id <= request.endReference
                }
                guard !verses.isEmpty else { continue }
                let includedVerseNumbers = Set(verses.map(\.number))
                loaded.append(LampChapter(
                    translationID: chapter.translationID,
                    book: chapter.book,
                    number: chapter.number,
                    verses: verses,
                    headings: chapter.headings.filter {
                        includedVerseNumbers.contains($0.beforeVerse)
                    }
                ))
            }
            try Task.checkCancellation()
            guard planReadingChapterRequest == request else { return }
            guard !loaded.isEmpty else {
                planReadingChapters = []
                loadedPlanReadingRequest = nil
                planReadingError = "No verses were found for this plan reading."
                isLoadingPlanReading = false
                return
            }
            // Unchanged, as a reread nearly always is, it is left alone rather
            // than drawn again.
            if planReadingChapters != loaded { planReadingChapters = loaded }
            loadedPlanReadingRequest = request
            isLoadingPlanReading = false
        } catch is CancellationError {
            return
        } catch {
            guard planReadingChapterRequest == request else { return }
            planReadingChapters = []
            loadedPlanReadingRequest = nil
            planReadingError = error.localizedDescription
            isLoadingPlanReading = false
        }
    }

    private func openPlanReading(_ reading: LampPlanReading) {
        guard var mode = planReadingMode else { return }
        mode.activeReadingID = reading.id
        planReadingMode = mode
        workspace.openReference(reading.startReference)
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

    private func navigateReaderBackward() {
        guard let mode = planReadingMode else {
            workspace.navigateBackward()
            return
        }
        guard let index = activePlanReadingIndex, index > mode.readings.startIndex else { return }
        openPlanReading(mode.readings[mode.readings.index(before: index)])
    }

    private func navigateReaderForward() {
        guard let mode = planReadingMode else {
            workspace.navigateForward()
            return
        }
        guard let index = activePlanReadingIndex,
              index < mode.readings.index(before: mode.readings.endIndex) else { return }
        openPlanReading(mode.readings[mode.readings.index(after: index)])
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

    private func passageView(_ chapters: [LampChapter]) -> some View {
        let sections = chapters.map { ReaderPassageChapter(chapter: $0) }
        let passageIdentity = sections.map(\.id).joined(separator: ",")
        let showsInstantDetails = StrongsKey.hasAnnotations(
            chapters.lazy
                .flatMap { $0.verses }
                .flatMap { $0.annotations }
                .map(\.strongs)
        )
        // Sized from the outside in. A ScrollView asked how big it would like to be
        // answers by measuring its content, and measuring this content means
        // walking every paragraph of the passage. Handing it exact bounds means
        // nothing above it ever has to ask.
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Typical reader passages contain only a few dozen rows.
                        // A lazy stack buys nothing at that scale, while its row
                        // estimation can enter a non-converging placement loop when
                        // scrolling wrapped NSViewRepresentable text: it repeatedly
                        // materialises the same rows, grows the estimated scroll
                        // extent, and allocates until the app is unresponsive.
                        // A regular stack measures the bounded passage once and gives
                        // the scroll view a stable content extent.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                readerChapterSection(
                                    section.chapter,
                                    isFirst: section.id == sections.first?.id,
                                    showsInstantDetails: showsInstantDetails,
                                    stacksCompanion: ReaderParallel.stacks(
                                        passageWidth: min(viewport.size.width - 96, passageWidth(for: chapters)),
                                        columns: parallelColumnCount(for: chapters)
                                    )
                                )
                            }
                        }
                        // The two modes intentionally reuse verse references as scroll
                        // targets. Give the container a new identity when switching so
                        // SwiftUI cannot reuse a whole paragraph for a single-verse row.
                        .id(readerLayoutMode)
                        .scrollTargetLayout()

                        // Keep the tail outside the lazy stack. A lazy final child is
                        // not measured until it nears the viewport, which changes the
                        // scroll extent mid-scroll and makes the scrollbar thumb jump.
                        Color.clear
                            .containerRelativeFrame(.vertical) { viewportHeight, _ in
                                ReaderScrollTail.height(for: viewportHeight)
                            }
                            .accessibilityHidden(true)
                    }
                    // Side by side, each column gets about the measure one
                    // column has on its own.
                    .frame(maxWidth: passageWidth(for: chapters), alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 42)
                    // The live viewport width, so the passage uses whatever room it
                    // has and re-wraps as that changes. Exact rather than flexible:
                    // the ScrollView is never asked to derive a width by measuring
                    // its content, which is what used to make opening the column an
                    // O(passage) operation.
                    .frame(width: viewport.size.width)
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .scrollIndicators(isPanelTransitioning ? .hidden : .automatic)
                .onReceive(lexicalHoverStore.linkActivations) { url in
                    _ = handleReaderLink(url)
                }
                // A new passage gets a fresh scroll container at its natural zero
                // offset, including the padding above the book heading.
                .id(passageIdentity)
                .onScrollTargetVisibilityChange(idType: Int.self) { visible in
                    guard !isPanelTransitioning,
                          readerLayoutMode.drawsVerseRows else { return }
                    scrollLink.readerDidScroll(to: visible.min())
                }
                // Read once per scroll rather than once per paragraph that happens to
                // move: the paragraphs report their positions into a store that
                // invalidates nothing, and the scroll itself decides when to look.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, _ in
                    guard !isPanelTransitioning,
                          readerLayoutMode == .continuousParagraphs else { return }
                    scrollLink.readerDidScroll(to: paragraphAnchors.topEdgeReference)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    if oldPhase.isUserDriven != newPhase.isUserDriven {
                        // Keep scroll phase outside SwiftUI state. Invalidating the
                        // reader here makes SwiftUI reconstruct the selectable
                        // attributed-text overlay while the passage is moving.
                        lexicalHoverStore.configure(isScrollFrozen: newPhase.isUserDriven)
                        if newPhase.isUserDriven {
                            lexicalHoverStore.clearForScrolling()
                        }
                    }
                    if !oldPhase.isUserDriven, newPhase.isUserDriven {
                        scrollLink.readerUserScrollDidBegin()
                    }
                    guard oldPhase.isScrolling,
                          !newPhase.isScrolling,
                          readerReachedBottom(context.geometry) else { return }
                    completeActivePlanReading()
                }
                .onReceive(scrollLink.toolAnchors) { reference in
                    // A study pane appearing or disappearing lays out, reports its
                    // position, and would drag the reader to it. The link is for
                    // following a pane the reader is scrolling, not for being
                    // rearranged by one that just arrived.
                    guard !isPanelTransitioning else { return }
                    proxy.scrollTo(scrollTarget(for: reference, in: chapters), anchor: .top)
                }
                .onAppear { scrollToReaderLocation(proxy, chapters: chapters) }
                .onChange(of: workspace.selectedVerseReference) { _, _ in
                    // Selecting a verse by clicking it in the reader must not move
                    // the reader: the verse is already under the pointer. This
                    // scroll is for selections made elsewhere — search, history, a
                    // cross-reference — where the verse is somewhere off screen.
                    guard !isSelectingVerseFromReader else {
                        isSelectingVerseFromReader = false
                        return
                    }
                    scrollToReaderLocation(proxy, chapters: chapters)
                }
                .onChange(of: passageIdentity, initial: true) { _, _ in
                    paragraphAnchors.prepare(for: chapters)
                    scrollLink.reset()
                    // Translation changes temporarily disable the shared store
                    // while the next passage loads. Re-enable it for every new
                    // passage, even when both translations contain annotations
                    // and this availability value therefore remains `true`.
                    lexicalHoverStore.configure(isDetailsEnabled: showsInstantDetails)
                }
                // Visibility reports arrive on first layout; a scroll-driven read does
                // not. Seed the anchor after the passage lays out so opening a study
                // pane before scrolling still finds a position to adopt.
                .task(id: passageIdentity) {
                    await Task.yield()
                    guard !isPanelTransitioning,
                          readerLayoutMode == .continuousParagraphs else { return }
                    scrollLink.readerDidScroll(to: paragraphAnchors.topEdgeReference)
                }
                .onChange(of: readerLayoutMode) { _, _ in
                    scrollLink.reset()
                    scrollToReaderLocation(proxy, chapters: chapters)
                }
                // Side by side, the rows arrive with the companion's text,
                // after the scroll that looked for the verse being read.
                .onChange(of: companionText.asked.sorted()) { _, _ in
                    guard readerLayoutMode == .sideBySide else { return }
                    scrollToReaderLocation(proxy, chapters: chapters)
                }
                // A column added, taken away or changed re-wraps every row
                // twice: once for the new number of columns, and again when
                // the new text is in. Each time the reader settles back onto
                // the verse it was showing, at the same passage: a change that
                // also opens another translation scrolls as opening one does.
                .onChange(of: chosenCompanionIDs) { _, _ in
                    guard readerLayoutMode == .sideBySide,
                          companionTranslations(beside: chapters.first?.translationID).map(\.id)
                            != companionText.translationIDs,
                          let reference = scrollLink.currentReaderAnchor else { return }
                    heldColumnsAnchor = (passageIdentity, reference)
                    proxy.scrollTo(scrollTarget(for: reference, in: chapters), anchor: .top)
                }
                .onChange(of: companionText.translationIDs) { _, _ in
                    guard let held = heldColumnsAnchor else { return }
                    heldColumnsAnchor = nil
                    guard held.passage == passageIdentity else { return }
                    proxy.scrollTo(scrollTarget(for: held.reference, in: chapters), anchor: .top)
                }
                .coordinateSpace(name: readerScrollCoordinateSpace)
                .overlay {
                    ReaderLexicalHoverObserver(
                        interactionStore: lexicalHoverStore
                    )
                        .frame(width: viewport.size.width, height: viewport.size.height)
                }
        }
        }
        .task(id: companionLoadKey(for: chapters)) {
            await loadCompanion(for: chapters)
        }
    }

    // MARK: Side by side

    /// A translation's short name, for a column's title.
    private func translationName(_ id: String?) -> String {
        guard let module = model.translations.first(where: { $0.id == id }) else { return "" }
        return module.abbreviation ?? module.name
    }

    /// A translation's full name, for a sentence: a short one like "ASVs",
    /// with its s for Strong's, reads as a plural there.
    private func translationFullName(_ id: String?) -> String {
        model.translations.first { $0.id == id }?.name ?? "translation"
    }

    /// The companions chosen, in column order.
    private var chosenCompanionIDs: [String] {
        let ids = companionTranslationIDList.split(separator: ",").map(String.init)
        return ids.isEmpty ? [singleCompanionTranslationID].filter { !$0.isEmpty } : ids
    }

    private func chooseCompanions(_ ids: [String]) {
        companionTranslationIDList = ids.joined(separator: ",")
        singleCompanionTranslationID = ""
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

    /// Takes a companion's column away. The last one's leaves side by side,
    /// and is read beside the translation again when side by side comes back.
    private func removeCompanion(at index: Int, among companions: [LampInstalledModule]) {
        guard companions.count > 1 else {
            readsSideBySide.wrappedValue = false
            return
        }
        var ids = companions.map(\.id)
        ids.remove(at: index)
        chooseCompanions(ids)
    }

    /// The translations read beside `mainID`, in column order: those chosen
    /// that are installed, and never `mainID` itself, or else the first other
    /// one installed.
    private func companionTranslations(beside mainID: String?) -> [LampInstalledModule] {
        let others = model.translations.filter { $0.id != mainID }
        var chosen: [LampInstalledModule] = []
        for id in chosenCompanionIDs where !chosen.contains(where: { $0.id == id }) {
            if let translation = others.first(where: { $0.id == id }) { chosen.append(translation) }
        }
        if chosen.isEmpty, let first = others.first { chosen = [first] }
        return Array(chosen.prefix(ReaderParallel.maximumCompanions))
    }

    private func parallelColumnCount(for chapters: [LampChapter]) -> Int {
        1 + companionTranslations(beside: chapters.first?.translationID).count
    }

    /// The passage's widest: one column's measure on its own, and each column
    /// about that, side by side.
    private func passageWidth(for chapters: [LampChapter]) -> CGFloat {
        guard readerLayoutMode == .sideBySide else { return 780 }
        return ReaderParallel.maximumColumnWidth * CGFloat(parallelColumnCount(for: chapters))
    }

    private func companionLoadKey(for chapters: [LampChapter]) -> String {
        guard readerLayoutMode == .sideBySide else { return "" }
        let companions = companionTranslations(beside: chapters.first?.translationID)
        guard !companions.isEmpty else { return "" }
        return companions.map(\.id).joined(separator: ",") + "|" + chapters
            .map { "\($0.translationID):\($0.book.id):\($0.number)" }
            .joined(separator: ",")
    }

    /// Loads the companions' text for the chapters on screen, or lets it go
    /// when the reader isn't side by side. Replaced whole once every chapter
    /// is in, so a column never shows one chapter's text beside another's.
    private func loadCompanion(for chapters: [LampChapter]) async {
        let companions = readerLayoutMode == .sideBySide
            ? companionTranslations(beside: chapters.first?.translationID)
            : []
        guard !companions.isEmpty else {
            if !companionText.translationIDs.isEmpty { companionText = ReaderCompanionText() }
            return
        }
        var loaded = ReaderCompanionText(translationIDs: companions.map(\.id))
        let mainVersification = (try? await model.library.versification(
            moduleID: chapters.first?.translationID ?? ""
        )) ?? .standard(.english)
        loaded.mainVersification = mainVersification
        // Each companion chapter once, though several on screen may need it.
        var fetched: [String: [[Int]: LampChapter]] = [:]
        for companion in companions {
            let versification = (try? await model.library.versification(moduleID: companion.id))
                ?? .standard(.english)
            var column = ReaderCompanionColumn(versification: versification)
            var highlights: [LampVerseHighlight] = []
            var chaptersOfCompanion: [[Int]: LampChapter] = [:]
            for chapter in chapters {
                let key = ReaderCompanionText.key(book: chapter.book.id, chapter: chapter.number)
                // The companion's own chapter of this number, and any other a
                // verse converts to, as the WEB's Romans 14:24 is the KJV's 16:25.
                var places: Set<[Int]> = [[chapter.book.id, chapter.number]]
                for verse in chapter.verses {
                    guard let partner = mainVersification.convert(verse.id, to: versification) else { continue }
                    places.insert([partner / 1_000_000, partner / 1_000 % 1_000])
                }
                var verses: [LampVerse] = []
                for place in places.sorted(by: { ($0[0], $0[1]) < ($1[0], $1[1]) }) {
                    if chaptersOfCompanion[place] == nil,
                       // A translation without this book or chapter leaves its side empty.
                       let text = try? await model.companionChapter(
                           translationID: companion.id,
                           book: place[0],
                           chapter: place[1]
                       ) {
                        guard !Task.isCancelled else { return }
                        chaptersOfCompanion[place] = text.chapter
                        highlights += text.highlights
                    }
                    verses += chaptersOfCompanion[place]?.verses ?? []
                }
                if !verses.isEmpty { column.chapters[key] = verses }
            }
            column.highlights = ReaderParallelRows.highlights(highlights, of: companion.id)
            loaded.columns[companion.id] = column
            fetched[companion.id] = chaptersOfCompanion
        }
        for chapter in chapters {
            loaded.asked.insert(ReaderCompanionText.key(book: chapter.book.id, chapter: chapter.number))
        }
        guard !Task.isCancelled else { return }
        companionText = loaded

        // Their translator's notes after their text, as the reading's come
        // after the reading's: the rows needn't wait for them. All at once,
        // so the rows are drawn again once rather than once a companion.
        var footnotes: [String: [Int: LampVerseStudyData]] = [:]
        for companion in companions {
            for verse in fetched[companion.id]?.values.flatMap(\.verses) ?? [] where verse.hasFootnotes {
                guard let data = try? await model.library.verseStudyData(
                    moduleID: companion.id,
                    reference: verse.id
                ) else { continue }
                guard !Task.isCancelled else { return }
                guard !data.footnotes.isEmpty, !data.footnoteReferences.isEmpty else { continue }
                footnotes[companion.id, default: [:]][verse.id] = data
            }
        }
        guard !Task.isCancelled, !footnotes.isEmpty,
              companionText.translationIDs == loaded.translationIDs else { return }
        for (id, notes) in footnotes {
            companionText.columns[id]?.footnotes = notes
        }
    }

    /// A chapter's rows beside the companion verses it pairs with, each
    /// through the two translations' numbering.
    private func parallelRows(for chapter: LampChapter) -> [ReaderParallelRow] {
        let key = ReaderCompanionText.key(book: chapter.book.id, chapter: chapter.number)
        let main = companionText.mainVersification
        let companions = companionText.translationIDs.map { id -> ReaderParallelCompanion in
            let column = companionText.columns[id]
            let verses = column?.chapters[key] ?? []
            guard let main, let other = column?.versification else {
                return ReaderParallelCompanion(verses: verses, fromMain: { $0 }, toMain: { $0 })
            }
            return ReaderParallelCompanion(
                verses: verses,
                fromMain: { main.convert($0, to: other) },
                toMain: { other.convert($0, to: main) }
            )
        }
        return ReaderParallelRows.rows(main: chapter.verses, companions: companions)
    }

    /// The translations over their columns, each a menu that changes its own
    /// column, or, with the companions beneath each verse, the same read as a
    /// sentence. A companion's menu can also make it the translation being
    /// read, or take its column away, as its close button does; the plus
    /// beside them adds one.
    ///
    /// The choice lives here rather than in a toolbar menu because this is
    /// where the translations are named: a column's title changes that column.
    private func parallelColumnTitles(for chapter: LampChapter, stacked: Bool) -> some View {
        let main = translationName(chapter.translationID)
        let companions = companionTranslations(beside: chapter.translationID)
        let canAdd = companions.count < ReaderParallel.maximumCompanions
            && model.translations.count > companions.count + 1
        return HStack(alignment: .firstTextBaseline, spacing: ReaderParallel.columnGap) {
            if stacked {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    translationMenu(main, selection: mainSelection(reading: chapter), among: model.translations)
                    Text("with")
                    ForEach(Array(companions.enumerated()), id: \.element.id) { index, companion in
                        if index > 0 {
                            if index == companions.count - 1 {
                                Text("and")
                            } else {
                                // Against the name before it, as a comma is set.
                                Text(",").padding(.leading, -4)
                            }
                        }
                        companionMenu(at: index, among: companions, reading: chapter)
                    }
                    Text("beneath each verse")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                translationMenu(main, selection: mainSelection(reading: chapter), among: model.translations)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(companions.enumerated()), id: \.element.id) { index, _ in
                    companionMenu(at: index, among: companions, reading: chapter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // Over the last title rather than beside it, so the titles keep the
        // columns' widths and stand over their own text.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                if canAdd {
                    Button("Add a Companion Translation", systemImage: "plus") {
                        addCompanion(reading: chapter)
                    }
                    .help("Read another translation beside these")
                }
                if companions.count == 1, let only = companions.first {
                    Button("Swap Translations", systemImage: "arrow.left.arrow.right") {
                        makeMain(only.id, reading: chapter)
                    }
                    .help("Read \(translationName(only.id)), with \(main) beside it")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    /// A column's title, which is also how that column's translation is chosen.
    private func translationMenu<Extras: View>(
        _ title: String,
        selection: Binding<String>,
        among translations: [LampInstalledModule],
        @ViewBuilder extras: () -> Extras = { EmptyView() }
    ) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(translations) { translation in
                    Text(translation.name).tag(translation.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            extras()
        } label: {
            // Styled here rather than left to the row: a bordered or borderless
            // menu draws its label in the control's own colour.
            Text(translations.isEmpty ? "No Other Translation" : title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(translations.isEmpty)
        .help("Choose the translation read in this column")
    }

    /// A companion column's title: its translation, and the column's own
    /// actions, with a button beside it that closes the column.
    private func companionMenu(
        at index: Int,
        among companions: [LampInstalledModule],
        reading chapter: LampChapter
    ) -> some View {
        let companion = companions[index]
        let closes = companions.count > 1
            ? "Stop reading \(translationName(companion.id)) beside \(translationName(chapter.translationID))"
            : "Read \(translationName(chapter.translationID)) on its own"
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            translationMenu(
                translationName(companion.id),
                selection: companionSelection(at: index, among: companions),
                among: model.translations.filter { $0.id != chapter.translationID }
            ) {
                Divider()
                Button("Read \(companion.name) Here Instead") {
                    makeMain(companion.id, reading: chapter)
                }
                Button("Remove This Column") {
                    removeCompanion(at: index, among: companions)
                }
            }
            Button("Remove \(companion.name)", systemImage: "xmark") {
                removeCompanion(at: index, among: companions)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .imageScale(.small)
            .help(closes)
        }
    }

    /// The translation in one companion column. Choosing one already in
    /// another column swaps the two, so no translation is read twice.
    private func companionSelection(at index: Int, among companions: [LampInstalledModule]) -> Binding<String> {
        Binding(
            get: { companions[index].id },
            set: { id in
                var ids = companions.map(\.id)
                if let other = ids.firstIndex(of: id) {
                    ids.swapAt(index, other)
                } else {
                    ids[index] = id
                }
                chooseCompanions(ids)
            }
        )
    }

    /// The translation being read, as the main column's title.
    private func mainSelection(reading chapter: LampChapter) -> Binding<String> {
        Binding(
            get: { chapter.translationID },
            set: { makeMain($0, reading: chapter) }
        )
    }

    /// Reads `id`, at the same place. A translation already in a companion
    /// column trades places with the one it replaces, so no column is lost or
    /// read twice: left to itself, the column would fall back to whichever
    /// other translation is installed first.
    private func makeMain(_ id: String, reading chapter: LampChapter) {
        guard id != chapter.translationID else { return }
        var ids = companionTranslations(beside: chapter.translationID).map(\.id)
        if let slot = ids.firstIndex(of: id) {
            ids[slot] = chapter.translationID
            chooseCompanions(ids)
        }
        workspace.openReference(readingPlace(in: chapter), translationID: id)
    }

    /// Adds a column for the first installed translation not yet read here.
    private func addCompanion(reading chapter: LampChapter) {
        var ids = companionTranslations(beside: chapter.translationID).map(\.id)
        guard let next = model.translations.first(where: {
            $0.id != chapter.translationID && !ids.contains($0.id)
        }) else { return }
        ids.append(next.id)
        chooseCompanions(ids)
    }

    /// Where a chapter reopens when its translation changes: the verse being
    /// studied, else the chapter's first verse.
    private func readingPlace(in chapter: LampChapter) -> Int {
        workspace.selectedVerseReference
            ?? chapter.verses.first?.id
            ?? chapter.book.id * 1_000_000 + chapter.number * 1_000 + 1
    }

    private func parallelRow(
        _ row: ReaderParallelRow,
        companionIDs: [String],
        key: String,
        stacked: Bool,
        showsInstantDetails: Bool
    ) -> some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    parallelMainCell(row, showsInstantDetails: showsInstantDetails)
                    ForEach(companionIDs, id: \.self) { id in
                        parallelCompanionCell(
                            row,
                            column: .companionBelow(id),
                            key: key,
                            showsInstantDetails: showsInstantDetails
                        )
                        .padding(.leading, ReaderParallel.stackedIndent)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: ReaderParallel.columnGap) {
                    parallelMainCell(row, showsInstantDetails: showsInstantDetails)
                    ForEach(companionIDs, id: \.self) { id in
                        parallelCompanionCell(
                            row,
                            column: .companion(id),
                            key: key,
                            showsInstantDetails: showsInstantDetails
                        )
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) { parallelRowMarks(for: row.reference) }
        .padding(.top, row.main.map { topPadding(for: $0) } ?? 5)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parallelMainCell(_ row: ReaderParallelRow, showsInstantDetails: Bool) -> some View {
        Group {
            if let verse = row.main {
                renderedVerseText(for: verse, column: .main)
                    .padding(.leading, partialPoetryRange(for: verse) == nil ? poetryIndent(for: verse) : 0)
                    .overlay {
                        ReaderNativeContextMenuAugmenter(
                            entries: verseContextMenuEntries(verse),
                            openLink: { _ = handleReaderLink($0) },
                            participatesInLexicalHover: showsInstantDetails
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
            } else {
                missingVerse(row.number, in: workspace.selectedTranslationID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func parallelCompanionCell(
        _ row: ReaderParallelRow,
        column: ReaderVerseColumn,
        key: String,
        showsInstantDetails: Bool
    ) -> some View {
        // The row's companions are in the order they loaded in, which a
        // change of columns reaches only once the new text is in.
        let index = column.companionID.flatMap { companionText.translationIDs.firstIndex(of: $0) }
        let verse = index.flatMap { row.companions.indices.contains($0) ? row.companions[$0] : nil }
        Group {
            if let verse {
                VStack(alignment: .leading, spacing: 0) {
                    verseLines(for: verse, column: column)
                        .padding(.leading, partialPoetryRange(for: verse) == nil ? poetryIndent(for: verse) : 0)
                        .overlay {
                            ReaderNativeContextMenuAugmenter(
                                entries: [],
                                openLink: { _ = handleReaderLink($0) },
                                participatesInLexicalHover: showsInstantDetails
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    revealedFootnoteNote(among: [verse], companionID: column.companionID)
                }
            } else if let id = column.companionID, companionText.columns[id]?.chapters[key] != nil {
                // Beneath each verse, a translation that leaves the verse out
                // simply has nothing to add; beside it, the column needs the
                // place kept.
                if !column.isBelow {
                    missingVerse(row.number, in: id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A verse one of the two translations leaves out: an empty place, so the
    /// rows after it stay level, that says what's missing.
    private func missingVerse(_ number: Int, in translationID: String?) -> some View {
        Text("—")
            .font(.system(size: fontSize * 0.8))
            .foregroundStyle(.tertiary)
            .help("Verse \(number) isn’t in the \(translationFullName(translationID))")
    }

    /// The margin beside a side-by-side row, where the reader alone draws it
    /// from the text: a bar when the row's verse is selected, and an icon for
    /// each kind of note it has. Drawn for the row, which spans the taller of
    /// the two columns and stands even where the translation being read
    /// leaves the verse out.
    @ViewBuilder
    private func parallelRowMarks(for reference: Int) -> some View {
        let font = readerFont(size: fontSize)
        let iconSize = (fontSize * 0.72).rounded()
        // Level with the first line's small letters, as the margin beside a
        // single column places them.
        let iconTop = font.ascender - font.xHeight / 2 - iconSize / 2
        ZStack(alignment: .topLeading) {
            if workspace.selectedVerseReference == reference {
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 2.5)
                    .padding(.vertical, 1)
                    .offset(x: -10)
            }
            HStack(spacing: 4) {
                if model.hasInstalledNote(for: reference) {
                    noteButton("book.closed", color: .systemPurple, size: iconSize, reference: reference,
                               help: "Study notes on verse \(LampBibleReferenceFormatter.components(of: reference).verse)")
                }
                if model.hasPersonalNote(for: reference) {
                    noteButton("note.text", color: .systemOrange, size: iconSize, reference: reference,
                               help: "Your note on verse \(LampBibleReferenceFormatter.components(of: reference).verse)")
                }
            }
            .frame(width: ReaderMargin.width - 15, alignment: .trailing)
            .offset(x: -ReaderMargin.width, y: iconTop)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func noteButton(
        _ symbol: String,
        color: NSColor,
        size: CGFloat,
        reference: Int,
        help: String
    ) -> some View {
        Button {
            openVerseStudy(reference: reference)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.82, weight: .semibold))
                .foregroundStyle(Color(nsColor: color))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func readerChapterSection(
        _ chapter: LampChapter,
        isFirst: Bool,
        showsInstantDetails: Bool,
        stacksCompanion: Bool = false
    ) -> some View {
        let headingsByVerse = Dictionary(grouping: chapter.headings, by: \.beforeVerse)
        VStack(alignment: .leading, spacing: 5) {
            Text(chapter.book.name)
                .font(.largeTitle.bold())
                .textSelection(.enabled)
            Text("Chapter \(chapter.number)")
                .font(.title2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.top, isFirst ? 0 : 52)
        .padding(.bottom, 28)
        .id(isFirst ? "chapter-top" : "chapter-\(chapter.book.id)-\(chapter.number)")

        if readerLayoutMode == .sideBySide {
            let key = ReaderCompanionText.key(book: chapter.book.id, chapter: chapter.number)
            // Rows wait the moment the companions take to load: drawn first
            // without them, every row would be laid out again when they came.
            // The columns follow the companions chosen, as the titles and the
            // passage's width do: one just added stays empty the moment its
            // text takes to load, rather than the rows keeping the old columns.
            let companionIDs = companionTranslations(beside: chapter.translationID).map(\.id)
            let isWaiting = !companionIDs.isEmpty && !companionText.asked.contains(key)
            if !isWaiting {
                parallelColumnTitles(for: chapter, stacked: stacksCompanion)
            }
            ForEach(isWaiting ? [] : parallelRows(for: chapter)) { row in
                VStack(alignment: .leading, spacing: 0) {
                    if let verse = row.main {
                        readerHeadings(headingsByVerse[verse.number] ?? [])
                    }
                    parallelRow(
                        row,
                        companionIDs: companionIDs,
                        key: key,
                        stacked: stacksCompanion,
                        showsInstantDetails: showsInstantDetails
                    )
                }
                .id(row.reference)
            }
        } else if readerLayoutMode == .versePerLine {
            ForEach(chapter.verses) { verse in
                // Heading and verse share one identity so the scroll link reports
                // whole verses; loose heading ids would look like verse references.
                VStack(alignment: .leading, spacing: 0) {
                    readerHeadings(headingsByVerse[verse.number] ?? [])
                    verseRow(verse, showsInstantDetails: showsInstantDetails)
                }
                .id(verse.id)
            }
        } else {
            ForEach(continuousParagraphs(in: chapter)) { paragraph in
                VStack(alignment: .leading, spacing: 0) {
                    readerHeadings(headingsByVerse[paragraph.firstVerse.number] ?? [])
                    continuousParagraph(
                        paragraph,
                        showsInstantDetails: showsInstantDetails
                    )
                }
                .id(paragraph.id)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(readerScrollCoordinateSpace))
                } action: { frame in
                    paragraphAnchors.record(frame, for: paragraph.id)
                }
                .onDisappear { paragraphAnchors.forget(paragraph.id) }
            }
        }
    }

    @ViewBuilder
    private func readerHeadings(_ headings: [LampHeading]) -> some View {
        ForEach(headings) { heading in
            Text(heading.text)
                .font(heading.level == 1 ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .textSelection(.enabled)
                .padding(.top, heading.level == 1 ? 26 : 18)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func continuousParagraph(
        _ paragraph: ReaderParagraph,
        showsInstantDetails: Bool
    ) -> some View {
        continuousParagraphText(paragraph)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, continuousTopPadding(for: paragraph.firstVerse))
            .padding(.leading, paragraphIndent(for: paragraph))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                ReaderNativeContextMenuAugmenter(
                    entries: paragraphContextMenuEntries(paragraph),
                    openLink: { _ = handleReaderLink($0) },
                    participatesInLexicalHover: showsInstantDetails
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    @ViewBuilder
    private func continuousParagraphText(_ paragraph: ReaderParagraph) -> some View {
        if paragraph.verses.count == 1, let verse = paragraph.verses.first {
            renderedVerseText(for: verse)
        } else {
            let run = continuousText(for: paragraph.verses)
            VStack(alignment: .leading, spacing: 0) {
                ReaderSelectableText(
                    attributedText: run.text,
                    marks: run.marks,
                    indent: paragraphIndent(for: paragraph),
                    openLink: { _ = handleReaderLink($0) },
                    openNote: { openVerseStudy(reference: $0) }
                )
                revealedFootnoteNote(among: paragraph.verses)
            }
        }
    }

    /// The opened note, shown under the text that marks it.
    ///
    /// Under the verse rather than in a panel elsewhere: a translator's note
    /// says what a word of this verse could also have been, and reading it
    /// anywhere but beside that word means carrying the sentence there.
    @ViewBuilder
    private func revealedFootnoteNote(among verses: [LampVerse], companionID: String? = nil) -> some View {
        if let key = revealedFootnote,
           key.companionID == companionID,
           verses.contains(where: { $0.id == key.verse }),
           let data = footnoteData(for: key.verse, companionID: companionID),
           case let marks = footnoteMarks(for: key.verse, companionID: companionID),
           marks.indices.contains(key.index),
           let note = data.footnotes.first(where: { $0.id == marks[key.index].footnoteID }) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(footnoteLabel(key.index))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .lampLink))
                Text(note.content)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Close Note", systemImage: "xmark") {
                    revealedFootnote = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .padding(.top, 6)
            .padding(.horizontal, 8)
        }
    }

    private func paragraphIndent(for paragraph: ReaderParagraph) -> CGFloat {
        guard partialPoetryRange(for: paragraph.firstVerse) == nil else { return 0 }
        return poetryIndent(for: paragraph.firstVerse)
    }

    private func continuousParagraphs(in chapter: LampChapter) -> [ReaderParagraph] {
        // Memoised. This is called from the reader's body, which re-evaluates on
        // every frame change — including each frame of the study column opening.
        paragraphAnchors.paragraphs(in: chapter)
    }

    /// Verses run together as one paragraph, with what the margin beside
    /// them marks.
    private func continuousText(
        for verses: [LampVerse],
        column: ReaderVerseColumn = .reading
    ) -> (text: NSAttributedString, marks: ReaderMarginMarks) {
        let result = NSMutableAttributedString(string: "")
        var marks = ReaderMarginMarks()
        for (index, verse) in verses.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " ", attributes: bodyTextAttributes()))
            }
            let start = result.length
            result.append(verseMarkerText(for: verse))
            result.append(verseBodyText(for: verse, column: column))
            if column == .reading {
                mark(verse, from: start, to: result.length, in: &marks)
            }
        }
        return (result, marks)
    }

    /// The marks beside one piece of a verse drawn on its own. Its notes are
    /// marked only beside the piece that holds its number.
    private func marks(
        for verse: LampVerse,
        drawnAs text: NSAttributedString,
        noting: Bool = true,
        column: ReaderVerseColumn
    ) -> ReaderMarginMarks {
        guard column == .reading else { return .none }
        var marks = ReaderMarginMarks()
        mark(verse, from: 0, to: text.length, noting: noting, in: &marks)
        return marks
    }

    /// Adds a verse's marks for the characters it was drawn as, from its
    /// number to its last character.
    private func mark(
        _ verse: LampVerse,
        from start: Int,
        to end: Int,
        noting: Bool = true,
        in marks: inout ReaderMarginMarks
    ) {
        if workspace.selectedVerseReference == verse.id {
            marks.selectedRange = NSRange(location: start, length: end - start)
        }
        guard noting else { return }
        var kinds: ReaderMarginMarks.NoteKinds = []
        if model.hasPersonalNote(for: verse.id) { kinds.insert(.personal) }
        if model.hasInstalledNote(for: verse.id) { kinds.insert(.module) }
        if !kinds.isEmpty {
            marks.notes.append(.init(location: start, reference: verse.id, kinds: kinds))
        }
    }

    private func verseMarkerText(for verse: LampVerse) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let verseURL = readerVerseURL(reference: verse.id)
        let isSelected = workspace.selectedVerseReference == verse.id

        // The selected verse is marked by a bar in the margin; its number only
        // darkens, to show where in a shared line the verse begins. Nothing
        // inside scripture takes the accent, where a red numeral next to
        // red-letter text reads as part of the words of Christ. A verse's notes
        // are marked in the margin too.
        var numberAttributes = markerTextAttributes(
            size: max(fontSize * 0.58, 10),
            weight: .semibold,
            color: isSelected ? .labelColor : .secondaryLabelColor,
            baselineOffset: max(fontSize * 0.28, 4)
        )
        numberAttributes[.link] = verseURL
        result.append(NSAttributedString(
            string: verse.number.formatted(),
            attributes: numberAttributes
        ))

        result.append(NSAttributedString(string: " ", attributes: bodyTextAttributes()))
        return result
    }

    @ViewBuilder
    private func renderedVerseText(for verse: LampVerse, column: ReaderVerseColumn = .reading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            verseLines(for: verse, column: column)
            revealedFootnoteNote(among: [verse])
        }
    }

    @ViewBuilder
    private func verseLines(for verse: LampVerse, column: ReaderVerseColumn = .reading) -> some View {
        let showsMargin = column == .reading
        if let poetryRange = partialPoetryRange(for: verse) {
            let opening = labelled(set(verseText(
                for: verse,
                range: ReaderTextRange(startOffset: 0, endOffset: poetryRange.startOffset),
                includesMarker: true,
                column: column
            ), for: column), for: column)
            let poetry = set(verseBodyText(for: verse, range: poetryRange, column: column), for: column)
            VStack(alignment: .leading, spacing: 4) {
                ReaderSelectableText(
                    attributedText: opening,
                    marks: marks(for: verse, drawnAs: opening, column: column),
                    showsMargin: showsMargin,
                    openLink: { _ = handleReaderLink($0) },
                    openNote: { openVerseStudy(reference: $0) }
                )

                ReaderSelectableText(
                    attributedText: poetry,
                    marks: marks(for: verse, drawnAs: poetry, noting: false, column: column),
                    indent: poetryIndent(for: verse),
                    showsMargin: showsMargin,
                    openLink: { _ = handleReaderLink($0) }
                )
                    .padding(.leading, poetryIndent(for: verse))

                if poetryRange.endOffset < verse.text.count {
                    let closing = set(verseBodyText(
                        for: verse,
                        range: ReaderTextRange(
                            startOffset: poetryRange.endOffset,
                            endOffset: verse.text.count
                        ),
                        column: column
                    ), for: column)
                    ReaderSelectableText(
                        attributedText: closing,
                        marks: marks(for: verse, drawnAs: closing, noting: false, column: column),
                        showsMargin: showsMargin,
                        openLink: { _ = handleReaderLink($0) }
                    )
                }
            }
        } else {
            let run = continuousText(for: [verse], column: column)
            ReaderSelectableText(
                attributedText: labelled(set(run.text, for: column), for: column),
                marks: run.marks,
                // Set in by the row, cell or paragraph around it.
                indent: poetryIndent(for: verse),
                showsMargin: showsMargin,
                openLink: { _ = handleReaderLink($0) },
                openNote: { openVerseStudy(reference: $0) }
            )
        }
    }

    /// The companion beneath each verse is set smaller and quieter than the
    /// verse it follows, so the two tell apart without a label on every verse.
    /// Red letters keep their colour, and translator's notes their link blue.
    private func set(_ text: NSAttributedString, for column: ReaderVerseColumn) -> NSAttributedString {
        guard column.isBelow else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont,
                  let smaller = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.88)
            else { return }
            result.addAttribute(.font, value: smaller, range: range)
        }
        result.enumerateAttribute(.baselineOffset, in: whole) { value, range, _ in
            guard let offset = value as? CGFloat else { return }
            result.addAttribute(.baselineOffset, value: offset * 0.88, range: range)
        }
        result.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let color = value as? NSColor, color == .labelColor else { return }
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        return result
    }

    /// A companion's verse beneath another's, named where several are: its
    /// translation's short name, before its verse number.
    private func labelled(_ text: NSAttributedString, for column: ReaderVerseColumn) -> NSAttributedString {
        guard column.isBelow, companionText.translationIDs.count > 1 else { return text }
        var attributes = markerTextAttributes(
            size: max(fontSize * 0.5, 9),
            weight: .semibold,
            color: .tertiaryLabelColor,
            baselineOffset: 0
        )
        attributes[.kern] = 0.4
        let result = NSMutableAttributedString(
            string: translationName(column.companionID) + "  ",
            attributes: attributes
        )
        result.append(text)
        return result
    }

    private func verseText(
        for verse: LampVerse,
        range: ReaderTextRange? = nil,
        includesMarker: Bool,
        column: ReaderVerseColumn = .reading
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        if includesMarker {
            result.append(verseMarkerText(for: verse))
        }
        result.append(verseBodyText(for: verse, range: range, column: column))
        return result
    }

    private func verseBodyText(
        for verse: LampVerse,
        range: ReaderTextRange? = nil,
        column: ReaderVerseColumn = .reading
    ) -> NSAttributedString {
        let text = styledText(for: verse, column: column)
        let characterIndices = Array(verse.text.indices) + [verse.text.endIndex]

        guard let range else {
            return markingFootnotes(
                in: text, of: verse,
                from: 0, to: verse.text.count,
                companionID: column.companionID
            )
        }

        guard range.startOffset >= 0,
              range.endOffset > range.startOffset,
              range.endOffset < characterIndices.count,
              range.startOffset < characterIndices.count else {
            return NSAttributedString(string: "", attributes: bodyTextAttributes())
        }
        let nativeRange = NSRange(
            characterIndices[range.startOffset]..<characterIndices[range.endOffset],
            in: verse.text
        )
        return markingFootnotes(
            in: text.attributedSubstring(from: nativeRange), of: verse,
            from: range.startOffset, to: range.endOffset,
            companionID: column.companionID
        )
    }

    /// Puts a letter in the text where each translator's note belongs.
    ///
    /// Done to the drawn text rather than inside `styledText`, and after any
    /// range has been taken from it: every offset the verse carries — its
    /// highlights, its red letter, the poetry split — counts the characters the
    /// translation wrote, and a marker put among them earlier would move the
    /// ones after it. Inserted from the back for the same reason.
    private func markingFootnotes(
        in body: NSAttributedString,
        of verse: LampVerse,
        from startOffset: Int,
        to endOffset: Int,
        companionID: String? = nil
    ) -> NSAttributedString {
        let marks = footnoteMarks(for: verse.id, companionID: companionID)
        guard !marks.isEmpty else { return body }

        let insertions = LampReaderFootnoteMarks.insertions(
            in: verse.text,
            from: startOffset,
            to: endOffset,
            markedAt: marks.map(\.offset)
        )
        guard !insertions.isEmpty else { return body }

        let result = NSMutableAttributedString(attributedString: body)
        for insertion in insertions {
            var attributes = markerTextAttributes(
                size: max(fontSize * 0.55, 10),
                weight: .semibold,
                // It opens the note, so it reads as a link.
                color: .lampLink,
                baselineOffset: max(fontSize * 0.32, 5)
            )
            attributes[.link] = readerFootnoteURL(verse: verse.id, index: insertion.index, companionID: companionID)
            guard insertion.location <= result.length else { continue }
            result.insert(
                NSAttributedString(
                    string: footnoteLabel(insertion.index), attributes: attributes
                ),
                at: insertion.location
            )
        }
        return result
    }

    private func partialPoetryRange(for verse: LampVerse) -> ReaderTextRange? {
        ReaderPoetryLayout.partialRange(in: verse.text, isPoetry: verse.poetry != nil)
    }

    private func continuousTopPadding(for verse: LampVerse) -> CGFloat {
        if verse.poetry?.stanzaBreak == true { return 18 }
        return verse.number == 1 ? 5 : 13
    }

    private func completeActivePlanReading() {
        guard let mode = planReadingMode, let reading = mode.activeReading else { return }
        model.setReadingCompleted(
            planID: mode.planID,
            day: mode.day,
            readingIndex: reading.id,
            year: mode.year,
            completed: true
        )
    }

    private func readerReachedBottom(_ geometry: ScrollGeometry) -> Bool {
        let scrollableHeight = geometry.contentSize.height
            + geometry.contentInsets.top
            + geometry.contentInsets.bottom
            - geometry.containerSize.height
        guard scrollableHeight > 1 else { return false }
        return ReaderScrollTail.hasReachedContentBottom(
            visibleMaxY: geometry.visibleRect.maxY,
            totalContentHeight: geometry.contentSize.height,
            viewportHeight: geometry.containerSize.height
        )
    }

    @ViewBuilder
    private func verseRow(_ verse: LampVerse, showsInstantDetails: Bool) -> some View {
        renderedVerseText(for: verse)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, topPadding(for: verse))
            .padding(.leading, partialPoetryRange(for: verse) == nil ? poetryIndent(for: verse) : 0)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(verseStudyHelp(verse))
            .overlay {
                ReaderNativeContextMenuAugmenter(
                    entries: verseContextMenuEntries(verse),
                    openLink: { _ = handleReaderLink($0) },
                    participatesInLexicalHover: showsInstantDetails
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private func paragraphContextMenuEntries(_ paragraph: ReaderParagraph) -> [ReaderContextMenuEntry] {
        var entries = copyContextMenuEntries(for: paragraph.verses)
        entries.append(.separator)
        if paragraph.verses.count == 1, let verse = paragraph.verses.first {
            entries += highlightContextMenuEntries(for: verse)
        } else {
            entries.append(.submenu(
                "Highlight Verse",
                systemImage: "highlighter",
                entries: paragraph.verses.map { verse in
                    .submenu(
                        "Verse \(verse.number)",
                        entries: highlightColorEntries(for: verse, includesRemoval: true)
                    )
                }
            ))
        }
        return entries
    }

    private func verseContextMenuEntries(_ verse: LampVerse) -> [ReaderContextMenuEntry] {
        var entries = copyContextMenuEntries(for: [verse])
        entries.append(.separator)
        entries += highlightContextMenuEntries(for: verse)
        entries.append(.separator)
        entries.append(.action(
            model.hasPersonalNote(for: verse.id) ? "Edit Note" : "Add Note",
            systemImage: "square.and.pencil"
        ) {
            prepareChapterForStudy(reference: verse.id)
            selectVerseFromReader(verse.id)
            selectedStudyTab = "notes"
            showingStudyInspector = true
        })
        entries.append(.action("Show Study Tools", systemImage: "sidebar.trailing") {
            prepareChapterForStudy(reference: verse.id)
            selectVerseFromReader(verse.id)
            showingStudyInspector = true
        })
        return entries
    }

    private func copyContextMenuEntries(for verses: [LampVerse]) -> [ReaderContextMenuEntry] {
        [
            .action("Copy as Citation", systemImage: "quote.opening") {
                copyAsCitation(verses)
            },
        ]
    }

    private func highlightContextMenuEntries(for verse: LampVerse) -> [ReaderContextMenuEntry] {
        [
            .action("Highlight Words…", systemImage: "selection.pin.in.out") {
                highlightVerse = verse
            },
            .submenu(
                "Highlight Verse",
                systemImage: "highlighter",
                entries: highlightColorEntries(for: verse, includesRemoval: false)
            ),
        ] + (model.personalHighlights(for: verse.id).isEmpty ? [] : [
            .action("Remove Highlight", systemImage: "eraser") {
                setHighlight(nil, for: verse)
            },
        ])
    }

    private func highlightColorEntries(
        for verse: LampVerse,
        includesRemoval: Bool
    ) -> [ReaderContextMenuEntry] {
        var entries = StudyHighlightPalette.colors.map { item in
            ReaderContextMenuEntry.action(item.name) {
                setHighlight(item.hex, for: verse)
            }
        }
        if includesRemoval, !model.personalHighlights(for: verse.id).isEmpty {
            entries.append(.separator)
            entries.append(.action("Remove Highlight", systemImage: "eraser") {
                setHighlight(nil, for: verse)
            })
        }
        return entries
    }

    private func copyAsCitation(_ fallbackVerses: [LampVerse]) {
        guard let firstReference = fallbackVerses.first?.id,
              let chapter = displayedChapters.first(where: { chapter in
                  chapter.verses.contains(where: { $0.id == firstReference })
              }) ?? workspace.chapter else { return }
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let copiedSelection = NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            && pasteboard.changeCount != originalChangeCount
            ? pasteboard.string(forType: .string)
            : nil
        let citationVerses = fallbackVerses.map { verse in
            ReaderCitationVerse(
                number: verse.number,
                text: verse.text,
                displayPrefix: verseDisplayPrefix(for: verse)
            )
        }
        let translation = model.translations.first { $0.id == chapter.translationID }
        let translationName = translation?.abbreviation ?? translation?.name ?? chapter.translationID
        guard let citation = ReaderCitationFormatter.citation(
            bookName: chapter.book.name,
            chapterNumber: chapter.number,
            verses: citationVerses,
            translationName: translationName,
            selectedDisplayText: copiedSelection
        ) else { return }

        pasteboard.clearContents()
        pasteboard.setString(citation, forType: .string)
    }

    private func verseDisplayPrefix(for verse: LampVerse) -> String {
        var prefix = String(verse.number)
        if verse.hasFootnotes { prefix += "*" }
        if model.hasPersonalNote(for: verse.id) { prefix += "✎" }
        if model.hasInstalledNote(for: verse.id) { prefix += "▣" }
        return prefix
    }

    private func verseStudyHelp(_ verse: LampVerse) -> String {
        var details: [String] = []
        if verse.hasFootnotes { details.append("translation note available") }
        if model.hasPersonalNote(for: verse.id) { details.append("personal note available") }
        if model.hasInstalledNote(for: verse.id) { details.append("study note available") }
        guard !details.isEmpty else { return "Show study tools for verse \(verse.number)" }
        return "Show study tools for verse \(verse.number) — \(details.joined(separator: ", "))"
    }

    private func openVerseStudy(_ verse: LampVerse) {
        prepareChapterForStudy(reference: verse.id)
        selectVerseFromReader(verse.id)
        if model.hasPersonalNote(for: verse.id) || model.hasInstalledNote(for: verse.id) {
            selectedStudyTab = "notes"
        } else if verse.hasFootnotes || verse.annotations.contains(where: { $0.strongs != nil }) {
            selectedStudyTab = "verse"
        }
        showingStudyInspector = true
    }

    private func openVerseStudy(reference: Int) {
        guard let verse = displayedChapters.lazy
            .flatMap(\.verses)
            .first(where: { $0.id == reference }) else {
            // A verse not on screen in the translation being read, such as
            // one only the companion beside it has. Its notes are the verse's,
            // whichever translation holds it.
            prepareChapterForStudy(reference: reference)
            workspace.focusVerse(reference)
            selectedStudyTab = model.hasPersonalNote(for: reference) || model.hasInstalledNote(for: reference)
                ? "notes"
                : "verse"
            showingStudyInspector = true
            return
        }
        openVerseStudy(verse)
    }

    /// What the notes on screen were fetched for. A translation's notes are
    /// its own, so a change of translation is a change of notes.
    private func footnoteLoadKey(for chapters: [LampChapter]) -> String {
        let passage = chapters
            .map { "\($0.book.id).\($0.number)" }
            .joined(separator: ",")
        return "\(workspace.selectedTranslationID ?? "-"):\(passage)"
    }

    /// Reads the translator's notes for the verses that advertise having any.
    ///
    /// After the passage is on screen rather than before it: the text is what
    /// the reader came for, and a chapter of Genesis asks the library once per
    /// footnoted verse. The markers appear as the answers arrive.
    private func loadFootnotes(for chapters: [LampChapter]) async {
        guard let translationID = workspace.selectedTranslationID else {
            chapterFootnotes = [:]
            return
        }
        let references = chapters.flatMap(\.verses).filter(\.hasFootnotes).map(\.id)
        guard !references.isEmpty else {
            chapterFootnotes = [:]
            return
        }
        var loaded: [Int: LampVerseStudyData] = [:]
        for reference in references {
            if Task.isCancelled { return }
            guard let data = try? await model.library.verseStudyData(
                moduleID: translationID,
                reference: reference
            ) else { continue }
            guard !data.footnotes.isEmpty, !data.footnoteReferences.isEmpty else { continue }
            loaded[reference] = data
        }
        guard !Task.isCancelled else { return }
        chapterFootnotes = loaded
        revealedFootnote = nil
    }

    /// A verse's notes in the order they are marked in its text.
    /// A verse's translator's notes, the reading's or a companion's.
    private func footnoteData(for verse: Int, companionID: String?) -> LampVerseStudyData? {
        guard let companionID else { return chapterFootnotes[verse] }
        return companionText.columns[companionID]?.footnotes[verse]
    }

    private func footnoteMarks(for verse: Int, companionID: String? = nil) -> [LampVerseFootnoteReference] {
        (footnoteData(for: verse, companionID: companionID)?.footnoteReferences ?? [])
            .sorted { $0.offset < $1.offset }
    }

    /// a, b, c — the letters a translation marks its notes with, rather than
    /// numbers, which would read as verse numbers in the middle of a verse.
    private func footnoteLabel(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String(letters[index % letters.count])
    }

    /// A translator's note's link, naming the companion it belongs to.
    private func readerFootnoteURL(verse: Int, index: Int, companionID: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "lamp-bible-footnote"
        components.host = String(verse)
        components.path = "/\(index)"
        if let companionID {
            components.queryItems = [URLQueryItem(name: "in", value: companionID)]
        }
        return components.url
    }

    private func readerFootnoteKey(from url: URL) -> ReaderFootnoteKey? {
        guard url.scheme == "lamp-bible-footnote",
              let host = url.host, let verse = Int(host),
              let index = Int(url.lastPathComponent)
        else { return nil }
        let companionID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "in" }?.value
        return ReaderFootnoteKey(verse: verse, index: index, companionID: companionID)
    }

    private func prepareChapterForStudy(reference: Int) {
        guard workspace.chapter?.verses.contains(where: { $0.id == reference }) != true else { return }
        workspace.openReference(reference)
    }

    private func readerVerseURL(reference: Int) -> URL? {
        URL(string: "lamp-bible-verse://\(reference)")
    }

    private func readerVerseReference(from url: URL) -> Int? {
        guard url.scheme == "lamp-bible-verse", let host = url.host else { return nil }
        return Int(host)
    }

    private func styledText(for verse: LampVerse, column: ReaderVerseColumn = .reading) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: verse.text,
            attributes: bodyTextAttributes()
        )

        // `index(startIndex, offsetBy:)` walks the string from the front every
        // time it is asked, and a densely tagged verse asks once per annotation
        // per pass. One walk up front turns each of those into a subscript.
        let characterIndices = Array(verse.text.indices) + [verse.text.endIndex]

        func attributedRange(from startOffset: Int, to endOffset: Int) -> NSRange? {
            guard startOffset >= 0,
                  endOffset > startOffset,
                  endOffset < characterIndices.count,
                  startOffset < characterIndices.count else {
                return nil
            }
            return NSRange(
                characterIndices[startOffset]..<characterIndices[endOffset],
                in: verse.text
            )
        }

        for annotation in verse.annotations {
            guard let range = attributedRange(
                from: annotation.startOffset,
                to: annotation.endOffset
            ) else { continue }

            switch annotation.kind {
            case "red-letter":
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor.lampWordsOfChrist,
                    range: range
                )
            case "added", "selah":
                result.addAttribute(
                    .font,
                    value: readerFont(size: fontSize, traits: .italicFontMask),
                    range: range
                )
            case "divine-name":
                result.addAttribute(
                    .font,
                    value: readerFont(size: fontSize, weight: .semibold),
                    range: range
                )
            case "variant":
                result.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            default:
                break
            }
        }

        let lexicalAnnotations = verse.annotations.filter { annotation in
            annotation.strongs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let groupedLexicalAnnotations = Dictionary(grouping: lexicalAnnotations) { annotation in
            VerseAnnotationRange(start: annotation.startOffset, end: annotation.endOffset)
        }
        for (annotationRange, annotations) in groupedLexicalAnnotations {
            let keys = StrongsKey.readerLookupKeys(annotations.compactMap(\.strongs))
            guard annotationRange.start >= 0,
                  annotationRange.end > annotationRange.start,
                  annotationRange.end < characterIndices.count,
                  !keys.isEmpty else { continue }
            let word = String(
                verse.text[characterIndices[annotationRange.start]..<characterIndices[annotationRange.end]]
            )
            guard let lookup = LexiconLookupLink(keys: keys, reference: verse.id, word: word),
                  let route = lookup.url?.absoluteString,
                  let range = attributedRange(
                      from: annotationRange.start,
                      to: annotationRange.end
                  ) else { continue }
            // Lexicon mappings are Lamp-owned hit-test metadata, not native
            // links. A normal `.link` leaks the routing URL in hover UI and
            // changes AppKit's right-click selection behavior.
            result.addAttribute(.languageIdentifier, value: route, range: range)
            let overlapsRedLetter = verse.annotations.contains { annotation in
                annotation.kind == "red-letter"
                    && annotation.startOffset < annotationRange.end
                    && annotation.endOffset > annotationRange.start
            }
            if !overlapsRedLetter {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }

        // Each column its own translation's: offsets made in one translation
        // would colour the wrong words of another.
        let highlights = column.companionID.map { companionText.columns[$0]?.highlights[verse.id] ?? [] }
            ?? model.highlights(for: verse.id)
        for highlight in highlights {
            let startOffset = min(max(highlight.startOffset, 0), verse.text.count)
            let endOffset = min(max(highlight.endOffset, startOffset), verse.text.count)
            guard let range = attributedRange(from: startOffset, to: endOffset) else { continue }
            let color = readerColor(hex: highlight.color ?? "FFCC00") ?? .systemYellow
            switch highlight.style {
            case .highlight:
                result.addAttribute(
                    .backgroundColor,
                    value: color.withAlphaComponent(0.34),
                    range: range
                )
            case .underlineSolid:
                result.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: color,
                ], range: range)
            case .underlineDashed:
                result.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single
                        .union(.patternDash).rawValue,
                    .underlineColor: color,
                ], range: range)
            case .underlineDotted:
                result.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single
                        .union(.patternDot).rawValue,
                    .underlineColor: color,
                ], range: range)
            }
        }

        return result
    }

    private func bodyTextAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        return [
            .font: readerFont(size: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func markerTextAttributes(
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        baselineOffset: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var result = bodyTextAttributes()
        result[.font] = readerFont(size: size, weight: weight)
        result[.foregroundColor] = color
        result[.baselineOffset] = baselineOffset
        return result
    }

    private func readerFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        traits: NSFontTraitMask = []
    ) -> NSFont {
        let key = ReaderFonts.Key(size: size, weight: weight.rawValue, traits: traits.rawValue, serif: typeface == .serif)
        if let font = ReaderFonts.made[key] { return font }
        let systemFont = NSFont.systemFont(ofSize: size, weight: weight)
        let designedFont: NSFont
        if typeface == .serif,
           let descriptor = systemFont.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            designedFont = font
        } else {
            designedFont = systemFont
        }
        let font = traits.isEmpty ? designedFont : NSFontManager.shared.convert(designedFont, toHaveTrait: traits)
        ReaderFonts.made[key] = font
        return font
    }

    private func readerColor(hex value: String) -> NSColor? {
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 6 || normalized.count == 8,
              let raw = UInt64(normalized, radix: 16) else { return nil }
        let includesAlpha = normalized.count == 8
        let red = CGFloat((raw >> (includesAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((raw >> (includesAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((raw >> (includesAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = includesAlpha ? CGFloat(raw & 0xFF) / 255 : 1
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Selects a verse the user clicked in the reader.
    ///
    /// Distinct from `workspace.focusVerse` on purpose: a selection made *here* must
    /// not scroll the reader to the verse, because the verse is already on screen
    /// under the pointer. Selections from elsewhere — search, history, read-aloud,
    /// a cross-reference — still scroll, because there the verse may be anywhere.
    private func selectVerseFromReader(_ reference: Int) {
        // Armed only for a change, which is what clears it: choosing the verse
        // already chosen changes nothing, and a flag left armed would swallow
        // the scroll of the next verse chosen from elsewhere in the chapter.
        isSelectingVerseFromReader = reference != workspace.selectedVerseReference
        workspace.focusVerse(reference)
    }

    private func openLexicon(_ lookup: LexiconLookupLink) {
        selectVerseFromReader(lookup.reference)
        // Queue the lookup before mounting the inspector. Its first rendered
        // instance can then adopt this exact request immediately on appearance.
        model.requestDictionaryLookup(keys: lookup.keys, word: lookup.word)
        selectedStudyTab = "dictionary"
        showingStudyInspector = true
    }

    private func handleReaderLink(_ url: URL) -> Bool {
        let isReaderLink = readerVerseReference(from: url) != nil
            || readerFootnoteKey(from: url) != nil
            || LexiconLookupLink(url: url) != nil
        guard isReaderLink else { return false }
        guard linkActivationGate.shouldActivate(url, at: ProcessInfo.processInfo.systemUptime) else {
            return true
        }

        if let footnote = readerFootnoteKey(from: url) {
            // A second click on the same marker puts the note away again.
            revealedFootnote = revealedFootnote == footnote ? nil : footnote
        } else if let reference = readerVerseReference(from: url) {
            openVerseStudy(reference: reference)
        } else if let lookup = LexiconLookupLink(url: url) {
            openLexicon(lookup)
        }
        return true
    }

    private func setHighlight(_ color: String?, for verse: LampVerse) {
        Task {
            do {
                try await model.setWholeVerseHighlight(
                    reference: verse.id,
                    textLength: verse.text.count,
                    color: color
                )
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func topPadding(for verse: LampVerse) -> CGFloat {
        if verse.poetry?.stanzaBreak == true { return 22 }
        if verse.beginsParagraph && verse.number != 1 { return 16 }
        return 5
    }

    private func poetryIndent(for verse: LampVerse) -> CGFloat {
        CGFloat(max(verse.poetry?.indent ?? 0, 0)) * 22
    }

    private func scrollTarget(for reference: Int, in chapters: [LampChapter]) -> AnyHashable {
        guard readerLayoutMode == .continuousParagraphs else { return AnyHashable(reference) }
        let paragraph = chapters.lazy
            .flatMap { continuousParagraphs(in: $0) }
            .first { paragraph in
                paragraph.verses.contains(where: { $0.id == reference })
            }
        return AnyHashable(paragraph?.id ?? reference)
    }

    private func scrollToReaderLocation(_ proxy: ScrollViewProxy, chapters: [LampChapter]) {
        guard let reference = workspace.selectedVerseReference else { return }
        // Plan readings deliberately start with the passage header visible. The
        // fresh scroll container already has the correct natural top position.
        guard planReadingMode?.activeReading?.startReference != reference else { return }
        let target = scrollTarget(for: reference, in: chapters)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ControlGroup {
                Button {
                    navigateBookBackward()
                } label: {
                    Image(systemName: "chevron.left.2")
                }
                .disabled(!canNavigateBookBackward || workspace.isLoadingChapter || isLoadingPlanReading)
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .help("Previous Book")
                .accessibilityLabel("Previous Book")

                Button {
                    navigateReaderBackward()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canNavigateReaderBackward || workspace.isLoadingChapter || isLoadingPlanReading)
                .keyboardShortcut("[", modifiers: .command)
                .help(backwardNavigationTitle)
                .accessibilityLabel(backwardNavigationTitle)

                Button {
                    showingReaderLocationPicker.toggle()
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
                .popover(isPresented: $showingReaderLocationPicker, arrowEdge: .bottom) {
                    PassagePickerPopover(
                        isPresented: $showingReaderLocationPicker,
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
                .disabled(!canNavigateReaderForward || workspace.isLoadingChapter || isLoadingPlanReading)
                .keyboardShortcut("]", modifiers: .command)
                .help(forwardNavigationTitle)
                .accessibilityLabel(forwardNavigationTitle)

                Button {
                    navigateBookForward()
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .disabled(!canNavigateBookForward || workspace.isLoadingChapter || isLoadingPlanReading)
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .help("Next Book")
                .accessibilityLabel("Next Book")
            }
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

            Button {
                toggleReadAloud()
            } label: {
                Label(readAloudButtonTitle, systemImage: readAloudButtonImage)
            }
            .disabled(readAloudVerses.isEmpty)
            .help(readAloudButtonTitle)

            Menu("Read Aloud Options", systemImage: "speaker.wave.2") {
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
                if readAloud.state == .playing {
                    Button("Pause", systemImage: "pause") { readAloud.pause() }
                } else if readAloud.state == .paused {
                    Button("Resume", systemImage: "play") { readAloud.resume() }
                }
                Button("Stop", systemImage: "stop") { readAloud.stop() }
                    .disabled(readAloud.state == .stopped)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingReaderChat.toggle()
            } label: {
                Label("Reader Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .help(showingReaderChat ? "Hide Reader Chat" : "Show Reader Chat")
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button {
                showingStudyInspector.toggle()
            } label: {
                Label("Study Tools", systemImage: "sidebar.trailing")
            }
            .help(showingStudyInspector ? "Hide Study Tools" : "Show Study Tools")
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }

    private var readerLocationTitle: String {
        let translation = model.selectedTranslation?.abbreviation ?? "Translation"
        if let reading = planReadingMode?.activeReading {
            return "\(translation) \u{00B7} \(reading.displayDescription)"
        }
        let book = workspace.selectedBook?.name ?? "Book"
        return "\(translation) \u{00B7} \(book) \(workspace.selectedChapterNumber)"
    }

    private func historyLabel(_ location: ReaderLocation) -> String {
        let book = LampBibleReferenceFormatter.bookName(location.bookNumber)
        let translation = model.translations.first { $0.id == location.translationID }
        let name = translation?.abbreviation ?? translation?.name ?? location.translationID
        return "\(book) \(location.chapterNumber) (\(name))"
    }

    private var readAloudButtonTitle: String {
        switch readAloud.state {
        case .stopped: "Read Aloud"
        case .playing: "Pause Read Aloud"
        case .paused: "Resume Read Aloud"
        }
    }

    private var readAloudButtonImage: String {
        switch readAloud.state {
        case .stopped: "play.fill"
        case .playing: "pause.fill"
        case .paused: "play.fill"
        }
    }

    private func toggleReadAloud() {
        let verses = readAloudVerses
        guard !verses.isEmpty else { return }
        readAloud.toggle(
            items: verses.map {
                ReadAloudItem(reference: $0.id, verseNumber: $0.number, text: $0.text)
            },
            startingAt: workspace.selectedVerseReference,
            voiceIdentifier: readAloudVoice,
            rate: readAloudRate
        )
    }

    private func startReadAloud(at reference: Int?) {
        let verses = readAloudVerses
        guard !verses.isEmpty else { return }
        readAloud.play(
            items: verses.map {
                ReadAloudItem(reference: $0.id, verseNumber: $0.number, text: $0.text)
            },
            startingAt: reference,
            voiceIdentifier: readAloudVoice,
            rate: readAloudRate
        )
    }

    private var readAloudVerses: [LampVerse] {
        displayedChapters.flatMap(\.verses)
    }
}

private struct VerseAnnotationRange: Hashable {
    let start: Int
    let end: Int
}


private struct InstalledModulesView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var moduleToRemove: LampInstalledModule?
    @State private var exportRequest: ModuleExportRequest?
    let showImporter: () -> Void

    private var exportChoices: [ModuleExportChoice] {
        LampPersonalModule.allCases.map(ModuleExportChoice.personal)
            + model.modules.filter { !$0.isBundled }.map(ModuleExportChoice.installed)
    }

    var body: some View {
        List {
            personalModuleSection
            moduleSection("Translations", modules: model.modules.filter { $0.kind == .translation })
            moduleSection("Dictionaries", modules: model.modules.filter { $0.kind == .dictionary })
            moduleSection("Commentaries", modules: model.modules.filter { $0.kind == .commentary })
            moduleSection("Books", modules: model.modules.filter { $0.kind == .book })
            moduleSection("Reading Plans", modules: model.planModules)
            moduleSection("Writing", modules: model.devotionalModules)
            moduleSection("Quizzes", modules: model.quizModuleInstallations)
            moduleSection("Notes", modules: model.noteModules)
            moduleSection("Highlights", modules: model.highlightModules)
        }
        .navigationTitle("Modules")
        .toolbar {
            ToolbarItemGroup {
                Button("Install Module…", systemImage: "plus", action: showImporter)
                    .help("Install a Lamp module")
                Button("Export Module…", systemImage: "square.and.arrow.up") {
                    exportRequest = ModuleExportRequest(initialChoiceID: nil)
                }
                .help("Export a personal or user-installed module")
                Button("Show Library in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(model.library.rootURL)
                }
                .help("Show the Lamp Bible library in Finder")
            }
        }
        .sheet(item: $exportRequest) { request in
            ModuleExportWizard(
                choices: exportChoices,
                initialChoiceID: request.initialChoiceID
            )
            .environmentObject(model)
        }
        .confirmationDialog(
            "Remove Module?",
            isPresented: Binding(
                get: { moduleToRemove != nil },
                set: { if !$0 { moduleToRemove = nil } }
            ),
            presenting: moduleToRemove
        ) { module in
            Button("Remove \(module.name)", role: .destructive) {
                model.remove(module)
                moduleToRemove = nil
            }
        } message: { module in
            // Not "the installed copy": `LibraryModel.remove(_:)` records the
            // removal through LampSyncRemovedModules first, which is what stops
            // the next sync fetching the module back — and so is what carries
            // the removal to the other devices.
            Text("This removes \(module.name) from your library — from this Mac, and from your other devices the next time they sync. Your original .lamp file is not affected.")
        }
    }

    private var personalModuleSection: some View {
        Section("Personal") {
            ForEach(LampPersonalModule.allCases) { personalModule in
                let choice = ModuleExportChoice.personal(personalModule)
                HStack(spacing: 12) {
                    Image(systemName: icon(for: personalModule.kind))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(personalModule.name)
                        Text("Personal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Export", systemImage: "square.and.arrow.up") {
                        exportRequest = ModuleExportRequest(initialChoiceID: choice.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Export \(personalModule.name)")
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Export Module…", systemImage: "square.and.arrow.up") {
                        exportRequest = ModuleExportRequest(initialChoiceID: choice.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moduleSection(_ title: String, modules: [LampInstalledModule]) -> some View {
        if !modules.isEmpty {
            Section(title) {
                ForEach(modules) { module in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: module.kind))
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(module.name)
                            HStack {
                                if let abbreviation = module.abbreviation {
                                    Text(abbreviation)
                                }
                                if module.isBundled {
                                    Label("Built In", systemImage: "shippingbox.fill")
                                } else {
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: Int64(module.compressedByteCount),
                                        countStyle: .file
                                    ))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !module.isBundled {
                            Button("Export", systemImage: "square.and.arrow.up") {
                                exportRequest = ModuleExportRequest(
                                    initialChoiceID: ModuleExportChoice.installed(module).id
                                )
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Export \(module.name)")
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                moduleToRemove = module
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove \(module.name)")
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        if !module.isBundled {
                            Button("Export Module…", systemImage: "square.and.arrow.up") {
                                exportRequest = ModuleExportRequest(
                                    initialChoiceID: ModuleExportChoice.installed(module).id
                                )
                            }
                            Divider()
                            Button("Remove Module", role: .destructive) {
                                moduleToRemove = module
                            }
                        }
                    }
                }
            }
        }
    }

    private func icon(for kind: LampModuleKind) -> String {
        switch kind {
        case .translation: "books.vertical"
        case .dictionary: "character.book.closed"
        case .commentary: "text.book.closed"
        case .book: "book.closed"
        case .plan: "checklist"
        case .devotional: "sun.max"
        case .quiz: "questionmark.bubble"
        case .notes: "note.text"
        case .highlights: "highlighter"
        }
    }
}

private struct ModuleExportChoice: Identifiable {
    enum Source {
        case personal(LampPersonalModule)
        case installed(LampInstalledModule)
    }

    let id: String
    let name: String
    let kind: LampModuleKind
    let exportIdentifier: String
    let source: Source

    static func personal(_ module: LampPersonalModule) -> Self {
        Self(
            id: "personal:\(module.id)",
            name: module.name,
            kind: module.kind,
            exportIdentifier: module.id,
            source: .personal(module)
        )
    }

    static func installed(_ module: LampInstalledModule) -> Self {
        Self(
            id: "installed:\(module.kind.rawValue):\(module.id)",
            name: module.name,
            kind: module.kind,
            exportIdentifier: module.id,
            source: .installed(module)
        )
    }

    var supportedFormats: [LampModuleExportFormat] {
        switch source {
        case .personal(let module):
            LampLibrary.supportedExportFormats(for: module)
        case .installed(let module):
            LampLibrary.supportsMarkdownExport(for: module.kind)
                ? [.lamp, .markdown]
                : [.lamp]
        }
    }
}

private struct ModuleExportRequest: Identifiable {
    let id = UUID()
    let initialChoiceID: String?
}

private struct ModuleExportWizard: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel
    let choices: [ModuleExportChoice]

    @State private var selectedChoiceID: String
    @State private var format = LampModuleExportFormat.lamp
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(choices: [ModuleExportChoice], initialChoiceID: String?) {
        self.choices = choices
        let initialID = initialChoiceID.flatMap { requestedID in
            choices.first(where: { $0.id == requestedID })?.id
        } ?? choices.first?.id ?? ""
        _selectedChoiceID = State(initialValue: initialID)
    }

    private var selectedChoice: ModuleExportChoice? {
        choices.first { $0.id == selectedChoiceID }
    }

    private var supportsMarkdown: Bool {
        selectedChoice?.supportedFormats.contains(.markdown) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Export Personal Module", systemImage: "square.and.arrow.up")
                    .font(.title2.bold())
                Text("Choose a personal or user-installed module and the portable format to create.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 24)

            Form {
                Picker("Module", selection: $selectedChoiceID) {
                    ForEach(choices) { choice in
                        Text("\(choice.name) — \(choice.kind.exportDisplayName)")
                            .tag(choice.id)
                    }
                }
                .help("Choose the personal or user-installed module to export")

                if supportsMarkdown {
                    Picker("Format", selection: $format) {
                        Text("Lamp Module (.lamp)")
                            .tag(LampModuleExportFormat.lamp)
                        Text("Markdown (.md)")
                            .tag(LampModuleExportFormat.markdown)
                    }
                    .pickerStyle(.radioGroup)
                    .help("Choose the exported file format")
                } else {
                    LabeledContent("Format") {
                        Text("Lamp Module (.lamp)")
                    }
                    .accessibilityLabel("Format: Lamp Module")
                }

                LabeledContent("About this format") {
                    Text(formatDescription)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 330, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .onChange(of: selectedChoiceID) { _, _ in
                if !supportsMarkdown { format = .lamp }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", systemImage: "square.and.arrow.up") {
                    chooseDestinationAndExport()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedChoice == nil || isExporting)
                .help("Choose where to save the exported module")
            }
            .padding(16)
        }
        .frame(width: 540, height: 390)
        .alert(
            "Module Could Not Be Exported",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The module could not be exported.")
        }
    }

    private var formatDescription: String {
        switch format {
        case .lamp:
            if let choice = selectedChoice, case .personal = choice.source {
                "A portable snapshot of the current personal collection, preserving its structured content and metadata."
            } else {
                "A lossless copy of the original module, including all metadata, annotations, and structured content."
            }
        case .markdown:
            "A readable text version of the module. Use the Lamp format when you need to preserve every module feature."
        }
    }

    private func chooseDestinationAndExport() {
        guard let choice = selectedChoice else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(choice.name)"
        panel.prompt = "Export"
        panel.nameFieldStringValue = choice.exportIdentifier + (format == .lamp ? ".lamp" : ".md")
        panel.allowedContentTypes = format == .lamp
            ? [UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data)]
            : [UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isExporting = true
        errorMessage = nil
        Task {
            do {
                switch choice.source {
                case .personal(let module):
                    try await model.library.exportPersonalModule(
                        module,
                        format: format,
                        to: destinationURL
                    )
                case .installed(let module):
                    try await model.library.exportModule(
                        moduleID: module.id,
                        format: format,
                        to: destinationURL
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}

private extension LampModuleKind {
    var exportDisplayName: String {
        switch self {
        case .translation: "Translation"
        case .dictionary: "Dictionary"
        case .commentary: "Commentary"
        case .book: "Book"
        case .devotional: "Writing"
        case .notes: "Notes"
        case .plan: "Reading Plan"
        case .highlights: "Highlights"
        case .quiz: "Quiz"
        }
    }
}

/// A passage waiting for its reader to choose a Bible app.
struct ExternalBibleRequest: Identifiable, Equatable {
    let startReference: Int
    let endReference: Int?

    var id: String { "\(startReference)-\(endReference ?? startReference)" }
}
