#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import Foundation
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
    /// This window's own back and forward. Two windows each keep their own
    /// trail: going back in one has nothing to do with where the other has
    /// been.
    private var history = ReaderNavigationHistory()

    var chapter: LampChapter? { contents.chapter }
    var selectedBook: LampTranslationBook? {
        books.first { $0.id == selectedBookNumber }
    }

    /// Hands the workspace the library, and the place to open if it has none
    /// of its own yet.
    ///
    /// Called when the window appears rather than at init: a `@StateObject` is
    /// made before the view has an environment, so there is nothing to read
    /// through at that point.
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
    func adoptIfUnplaced(_ location: ReaderLocation?) {
        guard selectedTranslationID == nil, let location else { return }
        open(
            translationID: location.translationID,
            book: location.bookNumber,
            chapter: location.chapterNumber,
            verse: location.verseReference
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
        loadBooksAndChapter()
    }

    private func loadBooksAndChapter() {
        guard let model, let translationID = selectedTranslationID else {
            contents = .empty
            mirror()
            return
        }
        chapterTask?.cancel()
        isLoadingChapter = true
        // Where this window is, before what it is reading arrives: a move
        // should reach the rest of the app at once, not a chapter later.
        mirror()
        chapterTask = Task {
            defer { if !Task.isCancelled { isLoadingChapter = false } }
            do {
                let loadedBooks = try await model.library.translationBooks(moduleID: translationID)
                guard !Task.isCancelled, selectedTranslationID == translationID else { return }
                books = loadedBooks
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
                contents = read
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
