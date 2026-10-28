import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// What a reader holds for one chapter.
///
/// The two filters are the point. Both were applied at the places that fetch,
/// where a second reader would have had to remember them; held here, one
/// chapter's contents cannot disagree with another's about what counts.
struct ReaderChapterContentsTests {
    private func chapter() -> LampChapter {
        LampChapter(
            translationID: "BSB",
            book: LampTranslationBook(
                id: 43, osisID: "John", name: "John", testament: "NT", chapterCount: 21
            ),
            number: 3,
            verses: [],
            headings: []
        )
    }

    private func highlight(
        id: Int64,
        translationID: String,
        reference: Int
    ) -> LampVerseHighlight {
        LampVerseHighlight(
            id: id,
            setID: "personal-highlights:\(translationID)",
            translationID: translationID,
            reference: reference,
            startOffset: 0,
            endOffset: 4
        )
    }

    private func note(moduleID: String, reference: Int) -> LampVerseNote {
        LampVerseNote(
            id: "\(moduleID)-\(reference)",
            moduleID: moduleID,
            reference: reference,
            title: nil,
            content: "A note"
        )
    }

    /// A module's highlight carries offsets into the text it was made against.
    /// Shown over another translation it would mark whichever words happen to
    /// sit at those offsets.
    @Test func amodulesHighlightsForAnotherTranslationAreLeftOut() {
        let contents = ReaderChapterContents(
            chapter: chapter(),
            translationID: "BSB",
            highlights: [],
            notes: [],
            installedHighlights: [
                highlight(id: 1, translationID: "BSB", reference: 43_003_016),
                highlight(id: 2, translationID: "KJV", reference: 43_003_016),
            ],
            installedNotes: []
        )

        #expect(contents.installedHighlightsByReference[43_003_016]?.map(\.id) == [1])
    }

    /// The same read returns the reader's notes and installed modules' notes.
    /// Only the reader's own mark a verse as noted; a module's are somebody
    /// else's writing and are shown as that.
    @Test func onlyThereadersOwnNotesMarkAVerseAsNoted() {
        let contents = ReaderChapterContents(
            chapter: chapter(),
            translationID: "BSB",
            highlights: [],
            notes: [
                note(moduleID: "personal-notes", reference: 43_003_016),
                note(moduleID: "matthew-henry", reference: 43_003_017),
            ],
            installedHighlights: [],
            installedNotes: [note(moduleID: "matthew-henry", reference: 43_003_017)]
        )

        #expect(contents.noteReferences == [43_003_016])
        #expect(contents.installedNotesByReference[43_003_017]?.count == 1)
    }

    @Test func thereadersOwnHighlightsAreKeptByVerse() {
        let contents = ReaderChapterContents(
            chapter: chapter(),
            translationID: "BSB",
            highlights: [
                highlight(id: 1, translationID: "BSB", reference: 43_003_016),
                highlight(id: 2, translationID: "BSB", reference: 43_003_016),
                highlight(id: 3, translationID: "BSB", reference: 43_003_017),
            ],
            notes: [],
            installedHighlights: [],
            installedNotes: []
        )

        #expect(contents.highlightsByReference[43_003_016]?.count == 2)
        #expect(contents.highlightsByReference[43_003_017]?.count == 1)
    }

    /// A reader that has not read anything yet holds nothing, rather than
    /// whatever the last chapter left behind.
    @Test func anemptyReaderHoldsNothing() {
        #expect(ReaderChapterContents.empty.chapter == nil)
        #expect(ReaderChapterContents.empty.noteReferences.isEmpty)
        #expect(ReaderChapterContents.empty.highlightsByReference.isEmpty)
    }
}
