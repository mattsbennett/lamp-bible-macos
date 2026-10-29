import Foundation
import Testing
@testable import LampBibleMacSupport

/// Writing a draft from outside Lamp, and deciding what happens to it when the
/// writer has been working too.
///
/// Everything here is about not losing someone's prose. A write that cannot be
/// shown to be safe is refused, and a draft that arrives after the writer has
/// moved on is kept where they can see it rather than applied over them.
struct WritingWriteTests {
    private let writingID = "living-hope"
    private let original = "# Living Hope\n\nIt asks that we hold to it.\n"

    private func workspace() throws -> (library: URL, support: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-write-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let folder = LampWritingWorkspace.url(libraryRootURL: library, writingID: writingID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(original.utf8).write(
            to: folder.appendingPathComponent(LampWritingWorkspace.draftFilename)
        )
        return (library, support)
    }

    private func draft(in library: URL) throws -> String {
        try LampWritingWorkspace.readDraft(libraryRootURL: library, writingID: writingID)
    }

    // MARK: - The fingerprint

    /// The same words with their accents stored differently are one draft, not
    /// two. Without composing first, a draft that had been through a different
    /// keyboard would read as changed and every write would be refused.
    ///
    /// Note what the first two expectations say together. Swift's own `==`
    /// treats these as one string, because String comparison is canonical
    /// equivalence — so an implementation that compared the drafts directly
    /// would have been right by accident, and one that hashed their bytes
    /// would have been wrong. Only the bytes show the difference, which is why
    /// this is tested on the bytes.
    @Test func thesameWordsFingerprintTheSameHoweverTheyAreComposed() {
        let decomposed = "cafe\u{301} and the questions it asks"
        let precomposed = decomposed.precomposedStringWithCanonicalMapping

        #expect(decomposed == precomposed, "Swift sees one string here")
        #expect(
            Array(decomposed.utf8) != Array(precomposed.utf8),
            "but the bytes differ, which is what a hash would see"
        )
        #expect(
            LampWritingWrite.fingerprint(decomposed)
                == LampWritingWrite.fingerprint(precomposed),
            "so the fingerprint has to compose before it hashes"
        )
        #expect(
            LampWritingWrite.fingerprint("one") != LampWritingWrite.fingerprint("two")
        )
    }

    // MARK: - Writing

    @Test func awriteBasedOnWhatIsThereIsTaken() throws {
        let (library, support) = try workspace()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        let revised = "# Living Hope\n\nIt asks that we hold to it before anything changes.\n"

        let note = try LampWritingWrite.writeDraft(
            libraryRootURL: library,
            applicationSupportURL: support,
            writingID: writingID,
            draft: revised,
            basedOn: original,
            libraryText: original
        )

        #expect(try draft(in: library) == revised)
        #expect(note.baseFingerprint == LampWritingWrite.fingerprint(original))
        #expect(note.draftFingerprint == LampWritingWrite.fingerprint(revised))
    }

    /// Another agent, or the workspace's own editor, moved the draft.
    @Test func awriteBasedOnAnOlderDraftIsRefused() throws {
        let (library, support) = try workspace()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }

        #expect(throws: LampWritingWrite.WriteError.draftMovedOnDisk) {
            try LampWritingWrite.writeDraft(
                libraryRootURL: library,
                applicationSupportURL: support,
                writingID: writingID,
                draft: "anything",
                basedOn: "a draft that was never on disk",
                libraryText: nil
            )
        }
        #expect(try draft(in: library) == original, "the draft must be untouched")
    }

    /// The writer edited in Lamp's own editor, which does not reach `draft.md`
    /// — so the draft on disk still matches and only the library has moved.
    /// This is the case the second check exists for.
    @Test func awriteIsRefusedWhenTheWriterHasEditedInLamp() throws {
        let (library, support) = try workspace()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }

        #expect(throws: LampWritingWrite.WriteError.writingChangedInLamp) {
            try LampWritingWrite.writeDraft(
                libraryRootURL: library,
                applicationSupportURL: support,
                writingID: writingID,
                draft: "anything",
                basedOn: original,
                libraryText: original + "\nA sentence the writer added in Lamp.\n"
            )
        }
        #expect(try draft(in: library) == original)
    }

    @Test func awritingWithNoWorkspaceIsRefusedRatherThanGivenOne() throws {
        let (library, support) = try workspace()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }

        #expect(throws: LampWritingWrite.WriteError.noWorkspace("never-opened")) {
            try LampWritingWrite.writeDraft(
                libraryRootURL: library,
                applicationSupportURL: support,
                writingID: "never-opened",
                draft: "anything",
                basedOn: "",
                libraryText: nil
            )
        }
        #expect(
            LampWritingWorkspace.exists(libraryRootURL: library, writingID: "never-opened") == false
        )
    }

    /// A refusal has to say what to do, because the agent reading it can
    /// recover by reading the writing again.
    @Test func refusalsSayHowToRecover() {
        for error in [
            LampWritingWrite.WriteError.draftMovedOnDisk,
            .writingChangedInLamp,
        ] {
            let message = error.localizedDescription
            #expect(message.contains("refused"))
            #expect(message.lowercased().contains("read the writing again"))
        }
    }

    // MARK: - The note

    /// Outside the library, so it cannot be swept up by sync: the workspace
    /// folders are gathered by name, and a note left in one would travel to
    /// the user's server as a side effect of where it was put.
    @Test func thenoteIsKeptOutsideTheLibrary() throws {
        let (library, support) = try workspace()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }

        try LampWritingWrite.writeDraft(
            libraryRootURL: library,
            applicationSupportURL: support,
            writingID: writingID,
            draft: "# Living Hope\n\nRevised.\n",
            basedOn: original,
            libraryText: original
        )

        let note = LampWritingWrite.noteURL(
            applicationSupportURL: support, writingID: writingID
        )
        #expect(FileManager.default.fileExists(atPath: note.path))
        #expect(!note.path.hasPrefix(library.path), "the note must not be inside the library")
        // And it carries no prose, only hashes.
        let text = try String(contentsOf: note, encoding: .utf8)
        #expect(!text.contains("Living Hope"))
        #expect(!text.contains("Revised"))
    }

    @Test func anoteReadsBackAndCanBeForgotten() throws {
        let (library, support) = try workspace()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        try LampWritingWrite.writeDraft(
            libraryRootURL: library,
            applicationSupportURL: support,
            writingID: writingID,
            draft: "# Living Hope\n\nRevised.\n",
            basedOn: original,
            libraryText: original
        )

        #expect(LampWritingWrite.note(applicationSupportURL: support, writingID: writingID) != nil)
        LampWritingWrite.forgetNote(applicationSupportURL: support, writingID: writingID)
        #expect(LampWritingWrite.note(applicationSupportURL: support, writingID: writingID) == nil)
    }

    // MARK: - Resolving at import

    @Test func thedraftIsTakenWhenTheWritingHasNotMoved() {
        let revised = "# Living Hope\n\nRevised.\n"
        let note = LampWritingWrite.Note(
            baseFingerprint: LampWritingWrite.fingerprint(original),
            draftFingerprint: LampWritingWrite.fingerprint(revised)
        )

        #expect(
            LampWritingWrite.resolve(
                note: note, draftOnDisk: revised, libraryText: original
            ) == .takeDraft
        )
    }

    /// The writer edited after the outside write. Their text stays; the
    /// arriving version goes to history for them to look at.
    @Test func thewritersTextStaysWhenTheyEditedAfterTheWrite() {
        let revised = "# Living Hope\n\nRevised by an agent.\n"
        let note = LampWritingWrite.Note(
            baseFingerprint: LampWritingWrite.fingerprint(original),
            draftFingerprint: LampWritingWrite.fingerprint(revised)
        )

        #expect(
            LampWritingWrite.resolve(
                note: note,
                draftOnDisk: revised,
                libraryText: original + "\nAnd a sentence of the writer's own.\n"
            ) == .keepWritingAndRecordDraft
        )
    }

    /// No note: an older Lamp, or a draft written by the workspace's own
    /// agent. The rule that was there before applies.
    @Test func adraftWithNoNoteIsTakenAsBefore() {
        #expect(
            LampWritingWrite.resolve(
                note: nil, draftOnDisk: "anything", libraryText: original
            ) == .takeDraftUnrecorded
        )
    }

    /// A note describing a draft that is no longer there. The writer typed in
    /// the workspace after the write, so `draft.md` is theirs now — resolving
    /// by this note would label their text as the agent's accepted write.
    @Test func anoteForADraftThatHasSinceChangedIsIgnored() {
        let note = LampWritingWrite.Note(
            baseFingerprint: LampWritingWrite.fingerprint(original),
            draftFingerprint: LampWritingWrite.fingerprint("what the agent wrote")
        )

        #expect(
            LampWritingWrite.resolve(
                note: note,
                draftOnDisk: "what the writer has typed since",
                libraryText: original
            ) == .takeDraftUnrecorded
        )
    }
}
