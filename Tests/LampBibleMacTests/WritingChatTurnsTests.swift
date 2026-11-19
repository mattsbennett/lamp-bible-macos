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

    @Test func withoutMarksAMessageIsSentAsItAlwaysWas() {
        let prompt = WritingChatTurns.prompt(for: "Tighten this.", focus: focus, review: nil, writing: "Text.")
        #expect(prompt == focus.prompt(for: "Tighten this."))
    }

    @Test func theAgentIsToldWhatIsStillMarkedAndToLeaveTheRest() {
        let old = "One two three.\n\nFour five six."
        let new = "One deux three.\n\nFour five six."
        let review = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        let prompt = WritingChatTurns.prompt(for: "Tighten this.", focus: focus, review: review, writing: new)
        #expect(prompt.hasPrefix(focus.contextText))
        #expect(prompt.contains("- \"deux\""))
        #expect(prompt.contains("Everything else has been read and cleared"))
        #expect(prompt.hasSuffix("The user's message:\nTighten this."))
    }

    @Test func aReviewWithEverythingClearedSaysSo() {
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "a b", to: "a c")
            .clearingAll()
        let note = WritingChatTurns.reviewNote(review, in: "a c")
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
        let note = WritingChatTurns.reviewNote(review, in: new) ?? ""
        #expect(note.components(separatedBy: "\n- \"").count - 1 == WritingChatTurns.reviewPassageLimit)
        #expect(note.contains("and 10 more"))
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
