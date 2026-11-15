import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

/// What the field is offering to do with what has been typed.
/// Where the book list is scrolled to, for the track beside it.
private struct PassagePickerScrollPosition: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
}

/// A slim track beside the book list with a thumb for the part in view.
/// Not a control: the list scrolls as lists do.
private struct PassagePickerScrollTrack: View {
    let position: PassagePickerScrollPosition

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            if position.content > position.visible, position.visible > 0 {
                let fraction = position.visible / position.content
                let thumb = max(height * fraction, 24)
                let travel = max(position.content - position.visible, 1)
                let progress = min(max(position.offset / travel, 0), 1)
                ZStack(alignment: .top) {
                    Capsule().fill(Color.lampTileFill)
                    Capsule()
                        .fill(Color.lampSecondaryText.opacity(0.7))
                        .frame(height: thumb)
                        .offset(y: (height - thumb) * progress)
                }
            }
        }
        .frame(width: 4)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A chapter or verse in the passage picker's grid. The one being read is
/// solid accent, as the chosen book is; the rest are quiet tiles that lift
/// under the pointer.
private struct PassagePickerCell: View {
    let number: Int
    let isCurrent: Bool
    let isRinged: Bool
    @State private var isHovered = false

    var body: some View {
        Text(number.formatted())
            .monospacedDigit()
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: 42, height: 32)
            // Raised tiles, a step lighter than the popover and edged, rather
            // than grey blocks on grey, which read as heavy and flat.
            .background(
                isCurrent ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(isHovered ? Color.lampRowHover : Color.lampRaisedTile),
                in: RoundedRectangle(cornerRadius: LampMetrics.tileRadius)
            )
            // A hairline round each tile, so its edge holds in both modes.
            .overlay {
                if !isCurrent {
                    RoundedRectangle(cornerRadius: LampMetrics.tileRadius)
                        .strokeBorder(Color.lampCardStroke)
                }
            }
            .overlay {
                // The focus ring, drawn on the cell rather than around the
                // grid; see the chapter grid's overlay.
                if isRinged {
                    RoundedRectangle(cornerRadius: LampMetrics.tileRadius)
                        .strokeBorder(isCurrent ? Color.primary.opacity(0.55) : Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct PassagePickerOffer {
    let icon: String
    let title: String
    let action: () -> Void
}

/// Hears a force click on a chapter in the passage picker, which SwiftUI has
/// no gesture for. The deeper press arrives as pressure events rather than as
/// a click, so they are watched on their way through the app, and the grid's
/// hover says which chapter the pointer is on.
@MainActor
private final class PassagePickerForceClick: ObservableObject {
    /// The chapter force clicked, each time one is.
    let chapters = PassthroughSubject<Int, Never>()
    private var hoveredChapter: Int?
    private var stage = 0
    private var eventMonitor: Any?

    init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func hover(_ chapter: Int, isInside: Bool) {
        if isInside {
            hoveredChapter = chapter
        } else if hoveredChapter == chapter {
            hoveredChapter = nil
        }
    }

    /// For when the grid goes, since a cell that leaves under a still
    /// pointer is not always told the pointer has left it.
    func clearHover() {
        hoveredChapter = nil
    }

    private func observe(_ event: NSEvent) {
        // Pressure events keep arriving while the press is held, so the
        // force click is the step into the second stage, not every event
        // that reports it.
        defer { stage = event.stage }
        guard event.stage == 2, stage < 2, let hoveredChapter else { return }
        chapters.send(hoveredChapter)
    }
}

/// The picker behind the reader's passage button, and behind a new tab's plus.
///
/// What the field takes differs between the two. From the reader it also takes
/// words to search for and Strong's keys, which go to the search and to the
/// analysis; a tab opens a chapter and nothing else, so there a reference or a
/// book's name is all it can offer to do.
///
/// Everything here can be reached from the keyboard: Tab and ⇧Tab move through
/// the field, the offer, the translation and the two columns, the arrows move
/// within whichever has focus, and Return takes it. See
/// `LampPassagePickerKeys` for why the ring is kept rather than left to macOS.
///
/// Holding a chapter, force clicking it, or Space while the grid has the
/// keyboard shows that chapter's verses in the grid's place, a level down,
/// with a way back to the chapters above them; Esc goes back too.
struct PassagePickerPopover: View {
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
    /// Laid out in a page (`NewReaderTabPage`) rather than in a popover:
    /// on the page's own ground, with no fill or margin of its own.
    var isInline = false
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
    /// The chapter whose verses the grid shows in place of the chapters, or
    /// nil while it shows the chapters.
    @State private var verseChapter: Int?
    /// That chapter's verses, read from the chapter itself so that a verse
    /// the translation leaves out has no cell. Nil while they load.
    @State private var verses: [Int]?
    @State private var versesError: String?
    /// The verse the arrows reached, which Return opens.
    @State private var verseNumber = 1
    @State private var scrollToVerse: Int?
    @StateObject private var forceClick = PassagePickerForceClick()
    @State private var booksScroll = PassagePickerScrollPosition()
    @FocusState private var focus: LampPassagePickerStop?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headline {
                Text(headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // Large: typing a reference is the fastest way through the picker.
            TextField(fieldPrompt, text: $typed)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
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
                    TranslationPickerOptions(translations: model.translations, tag: \.id)
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
                .frame(maxWidth: .infinity, minHeight: Self.columnsHeight)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.columnsHeight)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // What each column chooses, named, so the two levels read
                    // as book then chapter at a glance.
                    HStack(spacing: 25) {
                        Text("Book")
                            .lampSectionHeading()
                            .padding(.leading, 8)
                            .frame(width: Self.booksColumnWidth, alignment: .leading)
                        Text(verseChapter == nil ? "Chapter" : "Verse")
                            .lampSectionHeading()
                    }
                    .accessibilityHidden(true)
                    HStack(alignment: .top, spacing: 12) {
                        booksList
                        Divider()
                        passageColumn
                    }
                    .frame(height: Self.columnsHeight)
                }
            }
        }
        // Wide enough for what is inside it. The books column, the divider,
        // the chapter grid and the padding add up to this; a narrower frame
        // squeezed the padding away on one side, so the field's focus ring
        // sat against the popover's edge while the other side kept its
        // margin.
        .padding(isInline ? 0 : Self.padding)
        .frame(width: isInline ? Self.inlineWidth : Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Opaque, and one step off the page in both appearances. The
        // popover's glass let the passage behind it through as a smear of
        // grey words under the books and chapters, which is noise exactly
        // where the eye is choosing; and on the white page its edge all but
        // disappeared.
        .background(isInline ? Color.clear : Color.lampPopoverFill)
        .presentationBackground(Color.lampPopoverFill)
        .onAppear {
            resetSelection()
            focus = .field
        }
        .onReceive(forceClick.chapters) { openVerses($0) }
        .onKeyPress(keys: [.tab, Self.backTab]) { press in
            let backwards = press.key == Self.backTab || press.modifiers.contains(.shift)
            focus = LampPassagePickerKeys.stepping(from: focus, by: backwards ? -1 : 1, through: ring)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            arrow(press.key)
        }
        .onKeyPress(.return) { commitFocused() }
        // Space looks inside the chapter the grid's ring is on, as it looks
        // inside a file in the Finder; Esc comes back out.
        .onKeyPress(.space) {
            guard focus == .chapters, verseChapter == nil, selectedBook != nil else { return .ignored }
            openVerses(chapterNumber)
            return .handled
        }
        .onKeyPress(.escape) {
            guard verseChapter != nil else { return .ignored }
            closeVerses()
            return .handled
        }
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
            verseChapter = nil
        }
        .onChange(of: bookNumber) { oldValue, newValue in
            guard oldValue != newValue else { return }
            verseChapter = nil
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
    private static let booksColumnWidth: Double = 176
    private static let chaptersColumnWidth: Double = 246
    private static let padding: Double = 20
    /// The picker's width in a popover.
    static let width: Double = booksColumnWidth + chaptersColumnWidth + 65
    /// And in a page, without the popover's margin.
    static let inlineWidth: Double = width - 2 * padding
    /// Tall enough for a dozen books at once, and the 50 chapters of Genesis
    /// with no more than a short scroll.
    private static let columnsHeight: Double = 352
    /// The chapters' grid and the verses' alike, so the arrow keys and the
    /// layout agree about what "down" is in both.
    private static let gridColumns = Array(
        repeating: GridItem(.fixed(42), spacing: 6),
        count: LampPassagePickerKeys.chapterColumns
    )
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
        trimmedTyped.isEmpty ? nil : LampSearchQuery(trimmedTyped).reference(bookNames: bookNames)
    }

    /// The picker's translation's own names for its books, which a typed
    /// passage may use ("Génesis 1") beside the English ones.
    private var bookNames: [Int: String] {
        Dictionary(books.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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
                title: "Go to \(reference.description(bookNames: bookNames))",
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
            passages: !isLoadingBooks && errorMessage == nil
        )
    }

    /// The books the typed text narrows to. Anything that parses as a
    /// reference is handled above, so this is the half-typed case: "jo"
    /// while you are still deciding between John and Joshua.
    private var matchingBooks: [LampTranslationBook] {
        guard !trimmedTyped.isEmpty, typedReference == nil else { return books }
        // Accents aside, so "Genesis" finds a Spanish translation's Génesis.
        return books.filter {
            $0.name.range(of: trimmedTyped, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var booksList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(matchingBooks) { book in
                        if let testament = testamentHeading(before: book) {
                            Text(testament)
                                .lampSectionHeading()
                                .padding(.horizontal, 8)
                                .padding(.top, book.id == matchingBooks.first?.id ? 2 : 10)
                                .padding(.bottom, 3)
                                .accessibilityAddTraits(.isHeader)
                        }
                        Button {
                            focus = .books
                            bookNumber = book.id
                        } label: {
                            Text(book.name)
                                .lineLimit(1)
                                .fontWeight(book.id == bookNumber ? .semibold : .regular)
                                .foregroundStyle(book.id == bookNumber ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                // The accent, solid, as a list draws the row
                                // it has chosen and the grid the chapter
                                // being read. `.selection` drew the gray a
                                // list shows when it is not focused, which
                                // barely showed against the popover (user,
                                // 2026-11-05), and a pale tint of the accent
                                // was hardly better in dark.
                                .background(
                                    book.id == bookNumber ? AnyShapeStyle(.tint)
                                        : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: LampMetrics.tileRadius - 1)
                                )
                                .overlay {
                                    // The focus ring, on the book the arrows
                                    // reached. Only while the column has the
                                    // keyboard: the row stays filled when the
                                    // keyboard is elsewhere, as the book the
                                    // chapters belong to.
                                    if focus == .books, book.id == bookNumber {
                                        RoundedRectangle(cornerRadius: LampMetrics.tileRadius - 1)
                                            .strokeBorder(Color.primary.opacity(0.55), lineWidth: 2)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(book.id)
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(width: Self.booksColumnWidth)
            // The list goes on past both edges, which a track beside it shows
            // all the time: where in the 66 books the visible ones are, and
            // how much more there is either way. The system's overlay
            // scroller only shows while scrolling, and fading the rows out at
            // the edges made them look disabled.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: PassagePickerScrollPosition.self) { geometry in
                PassagePickerScrollPosition(
                    offset: geometry.contentOffset.y,
                    content: geometry.contentSize.height,
                    visible: geometry.containerSize.height
                )
            } action: { _, position in
                booksScroll = position
            }
            .overlay(alignment: .trailing) {
                PassagePickerScrollTrack(position: booksScroll)
                    .offset(x: 7)
            }
            .focusable()
            .focused($focus, equals: .books)
            .focusEffectDisabled()
            // As in the chapter grid: the ring sits on the row itself, since
            // ringing the whole column says only that the keyboard is
            // somewhere in it. While what is typed narrows the books to ones
            // the chosen book is not among there is no row to ring, so the
            // column says so on its own behalf.
            .overlay {
                if !matchingBooks.contains(where: { $0.id == bookNumber }) {
                    focusRing(.books, cornerRadius: 8)
                }
            }
            // Open on the book being read, rather than at Genesis with the
            // reader somewhere in Kings. Once the books are in the list, and a
            // turn after they are laid out: asked for on appearing, the list
            // was still empty or not yet laid out, the scroll was dropped, and
            // the column opened at Genesis with John selected out of sight.
            .task(id: books.map(\.id)) {
                await Task.yield()
                proxy.scrollTo(bookNumber, anchor: .center)
            }
            .onChange(of: scrollToBook) { _, book in
                guard let book else { return }
                proxy.scrollTo(book, anchor: .center)
            }
        }
    }

    /// The chapter grid, or one chapter's verses in its place. The keyboard
    /// stop is the column rather than either grid, so focus stays put while
    /// one grid gives way to the other.
    private var passageColumn: some View {
        ZStack(alignment: .top) {
            if let verseChapter, let selectedBook {
                verseLevel(book: selectedBook, chapter: verseChapter)
                    .transition(.move(edge: .trailing))
            } else {
                chapterGrid
                    .transition(.move(edge: .leading))
            }
        }
        .frame(width: Self.chaptersColumnWidth)
        .clipped()
        .focusable()
        .focused($focus, equals: .chapters)
        .focusEffectDisabled()
    }

    private var chapterGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let selectedBook {
                    LazyVGrid(columns: Self.gridColumns, spacing: 6) {
                        ForEach(1...selectedBook.chapterCount, id: \.self) { chapter in
                            Button {
                                // A hold that showed the verses ends with the
                                // chapter being let go of, which is not a
                                // click on it.
                                guard verseChapter == nil else { return }
                                commit(book: selectedBook.id, chapter: chapter)
                            } label: {
                                gridCell(
                                    chapter,
                                    isCurrent: isCurrent(book: selectedBook.id, chapter: chapter),
                                    // On the chapter the arrows reached and
                                    // Return would open. Only while the grid
                                    // has the keyboard: with a mouse it is
                                    // whichever is under the pointer.
                                    isRinged: focus == .chapters && chapter == chapterNumber
                                )
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    openVerses(chapter)
                                }
                            )
                            .onHover { forceClick.hover(chapter, isInside: $0) }
                            .help("Hold or force click for its verses")
                            .accessibilityAction(named: "Choose a verse") { openVerses(chapter) }
                            .id(chapter)
                        }
                    }
                    .padding(.vertical, 2)
                    // Said under the grid, where a short book leaves room:
                    // holding a chapter for its verses was only in a tooltip.
                    Label("Hold a chapter to choose a verse", systemImage: "hand.tap")
                        .font(.callout)
                        .foregroundStyle(Color.lampSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                        .padding(.leading, 2)
                        .accessibilityHidden(true)
                } else {
                    Text("Choose a book")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            // With a book chosen the ring sits on the chapter itself, above,
            // which is also what says the arrows move within the grid rather
            // than Tab. Ringing the grid as well read as the whole grid being
            // selected (user, 2026-10-31). Without a book there is nothing
            // inside to ring, so the grid says so on its own behalf.
            .overlay {
                if selectedBook == nil {
                    focusRing(.chapters, cornerRadius: 8)
                }
            }
            // On the chapter being read, as the books open on its book: at
            // Psalm 119 the grid would otherwise open on 1 to 40. Again on
            // coming back from a chapter's verses, which leaves the grid
            // where that chapter is.
            .task(id: selectedBook?.id) {
                await Task.yield()
                proxy.scrollTo(chapterNumber, anchor: .center)
            }
            .onChange(of: scrollToChapter) { _, chapter in
                guard let chapter else { return }
                proxy.scrollTo(chapter, anchor: .center)
            }
        }
    }

    /// A chapter's verses, a level below the chapters: the way back sits
    /// above them, beside the chapter they belong to.
    private func verseLevel(book: LampTranslationBook, chapter: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: closeVerses) {
                    // "Back to", as every back row in the app says.
                    Label("Back to Chapters", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to the chapters (Esc)")
                Spacer(minLength: 0)
                Text("\(book.name) \(chapter)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)

            if let versesError {
                Label(versesError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let verses, verses.isEmpty {
                Text("No verses in this chapter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let verses {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Self.gridColumns, spacing: 6) {
                            ForEach(verses, id: \.self) { verse in
                                Button {
                                    commit(book: book.id, chapter: chapter, verse: verse)
                                } label: {
                                    gridCell(
                                        verse,
                                        isCurrent: false,
                                        isRinged: focus == .chapters && verse == verseNumber
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(verse)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: scrollToVerse) { _, verse in
                        guard let verse else { return }
                        proxy.scrollTo(verse, anchor: .center)
                    }
                }
            }
        }
        .task(id: chapter) { await loadVerses(book: book.id, chapter: chapter) }
    }

    /// One cell of either grid.
    private func gridCell(_ number: Int, isCurrent: Bool, isRinged: Bool) -> some View {
        PassagePickerCell(number: number, isCurrent: isCurrent, isRinged: isRinged)
    }

    /// The heading over the first book of each testament, by the canonical
    /// numbering every translation's books carry: 1–39 the Old, 40–66 the
    /// New. Books past 66 (deuterocanonical) go unheaded under the New.
    private func testamentHeading(before book: LampTranslationBook) -> String? {
        let books = matchingBooks
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return nil }
        let previous = index > books.startIndex ? books[books.index(before: index)].id : nil
        if book.id <= 39, previous == nil { return "Old Testament" }
        if (40...66).contains(book.id), previous.map({ $0 < 40 }) ?? true { return "New Testament" }
        return nil
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
            if verseChapter != nil {
                guard let verses else { return .ignored }
                verseNumber = LampPassagePickerKeys.verse(from: verseNumber, by: offset, in: verses)
                scrollToVerse = verseNumber
                return .handled
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
        case .chapters where verseChapter != nil:
            guard let selectedBook, let verseChapter, verses?.contains(verseNumber) == true else {
                return .ignored
            }
            commit(book: selectedBook.id, chapter: verseChapter, verse: verseNumber)
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

    private func commit(book: Int, chapter: Int, verse: Int? = nil) {
        isPresented = false
        open(ReaderLocation(
            translationID: translationID,
            bookNumber: book,
            chapterNumber: chapter,
            verseReference: verse.map { book * 1_000_000 + chapter * 1_000 + $0 }
        ))
    }

    // MARK: - A chapter's verses

    private func openVerses(_ chapter: Int) {
        guard verseChapter == nil, selectedBook != nil else { return }
        forceClick.clearHover()
        chapterNumber = chapter
        verses = nil
        versesError = nil
        withAnimation(.easeInOut(duration: 0.2)) { verseChapter = chapter }
    }

    private func closeVerses() {
        forceClick.clearHover()
        withAnimation(.easeInOut(duration: 0.2)) { verseChapter = nil }
    }

    @MainActor
    private func loadVerses(book: Int, chapter: Int) async {
        let requestedTranslationID = translationID
        do {
            let loaded = try await model.library.chapter(
                moduleID: requestedTranslationID,
                bookNumber: book,
                chapterNumber: chapter
            )
            guard translationID == requestedTranslationID, verseChapter == chapter else { return }
            // A verse 0, a psalm's title in a translation that numbers it
            // so, is the top of the chapter, which the chapter itself opens.
            let numbers = Array(Set(loaded.verses.map(\.number).filter { $0 > 0 })).sorted()
            verses = numbers
            verseNumber = numbers.first ?? 1
        } catch {
            guard translationID == requestedTranslationID, verseChapter == chapter else { return }
            versesError = error.localizedDescription
        }
    }

    private func resetSelection() {
        // A new tab has no place of its own, and starts where the library
        // last was: the translation being read and its book, not the first
        // of everything.
        let fromLibrary = workspace.isBlank
        let readTranslationID = fromLibrary ? model.selectedTranslationID : workspace.selectedTranslationID
        translationID = readTranslationID ?? model.translations.first?.id ?? ""
        books = !fromLibrary && translationID == workspace.selectedTranslationID ? workspace.books : []
        bookNumber = (fromLibrary ? model.selectedBookNumber : workspace.selectedBookNumber) ?? books.first?.id ?? 0
        chapterNumber = fromLibrary ? model.selectedChapterNumber : workspace.selectedChapterNumber
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
