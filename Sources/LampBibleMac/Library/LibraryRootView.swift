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

private enum LibrarySelection: Hashable {
    case section(LibrarySection)
    case translation(String)
}

struct LibraryRootView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var syncController: LibrarySyncController
    @EnvironmentObject private var scrollLink: ReaderScrollLink
    @State private var selection: LibrarySelection? = .section(.reader)
    @State private var showingImporter = false
    @State private var showingStudyDataImporter = false
    @State private var readerTabs = ReaderTabCollection()
    @State private var showingNewReaderTab = false
    @State private var showingStudyInspector = false
    @State private var requestedBookID: String?
    @State private var requestedBookSectionID: String?
    @State private var isStudyInspectorMounted = false
    /// How much of the study column is on screen, in points. The single animated
    /// value behind the whole transition: it sets the reader's width, the gap, and
    /// the pane's opacity, so those three cannot disagree.
    @State private var studyInspectorRevealedWidth: Double = 0
    @State private var isStudyInspectorContentReady = false
    @State private var isStudyInspectorTransitioning = false
    @State private var planReadingMode: PlanReadingMode?
    // Keep hover mutations out of this view's observation graph. Only the small
    // readout observes the store, so moving between words cannot rebuild the
    // reader's selectable text hierarchy underneath the pointer.
    @State private var readerLexicalHoverStore = ReaderLexicalHoverStore()
    @AppStorage("studyInspector.width") private var studyInspectorWidth = StudyInspectorMetrics.defaultWidth

    var body: some View {
        ZStack {
            if model.hasLoadedInitialContent {
                libraryInterface
                    .transition(.opacity)
            } else {
                LampSplashView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: model.hasLoadedInitialContent)
        // Kept outside the branch above so the library still loads while the
        // splash is what's on screen.
        .onAppear {
            readerTabs.updateSelected(location: model.readerLocation)
            model.start()
        }
        .task {
            await syncController.syncAutomaticallyIfNeeded(library: model.library)
            model.refresh()
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

                if !model.translations.isEmpty {
                    Section("Translations") {
                        ForEach(model.translations) { translation in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(translation.abbreviation ?? translation.name)
                                    if translation.abbreviation != nil {
                                        Text(translation.name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "books.vertical")
                            }
                            .tag(LibrarySelection.translation(translation.id))
                        }
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
            openInCurrent: { openReferenceInCurrentTab($0) },
            openInNewTab: { openReferenceInNewTab($0) }
        ))
        .onOpenURL { handleOpenURL($0) }
        .onChange(of: selection) { _, newValue in
            if case .translation(let moduleID) = newValue {
                model.selectTranslation(moduleID)
            }
            if !isReaderSelection(newValue) {
                showingStudyInspector = false
            }
        }
        .onChange(of: model.readerLocation) { _, location in
            readerTabs.updateSelected(location: location)
            updateActivePlanReading(for: location)
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
        case .section(.reader), .translation:
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
            model.openReference(reference, translationID: translationID)
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

    private func presentNewReaderTabChooser() {
        selection = .section(.reader)
        showingNewReaderTab = true
    }

    private func duplicateCurrentReaderTab() {
        guard let location = model.readerLocation else { return }
        openReaderTab(at: location)
    }

    private func openReaderTab(at location: ReaderLocation) {
        readerTabs.updateSelected(location: model.readerLocation)
        readerTabs.add(location: location)
        model.openReaderTabLocation(location)
        selection = .section(.reader)
    }

    private func selectReaderTab(_ id: UUID) {
        guard id != readerTabs.selectedID else { return }
        readerTabs.updateSelected(location: model.readerLocation)
        if let location = readerTabs.select(id) {
            model.openReaderTabLocation(location)
        }
        selection = .section(.reader)
    }

    private func closeReaderTab(_ id: UUID) {
        guard readerTabs.tabs.count > 1 else { return }
        let wasSelected = readerTabs.selectedID == id
        if wasSelected { readerTabs.updateSelected(location: model.readerLocation) }
        let destination = readerTabs.close(id)
        if wasSelected, let destination {
            model.openReaderTabLocation(destination)
        }
    }

    private func openReferenceInCurrentTab(_ reference: Int) {
        model.openReference(reference)
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
        readerTabs.updateSelected(location: model.readerLocation)
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
        model.openReaderTabLocation(lastLocation)
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
        guard let translationID = model.selectedTranslationID ?? model.translations.first?.id else {
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

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .section(.reader), .translation:
            VStack(spacing: 0) {
                if planReadingMode == nil {
                    ReaderTabBar(
                        tabs: readerTabs.tabs,
                        selectedID: readerTabs.selectedID,
                        currentLocation: model.readerLocation,
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
                    let revealedWidth = isStudyInspectorTransitioning
                        ? min(max(studyInspectorRevealedWidth, 0), columnWidth)
                        : (showingStudyInspector ? columnWidth : 0)
                    let revealProgress = columnWidth > 0 ? revealedWidth / columnWidth : 0
                    // A plain row, not an overlay: the column is a sibling of the
                    // reader so the layout itself decides where it sits.
                    HStack(spacing: 0) {
                        TranslationReaderView(
                            planReadingMode: $planReadingMode,
                            showingStudyInspector: $showingStudyInspector,
                            lexicalHoverStore: readerLexicalHoverStore,
                            isSidebarTransitioning: isStudyInspectorTransitioning,
                            showImporter: { showingImporter = true }
                        )
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

                        if isStudyInspectorMounted {
                            StudyInspectorColumn(width: $studyInspectorWidth) {
                                if isStudyInspectorContentReady {
                                    StudyInspectorView(isPresented: $showingStudyInspector)
                                        .environmentObject(model)
                                        .environmentObject(scrollLink)
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
                        .smooth(duration: StudyInspectorMetrics.revealDuration),
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
                    .task(id: showingStudyInspector) {
                        let columnWidth = StudyInspectorMetrics.totalWidth(studyInspectorWidth)
                        if !showingStudyInspector,
                           !isStudyInspectorMounted,
                           studyInspectorRevealedWidth == 0 {
                            isStudyInspectorTransitioning = false
                            return
                        }
                        let duration = StudyInspectorMetrics.revealDuration
                        isStudyInspectorTransitioning = true
                        if showingStudyInspector {
                            // Mount before moving. SwiftUI does not animate a view's
                            // first layout, so mounting and revealing in one pass
                            // would always look like a jump.
                            isStudyInspectorMounted = true
                            // Mount the real inspector immediately so a lookup made by
                            // the click that opens this column is adopted while the
                            // column arrives, rather than after the animation ends.
                            isStudyInspectorContentReady = true
                            await Task.yield()
                            guard !Task.isCancelled, showingStudyInspector else { return }

                            // No `withAnimation`: the row carries its own.
                            studyInspectorRevealedWidth = columnWidth
                            do {
                                try await Task.sleep(for: .seconds(duration))
                            } catch {
                                return
                            }
                            guard !Task.isCancelled, showingStudyInspector else { return }
                            isStudyInspectorTransitioning = false
                        } else {
                            studyInspectorRevealedWidth = 0
                            do {
                                try await Task.sleep(for: .seconds(duration))
                            } catch {
                                return
                            }
                            guard !showingStudyInspector else { return }
                            isStudyInspectorMounted = false
                            isStudyInspectorContentReady = false
                            isStudyInspectorTransitioning = false
                        }
                    }
                }
            }
        case .section(.today):
            TodayPlansView(
                showImporter: { showingImporter = true },
                showPlans: { selection = .section(.plans) },
                openReading: openPlanReading,
                openAllReadings: openAllPlanReadings
            )
        case .section(.plans):
            ReadingPlansView(
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
                    model.openReference(reference)
                    selection = .section(.reader)
                }
            )
        case .section(.devotionals):
            DevotionalsView(
                showImporter: { showingImporter = true },
                openReference: { reference in
                    model.openReference(reference)
                    selection = .section(.reader)
                }
            )
        case .section(.quizzes):
            QuizzesView(
                showImporter: { showingImporter = true },
                openReference: { reference in
                    model.openReference(reference)
                    selection = .section(.reader)
                }
            )
        case .section(.search):
            UnifiedSearchView(
                showImporter: { showingImporter = true },
                openReference: { reference in
                    model.openReference(reference)
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
                openKind: { kind in
                    switch kind {
                    case .devotional:
                        selection = .section(.devotionals)
                    case .plan:
                        selection = .section(.plans)
                    case .quiz:
                        selection = .section(.quizzes)
                    case .book:
                        selection = .section(.books)
                    default:
                        break
                    }
                }
            )
        case .section(.modules):
            InstalledModulesView(showImporter: { showingImporter = true })
        case nil:
            ContentUnavailableView("Choose a Section", systemImage: "sidebar.left")
        }
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
private enum StudyInspectorMetrics {
    static let defaultWidth = 410.0
    static let minimumWidth = 330.0
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
        .background(cellBackground(isSelected: isSelected, isHovered: isHovered))
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
                .background(isHoveringNewTab ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNewTab = $0 }
        .help("New reader tab (⌘T)")
        .popover(isPresented: $showingNewTab) {
            NewReaderTabView(
                currentLocation: currentLocation,
                duplicate: duplicate,
                openLocation: openLocation
            )
        }
    }

    private func tabTitle(_ tab: ReaderTab) -> String {
        guard let location = tab.location else { return "Reader" }
        return "\(LampBibleReferenceFormatter.bookName(location.bookNumber)) \(location.chapterNumber)"
    }
}

private struct NewReaderTabView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel
    let currentLocation: ReaderLocation?
    let duplicate: () -> Void
    let openLocation: (ReaderLocation) -> Void
    @State private var translationID: String
    @State private var books: [LampTranslationBook] = []
    @State private var bookNumber: Int
    @State private var chapterNumber: Int
    @State private var verses: [LampVerse] = []
    @State private var verseReference: Int?
    @State private var isLoadingBooks = false
    @State private var isLoadingChapter = false
    @State private var errorMessage: String?

    init(
        currentLocation: ReaderLocation?,
        duplicate: @escaping () -> Void,
        openLocation: @escaping (ReaderLocation) -> Void
    ) {
        self.currentLocation = currentLocation
        self.duplicate = duplicate
        self.openLocation = openLocation
        _translationID = State(initialValue: currentLocation?.translationID ?? "")
        _bookNumber = State(initialValue: currentLocation?.bookNumber ?? 0)
        _chapterNumber = State(initialValue: currentLocation?.chapterNumber ?? 1)
        _verseReference = State(initialValue: currentLocation?.verseReference)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New Reader Tab")
                    .font(.headline)
                Text("Duplicate your place or open a different passage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if currentLocation != nil {
                Button {
                    duplicate()
                    dismiss()
                } label: {
                    Label("Duplicate Current Tab", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a passage")
                    .font(.subheadline.weight(.semibold))

                Picker("Translation", selection: $translationID) {
                    ForEach(model.translations) { translation in
                        Text(translation.abbreviation ?? translation.name)
                            .tag(translation.id)
                    }
                }

                Picker("Book", selection: $bookNumber) {
                    if books.isEmpty {
                        Text(isLoadingBooks ? "Loading…" : "Choose a translation")
                            .tag(0)
                    }
                    ForEach(books) { book in
                        Text(book.name).tag(book.id)
                    }
                }
                .disabled(books.isEmpty)

                Picker("Chapter", selection: $chapterNumber) {
                    if let selectedBook {
                        ForEach(1...selectedBook.chapterCount, id: \.self) { chapter in
                            Text(chapter.formatted()).tag(chapter)
                        }
                    } else {
                        Text("—").tag(1)
                    }
                }
                .disabled(selectedBook == nil)

                Picker("Verse", selection: $verseReference) {
                    Text("Chapter start").tag(Int?.none)
                    ForEach(verses) { verse in
                        Text(verse.number.formatted()).tag(Optional(verse.id))
                    }
                }
                .disabled(isLoadingChapter || verses.isEmpty)

                if isLoadingChapter {
                    ProgressView("Loading passage…")
                        .controlSize(.small)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Open New Tab", systemImage: "plus") {
                    guard let location else { return }
                    openLocation(location)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(location == nil)
            }
        }
        .padding(18)
        .frame(width: 390)
        .onAppear {
            if translationID.isEmpty {
                translationID = model.selectedTranslationID ?? model.translations.first?.id ?? ""
            }
        }
        .onChange(of: translationID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if newValue != currentLocation?.translationID {
                bookNumber = 0
                chapterNumber = 1
                verseReference = nil
            }
            verses = []
        }
        .onChange(of: bookNumber) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if newValue != currentLocation?.bookNumber {
                chapterNumber = 1
                verseReference = nil
            }
            clampChapterNumber()
            verses = []
        }
        .onChange(of: chapterNumber) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if newValue != currentLocation?.chapterNumber {
                verseReference = nil
            }
            verses = []
        }
        .task(id: translationID) {
            await loadBooks()
        }
        .task(id: chapterLoadID) {
            await loadChapter()
        }
    }

    private var selectedBook: LampTranslationBook? {
        books.first { $0.id == bookNumber }
    }

    private var chapterLoadID: String {
        "\(translationID):\(bookNumber):\(chapterNumber):\(books.count)"
    }

    private var location: ReaderLocation? {
        guard !translationID.isEmpty, bookNumber > 0, selectedBook != nil else { return nil }
        return ReaderLocation(
            translationID: translationID,
            bookNumber: bookNumber,
            chapterNumber: chapterNumber,
            verseReference: verseReference
        )
    }

    @MainActor
    private func loadBooks() async {
        guard !translationID.isEmpty else {
            books = []
            return
        }
        let requestedTranslationID = translationID
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

    @MainActor
    private func loadChapter() async {
        guard !translationID.isEmpty, bookNumber > 0, selectedBook != nil else {
            verses = []
            return
        }
        let requestedLoadID = chapterLoadID
        isLoadingChapter = true
        errorMessage = nil
        do {
            let loaded = try await model.library.chapter(
                moduleID: translationID,
                bookNumber: bookNumber,
                chapterNumber: chapterNumber
            )
            guard chapterLoadID == requestedLoadID else { return }
            verses = loaded.verses
            if let verseReference,
               !loaded.verses.contains(where: { $0.id == verseReference }) {
                self.verseReference = nil
            }
        } catch {
            guard chapterLoadID == requestedLoadID else { return }
            verses = []
            errorMessage = error.localizedDescription
        }
        if chapterLoadID == requestedLoadID { isLoadingChapter = false }
    }

    private func clampChapterNumber() {
        guard let selectedBook else {
            chapterNumber = 1
            return
        }
        chapterNumber = min(max(chapterNumber, 1), selectedBook.chapterCount)
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

    var id: Self { self }

    var title: String {
        switch self {
        case .versePerLine: "Verse per Line"
        case .continuousParagraphs: "Continuous Paragraph Flow"
        }
    }

    var systemImage: String {
        switch self {
        case .versePerLine: "text.line.first.and.arrowtriangle.forward"
        case .continuousParagraphs: "text.justify.leading"
        }
    }
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

/// Reader scripture uses AppKit selection directly. SwiftUI's `.textSelection`
/// installs a `SelectionOverlay` that can enter an unbounded update loop when a
/// lazy scroll view materialises attributed text containing many metadata runs.
/// An ordinary non-editable `NSTextView` provides the same native selection and
/// contextual menu without involving that overlay.
private struct ReaderSelectableText: NSViewRepresentable {
    let attributedText: NSAttributedString
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openLink: openLink)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.linkTextAttributes = [:]
        textView.textStorage?.setAttributedString(attributedText)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.openLink = openLink
        guard textView.attributedString() != attributedText else { return }
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(attributedText)
        if selection.location != NSNotFound,
           NSMaxRange(selection) <= attributedText.length {
            textView.setSelectedRange(selection)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }

        // Measurement must be observational. Resizing the live text container
        // here causes NSTextView to invalidate its hosted size while SwiftUI's
        // LazyVStack is still asking for that size. The lazy stack then places
        // the row again, which measures it again, and so on without settling.
        // NSAttributedString's bounding calculation uses an independent layout
        // context and cannot feed back into the represented view.
        let bounds = attributedText.boundingRect(
            with: NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(
            width: width,
            height: max(ceil(bounds.height), 1)
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
                  isEffectivelyVisible(row) else { continue }
            let localPoint = row.convert(windowPoint, from: nil)
            guard row.visibleRect.insetBy(dx: -2, dy: -2).contains(localPoint) else { continue }
            if let hit = row.textHit(at: windowPoint, in: window) {
                return hit
            }
        }
        return nil
    }

    private func isEffectivelyVisible(_ view: NSView) -> Bool {
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

        private func contains(_ windowPoint: NSPoint) -> Bool {
            bounds.contains(convert(windowPoint, from: nil))
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

private struct ReaderLocationPickerPopover: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var isPresented: Bool
    @State private var translationID = ""
    @State private var books: [LampTranslationBook] = []
    @State private var bookNumber = 0
    @State private var chapterNumber = 1
    @State private var isLoadingBooks = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Choose Passage", systemImage: "books.vertical")
                    .font(.headline)
                Text("Changes apply when you press Done.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Label("Translation", systemImage: "text.book.closed")
                    Picker("Translation", selection: $translationID) {
                        ForEach(model.translations) { translation in
                            Text(translation.name).tag(translation.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }

                GridRow {
                    Label("Book", systemImage: "book.closed")
                    Picker("Book", selection: $bookNumber) {
                        if books.isEmpty {
                            Text(isLoadingBooks ? "Loading Books…" : "Choose a Book")
                                .tag(0)
                        }
                        ForEach(books) { book in
                            Text(book.name).tag(book.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .disabled(books.isEmpty || isLoadingBooks)
                }

                GridRow {
                    Label("Chapter", systemImage: "number")
                    Picker("Chapter", selection: $chapterNumber) {
                        if let book = selectedBook {
                            ForEach(1...book.chapterCount, id: \.self) { chapter in
                                Text(chapter.formatted()).tag(chapter)
                            }
                        } else {
                            Text("—").tag(1)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .disabled(selectedBook == nil || isLoadingBooks)
                }
            }

            HStack {
                if isLoadingBooks {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading books…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Done") {
                    model.selectPassage(
                        translationID: translationID,
                        bookNumber: bookNumber,
                        chapterNumber: chapterNumber
                    )
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBook == nil || isLoadingBooks)
            }
        }
        .padding(18)
        .frame(width: 390)
        .onAppear { resetSelection() }
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
            chapterNumber = translationID == model.selectedTranslationID
                    && newValue == model.selectedBookNumber
                ? model.selectedChapterNumber
                : 1
            clampChapterNumber()
        }
        .task(id: translationID) { await loadBooks() }
    }

    private var selectedBook: LampTranslationBook? {
        books.first { $0.id == bookNumber }
    }

    private func resetSelection() {
        translationID = model.selectedTranslationID ?? model.translations.first?.id ?? ""
        books = translationID == model.selectedTranslationID ? model.books : []
        bookNumber = model.selectedBookNumber ?? books.first?.id ?? 0
        chapterNumber = model.selectedChapterNumber
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
        if requestedTranslationID == model.selectedTranslationID, !model.books.isEmpty {
            books = model.books
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

private struct TranslationReaderView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var scrollLink: ReaderScrollLink
    @AppStorage("reader.fontSize") private var fontSize = LampTextScale.readerText.defaultValue
    @AppStorage("reader.lineSpacing") private var lineSpacing = LampTextScale.readerLineSpacing.defaultValue
    @AppStorage("reader.typeface") private var typeface = ProseTypeface.readerDefault
    @AppStorage("reader.layoutMode") private var readerLayoutMode = ReaderLayoutMode.continuousParagraphs
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
    @State private var showingReaderLocationPicker = false
    @State private var highlightVerse: LampVerse?
    @State private var planReadingChapters: [LampChapter] = []
    @State private var loadedPlanReadingRequest: PlanReadingChapterRequest?
    @State private var isLoadingPlanReading = false
    @State private var planReadingError: String?
    /// Set by the reader's own click handlers, so the selection they make does not
    /// come back as an instruction to scroll to it.
    @State private var isSelectingVerseFromReader = false
    @State private var linkActivationGate = ReaderLinkActivationGate()
    @State private var paragraphAnchors = ReaderParagraphAnchorStore()
    @Namespace private var readerScrollCoordinateSpace
    @Binding var planReadingMode: PlanReadingMode?
    @Binding var showingStudyInspector: Bool
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
                                openReference: { model.openReference($0) }
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
        .toolbar { readerToolbar }
        .toolbar(removing: .title)
        .focusedObject(scrollLink)
        .sheet(item: $highlightVerse) { verse in
            VerseHighlightEditorView(verse: verse)
                .environmentObject(model)
        }
        .onChange(of: readAloud.currentReference) { _, reference in
            guard followReadAloud, let reference else { return }
            model.focusVerse(reference)
        }
        .onChange(of: model.selectedTranslationID) { _, _ in
            readAloud.stop()
            // Do not leave details from the previous translation visible while
            // the replacement passage is loading. The new passage opts back in
            // after confirming it contains Strong's annotations.
            lexicalHoverStore.configure(isDetailsEnabled: false)
        }
        .onChange(of: model.selectedBookNumber) { _, _ in readAloud.stop() }
        .onChange(of: model.selectedChapterNumber) { _, _ in readAloud.stop() }
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
            } else if let planReadingError, !isLoadingPlanReading {
                ContentUnavailableView(
                    "Reading Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(planReadingError)
                )
            } else {
                ProgressView("Loading Reading…")
            }
        } else if let chapter = model.chapter {
            passageView([chapter])
                .id("\(chapter.book.id):\(chapter.number)")
        } else if model.isLoadingChapter {
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
        guard let translationID = model.selectedTranslationID,
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
        return model.chapter.map { [$0] } ?? []
    }

    private func loadPlanReadingChapters(for request: PlanReadingChapterRequest?) async {
        guard let request else {
            planReadingChapters = []
            loadedPlanReadingRequest = nil
            isLoadingPlanReading = false
            planReadingError = nil
            return
        }
        if loadedPlanReadingRequest == request, !planReadingChapters.isEmpty { return }

        isLoadingPlanReading = true
        planReadingError = nil
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
            planReadingChapters = loaded
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
        model.openReference(reading.startReference)
    }

    private var activePlanReadingIndex: Int? {
        guard let mode = planReadingMode else { return nil }
        return mode.readings.firstIndex { $0.id == mode.activeReadingID }
    }

    private var canNavigateReaderBackward: Bool {
        if planReadingMode != nil {
            return activePlanReadingIndex.map { $0 > 0 } ?? false
        }
        return model.canNavigateBackward
    }

    private var canNavigateReaderForward: Bool {
        if let mode = planReadingMode {
            return activePlanReadingIndex.map { $0 < mode.readings.index(before: mode.readings.endIndex) } ?? false
        }
        return model.canNavigateForward
    }

    private var canNavigateBookBackward: Bool {
        guard planReadingMode == nil,
              let bookNumber = model.selectedBookNumber,
              let index = model.books.firstIndex(where: { $0.id == bookNumber }) else { return false }
        return index > model.books.startIndex
    }

    private var canNavigateBookForward: Bool {
        guard planReadingMode == nil,
              let bookNumber = model.selectedBookNumber,
              let index = model.books.firstIndex(where: { $0.id == bookNumber }) else { return false }
        return index < model.books.index(before: model.books.endIndex)
    }

    private var backwardNavigationTitle: String {
        planReadingMode == nil ? "Previous Chapter" : "Previous Plan Reading"
    }

    private var forwardNavigationTitle: String {
        planReadingMode == nil ? "Next Chapter" : "Next Plan Reading"
    }

    private func navigateReaderBackward() {
        guard let mode = planReadingMode else {
            model.navigateBackward()
            return
        }
        guard let index = activePlanReadingIndex, index > mode.readings.startIndex else { return }
        openPlanReading(mode.readings[mode.readings.index(before: index)])
    }

    private func navigateReaderForward() {
        guard let mode = planReadingMode else {
            model.navigateForward()
            return
        }
        guard let index = activePlanReadingIndex,
              index < mode.readings.index(before: mode.readings.endIndex) else { return }
        openPlanReading(mode.readings[mode.readings.index(after: index)])
    }

    private func navigateBookBackward() {
        guard canNavigateBookBackward,
              let bookNumber = model.selectedBookNumber,
              let index = model.books.firstIndex(where: { $0.id == bookNumber }) else { return }
        model.selectBook(model.books[model.books.index(before: index)].id)
    }

    private func navigateBookForward() {
        guard canNavigateBookForward,
              let bookNumber = model.selectedBookNumber,
              let index = model.books.firstIndex(where: { $0.id == bookNumber }) else { return }
        model.selectBook(model.books[model.books.index(after: index)].id)
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
                                    showsInstantDetails: showsInstantDetails
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
                    .frame(maxWidth: 780, alignment: .leading)
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
                          readerLayoutMode == .versePerLine else { return }
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
                .onChange(of: model.selectedVerseReference) { _, _ in
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
                // Settle back onto the verse the reader was showing before a side
                // panel changed its width. The passage re-wraps at the new width,
                // so without this the reading position drifts by however much the
                // text above it grew or shrank.
                .coordinateSpace(name: readerScrollCoordinateSpace)
                .overlay {
                    ReaderLexicalHoverObserver(
                        interactionStore: lexicalHoverStore
                    )
                        .frame(width: viewport.size.width, height: viewport.size.height)
                }
        }
        }
    }

    @ViewBuilder
    private func readerChapterSection(
        _ chapter: LampChapter,
        isFirst: Bool,
        showsInstantDetails: Bool
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

        if readerLayoutMode == .versePerLine {
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
            ReaderSelectableText(
                attributedText: continuousText(for: paragraph.verses),
                openLink: { _ = handleReaderLink($0) }
            )
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

    private func continuousText(for verses: [LampVerse]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, verse) in verses.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " ", attributes: bodyTextAttributes()))
            }
            result.append(verseMarkerText(for: verse))
            result.append(verseBodyText(for: verse))
        }
        return result
    }

    private func verseMarkerText(for verse: LampVerse) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let verseURL = readerVerseURL(reference: verse.id)
        let isSelected = model.selectedVerseReference == verse.id

        var numberAttributes = markerTextAttributes(
            size: max(fontSize * 0.58, 10),
            weight: .semibold,
            color: isSelected ? .controlAccentColor : .secondaryLabelColor,
            baselineOffset: max(fontSize * 0.28, 4)
        )
        numberAttributes[.link] = verseURL
        result.append(NSAttributedString(
            string: verse.number.formatted(),
            attributes: numberAttributes
        ))

        if verse.hasFootnotes {
            var attributes = markerTextAttributes(
                size: max(fontSize * 0.55, 10),
                weight: .bold,
                color: .controlAccentColor,
                baselineOffset: max(fontSize * 0.32, 5)
            )
            attributes[.link] = verseURL
            result.append(NSAttributedString(string: "*", attributes: attributes))
        }

        if model.hasPersonalNote(for: verse.id) {
            var attributes = markerTextAttributes(
                size: max(fontSize * 0.48, 9),
                weight: .semibold,
                color: .systemOrange,
                baselineOffset: max(fontSize * 0.28, 4)
            )
            attributes[.link] = verseURL
            result.append(NSAttributedString(string: "✎", attributes: attributes))
        }

        if model.hasInstalledNote(for: verse.id) {
            var attributes = markerTextAttributes(
                size: max(fontSize * 0.43, 8),
                weight: .semibold,
                color: .systemPurple,
                baselineOffset: max(fontSize * 0.28, 4)
            )
            attributes[.link] = verseURL
            result.append(NSAttributedString(string: "▣", attributes: attributes))
        }

        result.append(NSAttributedString(string: " ", attributes: bodyTextAttributes()))
        return result
    }

    @ViewBuilder
    private func renderedVerseText(for verse: LampVerse) -> some View {
        if let poetryRange = partialPoetryRange(for: verse) {
            VStack(alignment: .leading, spacing: 4) {
                ReaderSelectableText(
                    attributedText: verseText(
                        for: verse,
                        range: ReaderTextRange(startOffset: 0, endOffset: poetryRange.startOffset),
                        includesMarker: true
                    ),
                    openLink: { _ = handleReaderLink($0) }
                )

                ReaderSelectableText(
                    attributedText: verseBodyText(for: verse, range: poetryRange),
                    openLink: { _ = handleReaderLink($0) }
                )
                    .padding(.leading, poetryIndent(for: verse))

                if poetryRange.endOffset < verse.text.count {
                    ReaderSelectableText(
                        attributedText: verseBodyText(
                            for: verse,
                            range: ReaderTextRange(
                                startOffset: poetryRange.endOffset,
                                endOffset: verse.text.count
                            )
                        ),
                        openLink: { _ = handleReaderLink($0) }
                    )
                }
            }
        } else {
            ReaderSelectableText(
                attributedText: continuousText(for: [verse]),
                openLink: { _ = handleReaderLink($0) }
            )
        }
    }

    private func verseText(
        for verse: LampVerse,
        range: ReaderTextRange? = nil,
        includesMarker: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        if includesMarker {
            result.append(verseMarkerText(for: verse))
        }
        result.append(verseBodyText(for: verse, range: range))
        return result
    }

    private func verseBodyText(
        for verse: LampVerse,
        range: ReaderTextRange? = nil
    ) -> NSAttributedString {
        let text = styledText(for: verse)
        guard let range else { return text }

        let characterIndices = Array(verse.text.indices) + [verse.text.endIndex]
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
        return text.attributedSubstring(from: nativeRange)
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
              }) ?? model.chapter else { return }
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
            prepareChapterForStudy(reference: reference)
            model.focusVerse(reference)
            selectedStudyTab = "verse"
            showingStudyInspector = true
            return
        }
        openVerseStudy(verse)
    }

    private func prepareChapterForStudy(reference: Int) {
        guard model.chapter?.verses.contains(where: { $0.id == reference }) != true else { return }
        model.openReference(reference)
    }

    private func readerVerseURL(reference: Int) -> URL? {
        URL(string: "lamp-bible-verse://\(reference)")
    }

    private func readerVerseReference(from url: URL) -> Int? {
        guard url.scheme == "lamp-bible-verse", let host = url.host else { return nil }
        return Int(host)
    }

    private func styledText(for verse: LampVerse) -> NSAttributedString {
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
                    value: NSColor.systemRed.withAlphaComponent(0.82),
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

        for highlight in model.highlights(for: verse.id) {
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
        let systemFont = NSFont.systemFont(ofSize: size, weight: weight)
        let designedFont: NSFont
        if typeface == .serif,
           let descriptor = systemFont.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            designedFont = font
        } else {
            designedFont = systemFont
        }
        guard !traits.isEmpty else { return designedFont }
        return NSFontManager.shared.convert(designedFont, toHaveTrait: traits)
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
    /// Distinct from `model.focusVerse` on purpose: a selection made *here* must
    /// not scroll the reader to the verse, because the verse is already on screen
    /// under the pointer. Selections from elsewhere — search, history, read-aloud,
    /// a cross-reference — still scroll, because there the verse may be anywhere.
    private func selectVerseFromReader(_ reference: Int) {
        isSelectingVerseFromReader = true
        model.focusVerse(reference)
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
        let isReaderLink = readerVerseReference(from: url) != nil || LexiconLookupLink(url: url) != nil
        guard isReaderLink else { return false }
        guard linkActivationGate.shouldActivate(url, at: ProcessInfo.processInfo.systemUptime) else {
            return true
        }

        if let reference = readerVerseReference(from: url) {
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
        guard let reference = model.selectedVerseReference else { return }
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
                .disabled(!canNavigateBookBackward || model.isLoadingChapter || isLoadingPlanReading)
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .help("Previous Book")
                .accessibilityLabel("Previous Book")

                Button {
                    navigateReaderBackward()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canNavigateReaderBackward || model.isLoadingChapter || isLoadingPlanReading)
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
                .help("Choose translation, book, or chapter")
                .popover(isPresented: $showingReaderLocationPicker, arrowEdge: .bottom) {
                    ReaderLocationPickerPopover(isPresented: $showingReaderLocationPicker)
                        .environmentObject(model)
                }

                Button {
                    navigateReaderForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canNavigateReaderForward || model.isLoadingChapter || isLoadingPlanReading)
                .keyboardShortcut("]", modifiers: .command)
                .help(forwardNavigationTitle)
                .accessibilityLabel(forwardNavigationTitle)

                Button {
                    navigateBookForward()
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .disabled(!canNavigateBookForward || model.isLoadingChapter || isLoadingPlanReading)
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .help("Next Book")
                .accessibilityLabel("Next Book")
            }
            .controlSize(.regular)
        }

        ToolbarItemGroup(placement: .navigation) {
            Button("Back in Reading History", systemImage: "arrow.uturn.backward") {
                model.goBackInHistory()
            }
            .disabled(!model.canGoBackInHistory)
            .keyboardShortcut("[", modifiers: [.command, .option])

            Button("Forward in Reading History", systemImage: "arrow.uturn.forward") {
                model.goForwardInHistory()
            }
            .disabled(!model.canGoForwardInHistory)
            .keyboardShortcut("]", modifiers: [.command, .option])

            Menu("Reading History", systemImage: "clock.arrow.circlepath") {
                if model.recentReaderLocations.isEmpty {
                    Text("No Reading History")
                } else {
                    ForEach(model.recentReaderLocations, id: \.self) { location in
                        Button(historyLabel(location)) {
                            model.openHistoryLocation(location)
                        }
                    }
                    Divider()
                    Button("Clear History", role: .destructive) {
                        model.clearNavigationHistory()
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }

        ToolbarItemGroup {
            Menu("Reader Appearance", systemImage: "textformat") {
                Picker("Layout", selection: $readerLayoutMode) {
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
                Section("Verse markers") {
                    Text("Blue * — translation note")
                    Text("Orange ✎ — personal note")
                    Text("Purple ▣ — study note")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose the reader layout, typeface, text size, and verse markers")

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
                if model.selectedVerseReference != nil {
                    Button("Read from Selected Verse", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        startReadAloud(at: model.selectedVerseReference)
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
        let book = model.selectedBook?.name ?? "Book"
        return "\(translation) \u{00B7} \(book) \(model.selectedChapterNumber)"
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
            startingAt: model.selectedVerseReference,
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

private struct TranslationSearchView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var query = ""
    @State private var translationID: String?
    let showImporter: () -> Void
    let openResult: (LampTranslationSearchResult) -> Void

    var body: some View {
        Group {
            if model.translations.isEmpty {
                ContentUnavailableView {
                    Label("No Translation Installed", systemImage: "magnifyingglass")
                } description: {
                    Text("Install a translation before searching scripture.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Search Scripture",
                    systemImage: "text.magnifyingglass",
                    description: Text("Search every installed translation or narrow the search from the toolbar.")
                )
            } else if model.isSearching && model.searchResults.isEmpty {
                ProgressView("Searching…")
            } else if model.searchResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(model.searchResults) { result in
                    Button {
                        openResult(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text(result.displayReference)
                                    .font(.headline)
                                Text(result.translationAbbreviation ?? result.translationName)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                Spacer()
                            }
                            Text(result.text)
                                .font(.system(size: 16, design: .serif))
                                .lineLimit(3)
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open \(result.displayReference)") {
                            openResult(result)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Search scripture")
        .onChange(of: query) { _, newValue in
            model.search(newValue, translationID: translationID)
        }
        .onChange(of: translationID) { _, _ in
            model.search(query, translationID: translationID)
        }
        .toolbar {
            ToolbarItem {
                Picker("Translation", selection: $translationID) {
                    Text("All Translations").tag(String?.none)
                    ForEach(model.translations) { translation in
                        Text(translation.abbreviation ?? translation.name)
                            .tag(Optional(translation.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 150)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isSearching && !model.searchResults.isEmpty {
                ProgressView("Updating Results…")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .padding()
            }
        }
    }
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
            Text("This removes the installed copy of \(module.name). Your original .lamp file is not affected.")
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
