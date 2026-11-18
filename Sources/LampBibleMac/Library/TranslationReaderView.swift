import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

struct TranslationReaderView: View, Equatable {
    /// Handed in rather than observed: the reader takes the library's changes
    /// from the view above it, which lets a hidden reader decline them (see
    /// `==`). Shown, it updates whenever the library does, as before.
    let model: LibraryModel
    /// This window's place in scripture. Handed in for the same reason as the
    /// model above: observed here, a hidden reader could not decline its
    /// changes.
    let workspace: ReaderWorkspace
    @EnvironmentObject private var scrollLink: ReaderScrollLink
    @AppStorage(AIFeatures.key) private var aiFeaturesEnabled = AIFeatures.defaultValue
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
    @AppStorage("reader.readAloud.followAlong") private var followReadAloud = true
    /// Set, never read here, so typing in the dictionary does not redraw
    /// the reader.
    @Environment(StudyPaneState.self) private var studyPane
    /// The tab's, so the window's toolbar can work it (`ReaderWorkspace`).
    private var readAloud: ReadAloudController { workspace.readAloud }
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
        get { aiFeaturesEnabled && readerSidebar == .chat }
        nonmutating set {
            if newValue, aiFeaturesEnabled { readerSidebar = .chat } else if readerSidebar == .chat { readerSidebar = nil }
        }
    }
    /// The translator's notes for the passage on screen: what each says, and
    /// where in its verse it belongs. Fetched after the text is drawn, since
    /// most reading never opens one.
    @State private var chapterFootnotes: [Int: LampVerseStudyData] = [:]
    /// The note the reader has opened, by verse and by its place in that verse.
    @State private var revealedFootnote: ReaderFootnoteKey?
    private var showingReaderLocationPicker: Bool {
        get { workspace.isChoosingPassage }
        nonmutating set { workspace.isChoosingPassage = newValue }
    }
    @State private var highlightVerse: LampVerse?
    /// The highlight controls by the words selected or the highlight clicked.
    @State private var highlighter = ReaderHighlighter()
    // The tab's, which the window's toolbar reads too (`ReaderWorkspace`).
    private var planReadingChapters: [LampChapter] {
        get { workspace.planReadingChapters }
        nonmutating set { workspace.planReadingChapters = newValue }
    }
    private var loadedPlanReadingRequest: PlanReadingChapterRequest? {
        get { workspace.loadedPlanReadingRequest }
        nonmutating set { workspace.loadedPlanReadingRequest = newValue }
    }
    private var isLoadingPlanReading: Bool {
        get { workspace.isLoadingPlanReading }
        nonmutating set { workspace.isLoadingPlanReading = newValue }
    }
    private var planReadingError: String? {
        get { workspace.planReadingError }
        nonmutating set { workspace.planReadingError = newValue }
    }
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
        // The toolbar, ⌘L and the scroll link's focus are the window's
        // (`LibraryRootView.readerDetail`): readers kept for other tabs would
        // otherwise each bring their own, and the toolbar was rebuilt on
        // every switch.
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
        // The tab's own: a chat reads the selection of the tab it belongs to.
        .environment(\.readerTextSelection, workspace.textSelection)
        .environment(\.readerHighlighter, highlighter)
        .onAppear { highlighter.actions = highlighterActions }
        // The named marks of the set new highlights go to, read again when
        // the options sheet, where they are named, closes.
        .task(id: "\(workspace.selectedTranslationID ?? "")|\(highlightVerse == nil)") {
            guard highlightVerse == nil, let translationID = workspace.selectedTranslationID else { return }
            let setID = "personal-highlights:\(LampTranslationID.original(translationID))"
            highlighter.themes = (try? await model.library.highlightThemes(setID: setID)) ?? []
        }
    }

    /// What the highlight controls read and write: the reader's own
    /// highlights in the translation being read.
    private var highlighterActions: ReaderHighlighter.Actions {
        let model = model
        let workspace = workspace
        func setID() -> String? {
            workspace.selectedTranslationID.map { "personal-highlights:\(LampTranslationID.original($0))" }
        }
        func verse(_ reference: Int) -> LampVerse? {
            displayedChapters.lazy.flatMap(\.verses).first { $0.id == reference }
                ?? workspace.chapter?.verses.first { $0.id == reference }
        }
        return ReaderHighlighter.Actions(
            highlights: { model.personalHighlights(for: $0, in: workspace.selectedTranslationID) },
            verseLength: { verse($0)?.text.count },
            save: { span, color, style in
                guard let setID = setID() else { return }
                try await model.saveVerseHighlight(
                    reference: span.reference, startOffset: span.start, endOffset: span.end,
                    style: style, color: color, setID: setID
                )
            },
            restyle: { old, color, style in
                try await model.deleteVerseHighlight(id: old.id, reference: old.reference)
                try await model.saveVerseHighlight(
                    reference: old.reference, startOffset: old.startOffset, endOffset: old.endOffset,
                    style: style, color: color, setID: old.setID
                )
            },
            delete: { try await model.deleteVerseHighlight(id: $0.id, reference: $0.reference) },
            openNote: { reference in
                prepareChapterForStudy(reference: reference)
                selectVerseFromReader(reference)
                studyPane.noteToCompose = reference
                studyPane.tool = "notes"
                showingStudyInspector = true
            },
            copy: { spans, text in
                let verses = spans.compactMap { verse($0.reference) }
                copyAsCitation(verses, selectedText: text.isEmpty ? nil : text)
            },
            moreOptions: { reference in highlightVerse = verse(reference) },
            failed: { model.errorMessage = $0.localizedDescription }
        )
    }

    /// Whether this is the window's reader on screen: kept readers of other
    /// tabs stay live out of sight and must neither act on what the window's
    /// shared stores send nor send anything to them. Read live from the
    /// workspace, since a reader out of sight is never handed a new view.
    /// Not the library's active reader: a window behind is still on screen,
    /// and its reader and pane still scroll together.
    private var isActiveReader: Bool { workspace.isOnScreen }

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

    /// For a place this translation doesn't have: says so, and offers the
    /// same place in a translation that has it.
    private func missingBookNotice(_ book: Int) -> some View {
        let translationID = workspace.selectedTranslationID
        let name = model.translations.first { $0.id == translationID }?.name ?? "This translation"
        let other = model.translation(having: book, near: translationID)
        let reference = workspace.selectedVerseReference
            ?? book * 1_000_000 + workspace.selectedChapterNumber * 1_000 + 1
        return ContentUnavailableView {
            Label(
                "\(name) doesn’t include \(model.bookName(book, in: other?.id))",
                systemImage: "book.closed"
            )
        } description: {
            Text(other == nil
                ? "No installed translation has this book."
                : "Choose another book, or read this passage in \(other!.name).")
        } actions: {
            if let other {
                Button("Read in \(other.name)") {
                    workspace.openReference(reference, translationID: other.id)
                }
                .buttonStyle(.borderedProminent)
            }
        }
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
        } else if let book = workspace.missingBook {
            missingBookNotice(book)
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
                // A reading in a book the translation lacks, as a Gospel in a
                // Septuagint, rather than a range that names nothing.
                let first = request.startReference / 1_000_000
                let last = request.endReference / 1_000_000
                let covered = Set(books.map(\.id))
                if let missing = (first...max(first, last)).first(where: { !covered.contains($0) }) {
                    let name = model.translations.first { $0.id == request.translationID }?.name
                        ?? "This translation"
                    planReadingError = "\(name) doesn’t include \(model.bookName(missing, in: nil)). Choose a translation that does to read this reading."
                } else {
                    planReadingError = "The plan contains an invalid scripture range."
                }
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
                    // Hands the scroll view to the window's scroll memory, and
                    // puts a chosen tab back where it was left once laid out.
                    .background(ScrollMemoryLink(memory: workspace.scrollMemory, passage: passageIdentity))
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
                    // The store is the window's, shared by its kept tabs: only
                    // the tab on screen follows a link clicked in it.
                    guard isShown, isActiveReader else { return }
                    _ = handleReaderLink(url)
                }
                // A new passage gets a fresh scroll container at its natural zero
                // offset, including the padding above the book heading.
                .id(passageIdentity)
                .onScrollTargetVisibilityChange(idType: Int.self) { visible in
                    guard isActiveReader, !isPanelTransitioning,
                          readerLayoutMode.drawsVerseRows else { return }
                    scrollLink.readerDidScroll(to: visible.min())
                }
                // Read once per scroll rather than once per paragraph that happens to
                // move: the paragraphs report their positions into a store that
                // invalidates nothing, and the scroll itself decides when to look.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, _ in
                    guard isActiveReader, !isPanelTransitioning,
                          readerLayoutMode == .continuousParagraphs else { return }
                    scrollLink.readerDidScroll(to: paragraphAnchors.topEdgeReference)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    if isActiveReader, oldPhase.isUserDriven != newPhase.isUserDriven {
                        // Keep scroll phase outside SwiftUI state. Invalidating the
                        // reader here makes SwiftUI reconstruct the selectable
                        // attributed-text overlay while the passage is moving.
                        lexicalHoverStore.configure(isScrollFrozen: newPhase.isUserDriven)
                        if newPhase.isUserDriven {
                            lexicalHoverStore.clearForScrolling()
                        }
                    }
                    if isActiveReader, !oldPhase.isUserDriven, newPhase.isUserDriven {
                        scrollLink.readerUserScrollDidBegin()
                    }
                    // Where the open tab is, each time a scroll settles, so
                    // quitting keeps it.
                    if newPhase == .idle { workspace.scrollMemory.saveCurrent() }
                    guard oldPhase.isScrolling,
                          !newPhase.isScrolling,
                          readerReachedBottom(context.geometry) else { return }
                    completeActivePlanReading()
                }
                .onReceive(scrollLink.toolAnchors) { reference in
                    // A study pane appearing or disappearing lays out, reports its
                    // position, and would drag the reader to it. The link is for
                    // following a pane the reader is scrolling, not for being
                    // rearranged by one that just arrived. Nor for moving a kept
                    // tab out of sight.
                    guard isShown, isActiveReader, !isPanelTransitioning else { return }
                    proxy.scrollTo(scrollTarget(for: reference, in: chapters), anchor: .top)
                }
                .onAppear { scrollToReaderLocation(proxy, chapters: chapters) }
                // And when the app quits, for a place no settled scroll noted.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    workspace.scrollMemory.saveCurrent()
                }
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
                    guard isActiveReader else { return }
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
                    guard isActiveReader, !isPanelTransitioning,
                          readerLayoutMode == .continuousParagraphs else { return }
                    scrollLink.readerDidScroll(to: paragraphAnchors.topEdgeReference)
                }
                .onChange(of: readerLayoutMode) { _, _ in
                    if isActiveReader { scrollLink.reset() }
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
    ///
    /// Resolved against what is installed, which for a list is more than
    /// renaming each entry: resolution is many-to-one, so a list holding
    /// both an old and a new spelling of one translation would name it
    /// twice and the reader would draw the same text in two columns. Core's
    /// list form keeps each translation once, at its first position, and
    /// drops what is not installed at all.
    private var chosenCompanionIDs: [String] {
        let stored = companionTranslationIDList.split(separator: ",").map(String.init)
        let ids = stored.isEmpty
            ? [singleCompanionTranslationID].filter { !$0.isEmpty }
            : stored
        return LampTranslationID.held(ids, among: model.installedTranslationIDs)
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
        guard readerLayoutMode == .sideBySide else { return ReaderTextInset.singleColumnWidth(fontSize: fontSize) }
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
                    // Every chapter a verse reaches, not the first: one verse
                    // can answer to two, and a companion column that misses
                    // the second shows an empty row where text stands.
                    for partner in mainVersification.counterparts(of: verse.id, in: versification) {
                        places.insert([partner / 1_000_000, partner / 1_000 % 1_000])
                    }
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
                // One row against one row: a parallel column lines a verse
                // up with a single partner, which is what `opens` answers.
                fromMain: { main.opens($0, in: other) },
                toMain: { other.opens($0, in: main) }
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
                TranslationPickerOptions(translations: translations, tag: \.id)
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
        workspace.openReference(readingPlace(in: chapter), translationID: id, switchingTranslation: true)
    }

    /// A quiet way into reading side by side from the page itself, beside each
    /// chapter's opening; the toolbar's toggle and the View menu do the same.
    /// Side by side has its own add button over the column titles, so this
    /// shows only on a single column.
    @ViewBuilder
    private func parallelTranslationOffer(reading chapter: LampChapter) -> some View {
        let others = model.translations.filter { $0.id != chapter.translationID }
        if readerLayoutMode != .sideBySide, !others.isEmpty {
            let heading = "Read Beside \(translationName(chapter.translationID))"
            let choose: (LampInstalledModule) -> Void = { translation in
                chooseCompanions([translation.id])
                readsSideBySide.wrappedValue = true
            }
            Menu {
                // Grouped by language as ⌘L's translation picker is. With
                // language sections the heading stands above them on its own;
                // with one language it is the one section's title.
                if TranslationMenuOptions.isGrouped(others) {
                    Text(heading)
                    TranslationMenuOptions(translations: others, choose: choose)
                } else {
                    Section(heading) {
                        TranslationMenuOptions(translations: others, choose: choose)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Color.lampVerseNumber)
            .help("Read another translation beside this one")
            .accessibilityLabel("Add a Parallel Translation")
        }
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
        .padding(.horizontal, ReaderTextInset.horizontal)
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
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
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
            openVerseNotes(reference: reference)
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
        // The book in small tracked capitals and the chapter beneath it as a
        // large numeral in the reader's own face, as a printed Bible and the
        // iPhone reader set it: the chapter is what changes as the page is
        // read, so it is the one the eye should find.
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.book.name)
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(Color.lampVerseNumber)
                    .textSelection(.enabled)
                Text("\(chapter.number)")
                    .font(.system(size: max(fontSize * 2.4, 42), weight: .medium, design: typeface.design))
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(chapter.book.name), chapter \(chapter.number)")
            Spacer(minLength: 0)
            parallelTranslationOffer(reading: chapter)
        }
        // Level with the text and the headings, which the rows set in by
        // their own padding.
        .padding(.horizontal, ReaderTextInset.horizontal)
        .padding(.top, isFirst ? 0 : 56)
        .padding(.bottom, 4)
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
                let headings = headingsByVerse[verse.number] ?? []
                VStack(alignment: .leading, spacing: 0) {
                    readerHeadings(headings, opensChapter: verse.id == chapter.verses.first?.id)
                    verseRow(verse, followsHeading: !headings.isEmpty, showsInstantDetails: showsInstantDetails)
                }
                .id(verse.id)
            }
        } else {
            ForEach(continuousParagraphs(in: chapter)) { paragraph in
                let headings = headingsByVerse[paragraph.firstVerse.number] ?? []
                VStack(alignment: .leading, spacing: 0) {
                    readerHeadings(headings, opensChapter: paragraph.firstVerse.id == chapter.verses.first?.id)
                    continuousParagraph(
                        paragraph,
                        followsHeading: !headings.isEmpty,
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
    /// `opensChapter`: the headings straight under the chapter's title, which
    /// the title's own space already sets off. A full heading's space on top
    /// of it left a gap the panel kept calling out.
    private func readerHeadings(_ headings: [LampHeading], opensChapter: Bool = false) -> some View {
        ForEach(headings) { heading in
            // Sized from the text rather than fixed, so a heading keeps its
            // rank over the body at any reading size; and set in by the same
            // inset as the verses, which used to start 8 points right of it.
            Text(heading.text)
                .font(.system(
                    size: heading.level == 1 ? max(fontSize * 1.1, 17) : max(fontSize * 0.9, 15),
                    weight: heading.level == 1 ? .bold : .semibold
                ))
                .textSelection(.enabled)
                .padding(.top, opensChapter && heading.id == headings.first?.id
                         ? 14
                         : (heading.level == 1 ? 34 : 28))
                .padding(.bottom, ReaderTextInset.belowHeading)
                .padding(.horizontal, ReaderTextInset.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func continuousParagraph(
        _ paragraph: ReaderParagraph,
        followsHeading: Bool,
        showsInstantDetails: Bool
    ) -> some View {
        continuousParagraphText(paragraph)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, followsHeading ? 0 : continuousTopPadding(for: paragraph.firstVerse))
            .padding(.leading, paragraphIndent(for: paragraph))
            .padding(.horizontal, ReaderTextInset.horizontal)
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
                    openNote: { openVerseNotes(reference: $0) }
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
        //
        // Set in the system's sans rather than the reader's serif: at a
        // numeral's size the serif's thin strokes broke up, and a sans figure
        // is what the eye picks out scanning down for a verse. Tabular figures,
        // so 18 and 19 take the same room.
        var numberAttributes = markerTextAttributes(
            size: max(fontSize * 0.7, 11.5),
            weight: .semibold,
            color: isSelected ? .labelColor : .lampVerseNumber,
            baselineOffset: max(fontSize * 0.3, 4),
            apparatus: true
        )
        numberAttributes[.link] = verseURL
        numberAttributes[ReaderTextMarks.verse] = NSNumber(value: verse.id)
        numberAttributes[ReaderTextMarks.apparatus] = true
        result.append(NSAttributedString(
            string: verse.number.formatted(),
            attributes: numberAttributes
        ))

        var spaceAttributes = bodyTextAttributes()
        spaceAttributes[ReaderTextMarks.verse] = NSNumber(value: verse.id)
        result.append(NSAttributedString(string: " ", attributes: spaceAttributes))
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
                    openNote: { openVerseNotes(reference: $0) }
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
                openNote: { openVerseNotes(reference: $0) }
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

    /// A verse's words, each character marked with the verse it belongs to,
    /// so text selected in the reader can say where it is from.
    private func verseBodyText(
        for verse: LampVerse,
        range: ReaderTextRange? = nil,
        column: ReaderVerseColumn = .reading
    ) -> NSAttributedString {
        let body = NSMutableAttributedString(
            attributedString: untaggedVerseBodyText(for: verse, range: range, column: column)
        )
        let whole = NSRange(location: 0, length: body.length)
        body.addAttribute(ReaderTextMarks.verse, value: NSNumber(value: verse.id), range: whole)
        // Where these words begin in the verse, for highlighting them in place.
        body.addAttribute(
            ReaderHighlightMarks.offset, value: NSNumber(value: range?.startOffset ?? 0), range: whole
        )
        if let companionID = column.companionID {
            body.addAttribute(ReaderTextMarks.translation, value: companionID, range: whole)
        }
        return body
    }

    private func untaggedVerseBodyText(
        for verse: LampVerse,
        range: ReaderTextRange?,
        column: ReaderVerseColumn
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
                size: max(fontSize * 0.64, 11),
                weight: .bold,
                // It opens the note, so it reads as a link.
                color: .lampLink,
                baselineOffset: max(fontSize * 0.32, 5),
                apparatus: true
            )
            attributes[.link] = readerFootnoteURL(verse: verse.id, index: insertion.index, companionID: companionID)
            attributes[ReaderTextMarks.apparatus] = true
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
    private func verseRow(_ verse: LampVerse, followsHeading: Bool = false, showsInstantDetails: Bool) -> some View {
        renderedVerseText(for: verse)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, followsHeading ? 0 : topPadding(for: verse))
            .padding(.leading, partialPoetryRange(for: verse) == nil ? poetryIndent(for: verse) : 0)
            .padding(.horizontal, ReaderTextInset.horizontal)
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

    // Highlighting is offered by the text view itself (`ReaderHighlighter`),
    // for the verse or the words under the pointer.
    private func paragraphContextMenuEntries(_ paragraph: ReaderParagraph) -> [ReaderContextMenuEntry] {
        copyContextMenuEntries(for: paragraph.verses)
    }

    private func verseContextMenuEntries(_ verse: LampVerse) -> [ReaderContextMenuEntry] {
        var entries = copyContextMenuEntries(for: [verse])
        entries.append(.separator)
        entries.append(.action(
            model.hasPersonalNote(for: verse.id) ? "Edit Note" : "Add Note",
            systemImage: "square.and.pencil"
        ) {
            prepareChapterForStudy(reference: verse.id)
            selectVerseFromReader(verse.id)
            studyPane.noteToCompose = verse.id
            studyPane.tool = "notes"
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

    private func copyAsCitation(_ fallbackVerses: [LampVerse], selectedText: String? = nil) {
        guard let firstReference = fallbackVerses.first?.id,
              let chapter = displayedChapters.first(where: { chapter in
                  chapter.verses.contains(where: { $0.id == firstReference })
              }) ?? workspace.chapter else { return }
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let copiedSelection = selectedText
            ?? (NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                && pasteboard.changeCount != originalChangeCount
                ? pasteboard.string(forType: .string)
                : nil)
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
        if !Self.keepsVerseTool(studyPane.tool) {
            if model.hasPersonalNote(for: verse.id) || model.hasInstalledNote(for: verse.id) {
                studyPane.tool = "notes"
            } else if verse.hasFootnotes || verse.annotations.contains(where: { $0.strongs != nil }) {
                studyPane.tool = "verse"
            }
        }
        showingStudyInspector = true
    }

    /// Notes and Verse are both about the verse clicked, so a reader on
    /// either stays on it from verse to verse; choosing between them by what
    /// each verse holds moved them off the one they were reading at every
    /// click. From Commentary or Dictionary, the verse's contents choose.
    private static func keepsVerseTool(_ tool: String) -> Bool {
        tool == "notes" || tool == "verse"
    }

    /// A note's marker asks for the note itself, whichever tab is showing.
    private func openVerseNotes(reference: Int) {
        openVerseStudy(reference: reference)
        studyPane.tool = "notes"
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
            if !Self.keepsVerseTool(studyPane.tool) {
                studyPane.tool = model.hasPersonalNote(for: reference) || model.hasInstalledNote(for: reference)
                    ? "notes"
                    : "verse"
            }
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
        //
        // Two walks, because two kinds of offset arrive here and they are not
        // the same unit. A **tag** addresses its verse by code point, as every
        // annotation in Lamp does. A **highlight** is the reader's own, made by
        // this app and counted in `Character`s. Measuring either by the other's
        // unit moves it: a pointed Hebrew word is seven code points and four
        // Characters, so tagged ranges were being thrown away as out of bounds
        // and the words under them lost their lookup.
        let characterIndices = Array(verse.text.indices) + [verse.text.endIndex]
        let scalarIndices = Array(verse.text.unicodeScalars.indices) + [verse.text.endIndex]

        func range(_ indices: [String.Index], _ startOffset: Int, _ endOffset: Int) -> NSRange? {
            guard startOffset >= 0,
                  endOffset > startOffset,
                  endOffset < indices.count,
                  startOffset < indices.count else {
                return nil
            }
            return NSRange(indices[startOffset]..<indices[endOffset], in: verse.text)
        }

        /// A tag's range: code points, which is what its offsets count.
        func taggedRange(from startOffset: Int, to endOffset: Int) -> NSRange? {
            range(scalarIndices, startOffset, endOffset)
        }

        /// A highlight's range: `Character`s, which is what the reader's own
        /// marks were made in.
        func attributedRange(from startOffset: Int, to endOffset: Int) -> NSRange? {
            range(characterIndices, startOffset, endOffset)
        }

        for annotation in verse.annotations {
            guard let range = taggedRange(
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
                  annotationRange.end < scalarIndices.count,
                  !keys.isEmpty else { continue }
            let word = String(
                verse.text[scalarIndices[annotationRange.start]..<scalarIndices[annotationRange.end]]
            )
            guard let lookup = LexiconLookupLink(keys: keys, reference: verse.id, word: word),
                  let route = lookup.url?.absoluteString,
                  let range = taggedRange(
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
            ?? model.highlights(for: verse.id, in: workspace.selectedTranslationID)
        for highlight in highlights {
            let startOffset = min(max(highlight.startOffset, 0), verse.text.count)
            let endOffset = min(max(highlight.endOffset, startOffset), verse.text.count)
            guard let range = attributedRange(from: startOffset, to: endOffset) else { continue }
            let color = readerColor(hex: highlight.color ?? "FFCC00") ?? .systemYellow
            switch highlight.style {
            case .highlight:
                result.addAttribute(
                    .backgroundColor,
                    value: ReaderHighlightGrounds.ground(for: color),
                    range: range
                )
            // Thick: at the reader's size a single line read as faint, and a
            // dotted one as a link.
            case .underlineSolid:
                result.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: color,
                ], range: range)
            case .underlineDashed:
                result.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick
                        .union(.patternDash).rawValue,
                    .underlineColor: color,
                ], range: range)
            case .underlineDotted:
                result.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick
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

    /// `apparatus` sets the mark in the system sans with tabular figures, for
    /// the numbers and letters set in among scripture rather than the words.
    private func markerTextAttributes(
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        baselineOffset: CGFloat,
        apparatus: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        var result = bodyTextAttributes()
        result[.font] = apparatus
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : readerFont(size: size, weight: weight)
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
        studyPane.tool = "dictionary"
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
        // A tab chosen again goes back to where it was left, not to its
        // selected verse: every switch used to scroll the page.
        let passage = chapters.map { ReaderPassageChapter(chapter: $0).id }.joined(separator: ",")
        if workspace.scrollMemory.isRestoring(passage) {
            workspace.scrollMemory.restoreIfReady(passage: passage)
            return
        }
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
        // Where this put the page is where the tab now is: an older place
        // in the same chapter must not win when the app is opened again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [scrollMemory = workspace.scrollMemory] in
            scrollMemory.saveCurrent()
        }
    }

    private var readerLocationTitle: String {
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

}

private struct VerseAnnotationRange: Hashable {
    let start: Int
    let end: Int
}


// The Modules section's view is InstalledModulesView.swift.
