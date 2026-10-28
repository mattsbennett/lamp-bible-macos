import Foundation
import LampCore

/// Everything a reader shows for one chapter of one translation.
///
/// Gathered as a value rather than left as separate properties, because these
/// belong together: they are all read for the same chapter, they are all
/// replaced when the reader moves, and holding half of one chapter beside half
/// of another is never right. A window reading Genesis and a window reading
/// John need one of these each.
///
/// The library's own data — which modules are installed, every highlight ever
/// made — stays in the library. This is what a place in scripture looks like
/// once that data has been read for it.
public struct ReaderChapterContents: Equatable, Sendable {
    public var chapter: LampChapter?
    /// The reader's own highlights, by verse.
    public var highlightsByReference: [Int: [LampVerseHighlight]]
    /// Highlights from installed modules, by verse.
    public var installedHighlightsByReference: [Int: [LampVerseHighlight]]
    /// Verses the reader has written a note on.
    public var noteReferences: Set<Int>
    /// Notes from installed modules, by verse.
    public var installedNotesByReference: [Int: [LampVerseNote]]

    public static let empty = ReaderChapterContents()

    public init(
        chapter: LampChapter? = nil,
        highlightsByReference: [Int: [LampVerseHighlight]] = [:],
        installedHighlightsByReference: [Int: [LampVerseHighlight]] = [:],
        noteReferences: Set<Int> = [],
        installedNotesByReference: [Int: [LampVerseNote]] = [:]
    ) {
        self.chapter = chapter
        self.highlightsByReference = highlightsByReference
        self.installedHighlightsByReference = installedHighlightsByReference
        self.noteReferences = noteReferences
        self.installedNotesByReference = installedNotesByReference
    }

    /// Sorts what a chapter's reads returned into what the reader asks for.
    ///
    /// Two filters live here rather than at the call sites that fetch, so a
    /// second reader cannot acquire a different idea of them:
    ///
    /// - A module's highlights are kept only where they were made against the
    ///   translation being read. Offsets belong to a particular text, so a
    ///   highlight from another translation would mark the wrong words.
    /// - Only `personal-notes` counts as the reader's own note. The same read
    ///   returns installed modules' notes, which are somebody else's writing
    ///   and are shown as such.
    public init(
        chapter: LampChapter,
        translationID: String,
        highlights: [LampVerseHighlight],
        notes: [LampVerseNote],
        installedHighlights: [LampVerseHighlight],
        installedNotes: [LampVerseNote]
    ) {
        self.chapter = chapter
        self.highlightsByReference = Dictionary(grouping: highlights, by: \.reference)
        self.installedHighlightsByReference = Dictionary(
            grouping: installedHighlights.filter { $0.translationID == translationID },
            by: \.reference
        )
        self.noteReferences = Set(
            notes.filter { $0.moduleID == "personal-notes" }.map(\.reference)
        )
        self.installedNotesByReference = Dictionary(grouping: installedNotes, by: \.reference)
    }
}
