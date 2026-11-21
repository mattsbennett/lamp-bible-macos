import Foundation
import LampBibleMacSupport
import LampCore
import Testing
@testable import LampBibleMac

/// What a writing turn is sent with, wherever it is asked from.
@MainActor
struct WritingChatTurnsTests {
    private let focus = WritingEditorFocus(
        documentPath: "draft.md", documentName: "Draft", isVisual: true,
        selectedText: nil, selectedLines: nil
    )

    private func note(_ review: LampWritingReview?, in writing: String, known: [String] = []) -> String? {
        WritingChatTurns.reviewNote(review, marksAreOn: true, in: writing, known: known)
    }

    @Test func withoutMarksAMessageIsSentAsItAlwaysWas() {
        let off = WritingChatTurns.reviewNote(
            LampWritingReview(writingID: "w").markingAssistantChange(from: "a b", to: "a c"),
            marksAreOn: false, in: "a c", known: []
        )
        #expect(off == nil)
        let prompt = WritingChatTurns.prompt(for: "Tighten this.", focus: focus, note: off)
        #expect(prompt == focus.prompt(for: "Tighten this."))
    }

    /// The agent is told no note means marks are off, so a review that
    /// could not be read says so rather than saying nothing.
    @Test func marksThatCouldNotBeReadAreSaidToBeUnread() {
        #expect(note(nil, in: "Text.") == WritingChatTurns.unreadReviewNote)
    }

    /// Typing into a mark before the save that carries it splits the mark's
    /// words: the note carries the stored marks into the draft, as the
    /// editor draws them, rather than looking for the words as they were.
    @Test func aMarkTypedIntoBeforeASaveIsStillSaid() {
        let before = "Start. Alpha beta gamma. End."
        let marked = LampWritingReview(writingID: "w").markingAssistantChange(from: "Start. End.", to: before)
        let typed = "Start. Alpha mine beta gamma. End."
        let said = note(marked, in: typed, known: [before]) ?? ""
        #expect(!said.contains("Everything in the writing has been read and cleared"))
        #expect(said.contains("Alpha"))
    }

    @Test func theAgentIsToldWhatIsStillMarkedAndToLeaveTheRest() {
        let old = "One two three.\n\nFour five six."
        let new = "One deux three.\n\nFour five six."
        let review = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        let prompt = WritingChatTurns.prompt(for: "Tighten this.", focus: focus, note: note(review, in: new))
        #expect(prompt.hasPrefix(focus.contextText))
        #expect(prompt.contains("- \"deux\""))
        #expect(prompt.contains("Everything else has been read and cleared"))
        #expect(prompt.hasSuffix("The user's message:\nTighten this."))
    }

    /// A change the writer put back leaves no mark — the passage is theirs
    /// again, and read — so nothing but this tells the assistant about it,
    /// and without it the same change comes back every turn.
    @Test func theAgentIsToldWhatTheWriterPutBack() throws {
        let old = "The quick brown fox jumps."
        let new = "The slow red fox jumps."
        let review = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        let plan = try #require(review.restorePlan(for: NSRange(location: 0, length: (new as NSString).length), in: new))
        let put = review.restoringWording(plan, from: new, to: old)
        #expect(put.marks.isEmpty, "nothing is marked: the passage is the writer's again")
        let note = try #require(note(put, in: old))
        #expect(note.contains("put their own wording back"))
        #expect(note.contains("quick brown"))
        #expect(note.contains("slow red"))
    }

    @Test func whatTheWriterPutBackIsSaidEvenWithNothingMarked() throws {
        var review = LampWritingReview(writingID: "w")
        review.restorations = [
            .init(markID: UUID(), turnID: nil, restored: "mine", discarded: "yours", restoredAt: Date()),
        ]
        let note = try #require(note(review, in: "mine stands here"))
        #expect(note.contains("Everything in the writing has been read and cleared"))
        #expect(note.contains("\"mine\" again, in place of your \"yours\""))
    }

    @Test func wordsTakenBackOutAndWordsPutBackReadDifferently() throws {
        let takenOut = WritingChatTurns.restorationLines([
            .init(markID: UUID(), turnID: nil, restored: "", discarded: "your sentence", restoredAt: Date()),
        ])
        #expect(takenOut?.contains("took out \"your sentence\", which you had put in") == true)
        let putBack = WritingChatTurns.restorationLines([
            .init(markID: UUID(), turnID: nil, restored: "my sentence", discarded: "", restoredAt: Date()),
        ])
        #expect(putBack?.contains("put \"my sentence\" back, which you had taken out") == true)
        #expect(WritingChatTurns.restorationLines([]) == nil)
    }

    @Test func aLongListOfRestorationsIsCut() throws {
        let many: [LampWritingReview.Restoration] = (0..<WritingChatTurns.restorationLimit + 4).map {
            .init(
                markID: UUID(), turnID: nil, restored: "back \($0)", discarded: "gone \($0)",
                restoredAt: Date().addingTimeInterval(-Double($0))
            )
        }
        let lines = try #require(WritingChatTurns.restorationLines(many))
        #expect(lines.contains("and 4 more"))
        // The newest are the ones that matter: they are what the assistant
        // would otherwise do again on this very turn.
        #expect(lines.contains("back 0"))
        #expect(!lines.contains("back \(WritingChatTurns.restorationLimit + 3)"))
    }

    @Test func aReviewWithEverythingClearedSaysSo() {
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "a b", to: "a c")
            .clearingAll()
        let note = note(review, in: "a c")
        #expect(note?.contains("Everything in the writing has been read and cleared") == true)
    }

    @Test func aLongListOfMarksIsCut() {
        var old = ""
        var new = ""
        for index in 0..<30 {
            old += "Line \(index) old.\n\n"
            new += "Line \(index) new.\n\n"
        }
        let review = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        let note = note(review, in: new) ?? ""
        #expect(note.components(separatedBy: "\n- \"").count - 1 == WritingChatTurns.reviewPassageLimit)
        #expect(note.contains("and 10 more"))
    }

    /// The note `.lamp/editor.md` carries is built from the ranges the
    /// editor draws: a place words were taken out is an empty range, and is
    /// counted rather than quoted.
    @Test func theNoteFromDrawnRangesQuotesPassagesAndCountsRemovals() {
        let writing = "One deux three. Four six."
        let note = WritingChatTurns.reviewNote(
            ranges: [NSRange(location: 4, length: 4), NSRange(location: 20, length: 0)], in: writing
        )
        #expect(note.contains("- \"deux\""))
        #expect(note.contains("- and 1 place where words were taken out"))
        #expect(WritingChatTurns.reviewNote(ranges: [], in: writing)
            .contains("Everything in the writing has been read and cleared"))
    }

    @Test func theNoteFromAReviewIsTheNoteFromItsRanges() {
        let old = "One two three.\n\nFour five six."
        let new = "One deux three.\n\nFour six."
        let review = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        #expect(note(review, in: new)
            == WritingChatTurns.reviewNote(ranges: review.highlightedRanges(in: new), in: new))
    }

    /// The agent is told what marks are and that only the writer clears
    /// them, and only while marks are on.
    @Test func theInstructionsSayWhoClearsMarksOnlyWhileTheyAreOn() {
        let on = DevotionalAgentWorkspaceStore.instructions(contextFiles: ["notes.md"], reviewMarks: true)
        let off = DevotionalAgentWorkspaceStore.instructions(contextFiles: ["notes.md"], reviewMarks: false)
        #expect(on.contains("Only the writer clears marks"))
        #expect(on.contains("`.lamp/editor.md`, says which passages are still marked"))
        #expect(on.contains("A message that says nothing of marks means the writer has turned them off"))
        #expect(!off.contains("marks"))
        #expect(off.contains("- `context/notes.md`"))
    }

    @Test func aWritingIsWatchedForAsLongAsAnyWindowHasIt() {
        let id = "watched-\(UUID().uuidString)"
        #expect(!WritingChatTurns.isWatched(id))
        let first = WritingChatTurns.watch(writingID: id)
        let second = WritingChatTurns.watch(writingID: id)
        first.end()
        first.end()
        #expect(WritingChatTurns.isWatched(id), "the other window still has it, and a second end does nothing")
        second.end()
        #expect(!WritingChatTurns.isWatched(id))
    }

    @Test func theOldestCopyAnyEditorHoldsIsTheOneSaid() {
        let id = "revision-\(UUID().uuidString)"
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_500)
        #expect(WritingChatTurns.watched(id) == nil)
        let first = WritingChatTurns.hold(id, revision: older, digest: "a")
        let second = WritingChatTurns.hold(id, revision: newer, digest: "b")
        #expect(WritingChatTurns.watched(id)?.revision == older)
        #expect(WritingChatTurns.watched(id)?.digest == "a")
        #expect(WritingChatTurns.watchedCopies(id).map(\.digest) == ["a", "b"])
        first.release()
        #expect(WritingChatTurns.watchedRevision(id) == newer)
        second.update(revision: older, digest: "c")
        #expect(WritingChatTurns.watched(id)?.digest == "c")
        second.release()
        #expect(WritingChatTurns.watched(id) == nil)
        #expect(WritingChatTurns.watchedCopies(id).isEmpty)
    }

    @Test func copiesFromTheSameSecondAreEachSaid() {
        let id = "revision-\(UUID().uuidString)"
        let second = Date(timeIntervalSince1970: 1_700_000_000)
        let matching = WritingChatTurns.hold(id, revision: second, digest: "phone")
        let stale = WritingChatTurns.hold(id, revision: second, digest: "older")
        #expect(Set(WritingChatTurns.watchedCopies(id).compactMap(\.digest)) == ["phone", "older"])
        matching.release()
        stale.release()
    }
}
