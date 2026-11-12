#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import AppKit
import Foundation
import SwiftUI
import LampCore

/// Where one reader window is in scripture, and what it has read for that
/// place.
///
/// A window owns one of these. The library owns what exists — the installed
/// modules, every highlight ever made, the plans — and a workspace owns where
/// you are and whatever had to be read to show it. That line is what lets two
/// windows sit on different chapters without a second copy of the library
/// between them.
///
/// Tabs are places within one workspace, which is why they are not workspaces
/// themselves: a window's tab bar offers somewhere to go, and this says where
/// the window went.
@MainActor
final class ReaderWorkspace: ObservableObject {
    /// Words typed into the reader's passage field that turned out not to be
    /// a passage. The root watches this and shows the search; the reader has
    /// no way to reach the sidebar's selection itself, and this is the object
    /// they already share.
    @Published var requestedSearch: String?
    /// A Strong's key typed into the same field, which belongs to the
    /// analysis rather than to a text search.
    @Published var requestedStrongsKey: String?

    @Published private(set) var selectedTranslationID: String?
    @Published private(set) var selectedBookNumber: Int?
    @Published private(set) var selectedChapterNumber = 1
    @Published private(set) var selectedVerseReference: Int?
    @Published private(set) var books: [LampTranslationBook] = []
    /// What was read for this window's chapter. Its highlights and notes are
    /// handed to the library, which keeps them for every window; what stays
    /// here is the chapter itself.
    @Published private(set) var contents = ReaderChapterContents.empty
    @Published private(set) var isLoadingChapter = false

    /// The library this workspace reads through. Set once the window has an
    /// environment to take it from, so a workspace exists before it can read.
    private weak var model: LibraryModel?
    private var chapterTask: Task<Void, Never>?
    /// Chapters this window has read lately, so going back to one — a tab
    /// chosen again, mostly — shows it at once rather than "Loading
    /// Chapter…" and a read. It is still read again underneath, quietly:
    /// highlights and notes edited since live in the library, not here.
    private var recentChapters = ReaderRecentChapters()
    /// Where each tab was scrolled, so choosing it again goes back to where
    /// it was left rather than scrolling to its selected verse.
    let scrollMemory = ReaderScrollMemory()
    /// This window's own back and forward. Two windows each keep their own
    /// trail: going back in one has nothing to do with where the other has
    /// been.
    private var history = ReaderNavigationHistory()

    var chapter: LampChapter? { contents.chapter }
    var selectedBook: LampTranslationBook? {
        books.first { $0.id == selectedBookNumber }
    }

    /// Hands the workspace the library, and opens the window's place: the one
    /// given, or else the library's choice.
    ///
    /// Called once the library has been read rather than at init: a
    /// `@StateObject` is made before the view has an environment, and a
    /// chapter read before the library knows its note and highlight modules
    /// would come without them.
    func start(model: LibraryModel, at location: ReaderLocation?) {
        guard self.model == nil else { return }
        self.model = model
        if let location {
            open(
                translationID: location.translationID,
                book: location.bookNumber,
                chapter: location.chapterNumber,
                verse: nil
            )
        } else {
            adoptIfUnplaced()
        }
    }

    /// Takes the library's idea of where to start, for a window that has
    /// nowhere of its own yet.
    ///
    /// A first launch, or an empty library that has just had its first
    /// translation installed: the library chooses what to open, and a window
    /// that has not been anywhere follows it. A window already reading
    /// something ignores this, which is the whole point of the window owning
    /// its place.
    func adoptIfUnplaced() {
        guard let model, selectedTranslationID == nil,
              let translationID = model.selectedTranslationID else { return }
        // The book may be unknown, on a first launch: the translation's first
        // is opened then.
        open(
            translationID: translationID,
            book: model.selectedBookNumber,
            chapter: model.selectedChapterNumber,
            verse: model.selectedVerseReference
        )
    }

    /// Goes to a place, reading it if this workspace is not there already.
    func open(translationID: String?, book: Int?, chapter: Int, verse: Int?) {
        let movedChapter = translationID != selectedTranslationID
            || book != selectedBookNumber
            || chapter != selectedChapterNumber
        selectedTranslationID = translationID
        selectedBookNumber = book
        selectedChapterNumber = max(chapter, 1)
        selectedVerseReference = verse
        guard movedChapter else {
            mirror()
            return
        }
        loadBooksAndChapter()
    }

    /// Chooses a verse within the chapter already open.
    func focusVerse(_ reference: Int?) {
        selectedVerseReference = reference
        mirror()
    }

    // MARK: - Moving about

    var canNavigateBackward: Bool {
        guard let selectedBookNumber,
              let index = books.firstIndex(where: { $0.id == selectedBookNumber })
        else { return false }
        return selectedChapterNumber > 1 || index > books.startIndex
    }

    var canNavigateForward: Bool {
        guard let book = selectedBook,
              let index = books.firstIndex(where: { $0.id == book.id })
        else { return false }
        return selectedChapterNumber < book.chapterCount
            || index < books.index(before: books.endIndex)
    }

    var canGoBackInHistory: Bool { history.canGoBack }
    var canGoForwardInHistory: Bool { history.canGoForward }
    var recentLocations: [ReaderLocation] {
        Array(history.backStack.reversed().prefix(20))
    }

    var currentLocation: ReaderLocation? {
        guard let selectedTranslationID, let selectedBookNumber else { return nil }
        return ReaderLocation(
            translationID: selectedTranslationID,
            bookNumber: selectedBookNumber,
            chapterNumber: selectedChapterNumber,
            verseReference: selectedVerseReference
        )
    }

    func selectTranslation(_ moduleID: String) {
        guard selectedTranslationID != moduleID || books.isEmpty else { return }
        selectedTranslationID = moduleID
        selectedBookNumber = nil
        selectedChapterNumber = 1
        selectedVerseReference = nil
        loadBooksAndChapter()
    }

    func selectBook(_ bookNumber: Int) {
        guard selectedBookNumber != bookNumber || chapter == nil else { return }
        selectedBookNumber = bookNumber
        selectedChapterNumber = 1
        selectedVerseReference = nil
        record()
        loadBooksAndChapter()
    }

    func selectChapter(_ chapterNumber: Int) {
        guard chapterNumber > 0, chapterNumber != selectedChapterNumber else { return }
        selectedChapterNumber = chapterNumber
        selectedVerseReference = nil
        record()
        loadBooksAndChapter()
    }

    func selectPassage(translationID: String, bookNumber: Int, chapterNumber: Int) {
        guard !translationID.isEmpty, bookNumber > 0, chapterNumber > 0 else { return }
        guard selectedTranslationID != translationID
                || selectedBookNumber != bookNumber
                || selectedChapterNumber != chapterNumber
        else { return }
        selectedTranslationID = translationID
        selectedBookNumber = bookNumber
        selectedChapterNumber = chapterNumber
        selectedVerseReference = nil
        record()
        loadBooksAndChapter()
    }

    func openReference(_ encodedReference: Int, translationID: String? = nil) {
        let parts = LampBibleReferenceFormatter.components(of: encodedReference)
        let translation = translationID ?? selectedTranslationID
        open(
            translationID: translation,
            book: parts.book,
            chapter: parts.chapter,
            verse: encodedReference
        )
        record()
    }

    func navigateBackward() {
        guard let selectedBookNumber,
              let index = books.firstIndex(where: { $0.id == selectedBookNumber })
        else { return }
        if selectedChapterNumber > 1 {
            selectedChapterNumber -= 1
        } else if index > books.startIndex {
            let previous = books[books.index(before: index)]
            self.selectedBookNumber = previous.id
            selectedChapterNumber = previous.chapterCount
        } else {
            return
        }
        selectedVerseReference = nil
        record()
        loadBooksAndChapter()
    }

    func navigateForward() {
        guard let selectedBookNumber,
              let index = books.firstIndex(where: { $0.id == selectedBookNumber })
        else { return }
        let book = books[index]
        if selectedChapterNumber < book.chapterCount {
            selectedChapterNumber += 1
        } else if index < books.index(before: books.endIndex) {
            let next = books[books.index(after: index)]
            self.selectedBookNumber = next.id
            selectedChapterNumber = 1
        } else {
            return
        }
        selectedVerseReference = nil
        record()
        loadBooksAndChapter()
    }

    func goBackInHistory() {
        guard let location = history.goBack() else { return }
        apply(location)
    }

    func goForwardInHistory() {
        guard let location = history.goForward() else { return }
        apply(location)
    }

    func openHistoryLocation(_ location: ReaderLocation) {
        history.visit(location)
        apply(location)
    }

    /// Goes to a tab's place. Changing tabs is not a move to record: back
    /// retraces where this window was taken, not which tabs were chosen.
    func openTab(at location: ReaderLocation) {
        apply(location)
    }

    func clearHistory() {
        history.clear(keeping: currentLocation)
    }

    /// Goes to a place without recording it, for history, which is already
    /// holding the record.
    private func apply(_ location: ReaderLocation) {
        open(
            translationID: location.translationID,
            book: location.bookNumber,
            chapter: location.chapterNumber,
            verse: location.verseReference
        )
    }

    private func record() {
        guard let location = currentLocation else { return }
        history.visit(location)
    }

    /// Tells the library where this window is, when it is the one being used.
    ///
    /// Windows that are not readers — the writing editor, Slide Studio — ask
    /// the library for the current verse, and there is no answer in the data
    /// once several readers disagree. The answer is the reader last used, so
    /// each move reports itself.
    private func mirror() {
        model?.adoptActiveReader(
            translationID: selectedTranslationID,
            book: selectedBookNumber,
            chapter: selectedChapterNumber,
            verse: selectedVerseReference,
            books: books,
            contents: contents
        )
    }

    /// Reads this workspace's chapter again, for when the library beneath it
    /// has changed — a highlight made, a note written, a module installed.
    func reload() {
        recentChapters.removeAll()
        loadBooksAndChapter()
    }

    private func loadBooksAndChapter() {
        guard let model, let translationID = selectedTranslationID else {
            contents = .empty
            mirror()
            return
        }
        chapterTask?.cancel()
        if let book = selectedBookNumber,
           let recent = recentChapters.chapter(translationID: translationID, book: book, chapter: selectedChapterNumber) {
            // Shown at once, and read again below without the loading state:
            // the text cannot have changed, but what is marked on it may have.
            books = recent.books
            contents = recent.contents
            isLoadingChapter = false
        } else {
            isLoadingChapter = true
        }
        // Where this window is, before what it is reading arrives: a move
        // should reach the rest of the app at once, not a chapter later.
        mirror()
        chapterTask = Task {
            defer {
                if !Task.isCancelled {
                    isLoadingChapter = false
                    model.markInitialContentLoaded()
                }
            }
            do {
                let loadedBooks = try await model.library.translationBooks(moduleID: translationID)
                guard !Task.isCancelled, selectedTranslationID == translationID else { return }
                if books != loadedBooks { books = loadedBooks }
                let book = loadedBooks.first { $0.id == selectedBookNumber } ?? loadedBooks.first
                selectedBookNumber = book?.id
                guard let book else {
                    contents = .empty
                    return
                }
                selectedChapterNumber = min(max(selectedChapterNumber, 1), book.chapterCount)

                let read = try await model.chapterContents(
                    translationID: translationID,
                    book: book.id,
                    chapter: selectedChapterNumber
                )
                // The window may have moved on while this was being read.
                // Showing it then would put one chapter's highlights over
                // another chapter's words.
                guard !Task.isCancelled,
                      selectedTranslationID == translationID,
                      selectedBookNumber == book.id,
                      read.chapter?.number == selectedChapterNumber
                else { return }
                recentChapters.keep(read, books: loadedBooks, translationID: translationID)
                // Only a change is published: a chapter shown from the recent
                // ones and read again unchanged would otherwise lay the whole
                // passage out a second time.
                if contents != read { contents = read }
                // Highlights and notes go to the library, keyed by verse
                // reference, which is unique across the Bible: one made in
                // either window is then seen by both, and by the window that
                // made it without reading the chapter again.
                model.absorbChapterContents(read)
                mirror()
            } catch {
                guard !Task.isCancelled else { return }
                model.errorMessage = error.localizedDescription
                contents = .empty
            }
        }
    }
}

/// The chapters a window read last, most recent last, a few at most.
struct ReaderRecentChapters {
    private struct Entry {
        let translationID: String
        let books: [LampTranslationBook]
        let contents: ReaderChapterContents
    }

    /// Enough for the tabs most people keep open; each holds a chapter's
    /// text and what is marked on it.
    static let capacity = 8
    private var entries: [Entry] = []

    func chapter(translationID: String, book: Int, chapter: Int)
        -> (books: [LampTranslationBook], contents: ReaderChapterContents)? {
        entries.last { entry in
            entry.translationID == translationID
                && entry.contents.chapter?.book.id == book
                && entry.contents.chapter?.number == chapter
        }.map { ($0.books, $0.contents) }
    }

    mutating func keep(_ contents: ReaderChapterContents, books: [LampTranslationBook], translationID: String) {
        guard let read = contents.chapter else { return }
        entries.removeAll { entry in
            entry.translationID == translationID
                && entry.contents.chapter?.book.id == read.book.id
                && entry.contents.chapter?.number == read.number
        }
        entries.append(Entry(translationID: translationID, books: books, contents: contents))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    mutating func removeAll() { entries.removeAll() }
}

/// Where each of a window's tabs was scrolled.
///
/// Choosing a tab used to open its chapter as a jump from search does,
/// scrolling to its selected verse with an animation, so every switch moved
/// the page. Each tab now goes back to the exact offset it was left at, and
/// so does the window's open tab when the app is opened again.
///
/// A plain class: nothing observes it, so scrolling invalidates nothing. The
/// offset is the reader's own scroll view's, read from it and given back to
/// it, so no coordinate is converted. It is put back during the layout that
/// sizes the passage, before the passage is first drawn; put back after,
/// the page showed at its top for a frame and then jumped.
@MainActor
final class ReaderScrollMemory {
    private struct Place: Codable {
        /// The passage the offset was taken in: an offset means nothing in
        /// another chapter.
        let passage: String
        let y: Double
    }

    private struct Pending {
        let place: Place
        let asked: Date
        /// When its passage first appeared. A launch can take seconds to
        /// show a chapter; only once it is there does the wait begin.
        var seen: Date?
    }

    private let defaults: UserDefaults
    /// Where its offsets are kept: the reader's and the study pane's are
    /// separate memories, one place per tab each.
    private let keyPrefix: String
    private weak var scrollView: NSScrollView?
    private var scrollPassage: String?
    private var places: [UUID: Place] = [:]
    private var pending: Pending?
    /// The tab the reader is showing, whose place a settled scroll records.
    private var currentTab: UUID?

    init(defaults: UserDefaults = .standard, keyPrefix: String = "reader.tabs.scroll.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// The reader's scroll view, from inside the passage it is showing.
    func register(_ scrollView: NSScrollView, passage: String) {
        self.scrollView = scrollView
        scrollPassage = passage
        if pending?.place.passage == passage, pending?.seen == nil { pending?.seen = Date() }
    }

    /// Notes where a tab is scrolled: the tab being left, or the one being
    /// read when its scrolling settles. Kept across launches.
    func save(tab: UUID) {
        // Not while a tab is being put back: the passage is still at the top
        // it opened at, which is not where anyone left it.
        if let pending, !isStale(pending) { return }
        guard let scrollView, let scrollPassage else { return }
        let place = Place(passage: scrollPassage, y: scrollView.contentView.bounds.origin.y)
        guard places[tab]?.passage != place.passage || places[tab]?.y != place.y else { return }
        places[tab] = place
        if let data = try? JSONEncoder().encode(place) {
            defaults.set(data, forKey: key(for: tab))
        }
    }

    /// Records the open tab's place once a scroll has settled, so quitting
    /// — or a crash — keeps it.
    func saveCurrent() {
        if let currentTab { save(tab: currentTab) }
    }

    /// Readies a tab being shown to go back to where it was left: chosen in
    /// the bar, or opened with the window. False when it has no place yet.
    @discardableResult
    func prepare(tab: UUID) -> Bool {
        currentTab = tab
        pending = place(of: tab).map { Pending(place: $0, asked: Date()) }
        return pending != nil
    }

    func forget(tab: UUID) {
        places[tab] = nil
        defaults.removeObject(forKey: key(for: tab))
    }

    /// Whether `passage` is about to be put back where it was left, so the
    /// reader should not scroll it anywhere itself.
    func isRestoring(_ passage: String) -> Bool {
        guard let pending, !isStale(pending) else { return false }
        return pending.place.passage == passage
    }

    /// Puts the passage back where it was left, once its scroll view is
    /// there and laid out. Asked at each layout until it happens; given up
    /// a moment after the passage appears, so a late layout never jumps the
    /// page.
    func restoreIfReady(passage: String) {
        guard let current = pending, current.place.passage == passage, scrollPassage == passage,
              let scrollView, let document = scrollView.documentView else { return }
        guard !isStale(current) else {
            pending = nil
            return
        }
        // Not until the passage has laid out: before, there is nothing to
        // scroll. A passage now shorter (a wider window) stops at its end.
        let clip = scrollView.contentView
        guard document.frame.height > clip.bounds.height else {
            if document.frame.height > 0 { pending = nil }
            return
        }
        pending = nil
        let bottom = max(document.frame.height - clip.bounds.height, 0)
        let y = min(CGFloat(current.place.y), bottom)
        guard clip.bounds.origin.y != y else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The same, for whatever passage the scroll view is showing: after a
    /// switch between two tabs on one chapter, which lays nothing out anew.
    func restoreIfReady() {
        if let scrollPassage { restoreIfReady(passage: scrollPassage) }
    }

    private func place(of tab: UUID) -> Place? {
        if let place = places[tab] { return place }
        guard let data = defaults.data(forKey: key(for: tab)),
              let place = try? JSONDecoder().decode(Place.self, from: data) else { return nil }
        places[tab] = place
        return place
    }

    private func isStale(_ pending: Pending) -> Bool {
        if let seen = pending.seen { return Date().timeIntervalSince(seen) > 1.5 }
        return Date().timeIntervalSince(pending.asked) > 30
    }

    private func key(for tab: UUID) -> String { keyPrefix + tab.uuidString }
}

/// A scroll view, handed to a `ReaderScrollMemory` from inside the content it
/// scrolls, which then puts a chosen tab back where it was left as soon as
/// that content has laid out, and notes where it is each time a scroll by
/// hand ends. `passage` names the content, so an offset is only ever put
/// back on what it was taken from.
struct ScrollMemoryLink: NSViewRepresentable {
    let memory: ReaderScrollMemory
    let passage: String

    func makeNSView(context: Context) -> LinkView {
        let view = LinkView()
        view.memory = memory
        view.passage = passage
        return view
    }

    // Runs on every update of the view around it: it only notes the passage.
    func updateNSView(_ view: LinkView, context: Context) {
        if view.passage != passage { view.passage = passage }
    }

    final class LinkView: NSView {
        weak var memory: ReaderScrollMemory?
        var passage = ""
        private weak var observed: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            memory?.register(scrollView, passage: passage)
            observe(scrollView)
        }

        override func layout() {
            super.layout()
            if let scrollView = enclosingScrollView { memory?.register(scrollView, passage: passage) }
            // In this layout, before the content is first drawn: put back
            // after it, the page showed at its top for a frame and jumped.
            memory?.restoreIfReady(passage: passage)
            // And once more after the pass, for content whose document was
            // not yet its full height when this view was laid out.
            let passage = passage
            DispatchQueue.main.async { [weak self] in
                self?.memory?.restoreIfReady(passage: passage)
            }
        }

        /// A scroll by hand that has ended is where the tab now is.
        private func observe(_ scrollView: NSScrollView) {
            guard observed !== scrollView else { return }
            if let observed {
                NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification, object: observed)
            }
            observed = scrollView
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scrollView
            )
        }

        @objc private func scrollEnded() {
            memory?.saveCurrent()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
