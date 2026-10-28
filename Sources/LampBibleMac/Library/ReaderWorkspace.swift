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
    @Published private(set) var contents = ReaderChapterContents.empty
    @Published private(set) var isLoadingChapter = false

    /// The library this workspace reads through. Set once the window has an
    /// environment to take it from, so a workspace exists before it can read.
    private weak var model: LibraryModel?
    private var chapterTask: Task<Void, Never>?

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

    /// Goes to a place, reading it if this workspace is not there already.
    func open(translationID: String?, book: Int?, chapter: Int, verse: Int?) {
        let movedChapter = translationID != selectedTranslationID
            || book != selectedBookNumber
            || chapter != selectedChapterNumber
        selectedTranslationID = translationID
        selectedBookNumber = book
        selectedChapterNumber = max(chapter, 1)
        selectedVerseReference = verse
        guard movedChapter else { return }
        loadBooksAndChapter()
    }

    /// Chooses a verse within the chapter already open.
    func focusVerse(_ reference: Int?) {
        selectedVerseReference = reference
    }

    /// Reads this workspace's chapter again, for when the library beneath it
    /// has changed — a highlight made, a note written, a module installed.
    func reload() {
        loadBooksAndChapter()
    }

    private func loadBooksAndChapter() {
        guard let model, let translationID = selectedTranslationID else {
            contents = .empty
            return
        }
        chapterTask?.cancel()
        isLoadingChapter = true
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
            } catch {
                guard !Task.isCancelled else { return }
                model.errorMessage = error.localizedDescription
                contents = .empty
            }
        }
    }
}
