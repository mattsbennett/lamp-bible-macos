import AppKit
import AVFoundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import SwiftUI

struct BookReaderRequest: Codable, Hashable {
    var bookID: String?
    var sectionID: String?

    init(bookID: String? = nil, sectionID: String? = nil) {
        self.bookID = bookID
        self.sectionID = sectionID
    }
}

struct BookModulesView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("books.showsBookList") private var showsBookList = true
    @AppStorage("books.showsTableOfContents") private var showsTableOfContents = true
    @State private var books: [LampBook] = []
    @State private var sections: [LampBookSection] = []
    @State private var selectedBookID: String?
    @State private var selectedSectionID: String?
    @State private var sectionSearchText = ""
    @State private var bookmarkIDs: Set<String> = []
    @State private var showsBookInformation = false
    @State private var errorMessage: String?

    var initialBookID: String? = nil
    var initialSectionID: String? = nil
    var allowsStandaloneWindow = true
    let showImporter: () -> Void
    let openReference: (Int) -> Void

    private let readingState = BookReadingStateStore()
    private var selectedBook: LampBook? {
        books.first { $0.id == selectedBookID }
    }

    private var selectedSection: LampBookSection? {
        sections.first { $0.id == selectedSectionID }
    }

    private var orderedSections: [LampBookSection] {
        sectionTree.flatMap(\.flattenedSections)
    }

    private var orderedSectionIDs: [String] { orderedSections.map(\.id) }

    private var previousSection: LampBookSection? {
        guard let selectedSectionID,
              let id = BookReaderNavigation.previousID(
                in: orderedSectionIDs,
                currentID: selectedSectionID
              ) else { return nil }
        return sections.first { $0.id == id }
    }

    private var nextSection: LampBookSection? {
        guard let selectedSectionID,
              let id = BookReaderNavigation.nextID(
                in: orderedSectionIDs,
                currentID: selectedSectionID
              ) else { return nil }
        return sections.first { $0.id == id }
    }

    private var filteredSections: [LampBookSection] {
        let query = sectionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }
        return orderedSections.filter { section in
            [section.number, section.title, section.subtitle, section.content]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var sectionTree: [BookSectionNode] {
        BookSectionNode.tree(from: sections)
    }

    private var bookmarkedSections: [LampBookSection] {
        orderedSections.filter { bookmarkIDs.contains($0.id) }
    }

    private var reloadID: String {
        model.modules
            .filter { $0.kind == .book }
            .map(\.id)
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    "Unable to Open Books",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if books.isEmpty {
                ContentUnavailableView {
                    Label("No Books Installed", systemImage: "book.closed")
                } description: {
                    Text("Install a long-form book module to read it here.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                BookReaderResizableLayout(
                    showsBookList: showsBookList,
                    showsTableOfContents: showsTableOfContents
                ) {
                    booksList
                } tableOfContents: {
                    contentsList
                } reader: {
                    if let book = selectedBook, let section = selectedSection {
                        BookSectionReaderView(
                            book: book,
                            section: section,
                            previousSection: previousSection,
                            nextSection: nextSection,
                            isBookmarked: bookmarkIDs.contains(section.id),
                            libraryRootURL: model.library.rootURL,
                            openReference: openReference,
                            showBookInformation: { showsBookInformation = true },
                            toggleBookmark: toggleCurrentBookmark,
                            selectSection: { selectedSectionID = $0.id }
                        )
                        .id(section.id)
                    } else {
                        ContentUnavailableView("Choose a Section", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle(selectedBook?.title ?? "Books")
        .navigationSubtitle(selectedSection?.title ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(
                    showsBookList ? "Hide Book List" : "Show Book List",
                    systemImage: "books.vertical"
                ) {
                    showsBookList.toggle()
                }
                .labelStyle(.iconOnly)
                .help(showsBookList ? "Hide Book List" : "Show Book List")
                .accessibilityValue(showsBookList ? "Shown" : "Hidden")

                Button(
                    showsTableOfContents ? "Hide Table of Contents" : "Show Table of Contents",
                    systemImage: "list.bullet.indent"
                ) {
                    showsTableOfContents.toggle()
                }
                .labelStyle(.iconOnly)
                .help(
                    showsTableOfContents
                        ? "Hide Table of Contents"
                        : "Show Table of Contents"
                )
                .accessibilityValue(showsTableOfContents ? "Shown" : "Hidden")

                if allowsStandaloneWindow {
                    Button("Open in Book Reader", systemImage: "macwindow") {
                        openWindow(
                            id: "book-reader",
                            value: BookReaderRequest(
                                bookID: selectedBookID,
                                sectionID: selectedSectionID
                            )
                        )
                    }
                    .labelStyle(.iconOnly)
                    .help("Open the current book in a separate reader window")
                    .disabled(selectedBookID == nil)
                }
            }
        }
        .task(id: reloadID) { await loadBooks() }
        .onChange(of: selectedBookID) { _, _ in
            sectionSearchText = ""
            Task { await loadSections() }
        }
        .onChange(of: initialBookID) { _, newBookID in
            guard let newBookID, books.contains(where: { $0.id == newBookID }) else { return }
            selectedBookID = newBookID
        }
        .onChange(of: initialSectionID) { _, newSectionID in
            guard let newSectionID,
                  let section = sections.first(where: {
                      $0.id == newSectionID || $0.sectionID == newSectionID
                  }) else { return }
            selectedSectionID = section.id
        }
        .sheet(isPresented: $showsBookInformation) {
            if let selectedBook {
                BookInformationView(
                    book: selectedBook,
                    sectionCount: sections.count,
                    media: BookReaderJSON.decodeMedia(selectedBook.mediaJSON),
                    libraryRootURL: model.library.rootURL
                )
            }
        }
    }

    private var booksList: some View {
        List(selection: $selectedBookID) {
            ForEach(books) { book in
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.headline)
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                    if let position = readingState.position(for: book.id) {
                        let sectionTitle = book.id == selectedBookID
                            ? sections.first(where: { $0.id == position.sectionID })?.title
                            : nil
                        Label(sectionTitle ?? "Resume reading", systemImage: "bookmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
                .tag(Optional(book.id))
            }
        }
        .listStyle(.sidebar)
    }

    private var contentsList: some View {
        List(selection: $selectedSectionID) {
            if !sectionSearchText.isEmpty {
                Section("Search Results") {
                    ForEach(filteredSections) { section in
                        sectionRow(section, showsDepth: true)
                    }
                }
            } else {
                if !bookmarkedSections.isEmpty {
                    Section("Bookmarks") {
                        ForEach(bookmarkedSections) { section in
                            sectionRow(section, showsDepth: false)
                        }
                    }
                }
                Section {
                    OutlineGroup(sectionTree, children: \.outlineChildren) { node in
                        sectionRow(node.section, showsDepth: false)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Contents")
                        if let subtitle = selectedBook?.subtitle, !subtitle.isEmpty {
                            Text(subtitle).textCase(nil)
                        }
                    }
                }
            }
        }
        .searchable(text: $sectionSearchText, prompt: "Search this book")
        .overlay {
            if !sectionSearchText.isEmpty, filteredSections.isEmpty {
                ContentUnavailableView.search(text: sectionSearchText)
            }
        }
        .listStyle(.inset)
    }

    private func sectionRow(_ section: LampBookSection, showsDepth: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: sectionIcon(section.type))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let number = section.number, !number.isEmpty {
                        Text(number).foregroundStyle(.secondary)
                    }
                    Text(section.title)
                    if bookmarkIDs.contains(section.id) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                if let subtitle = section.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.leading, showsDepth ? CGFloat(section.depth) * 10 : 0)
        .tag(Optional(section.id))
    }

    private func sectionIcon(_ type: String) -> String {
        switch type {
        case "part": "folder"
        case "chapter": "doc.text"
        case "front-matter", "back-matter": "doc.plaintext"
        case "appendix": "paperclip"
        default: "text.alignleft"
        }
    }

    private func toggleCurrentBookmark() {
        guard let selectedBookID, let selectedSectionID else { return }
        let isBookmarked = readingState.toggleBookmark(
            sectionID: selectedSectionID,
            for: selectedBookID
        )
        if isBookmarked {
            bookmarkIDs.insert(selectedSectionID)
        } else {
            bookmarkIDs.remove(selectedSectionID)
        }
    }

    private func loadBooks() async {
        do {
            books = try await model.library.bookModules()
            errorMessage = nil
            if !books.contains(where: { $0.id == selectedBookID }) {
                let requested = books.first(where: { $0.id == initialBookID })?.id
                let mostRecent = books
                    .compactMap { book in
                        readingState.position(for: book.id).map { (book.id, $0.updatedAt) }
                    }
                    .max { $0.1 < $1.1 }?.0
                selectedBookID = requested ?? mostRecent ?? books.first?.id
            } else {
                await loadSections()
            }
        } catch {
            books = []
            sections = []
            errorMessage = error.localizedDescription
        }
    }

    private func loadSections() async {
        guard let selectedBookID else {
            sections = []
            selectedSectionID = nil
            bookmarkIDs = []
            return
        }
        do {
            sections = try await model.library.bookSections(moduleID: selectedBookID)
            bookmarkIDs = readingState.bookmarkIDs(for: selectedBookID)
            errorMessage = nil
            if !sections.contains(where: { $0.id == selectedSectionID }) {
                let requested = sections.first(where: {
                    $0.id == initialSectionID || $0.sectionID == initialSectionID
                })?.id
                let restored = readingState.position(for: selectedBookID)?.sectionID
                selectedSectionID = requested
                    ?? sections.first(where: { $0.id == restored })?.id
                    ?? sections.first?.id
            }
        } catch {
            sections = []
            selectedSectionID = nil
            bookmarkIDs = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookReaderResizableLayout<
    BookList: View,
    TableOfContents: View,
    Reader: View
>: View {
    let showsBookList: Bool
    let showsTableOfContents: Bool
    let bookList: BookList
    let tableOfContents: TableOfContents
    let reader: Reader

    @State private var preferredBookListWidth = 200.0
    @State private var preferredTableOfContentsWidth = 250.0

    private let minimumBookListWidth: CGFloat = 140
    private let maximumBookListWidth: CGFloat = 220
    private let minimumTableOfContentsWidth: CGFloat = 160
    private let maximumTableOfContentsWidth: CGFloat = 270

    init(
        showsBookList: Bool,
        showsTableOfContents: Bool,
        @ViewBuilder bookList: () -> BookList,
        @ViewBuilder tableOfContents: () -> TableOfContents,
        @ViewBuilder reader: () -> Reader
    ) {
        self.showsBookList = showsBookList
        self.showsTableOfContents = showsTableOfContents
        self.bookList = bookList()
        self.tableOfContents = tableOfContents()
        self.reader = reader()
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsBookList {
                bookList
                    .frame(width: bookListWidth)
                BookReaderColumnResizeHandle(
                    preferredWidth: $preferredBookListWidth,
                    displayedWidth: Double(bookListWidth),
                    minimumWidth: Double(minimumBookListWidth),
                    maximumWidth: Double(maximumBookListWidth),
                    label: "Resize Book List"
                )
            }
            if showsTableOfContents {
                tableOfContents
                    .frame(width: tableOfContentsWidth)
                BookReaderColumnResizeHandle(
                    preferredWidth: $preferredTableOfContentsWidth,
                    displayedWidth: Double(tableOfContentsWidth),
                    minimumWidth: Double(minimumTableOfContentsWidth),
                    maximumWidth: Double(maximumTableOfContentsWidth),
                    label: "Resize Table of Contents"
                )
            }
            reader
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(2)
        }
    }

    private var bookListWidth: CGFloat {
        min(
            max(CGFloat(preferredBookListWidth), minimumBookListWidth),
            maximumBookListWidth
        )
    }

    private var tableOfContentsWidth: CGFloat {
        min(
            max(CGFloat(preferredTableOfContentsWidth), minimumTableOfContentsWidth),
            maximumTableOfContentsWidth
        )
    }
}

private struct BookReaderColumnResizeHandle: View {
    @Binding var preferredWidth: Double
    let displayedWidth: Double
    let minimumWidth: Double
    let maximumWidth: Double
    let label: String

    @State private var widthAtDragStart: Double?
    @State private var isShowingResizeCursor = false

    var body: some View {
        Divider()
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover(perform: setResizeCursor)
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtDragStart ?? displayedWidth
                                widthAtDragStart = start
                                preferredWidth = clamped(
                                    start + value.translation.width
                                )
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
                    .onDisappear { setResizeCursor(false) }
            }
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(displayedWidth.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    preferredWidth = clamped(displayedWidth + 20)
                case .decrement:
                    preferredWidth = clamped(displayedWidth - 20)
                @unknown default:
                    break
                }
            }
            .zIndex(1)
    }

    private func clamped(_ width: Double) -> Double {
        min(max(width, minimumWidth), maximumWidth)
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
}

private struct BookSectionNode: Identifiable {
    let section: LampBookSection
    let children: [BookSectionNode]

    var id: String { section.id }
    var outlineChildren: [BookSectionNode]? { children.isEmpty ? nil : children }
    var flattenedSections: [LampBookSection] {
        [section] + children.flatMap(\.flattenedSections)
    }

    static func tree(from sections: [LampBookSection]) -> [BookSectionNode] {
        let knownIDs = Set(sections.map(\.id))
        let childrenByParent = Dictionary(grouping: sections) { $0.parentID }
        let roots = sections.filter { section in
            guard let parentID = section.parentID else { return true }
            return !knownIDs.contains(parentID)
        }

        func node(for section: LampBookSection, ancestors: Set<String>) -> BookSectionNode {
            guard !ancestors.contains(section.id) else {
                return BookSectionNode(section: section, children: [])
            }
            let nextAncestors = ancestors.union([section.id])
            let children = (childrenByParent[section.id] ?? [])
                .sorted { ($0.orderIndex, $0.title) < ($1.orderIndex, $1.title) }
                .map { node(for: $0, ancestors: nextAncestors) }
            return BookSectionNode(section: section, children: children)
        }

        return roots
            .sorted { ($0.orderIndex, $0.title) < ($1.orderIndex, $1.title) }
            .map { node(for: $0, ancestors: []) }
    }
}

private struct BookSectionReaderDocument: Sendable {
    let sectionID: String
    let decoded: BookReaderDecodedBlocks
    let footnotes: [BookReaderFootnote]
    let referencedFootnotes: [BookReaderFootnote]
    let mediaByID: [String: BookReaderMedia]
    private let attributedTextByContent: [BookReaderAnnotatedText: AttributedString]

    init(
        sectionID: String,
        contentJSON: String,
        footnotesJSON: String?,
        mediaJSON: String?
    ) {
        self.sectionID = sectionID
        decoded = BookReaderJSON.decodeBlocks(contentJSON)
        footnotes = BookReaderJSON.decodeFootnotes(footnotesJSON)

        var mediaByID: [String: BookReaderMedia] = [:]
        for item in BookReaderJSON.decodeMedia(mediaJSON) {
            mediaByID[item.id] = item
        }
        self.mediaByID = mediaByID

        var contents = Set<BookReaderAnnotatedText>()
        for block in decoded.blocks {
            Self.collectAnnotatedText(from: block, into: &contents)
        }
        let referencedFootnoteIDs = BookReaderFootnoteReferences.ids(in: decoded.blocks)
        referencedFootnotes = footnotes.filter { referencedFootnoteIDs.contains($0.id) }
        contents.formUnion(referencedFootnotes.map(\.content.annotatedText))

        var attributedTextByContent: [BookReaderAnnotatedText: AttributedString] = [:]
        for content in contents {
            attributedTextByContent[content] = BookAttributedTextRenderer.render(
                content,
                footnotes: footnotes
            )
        }
        self.attributedTextByContent = attributedTextByContent
    }

    func attributedText(for content: BookReaderAnnotatedText) -> AttributedString {
        attributedTextByContent[content]
            ?? BookAttributedTextRenderer.render(content, footnotes: footnotes)
    }

    private static func collectAnnotatedText(
        from block: BookReaderContentBlock,
        into contents: inout Set<BookReaderAnnotatedText>
    ) {
        if let content = block.content { contents.insert(content) }
        if let caption = block.caption?.annotatedText { contents.insert(caption) }
        for item in block.items {
            collectAnnotatedText(from: item, into: &contents)
        }
        for row in block.rows {
            contents.formUnion(row.cells.map(\.content))
        }
    }

    private static func collectAnnotatedText(
        from item: BookReaderListItem,
        into contents: inout Set<BookReaderAnnotatedText>
    ) {
        contents.insert(item.content)
        for child in item.children {
            collectAnnotatedText(from: child, into: &contents)
        }
    }
}

@MainActor
private final class BookReadingPositionTracker: ObservableObject {
    private let store = BookReadingStateStore()
    private var moduleID: String?
    private var sectionID: String?
    private var position = BookReadingPositionBuffer()
    private var isRestoring = false

    func prepare(moduleID: String, sectionID: String) -> Int {
        self.moduleID = moduleID
        self.sectionID = sectionID
        let savedPosition = store.position(for: moduleID)
        let blockIndex = savedPosition?.sectionID == sectionID
            ? savedPosition?.blockIndex ?? -1
            : -1
        position = BookReadingPositionBuffer(blockIndex: blockIndex)
        isRestoring = true

        if savedPosition?.sectionID != sectionID {
            store.save(
                position: BookReadingPosition(sectionID: sectionID, blockIndex: blockIndex),
                for: moduleID
            )
        }
        return blockIndex
    }

    func observe(visibleBlockIndices: [Int]) {
        guard !isRestoring else { return }
        position.observe(visibleBlockIndices: visibleBlockIndices)
    }

    func finishRestoring() {
        isRestoring = false
    }

    func flush() {
        guard let moduleID, let sectionID,
              let blockIndex = position.takeChangedBlockIndex() else { return }
        store.save(
            position: BookReadingPosition(sectionID: sectionID, blockIndex: blockIndex),
            for: moduleID
        )
    }
}

private struct BookSectionReaderView: View {
    let book: LampBook
    let section: LampBookSection
    let previousSection: LampBookSection?
    let nextSection: LampBookSection?
    let isBookmarked: Bool
    let libraryRootURL: URL
    let openReference: (Int) -> Void
    let showBookInformation: () -> Void
    let toggleBookmark: () -> Void
    let selectSection: (LampBookSection) -> Void

    @AppStorage("books.fontSize") private var fontSize = LampTextScale.bookText.defaultValue
    @AppStorage("books.lineSpacing") private var lineSpacing = LampTextScale.bookLineSpacing.defaultValue
    @AppStorage("books.typeface") private var typefaceRaw = ProseTypeface.readerDefault.rawValue
    @StateObject private var positionTracker = BookReadingPositionTracker()
    @State private var document: BookSectionReaderDocument?
    @State private var showsFootnotes = false
    @State private var selectedFootnote: BookReaderFootnote?
    @State private var presentedImage: PresentedBookImage?

    private var typeface: ProseTypeface {
        ProseTypeface(rawValue: typefaceRaw) ?? .readerDefault
    }

    private var typefaceBinding: Binding<ProseTypeface> {
        Binding(
            get: { typeface },
            set: { typefaceRaw = $0.rawValue }
        )
    }

    private var sectionURL: URL? {
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = "books"
        components.queryItems = [
            URLQueryItem(name: "module", value: book.id),
            URLQueryItem(name: "section", value: section.sectionID),
        ]
        return components.url
    }

    var body: some View {
        VStack(spacing: 0) {
            readerToolbar
            Divider()
            if let document {
                reader(document)
            } else {
                ProgressView("Preparing section…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.layoutDirection, book.textDirection == "rtl" ? .rightToLeft : .leftToRight)
        .overlay {
            ReaderNativeContextMenuAugmenter(
                entries: [],
                openLink: { _ in },
                showsLinkCursor: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: section.id) {
            let sectionID = section.id
            let contentJSON = section.contentJSON
            let footnotesJSON = book.footnotesJSON
            let mediaJSON = book.mediaJSON
            let preparedDocument = await Task.detached(priority: .userInitiated) {
                BookSectionReaderDocument(
                    sectionID: sectionID,
                    contentJSON: contentJSON,
                    footnotesJSON: footnotesJSON,
                    mediaJSON: mediaJSON
                )
            }.value
            guard !Task.isCancelled else { return }
            document = preparedDocument
        }
        .onDisappear { positionTracker.flush() }
        .sheet(item: $selectedFootnote) { footnote in
            if let document {
                BookFootnoteSheet(
                    footnote: footnote,
                    number: document.footnotes.firstIndex(where: { $0.id == footnote.id }).map { $0 + 1 },
                    document: document,
                    fontSize: fontSize,
                    typeface: typeface,
                    selectFootnote: { selectedFootnote = $0 }
                )
            }
        }
        .sheet(item: $presentedImage) { item in
            VStack(spacing: 14) {
                Image(nsImage: item.image)
                    .resizable()
                    .scaledToFit()
                if !item.caption.isEmpty {
                    Text(item.caption).font(.headline)
                }
            }
            .padding(24)
            .frame(minWidth: 780, minHeight: 600)
        }
    }

    private func reader(_ document: BookSectionReaderDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Book sections are modest in size, while tables can change a
                // block's estimated height substantially as they enter the
                // viewport. A LazyVStack repeatedly re-estimates those heights
                // on macOS and can get stuck in a layout loop at a table edge.
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader.id(-1)

                    if document.decoded.blocks.isEmpty {
                        if section.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView(
                                "No Text in This Section",
                                systemImage: "rectangle.stack",
                                description: Text("Choose one of its sub-sections from the contents.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            Text(section.content)
                                .font(.system(size: fontSize, design: typeface.design))
                                .lineSpacing(lineSpacing)
                                .id(0)
                        }
                    } else {
                        ForEach(document.decoded.blocks.indices, id: \.self) { index in
                            BookContentBlockView(
                                block: document.decoded.blocks[index],
                                document: document,
                                moduleID: book.id,
                                libraryRootURL: libraryRootURL,
                                fontSize: fontSize,
                                lineSpacing: lineSpacing,
                                typeface: typeface,
                                selectFootnote: { selectedFootnote = $0 },
                                presentImage: { image, caption in
                                    presentedImage = PresentedBookImage(
                                        image: image,
                                        caption: caption
                                    )
                                }
                            )
                            .id(index)
                        }
                    }

                    if document.decoded.discardedBlockCount > 0 {
                        Label(
                            "\(document.decoded.discardedBlockCount) unsupported content \(document.decoded.discardedBlockCount == 1 ? "block was" : "blocks were") skipped.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    }

                    if !document.referencedFootnotes.isEmpty {
                        Divider().padding(.top, 12)
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                showsFootnotes.toggle()
                            } label: {
                                HStack(spacing: 7) {
                                    Image(
                                        systemName: showsFootnotes
                                            ? "chevron.down"
                                            : "chevron.right"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 12)
                                    Text("Footnotes")
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .pointingHandCursor()
                            .accessibilityValue(showsFootnotes ? "Expanded" : "Collapsed")

                            if showsFootnotes {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(document.referencedFootnotes) { footnote in
                                        let number = document.footnotes
                                            .firstIndex(where: { $0.id == footnote.id })
                                            .map { $0 + 1 }
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(number.map { "\($0)." } ?? "•")
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                            BookInlineText(
                                                attributedText: document.attributedText(
                                                    for: footnote.content.annotatedText
                                                ),
                                                footnotes: document.footnotes,
                                                selectFootnote: { selectedFootnote = $0 }
                                            )
                                        }
                                        .font(.system(
                                            size: max(fontSize - 2, 11),
                                            design: typeface.design
                                        ))
                                        .lineSpacing(lineSpacing)
                                    }
                                }
                                .padding(.top, 10)
                            }
                        }
                        .font(.headline)
                    }

                    chapterNavigation
                }
                .scrollTargetLayout()
                .frame(maxWidth: 760, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // A selection scope around the complete lazy document makes
                // SwiftUI's macOS SelectionOverlay repeatedly invalidate every
                // attributed-text row while scrolling. Sections containing
                // zero-height or complex blocks (notably tables) can turn that
                // feedback into an unbounded allocation loop.
            }
            .onScrollTargetVisibilityChange(idType: Int.self) { visibleBlockIndices in
                positionTracker.observe(visibleBlockIndices: visibleBlockIndices)
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .idle {
                    positionTracker.flush()
                }
            }
            .task(id: document.sectionID) {
                let blockIndex = positionTracker.prepare(
                    moduleID: book.id,
                    sectionID: section.id
                )
                await Task.yield()
                proxy.scrollTo(blockIndex, anchor: .top)
                await Task.yield()
                positionTracker.finishRestoring()
            }
        }
    }

    private var readerToolbar: some View {
        HStack(spacing: 8) {
            Button("Previous Section", systemImage: "chevron.left") {
                if let previousSection { selectSection(previousSection) }
            }
            .labelStyle(.iconOnly)
            .disabled(previousSection == nil)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("Next Section", systemImage: "chevron.right") {
                if let nextSection { selectSection(nextSection) }
            }
            .labelStyle(.iconOnly)
            .disabled(nextSection == nil)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Spacer()
            Button(
                isBookmarked ? "Remove Bookmark" : "Bookmark Section",
                systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
            ) {
                toggleBookmark()
            }
            .labelStyle(.iconOnly)
            .help(isBookmarked ? "Remove this section's bookmark" : "Bookmark this section")

            if let sectionURL {
                ShareLink(item: sectionURL) {
                    Label("Share Section", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .help("Share a link to this book section")
            }

            TextSizeMenu(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing,
                typeface: typefaceBinding,
                defaultTypeface: .readerDefault,
                fontScale: .bookText,
                lineSpacingScale: .bookLineSpacing,
                help: "Choose the book typeface, text size, and line spacing"
            )

            Button("Book Information", systemImage: "info.circle", action: showBookInformation)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let number = section.number, !number.isEmpty {
                Text(number.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(section.title)
                .font(.system(size: max(fontSize * 1.8, 30), weight: .bold, design: typeface.design))
            if let subtitle = section.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: max(fontSize * 1.15, 18), design: typeface.design))
                    .foregroundStyle(.secondary)
            }

            if !section.keyScriptures.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(section.keyScriptures) { link in
                            Button(link.displayDescription) {
                                openReference(link.startReference)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chapterNavigation: some View {
        HStack(spacing: 12) {
            if let previousSection {
                Button {
                    selectSection(previousSection)
                } label: {
                    navigationLabel(
                        eyebrow: "Previous",
                        title: previousSection.title,
                        systemImage: "chevron.left",
                        placesIconAfterText: false
                    )
                }
            }
            Spacer(minLength: 12)
            if let nextSection {
                Button {
                    selectSection(nextSection)
                } label: {
                    navigationLabel(
                        eyebrow: "Next",
                        title: nextSection.title,
                        systemImage: "chevron.right",
                        placesIconAfterText: true
                    )
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(.top, 24)
    }

    private func navigationLabel(
        eyebrow: String,
        title: String,
        systemImage: String,
        placesIconAfterText: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if !placesIconAfterText {
                Image(systemName: systemImage)
            }
            VStack(alignment: eyebrow == "Next" ? .trailing : .leading, spacing: 2) {
                Text(eyebrow).font(.caption).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
            }
            if placesIconAfterText {
                Image(systemName: systemImage)
            }
        }
        .frame(maxWidth: 260)
    }
}

private struct BookContentBlockView: View {
    let block: BookReaderContentBlock
    let document: BookSectionReaderDocument
    let moduleID: String
    let libraryRootURL: URL
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface
    let selectFootnote: (BookReaderFootnote) -> Void
    let presentImage: (NSImage, String) -> Void

    private func inlineMedia(in content: BookReaderAnnotatedText) -> [BookReaderMedia] {
        var seen: Set<String> = []
        return content.annotations.compactMap { annotation in
            guard annotation.type == "media", let id = annotation.data?.mediaID,
                  seen.insert(id).inserted else { return nil }
            return document.mediaByID[id]
        }
    }

    @ViewBuilder
    var body: some View {
        switch block.type {
        case "heading":
            prose(block.content)
                .font(.system(
                    size: headingSize,
                    weight: (block.level ?? 2) <= 2 ? .bold : .semibold,
                    design: typeface.design
                ))
                .padding(.top, 6)
        case "blockquote":
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                prose(block.content)
                    .font(.system(size: fontSize, design: typeface.design).italic())
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(.secondary)
            }
        case "list":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                    BookListItemView(
                        item: item,
                        marker: block.listType == "numbered" ? "\(index + 1)." : "•",
                        document: document,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        typeface: typeface,
                        moduleID: moduleID,
                        libraryRootURL: libraryRootURL,
                        selectFootnote: selectFootnote,
                        presentImage: presentImage
                    )
                }
            }
        case "table":
            BookTableBlockView(
                rows: block.rows,
                columnCount: block.columnCount,
                document: document,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                typeface: typeface,
                selectFootnote: selectFootnote
            )
        case "thematic-break":
            Divider().padding(.vertical, 8)
        case "image", "audio":
            if let mediaID = block.mediaID, let media = document.mediaByID[mediaID] {
                BookMediaBlockView(
                    media: media,
                    caption: block.caption?.annotatedText,
                    alignment: block.alignment,
                    showWaveform: block.showWaveform,
                    autoplay: block.autoplay,
                    moduleID: moduleID,
                    libraryRootURL: libraryRootURL,
                    document: document,
                    selectFootnote: selectFootnote,
                    presentImage: presentImage
                )
            } else {
                BookUnavailableMediaView(
                    label: block.caption?.annotatedText.text
                        ?? (block.type == "image" ? "Image" : "Audio"),
                    systemImage: block.type == "image" ? "photo" : "waveform",
                    detail: block.mediaID.map { "Media item \($0) is missing from this module." }
                )
            }
        default:
            prose(block.content)
                .font(.system(size: fontSize, design: typeface.design))
                .lineSpacing(lineSpacing)
        }
    }

    @ViewBuilder
    private func prose(_ content: BookReaderAnnotatedText?) -> some View {
        if let content {
            VStack(alignment: .leading, spacing: 12) {
                BookInlineText(
                    attributedText: document.attributedText(for: content),
                    footnotes: document.footnotes,
                    selectFootnote: selectFootnote
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(inlineMedia(in: content)) { media in
                    BookMediaBlockView(
                        media: media,
                        caption: nil,
                        alignment: nil,
                        showWaveform: true,
                        autoplay: false,
                        moduleID: moduleID,
                        libraryRootURL: libraryRootURL,
                        document: document,
                        selectFootnote: selectFootnote,
                        presentImage: presentImage
                    )
                }
            }
        }
    }

    private var headingSize: Double {
        switch block.level ?? 2 {
        case 1: fontSize * 1.55
        case 2: fontSize * 1.32
        case 3: fontSize * 1.16
        default: fontSize * 1.05
        }
    }
}

private struct BookTableBlockView: View {
    let rows: [BookReaderTableRow]
    let columnCount: Int?
    let document: BookSectionReaderDocument
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface
    let selectFootnote: (BookReaderFootnote) -> Void

    var body: some View {
        Group {
            if rows.isEmpty {
                Label("Empty table", systemImage: "tablecells")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if usesHorizontalScrolling {
                ScrollView(.horizontal, showsIndicators: true) {
                    tableGrid
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                tableGrid
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Table")
    }

    private var tableGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow(alignment: .top) {
                    ForEach(placements(in: row)) { placement in
                        if let cell = placement.cell {
                            BookTableCellView(
                                cell: cell,
                                document: document,
                                width: usesHorizontalScrolling
                                    ? cellWidth * CGFloat(placement.span)
                                    : nil,
                                rowIndex: rowIndex,
                                fontSize: fontSize,
                                lineSpacing: lineSpacing,
                                typeface: typeface,
                                selectFootnote: selectFootnote
                            )
                            .gridCellColumns(placement.span)
                        } else {
                            BookTableEmptyCell(
                                width: usesHorizontalScrolling
                                    ? cellWidth * CGFloat(placement.span)
                                    : nil
                            )
                            .gridCellColumns(placement.span)
                        }
                    }
                }
            }
        }
        .padding(1)
    }

    private var resolvedColumnCount: Int {
        let inferred = rows
            .flatMap(\.cells)
            .map { $0.column + max($0.columnSpan, 1) }
            .max() ?? 0
        return max(columnCount ?? 0, inferred, 1)
    }

    private var cellWidth: CGFloat {
        switch resolvedColumnCount {
        case 1: 640
        case 2: 310
        case 3: 215
        case 4: 165
        default: 150
        }
    }

    private var usesHorizontalScrolling: Bool {
        resolvedColumnCount > 4
    }

    private func placements(in row: BookReaderTableRow) -> [BookTableCellPlacement] {
        let cells = Dictionary(
            row.cells
                .filter { $0.column >= 0 && $0.column < resolvedColumnCount }
                .map { ($0.column, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [BookTableCellPlacement] = []
        var column = 0
        while column < resolvedColumnCount {
            if let cell = cells[column] {
                let span = min(max(cell.columnSpan, 1), resolvedColumnCount - column)
                result.append(BookTableCellPlacement(
                    column: column,
                    span: span,
                    cell: cell
                ))
                column += span
            } else {
                result.append(BookTableCellPlacement(column: column, span: 1, cell: nil))
                column += 1
            }
        }
        return result
    }
}

private struct BookTableCellPlacement: Identifiable {
    let column: Int
    let span: Int
    let cell: BookReaderTableCell?

    var id: Int { column }
}

private struct BookTableCellView: View {
    let cell: BookReaderTableCell
    let document: BookSectionReaderDocument
    let width: CGFloat?
    let rowIndex: Int
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface
    let selectFootnote: (BookReaderFootnote) -> Void

    var body: some View {
        Group {
            if let width {
                cellContent.frame(width: width, alignment: .topLeading)
            } else {
                cellContent.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minHeight: 42, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay { Rectangle().stroke(.separator.opacity(0.7), lineWidth: 0.5) }
    }

    private var cellContent: some View {
        BookInlineText(
            attributedText: document.attributedText(for: cell.content),
            footnotes: document.footnotes,
            selectFootnote: selectFootnote
        )
        .font(.system(
            size: max(fontSize - 1, 11),
            weight: cell.isHeader ? .semibold : .regular,
            design: typeface.design
        ))
        .lineSpacing(max(lineSpacing - 1, 0))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var background: Color {
        if cell.isHeader {
            return Color.accentColor.opacity(0.14)
        }
        return rowIndex.isMultiple(of: 2)
            ? Color.primary.opacity(0.035)
            : Color.clear
    }
}

private struct BookTableEmptyCell: View {
    let width: CGFloat?

    var body: some View {
        Group {
            if let width {
                Color.clear.frame(width: width)
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 42, maxHeight: .infinity)
        .overlay { Rectangle().stroke(.separator.opacity(0.7), lineWidth: 0.5) }
    }
}

private struct BookListItemView: View {
    let item: BookReaderListItem
    let marker: String
    let document: BookSectionReaderDocument
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface
    let moduleID: String
    let libraryRootURL: URL
    let selectFootnote: (BookReaderFootnote) -> Void
    let presentImage: (NSImage, String) -> Void

    private var inlineMedia: [BookReaderMedia] {
        var seen: Set<String> = []
        return item.content.annotations.compactMap { annotation in
            guard annotation.type == "media", let id = annotation.data?.mediaID,
                  seen.insert(id).inserted else { return nil }
            return document.mediaByID[id]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                BookInlineText(
                    attributedText: document.attributedText(for: item.content),
                    footnotes: document.footnotes,
                    selectFootnote: selectFootnote
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: fontSize, design: typeface.design))
            .lineSpacing(lineSpacing)
            ForEach(inlineMedia) { media in
                BookMediaBlockView(
                    media: media,
                    caption: nil,
                    alignment: nil,
                    showWaveform: true,
                    autoplay: false,
                    moduleID: moduleID,
                    libraryRootURL: libraryRootURL,
                    document: document,
                    selectFootnote: selectFootnote,
                    presentImage: presentImage
                )
                .padding(.leading, 28)
            }
            ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                BookListItemView(
                    item: child,
                    marker: "•",
                    document: document,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    typeface: typeface,
                    moduleID: moduleID,
                    libraryRootURL: libraryRootURL,
                    selectFootnote: selectFootnote,
                    presentImage: presentImage
                )
                .padding(.leading, 24)
            }
        }
    }
}

private enum BookAttributedTextRenderer {
    static func render(
        _ content: BookReaderAnnotatedText,
        footnotes: [BookReaderFootnote]
    ) -> AttributedString {
        var value = AttributedString(content.text)
        for annotation in content.annotations {
            guard let range = range(
                from: annotation.start,
                to: annotation.end,
                in: value
            ) else { continue }
            switch annotation.type {
            case "scripture":
                let reference = annotation.data?.startReference
                    ?? annotation.data?.references.first?.startReference
                let endReference = annotation.data?.endReference
                    ?? annotation.data?.references.first?.endReference
                if let reference,
                   let link = ScriptureAnnotationLink(
                    startReference: reference,
                    endReference: endReference
                   )?.url {
                    value[range].link = link
                }
            case "link":
                if let rawURL = annotation.data?.url, let url = URL(string: rawURL) {
                    value[range].link = url
                }
            case "footnote":
                if let id = annotation.data?.footnoteID {
                    value[range].link = makeFootnoteURL(id)
                }
            case "emphasis":
                switch annotation.data?.style {
                case "bold":
                    value[range].inlinePresentationIntent = .stronglyEmphasized
                case "underline":
                    value[range].underlineStyle = .single
                default:
                    value[range].inlinePresentationIntent = .emphasized
                }
            case "quote":
                value[range].inlinePresentationIntent = .emphasized
            case "strongs", "greek", "hebrew":
                value[range].underlineStyle = .single
            default:
                break
            }
        }

        var insertions: [(offset: Int, marker: AttributedString)] = []
        for reference in content.footnoteReferences {
            let number = footnotes.firstIndex { $0.id == reference.id }.map { $0 + 1 }
            var marker = AttributedString("[\(number.map(String.init) ?? "•")]")
            marker.link = makeFootnoteURL(reference.id)
            marker.baselineOffset = 4
            marker.font = .caption
            insertions.append((reference.offset, marker))
        }
        for annotation in content.annotations where annotation.type == "page" {
            guard let pageNumber = annotation.data?.pageNumber else { continue }
            var marker = AttributedString(" [p. \(pageNumber)] ")
            marker.font = .caption
            marker.inlinePresentationIntent = .emphasized
            insertions.append((annotation.start, marker))
        }
        for insertion in insertions.sorted(by: { $0.offset > $1.offset }) {
            guard let index = index(at: insertion.offset, in: value) else { continue }
            value.insert(insertion.marker, at: index)
        }
        return value
    }

    private static func index(
        at offset: Int,
        in value: AttributedString
    ) -> AttributedString.Index? {
        guard offset >= 0 else { return nil }
        return value.characters.index(
            value.characters.startIndex,
            offsetBy: offset,
            limitedBy: value.characters.endIndex
        )
    }

    private static func range(
        from start: Int,
        to end: Int,
        in value: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard start >= 0, end >= start,
              let lower = index(at: start, in: value),
              let upper = index(at: end, in: value),
              lower < upper else { return nil }
        return lower..<upper
    }

    private static func makeFootnoteURL(_ id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "lamp-book"
        components.host = "footnote"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }
}

private struct BookInlineText: View {
    let attributedText: AttributedString
    let footnotes: [BookReaderFootnote]
    let selectFootnote: (BookReaderFootnote) -> Void
    @StateObject private var pointerTracker = BookInlineTextPointerTracker()
    @State private var previewLink: LampScriptureLink?
    @State private var previewAnchor = CGRect.zero

    var body: some View {
        Text(attributedText)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointerTracker.location = location
                case .ended:
                    pointerTracker.location = nil
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if let scripture = ScriptureAnnotationLink(url: url) {
                    previewAnchor = pointerTracker.location.map {
                        CGRect(x: $0.x - 1, y: $0.y - 1, width: 2, height: 2)
                    } ?? .zero
                    previewLink = LampScriptureLink(
                        startReference: scripture.startReference,
                        endReference: scripture.endReference
                    )
                    return .handled
                }
                if let footnoteID = footnoteID(from: url),
                   let footnote = footnotes.first(where: { $0.id == footnoteID }) {
                    selectFootnote(footnote)
                    return .handled
                }
                return .systemAction
            })
            .popover(
                item: $previewLink,
                attachmentAnchor: previewAnchor == .zero
                    ? .rect(.bounds)
                    : .rect(.rect(previewAnchor))
            ) { link in
                ScriptureReferencePopover(
                    link: link,
                    typeface: .readerDefault,
                    lineSpacing: LampTextScale.bookLineSpacing.defaultValue,
                    contextAmount: .oneVerse
                )
            }
    }

    private func footnoteID(from url: URL) -> String? {
        guard url.scheme == "lamp-book", url.host == "footnote",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first { $0.name == "id" }?.value
    }
}

@MainActor
private final class BookInlineTextPointerTracker: ObservableObject {
    var location: CGPoint?
}

private struct BookPointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
                isHovering = hovering
            }
            .onDisappear {
                guard isHovering else { return }
                NSCursor.pop()
                isHovering = false
            }
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        modifier(BookPointingHandCursorModifier())
    }
}

private struct BookMediaBlockView: View {
    let media: BookReaderMedia
    let caption: BookReaderAnnotatedText?
    let alignment: String?
    let showWaveform: Bool
    let autoplay: Bool
    let moduleID: String
    let libraryRootURL: URL
    let document: BookSectionReaderDocument
    let selectFootnote: (BookReaderFootnote) -> Void
    let presentImage: (NSImage, String) -> Void

    private var url: URL? {
        BookReaderMediaResolver.url(
            for: media.filename,
            moduleID: moduleID,
            libraryRootURL: libraryRootURL
        )
    }

    private var captionText: String { caption?.text ?? media.alt ?? "" }

    @ViewBuilder
    var body: some View {
        if let url {
            Group {
                if media.type == "image" {
                    BookImageView(
                        url: url,
                        alt: media.alt,
                        caption: captionText,
                        presentImage: presentImage
                    )
                } else if media.type == "audio" {
                    BookAudioView(
                        url: url,
                        media: media,
                        label: captionText,
                        showWaveform: showWaveform,
                        autoplay: autoplay
                    )
                } else {
                    BookUnavailableMediaView(
                        label: captionText.isEmpty ? "Media" : captionText,
                        systemImage: "questionmark.square.dashed",
                        detail: "This version of Lamp does not recognize media type \(media.type)."
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)

            if let caption, !caption.text.isEmpty, media.type == "audio" {
                BookInlineText(
                    attributedText: document.attributedText(for: caption),
                    footnotes: document.footnotes,
                    selectFootnote: selectFootnote
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        } else {
            BookUnavailableMediaView(
                label: captionText.isEmpty ? media.filename : captionText,
                systemImage: media.type == "image" ? "photo" : "waveform",
                detail: "The referenced file \(media.filename) is not available on this Mac."
            )
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case "right": .trailing
        case "center": .center
        default: .leading
        }
    }
}

private struct BookImageView: View {
    let url: URL
    let alt: String?
    let caption: String
    let presentImage: (NSImage, String) -> Void

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Button {
                    presentImage(image, caption)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 720, maxHeight: 560)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel(alt ?? caption)
                        if !caption.isEmpty {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            } else if didFail {
                BookUnavailableMediaView(
                    label: caption.isEmpty ? "Image" : caption,
                    systemImage: "photo",
                    detail: "The image could not be opened."
                )
            } else {
                ProgressView(caption.isEmpty ? "Loading image…" : "Loading \(caption)…")
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            image = nil
            didFail = false
            let data = try? await Task.detached(priority: .utility) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
            didFail = image == nil
        }
    }
}

private struct BookAudioView: View {
    let url: URL
    let media: BookReaderMedia
    let label: String
    let showWaveform: Bool
    let autoplay: Bool
    @StateObject private var player = BookAudioPlayer()
    @State private var showsTranscript = false

    private var duration: Double { max(player.duration, media.duration ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.toggle(url: url, expectedDuration: media.duration)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.isEmpty ? "Audio" : label).font(.headline)
                    Text(media.filename).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(formatTime(player.currentTime)) / \(formatTime(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if showWaveform, !media.waveform.isEmpty {
                BookWaveformView(
                    samples: media.waveform,
                    progress: duration > 0 ? player.currentTime / duration : 0
                )
                .frame(height: 34)
            }

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(duration, 1)
            )
            .disabled(duration <= 0)

            if let transcription = media.transcription, !transcription.isEmpty {
                DisclosureGroup("Transcript", isExpanded: $showsTranscript) {
                    Text(transcription)
                        .font(.callout)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            player.prepare(url: url, expectedDuration: media.duration)
            if autoplay { player.play() }
        }
        .onDisappear { player.stop() }
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let seconds = Int(value.rounded(.down))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

@MainActor
private final class BookAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0

    private var player: AVPlayer?
    private var loadedURL: URL?
    private var timeObserver: Any?

    func prepare(url: URL, expectedDuration: Double?) {
        guard loadedURL != url else { return }
        removeObserver()
        loadedURL = url
        currentTime = 0
        duration = expectedDuration ?? 0
        let player = AVPlayer(url: url)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = max(seconds, 0) }
                if let itemDuration = player?.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                if self.duration > 0, self.currentTime >= self.duration - 0.1 {
                    self.isPlaying = false
                }
            }
        }
    }

    func toggle(url: URL, expectedDuration: Double?) {
        prepare(url: url, expectedDuration: expectedDuration)
        isPlaying ? pause() : play()
    }

    func play() {
        if duration > 0, currentTime >= duration - 0.1 {
            seek(to: 0)
        }
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(duration, seconds))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
    }

    func stop() {
        pause()
        player?.seek(to: .zero)
        currentTime = 0
    }

    private func removeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}

private struct BookWaveformView: View {
    let samples: [Double]
    let progress: Double

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }
            let barWidth = size.width / CGFloat(samples.count)
            let completed = min(max(progress, 0), 1) * Double(samples.count)
            for (index, sample) in samples.enumerated() {
                let height = max(2, size.height * CGFloat(min(max(sample, 0), 1)))
                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: (size.height - height) / 2,
                    width: max(barWidth - 1, 1),
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(Double(index) < completed ? .accentColor : .secondary.opacity(0.35))
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct BookUnavailableMediaView: View {
    let label: String
    let systemImage: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.headline)
                if let detail { Text(detail).font(.caption) }
            }
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct BookFootnoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let footnote: BookReaderFootnote
    let number: Int?
    let document: BookSectionReaderDocument
    let fontSize: Double
    let typeface: ProseTypeface
    let selectFootnote: (BookReaderFootnote) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(number.map { "Footnote \($0)" } ?? "Footnote")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            BookInlineText(
                attributedText: document.attributedText(for: footnote.content.annotatedText),
                footnotes: document.footnotes,
                selectFootnote: selectFootnote
            )
            .font(.system(size: fontSize, design: typeface.design))
            .lineSpacing(5)
            .textSelection(.enabled)
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 240)
    }
}

private struct BookInformationView: View {
    @Environment(\.dismiss) private var dismiss
    let book: LampBook
    let sectionCount: Int
    let media: [BookReaderMedia]
    let libraryRootURL: URL

    private var cover: BookReaderMedia? {
        guard let coverMediaID = book.coverMediaID else { return nil }
        return media.first { $0.id == coverMediaID && $0.type == "image" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 22) {
                    coverView
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title).font(.largeTitle.bold())
                        if let subtitle = nonempty(book.subtitle) {
                            Text(subtitle).font(.title3).foregroundStyle(.secondary)
                        }
                        if let author = nonempty(book.author) {
                            Text("by \(author)").font(.headline)
                        }
                        if let description = nonempty(book.description) {
                            Text(description).lineSpacing(4).padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                    metadataRow("Editor", book.editor)
                    metadataRow("Publisher", book.publisher)
                    metadataRow("Year", book.year.map(String.init))
                    metadataRow("Edition", book.edition)
                    metadataRow("ISBN", book.isbn)
                    metadataRow("Language", book.language)
                    metadataRow("Version", book.version)
                    metadataRow("Sections", String(sectionCount))
                    metadataRow("Media", String(media.count))
                    metadataRow("Created", book.created?.formatted(date: .long, time: .omitted))
                    metadataRow("Last Updated", book.lastModified?.formatted(date: .long, time: .omitted))
                    metadataRow("Editable", book.isEditable ? "Yes" : "No")
                    metadataRow("Copyright", book.copyright)
                    metadataRow("License", book.license)
                }

                if !book.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags").font(.headline)
                        WrappingRow(spacing: 6) {
                            ForEach(book.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var coverView: some View {
        if let cover,
           let url = BookReaderMediaResolver.url(
            for: cover.filename,
            moduleID: book.id,
            libraryRootURL: libraryRootURL
           ) {
            BookImageView(url: url, alt: cover.alt, caption: "") { _, _ in }
                .frame(width: 180, height: 250)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 58))
                .foregroundStyle(.secondary)
                .frame(width: 180, height: 250)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("No book cover")
        }
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value = nonempty(value) {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct PresentedBookImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let caption: String
}
