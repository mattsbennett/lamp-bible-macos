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
    @State private var selection: LibrarySelection? = .section(.reader)
    @State private var showingImporter = false
    @State private var showingStudyDataImporter = false

    var body: some View {
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
        .onAppear { model.start() }
        .task { await syncController.syncAutomaticallyIfNeeded(library: model.library) }
        .onOpenURL { handleOpenURL($0) }
        .onChange(of: selection) { _, newValue in
            if case .translation(let moduleID) = newValue {
                model.selectTranslation(moduleID)
            }
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

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .section(.reader), .translation:
            TranslationReaderView(showImporter: { showingImporter = true })
        case .section(.today):
            TodayPlansView(
                showImporter: { showingImporter = true },
                showPlans: { selection = .section(.plans) },
                openReading: { reading in
                    model.openReading(reading)
                    selection = .section(.reader)
                }
            )
        case .section(.plans):
            ReadingPlansView(
                showImporter: { showingImporter = true },
                openReading: { reading in
                    model.openReading(reading)
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
                openKind: { kind in
                    switch kind {
                    case .devotional:
                        selection = .section(.devotionals)
                    case .plan:
                        selection = .section(.plans)
                    case .quiz:
                        selection = .section(.quizzes)
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

private struct TranslationReaderView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 7.0
    @AppStorage("reader.readAloud.voice") private var readAloudVoice = ""
    @AppStorage("reader.readAloud.rate") private var readAloudRate = 0.5
    @AppStorage("reader.readAloud.followAlong") private var followReadAloud = true
    @AppStorage("studyInspector.tab") private var selectedStudyTab = "commentary"
    @StateObject private var readAloud = ReadAloudController()
    @State private var showingStudyInspector = false
    @State private var highlightVerse: LampVerse?
    let showImporter: () -> Void

    var body: some View {
        Group {
            if model.translations.isEmpty {
                ContentUnavailableView {
                    Label("No Translation Installed", systemImage: "books.vertical")
                } description: {
                    Text("Install a translation .lamp module, or build one in Module Studio.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else if let chapter = model.chapter {
                chapterView(chapter)
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
        .navigationTitle(readerTitle)
        .toolbar { readerToolbar }
        .inspector(isPresented: $showingStudyInspector) {
            StudyInspectorView()
                .environmentObject(model)
        }
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
        .onDisappear { readAloud.stop() }
    }

    private var readerTitle: String {
        guard let chapter = model.chapter else { return "Reader" }
        return "\(chapter.book.name) \(chapter.number)"
    }

    private func chapterView(_ chapter: LampChapter) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(chapter.book.name)
                            .font(.largeTitle.bold())
                        Text("Chapter \(chapter.number)")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 28)
                    .id("chapter-top")

                    ForEach(chapter.verses) { verse in
                        let headings = chapter.headings.filter { $0.beforeVerse == verse.number }
                        ForEach(headings) { heading in
                            Text(heading.text)
                                .font(heading.level == 1 ? .title2.weight(.semibold) : .title3.weight(.semibold))
                                .padding(.top, heading.level == 1 ? 26 : 18)
                                .padding(.bottom, 10)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Button {
                                model.focusVerse(verse.id)
                                if model.hasPersonalNote(for: verse.id)
                                    || model.hasInstalledNote(for: verse.id) {
                                    selectedStudyTab = "notes"
                                } else if verse.hasFootnotes || verse.annotations.contains(where: { $0.strongs != nil }) {
                                    selectedStudyTab = "verse"
                                }
                                showingStudyInspector = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(verse.number.formatted())
                                    if verse.hasFootnotes {
                                        Image(systemName: "note.text")
                                            .font(.system(size: max(fontSize * 0.46, 9)))
                                            .foregroundStyle(.tint)
                                    }
                                    if model.hasPersonalNote(for: verse.id) {
                                        Image(systemName: "square.and.pencil")
                                            .font(.system(size: max(fontSize * 0.46, 9)))
                                            .foregroundStyle(.orange)
                                    }
                                    if model.hasInstalledNote(for: verse.id) {
                                        Image(systemName: "books.vertical")
                                            .font(.system(size: max(fontSize * 0.46, 9)))
                                            .foregroundStyle(.purple)
                                    }
                                }
                                .font(.system(size: max(fontSize * 0.58, 10), weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 24, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .help("Show study tools for verse \(verse.number)")
                            Text(styledText(for: verse))
                                .lineSpacing(lineSpacing)
                                .textSelection(.enabled)
                        }
                        .padding(.top, topPadding(for: verse))
                        .padding(.leading, poetryIndent(for: verse))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if model.selectedVerseReference == verse.id {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(.tint.opacity(0.12))
                            }
                        }
                        .contextMenu {
                            Button("Highlight Selection…", systemImage: "selection.pin.in.out") {
                                highlightVerse = verse
                            }
                            Menu("Highlight") {
                                ForEach(StudyHighlightPalette.colors) { item in
                                    Button(item.name) {
                                        setHighlight(item.hex, for: verse)
                                    }
                                }
                            }
                            if !model.personalHighlights(for: verse.id).isEmpty {
                                Button("Remove Highlight", systemImage: "eraser") {
                                    setHighlight(nil, for: verse)
                                }
                            }
                            Divider()
                            Button(
                                model.hasPersonalNote(for: verse.id) ? "Edit Note" : "Add Note",
                                systemImage: "square.and.pencil"
                            ) {
                                model.focusVerse(verse.id)
                                selectedStudyTab = "notes"
                                showingStudyInspector = true
                            }
                            Button("Show Study Tools", systemImage: "sidebar.trailing") {
                                model.focusVerse(verse.id)
                                showingStudyInspector = true
                            }
                        }
                        .id(verse.id)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.vertical, 42)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scrollToReaderLocation(proxy) }
            .onChange(of: model.selectedVerseReference) { _, _ in
                scrollToReaderLocation(proxy)
            }
            .onChange(of: chapter.number) { _, _ in
                scrollToReaderLocation(proxy)
            }
            .onChange(of: chapter.book.id) { _, _ in
                scrollToReaderLocation(proxy)
            }
        }
    }

    private func styledText(for verse: LampVerse) -> AttributedString {
        var result = AttributedString(verse.text)
        result.font = .system(size: fontSize, design: .serif)

        for annotation in verse.annotations {
            guard annotation.startOffset >= 0,
                  annotation.endOffset > annotation.startOffset,
                  annotation.endOffset <= verse.text.count else { continue }
            let stringStart = verse.text.index(
                verse.text.startIndex,
                offsetBy: annotation.startOffset
            )
            let stringEnd = verse.text.index(
                verse.text.startIndex,
                offsetBy: annotation.endOffset
            )
            guard let start = AttributedString.Index(stringStart, within: result),
                  let end = AttributedString.Index(stringEnd, within: result) else { continue }
            let range = start..<end

            switch annotation.kind {
            case "red-letter":
                result[range].foregroundColor = .red.opacity(0.82)
            case "added", "selah":
                result[range].font = .system(size: fontSize, design: .serif).italic()
            case "divine-name":
                result[range].font = .system(size: fontSize, design: .serif).weight(.semibold).smallCaps()
            case "variant":
                result[range].underlineStyle = .single
            default:
                break
            }
        }

        for highlight in model.highlights(for: verse.id) {
            let startOffset = min(max(highlight.startOffset, 0), verse.text.count)
            let endOffset = min(max(highlight.endOffset, startOffset), verse.text.count)
            guard endOffset > startOffset else { continue }
            let stringStart = verse.text.index(verse.text.startIndex, offsetBy: startOffset)
            let stringEnd = verse.text.index(verse.text.startIndex, offsetBy: endOffset)
            guard let start = AttributedString.Index(stringStart, within: result),
                  let end = AttributedString.Index(stringEnd, within: result) else { continue }
            let range = start..<end
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

    private func scrollToReaderLocation(_ proxy: ScrollViewProxy) {
        let target: AnyHashable = model.selectedVerseReference.map(AnyHashable.init)
            ?? AnyHashable("chapter-top")
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: model.selectedVerseReference == nil ? .top : .center)
            }
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Previous Chapter", systemImage: "chevron.left") {
                model.navigateBackward()
            }
            .disabled(!model.canNavigateBackward || model.isLoadingChapter)
            .keyboardShortcut("[", modifiers: .command)

            Menu {
                ForEach(model.translations) { translation in
                    Button {
                        model.selectTranslation(translation.id)
                    } label: {
                        if translation.id == model.selectedTranslationID {
                            Label(translation.name, systemImage: "checkmark")
                        } else {
                            Text(translation.name)
                        }
                    }
                }
            } label: {
                Label(
                    model.selectedTranslation?.abbreviation ?? "Translation",
                    systemImage: "books.vertical"
                )
            }

            Menu {
                ForEach(model.books) { book in
                    Button {
                        model.selectBook(book.id)
                    } label: {
                        if book.id == model.selectedBookNumber {
                            Label(book.name, systemImage: "checkmark")
                        } else {
                            Text(book.name)
                        }
                    }
                }
            } label: {
                Text(model.selectedBook?.name ?? "Book")
            }
            .disabled(model.books.isEmpty)

            Menu {
                if let book = model.selectedBook {
                    ForEach(1...book.chapterCount, id: \.self) { chapter in
                        Button {
                            model.selectChapter(chapter)
                        } label: {
                            if chapter == model.selectedChapterNumber {
                                Label("Chapter \(chapter)", systemImage: "checkmark")
                            } else {
                                Text("Chapter \(chapter)")
                            }
                        }
                    }
                }
            } label: {
                Text("Chapter \(model.selectedChapterNumber)")
            }
            .disabled(model.selectedBook == nil)

            Button("Next Chapter", systemImage: "chevron.right") {
                model.navigateForward()
            }
            .disabled(!model.canNavigateForward || model.isLoadingChapter)
            .keyboardShortcut("]", modifiers: .command)
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
            Button {
                toggleReadAloud()
            } label: {
                Label(readAloudButtonTitle, systemImage: readAloudButtonImage)
            }
            .disabled(model.chapter?.verses.isEmpty != false)
            .help(readAloudButtonTitle)

            Menu("Read Aloud Options", systemImage: "speaker.wave.2") {
                Button("Read Chapter from Beginning", systemImage: "text.book.closed") {
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

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingStudyInspector.toggle()
            } label: {
                Label("Study Tools", systemImage: "sidebar.trailing")
            }
            .help(showingStudyInspector ? "Hide Study Tools" : "Show Study Tools")
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
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
        guard let chapter = model.chapter else { return }
        readAloud.toggle(
            items: chapter.verses.map {
                ReadAloudItem(reference: $0.id, verseNumber: $0.number, text: $0.text)
            },
            startingAt: model.selectedVerseReference,
            voiceIdentifier: readAloudVoice,
            rate: readAloudRate
        )
    }

    private func startReadAloud(at reference: Int?) {
        guard let chapter = model.chapter else { return }
        readAloud.play(
            items: chapter.verses.map {
                ReadAloudItem(reference: $0.id, verseNumber: $0.number, text: $0.text)
            },
            startingAt: reference,
            voiceIdentifier: readAloudVoice,
            rate: readAloudRate
        )
    }
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
        case .plan: "checklist"
        case .devotional: "sun.max"
        case .quiz: "questionmark.bubble"
        case .notes: "note.text"
        case .highlights: "highlighter"
        }
    }
}
