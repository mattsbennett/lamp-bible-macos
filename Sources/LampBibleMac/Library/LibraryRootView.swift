import AppKit
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
    case devotionals = "Devotionals"
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
        case .plans: "Reading Plans"
        case .devotionals: "Devotionals"
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
    @State private var isStudyInspectorRevealed = false
    @State private var isStudyInspectorSpaceReserved = false
    @State private var isStudyInspectorContentReady = false
    @State private var planReadingMode: PlanReadingMode?
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
        .task { await syncController.syncAutomaticallyIfNeeded(library: model.library) }
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
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Install Module…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        showingStudyDataImporter = true
                    } label: {
                        Label("Import Study Data…", systemImage: "arrow.up.arrow.down.square")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        openWindow(id: "module-studio")
                    } label: {
                        Label("Module Studio", systemImage: "hammer")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
        guard let deepLink = LampDeepLink(url: url) else { return }
        switch deepLink {
        case .reader(let reference, let translationID):
            model.openReference(reference, translationID: translationID)
            selection = .section(.reader)
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
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        TranslationReaderView(
                            planReadingMode: $planReadingMode,
                            showingStudyInspector: $showingStudyInspector,
                            showImporter: { showingImporter = true }
                        )
                        .frame(maxWidth: .infinity)

                        if isStudyInspectorSpaceReserved {
                            Color.clear
                                .frame(width: StudyInspectorMetrics.totalWidth(studyInspectorWidth))
                        }
                    }

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
                        .offset(
                            x: isStudyInspectorRevealed
                                ? 0
                                : StudyInspectorMetrics.totalWidth(studyInspectorWidth)
                        )
                        .allowsHitTesting(isStudyInspectorRevealed)
                    }
                }
                .clipped()
                .task(id: showingStudyInspector) {
                    let duration = 0.22
                    if showingStudyInspector {
                        isStudyInspectorMounted = true
                        isStudyInspectorContentReady = false
                        await Task.yield()
                        guard !Task.isCancelled, showingStudyInspector else { return }

                        withAnimation(.smooth(duration: duration)) {
                            isStudyInspectorRevealed = true
                        }
                        do {
                            try await Task.sleep(for: .seconds(duration))
                        } catch {
                            return
                        }
                        guard showingStudyInspector else { return }

                        // Reserve the column in one non-animated layout pass after
                        // the overlay has covered that part of the reader.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            isStudyInspectorSpaceReserved = true
                        }
                        await Task.yield()
                        guard !Task.isCancelled, showingStudyInspector else { return }
                        isStudyInspectorContentReady = true
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            isStudyInspectorSpaceReserved = false
                        }
                        withAnimation(.smooth(duration: duration)) {
                            isStudyInspectorRevealed = false
                        }
                        do {
                            try await Task.sleep(for: .seconds(duration))
                        } catch {
                            return
                        }
                        guard !showingStudyInspector else { return }
                        isStudyInspectorMounted = false
                        isStudyInspectorContentReady = false
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
                    Text("\(mode.planName) · Day \(mode.day)")
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
}

private struct PlanReadingQuizPanel: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
    let mode: PlanReadingMode
    let close: () -> Void
    let openReference: (Int) -> Void
    @State private var selectedQuizID: String?
    @State private var selectedAgeGroupID: String?
    @State private var questions: [LampQuizQuestion] = []
    @State private var revealedAnswers: Set<Int64> = []
    @State private var isLoading = false

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
        .onChange(of: selectedAgeGroupID) { _, ageGroupID in
            if let ageGroupID { defaultQuizAgeGroup = ageGroupID }
        }
        .task(id: loadKey) { await loadQuestions() }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(question.readingDescription) {
                    openReference(question.startReference)
                }
                .buttonStyle(.link)
                Spacer()
                if question.isChristFocused {
                    Label("Christ-focused", systemImage: "star.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help("Christ-focused question")
                }
            }

            Text(question.question)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)

            if revealedAnswers.contains(question.id) {
                Divider()
                Text(question.answer)
                    .textSelection(.enabled)
                let references = Array(Set(question.references + question.crossReferences)).sorted()
                if !references.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(references, id: \.self) { reference in
                                Button(LampBibleReferenceFormatter.describeRange(from: reference, to: reference)) {
                                    openReference(reference)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }

            Button(revealedAnswers.contains(question.id) ? "Hide Answer" : "Reveal Answer") {
                if revealedAnswers.contains(question.id) {
                    revealedAnswers.remove(question.id)
                } else {
                    revealedAnswers.insert(question.id)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(13)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.4))
        }
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

private enum ReaderLayoutMode: String, CaseIterable, Identifiable {
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

private struct ReaderParagraph: Identifiable {
    let verses: [LampVerse]

    var id: Int { verses[0].id }
    var firstVerse: LampVerse { verses[0] }
}

private struct ReaderParagraphFrame: Equatable {
    let reference: Int
    let frame: CGRect
}

private struct ReaderParagraphFramesKey: PreferenceKey {
    static var defaultValue: [ReaderParagraphFrame] { [] }

    static func reduce(
        value: inout [ReaderParagraphFrame],
        nextValue: () -> [ReaderParagraphFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct ReaderPassageChapter: Identifiable {
    let chapter: LampChapter

    var id: String {
        "reader-chapter:\(chapter.translationID):\(chapter.book.id):\(chapter.number)"
    }
}

private struct PlanReadingChapterRequest: Equatable, Hashable {
    let translationID: String
    let readingID: Int
    let startReference: Int
    let endReference: Int
}

private struct ReaderContextMenuEntry {
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

/// SwiftUI's selectable Text owns the native contextual menu. Observe the contextual
/// click without intercepting it, then add reader actions to that same menu when it
/// begins tracking.
private struct ReaderNativeContextMenuAugmenter: NSViewRepresentable {
    let entries: [ReaderContextMenuEntry]

    func makeCoordinator() -> Coordinator { Coordinator(entries: entries) }

    func makeNSView(context: Context) -> ContextMenuObservationView {
        let view = ContextMenuObservationView()
        view.menuAugmenter = context.coordinator.augment(menu:)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ContextMenuObservationView, context: Context) {
        context.coordinator.entries = entries
        view.menuAugmenter = context.coordinator.augment(menu:)
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
        private var eventMonitor: Any?
        private var hasPendingContextClick = false
        private var pendingContextClickGeneration = 0

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
                self?.observeContextualClick(event)
                return event
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func observeContextualClick(_ event: NSEvent) {
            guard let window,
                  event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else {
                return
            }

            hasPendingContextClick = true
            pendingContextClickGeneration &+= 1
            let generation = pendingContextClickGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard self?.pendingContextClickGeneration == generation else { return }
                self?.hasPendingContextClick = false
            }
        }

        @objc private func menuDidBeginTracking(_ notification: Notification) {
            guard hasPendingContextClick,
                  let menu = notification.object as? NSMenu else { return }
            hasPendingContextClick = false
            menuAugmenter?(menu)
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
    @State private var showingReaderLocationPicker = false
    @State private var highlightVerse: LampVerse?
    @State private var planReadingChapters: [LampChapter] = []
    @State private var loadedPlanReadingRequest: PlanReadingChapterRequest?
    @State private var isLoadingPlanReading = false
    @State private var planReadingError: String?
    @Namespace private var readerScrollCoordinateSpace
    @Binding var planReadingMode: PlanReadingMode?
    @Binding var showingStudyInspector: Bool
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

            HStack(spacing: 0) {
                readerContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showingPlanQuiz, let planReadingMode {
                    Divider()
                    PlanReadingQuizPanel(
                        mode: planReadingMode,
                        close: { showingPlanQuiz = false },
                        openReference: { model.openReference($0) }
                    )
                    .frame(width: 410)
                }
            }
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
        .onChange(of: model.selectedTranslationID) { _, _ in readAloud.stop() }
        .onChange(of: model.selectedBookNumber) { _, _ in readAloud.stop() }
        .onChange(of: model.selectedChapterNumber) { _, _ in readAloud.stop() }
        .onChange(of: planReadingMode) { _, mode in
            if mode == nil { showingPlanQuiz = false }
        }
        .task(id: planReadingChapterRequest) {
            await loadPlanReadingChapters(for: planReadingChapterRequest)
        }
        .onDisappear { readAloud.stop() }
        .environment(\.openURL, OpenURLAction { url in
            if let reference = readerVerseReference(from: url) {
                openVerseStudy(reference: reference)
                return .handled
            }
            guard let lookup = LexiconLookupLink(url: url) else { return .systemAction }
            openLexicon(lookup)
            return .handled
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
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        readerChapterSection(
                            section.chapter,
                            isFirst: section.id == sections.first?.id
                        )
                    }
                }
                // The two modes intentionally reuse verse references as scroll
                // targets. Give the container a new identity when switching so
                // SwiftUI cannot reuse a whole paragraph for a single-verse row.
                .id(readerLayoutMode)
                .scrollTargetLayout()
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.vertical, 42)
                .frame(maxWidth: .infinity)
            }
            // A new passage gets a fresh scroll container at its natural zero
            // offset, including the padding above the book heading.
            .id(passageIdentity)
            .onScrollTargetVisibilityChange(idType: Int.self) { visible in
                guard readerLayoutMode == .versePerLine else { return }
                scrollLink.readerDidScroll(to: visible.min())
            }
            .onPreferenceChange(ReaderParagraphFramesKey.self) { frames in
                guard readerLayoutMode == .continuousParagraphs else { return }
                scrollLink.readerDidScroll(to: continuousReaderReference(
                    in: frames,
                    chapters: chapters
                ))
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                if !oldPhase.isUserDriven, newPhase.isUserDriven {
                    scrollLink.readerUserScrollDidBegin()
                }
                guard oldPhase.isScrolling,
                      !newPhase.isScrolling,
                      readerReachedBottom(context.geometry) else { return }
                completeActivePlanReading()
            }
            .onReceive(scrollLink.toolAnchors) { reference in
                proxy.scrollTo(scrollTarget(for: reference, in: chapters), anchor: .top)
            }
            .onAppear { scrollToReaderLocation(proxy, chapters: chapters) }
            .onChange(of: model.selectedVerseReference) { _, _ in
                scrollToReaderLocation(proxy, chapters: chapters)
            }
            .onChange(of: passageIdentity) { _, _ in
                scrollLink.reset()
            }
            .onChange(of: readerLayoutMode) { _, _ in
                scrollLink.reset()
                scrollToReaderLocation(proxy, chapters: chapters)
            }
            .coordinateSpace(name: readerScrollCoordinateSpace)
        }
    }

    @ViewBuilder
    private func readerChapterSection(_ chapter: LampChapter, isFirst: Bool) -> some View {
        let headingsByVerse = Dictionary(grouping: chapter.headings, by: \.beforeVerse)
        VStack(alignment: .leading, spacing: 5) {
            Text(chapter.book.name)
                .font(.largeTitle.bold())
            Text("Chapter \(chapter.number)")
                .font(.title2)
                .foregroundStyle(.secondary)
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
                    verseRow(verse)
                }
                .id(verse.id)
            }
        } else {
            ForEach(continuousParagraphs(in: chapter)) { paragraph in
                VStack(alignment: .leading, spacing: 0) {
                    readerHeadings(headingsByVerse[paragraph.firstVerse.number] ?? [])
                    continuousParagraph(paragraph)
                }
                .id(paragraph.id)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ReaderParagraphFramesKey.self,
                            value: [ReaderParagraphFrame(
                                reference: paragraph.id,
                                frame: geometry.frame(in: .named(readerScrollCoordinateSpace))
                            )]
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readerHeadings(_ headings: [LampHeading]) -> some View {
        ForEach(headings) { heading in
            Text(heading.text)
                .font(heading.level == 1 ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .padding(.top, heading.level == 1 ? 26 : 18)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func continuousParagraph(_ paragraph: ReaderParagraph) -> some View {
        continuousParagraphText(paragraph)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, continuousTopPadding(for: paragraph.firstVerse))
            .padding(.leading, paragraphIndent(for: paragraph))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                ReaderNativeContextMenuAugmenter(entries: paragraphContextMenuEntries(paragraph))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    @ViewBuilder
    private func continuousParagraphText(_ paragraph: ReaderParagraph) -> some View {
        if paragraph.verses.count == 1, let verse = paragraph.verses.first {
            renderedVerseText(for: verse)
        } else {
            continuousText(for: paragraph.verses)
        }
    }

    private func paragraphIndent(for paragraph: ReaderParagraph) -> CGFloat {
        guard partialPoetryRange(for: paragraph.firstVerse) == nil else { return 0 }
        return poetryIndent(for: paragraph.firstVerse)
    }

    private func continuousParagraphs(in chapter: LampChapter) -> [ReaderParagraph] {
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

    private func continuousReaderReference(
        in frames: [ReaderParagraphFrame],
        chapters: [LampChapter]
    ) -> Int? {
        guard let visibleFrame = frames
            .filter({ $0.frame.maxY > 0 })
            .min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        let paragraphs = chapters
            .flatMap(continuousParagraphs(in:))
        guard let paragraph = paragraphs.first(where: { $0.id == visibleFrame.reference }) else {
            return visibleFrame.reference
        }

        let height = max(visibleFrame.frame.height, 1)
        let progress = -visibleFrame.frame.minY / height
        let segments = paragraph.verses.map { verse in
            ReaderParagraphSegment(
                reference: verse.id,
                characterCount: verse.text.count + String(verse.number).count + 1
            )
        }
        return ReaderParagraphAnchorResolver.reference(at: progress, in: segments)
    }

    private func continuousText(for verses: [LampVerse]) -> Text {
        var result = Text("")
        for (index, verse) in verses.enumerated() {
            if index > 0 { result = result + Text(" ") }
            result = result + verseMarkerText(for: verse)
            result = result + verseBodyText(for: verse)
        }
        return result
    }

    private func verseMarkerText(for verse: LampVerse) -> Text {
        var result = Text("")
        let verseURL = readerVerseURL(reference: verse.id)
        let isSelected = model.selectedVerseReference == verse.id

        var number = AttributedString(verse.number.formatted())
        number.font = .system(size: max(fontSize * 0.58, 10), weight: .semibold)
        number.foregroundColor = isSelected ? .accentColor : .secondary
        number.baselineOffset = max(fontSize * 0.28, 4)
        number.link = verseURL
        result = result + Text(number)

        if verse.hasFootnotes {
            var marker = AttributedString("*")
            marker.font = .system(size: max(fontSize * 0.55, 10), weight: .bold)
            marker.foregroundColor = .accentColor
            marker.baselineOffset = max(fontSize * 0.32, 5)
            marker.link = verseURL
            result = result + Text(marker)
        }

        if model.hasPersonalNote(for: verse.id) {
            var marker = AttributedString("✎")
            marker.font = .system(size: max(fontSize * 0.48, 9), weight: .semibold)
            marker.foregroundColor = .orange
            marker.baselineOffset = max(fontSize * 0.28, 4)
            marker.link = verseURL
            result = result + Text(marker)
        }

        if model.hasInstalledNote(for: verse.id) {
            var marker = AttributedString("▣")
            marker.font = .system(size: max(fontSize * 0.43, 8), weight: .semibold)
            marker.foregroundColor = .purple
            marker.baselineOffset = max(fontSize * 0.28, 4)
            marker.link = verseURL
            result = result + Text(marker)
        }

        return result + Text(" ")
    }

    @ViewBuilder
    private func renderedVerseText(for verse: LampVerse) -> some View {
        if let poetryRange = partialPoetryRange(for: verse) {
            VStack(alignment: .leading, spacing: 4) {
                verseMarkerText(for: verse)
                    + verseBodyText(
                        for: verse,
                        range: ReaderTextRange(startOffset: 0, endOffset: poetryRange.startOffset)
                    )

                verseBodyText(
                    for: verse,
                    range: poetryRange
                )
                .padding(.leading, poetryIndent(for: verse))

                if poetryRange.endOffset < verse.text.count {
                    verseBodyText(
                        for: verse,
                        range: ReaderTextRange(
                            startOffset: poetryRange.endOffset,
                            endOffset: verse.text.count
                        )
                    )
                }
            }
        } else {
            continuousText(for: [verse])
        }
    }

    private func verseBodyText(
        for verse: LampVerse,
        range: ReaderTextRange? = nil
    ) -> Text {
        let text = styledText(for: verse)
        guard let range else { return Text(text) }

        let characterIndices = Array(verse.text.indices) + [verse.text.endIndex]
        guard range.startOffset >= 0,
              range.endOffset > range.startOffset,
              range.endOffset < characterIndices.count,
              let start = AttributedString.Index(characterIndices[range.startOffset], within: text),
              let end = AttributedString.Index(characterIndices[range.endOffset], within: text) else {
            return Text("")
        }
        return Text(AttributedString(text[start..<end]))
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
        return geometry.visibleRect.maxY >= geometry.contentSize.height - 8
    }

    @ViewBuilder
    private func verseRow(_ verse: LampVerse) -> some View {
        renderedVerseText(for: verse)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, topPadding(for: verse))
            .padding(.leading, partialPoetryRange(for: verse) == nil ? poetryIndent(for: verse) : 0)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(verseStudyHelp(verse))
            .overlay {
                ReaderNativeContextMenuAugmenter(entries: verseContextMenuEntries(verse))
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
            model.focusVerse(verse.id)
            selectedStudyTab = "notes"
            showingStudyInspector = true
        })
        entries.append(.action("Show Study Tools", systemImage: "sidebar.trailing") {
            prepareChapterForStudy(reference: verse.id)
            model.focusVerse(verse.id)
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
        model.focusVerse(verse.id)
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

    private func styledText(for verse: LampVerse) -> AttributedString {
        var result = AttributedString(verse.text)
        result.font = .system(size: fontSize, design: typeface.design)

        // `index(startIndex, offsetBy:)` walks the string from the front every
        // time it is asked, and a densely tagged verse asks once per annotation
        // per pass. One walk up front turns each of those into a subscript.
        let characterIndices = Array(verse.text.indices) + [verse.text.endIndex]

        func attributedRange(
            from startOffset: Int,
            to endOffset: Int,
            in string: AttributedString
        ) -> Range<AttributedString.Index>? {
            guard startOffset >= 0,
                  endOffset > startOffset,
                  endOffset < characterIndices.count,
                  let start = AttributedString.Index(characterIndices[startOffset], within: string),
                  let end = AttributedString.Index(characterIndices[endOffset], within: string) else {
                return nil
            }
            return start..<end
        }

        for annotation in verse.annotations {
            guard let range = attributedRange(
                from: annotation.startOffset,
                to: annotation.endOffset,
                in: result
            ) else { continue }

            switch annotation.kind {
            case "red-letter":
                result[range].foregroundColor = .red.opacity(0.82)
            case "added", "selah":
                result[range].font = .system(size: fontSize, design: typeface.design).italic()
            case "divine-name":
                result[range].font = .system(size: fontSize, design: typeface.design).weight(.semibold).smallCaps()
            case "variant":
                result[range].underlineStyle = .single
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
            let keys = annotations.compactMap(\.strongs)
            guard annotationRange.start >= 0,
                  annotationRange.end > annotationRange.start,
                  annotationRange.end < characterIndices.count else { continue }
            let word = String(
                verse.text[characterIndices[annotationRange.start]..<characterIndices[annotationRange.end]]
            )
            guard let lookup = LexiconLookupLink(keys: keys, reference: verse.id, word: word),
                  let url = lookup.url,
                  let range = attributedRange(
                      from: annotationRange.start,
                      to: annotationRange.end,
                      in: result
                  ) else { continue }
            result[range].link = url
            let overlapsRedLetter = verse.annotations.contains { annotation in
                annotation.kind == "red-letter"
                    && annotation.startOffset < annotationRange.end
                    && annotation.endOffset > annotationRange.start
            }
            if !overlapsRedLetter {
                result[range].foregroundColor = .primary
            }
        }

        for highlight in model.highlights(for: verse.id) {
            let startOffset = min(max(highlight.startOffset, 0), verse.text.count)
            let endOffset = min(max(highlight.endOffset, startOffset), verse.text.count)
            guard let range = attributedRange(from: startOffset, to: endOffset, in: result) else { continue }
            let color = Color(lampHex: highlight.color ?? "FFCC00") ?? .yellow
            switch highlight.style {
            case .highlight:
                result[range].backgroundColor = color.opacity(0.34)
            case .underlineSolid, .underlineDashed, .underlineDotted:
                result[range].underlineStyle = .single
                result[range].foregroundColor = color
            }
        }
        return result
    }

    private func openLexicon(_ lookup: LexiconLookupLink) {
        model.focusVerse(lookup.reference)
        selectedStudyTab = "dictionary"
        showingStudyInspector = true
        model.requestDictionaryLookup(keys: lookup.keys, word: lookup.word)
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
    let showImporter: () -> Void

    var body: some View {
        Group {
            if model.modules.isEmpty {
                ContentUnavailableView {
                    Label("No Modules Installed", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Install .lamp translations, dictionaries, commentaries, reading plans, devotionals, quizzes, notes, and highlights.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    moduleSection("Translations", modules: model.modules.filter { $0.kind == .translation })
                    moduleSection("Dictionaries", modules: model.modules.filter { $0.kind == .dictionary })
                    moduleSection("Commentaries", modules: model.modules.filter { $0.kind == .commentary })
                    moduleSection("Reading Plans", modules: model.planModules)
                    moduleSection("Devotionals", modules: model.devotionalModules)
                    moduleSection("Quizzes", modules: model.quizModuleInstallations)
                    moduleSection("Notes", modules: model.noteModules)
                    moduleSection("Highlights", modules: model.highlightModules)
                }
            }
        }
        .navigationTitle("Modules")
        .toolbar {
            ToolbarItemGroup {
                Button("Install Module…", systemImage: "plus", action: showImporter)
                Button("Show Library in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(model.library.rootURL)
                }
            }
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
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                moduleToRemove = module
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        if !module.isBundled {
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
