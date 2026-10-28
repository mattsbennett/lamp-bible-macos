import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// Taking back an edit to a deck.
///
/// Slide Studio saves as you type, so a deletion or a paste over the wrong
/// slide is written before anyone can think better of it. What matters most
/// here is the gathering of edits into bursts: an undo that steps back one
/// character at a time is one nobody waits for.
struct DeckEditHistoryTests {
    private func deck(title: String, id: String = "deck-1") -> LampPresentationDeck {
        var deck = LampPresentationDeck.starter(title: title)
        deck.id = id
        return deck
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func anuntouchedHistoryHasNothingToUndo() {
        let history = LampDeckEditHistory()
        #expect(history.canUndo == false)
        #expect(history.canRedo == false)
        #expect(history.undo(from: deck(title: "A")) == nil)
    }

    @Test func aneditIsTakenBackToWhereItWas() {
        let history = LampDeckEditHistory()
        let before = deck(title: "Psalm 23")
        history.record(before, at: start)

        #expect(history.canUndo)
        #expect(history.undo(from: deck(title: "Psalm 24")) == before)
    }

    /// Typing a title would otherwise leave one step per character, and taking
    /// back a word would mean pressing undo as many times as the word is long.
    @Test func keystrokesInOneBurstAreOneStep() {
        let history = LampDeckEditHistory()
        let first = deck(title: "P")
        history.record(first, at: start)
        history.record(deck(title: "Ps"), at: start.addingTimeInterval(0.2))
        history.record(deck(title: "Psa"), at: start.addingTimeInterval(0.4))

        #expect(
            history.undo(from: deck(title: "Psalm")) == first,
            "one undo returns to where the burst began, not to its last keystroke"
        )
        #expect(history.canUndo == false, "and the burst was one step")
    }

    /// A pause ends a burst, so a deliberate second change is its own step.
    @Test func achangeAfterAPauseIsItsOwnStep() {
        let history = LampDeckEditHistory()
        history.record(deck(title: "A"), at: start)
        let afterPause = deck(title: "B")
        history.record(afterPause, at: start.addingTimeInterval(5))

        #expect(history.undo(from: deck(title: "C")) == afterPause)
        #expect(history.canUndo, "the earlier burst is still there")
    }

    /// Two decks are two histories. Undoing across that boundary would put one
    /// deck's slides into another.
    @Test func achangeToAnotherDeckIsNeverGatheredWithThisOne() {
        let history = LampDeckEditHistory()
        history.record(deck(title: "A", id: "deck-1"), at: start)
        let other = deck(title: "B", id: "deck-2")
        history.record(other, at: start.addingTimeInterval(0.1))

        #expect(history.undo(from: deck(title: "C", id: "deck-2")) == other)
    }

    @Test func whatWasTakenBackCanBePutBack() {
        let history = LampDeckEditHistory()
        let before = deck(title: "Psalm 23")
        history.record(before, at: start)
        let edited = deck(title: "Psalm 24")

        #expect(history.undo(from: edited) == before)
        #expect(history.canRedo)
        #expect(history.redo(from: before) == edited)
        #expect(history.canUndo, "and it can be taken back again")
    }

    /// An edit made after an undo is a new thought. Keeping the redo would
    /// offer to restore a version that no longer follows from what is here.
    @Test func editingAfterAnUndoDropsWhatWasUndone() {
        let history = LampDeckEditHistory()
        history.record(deck(title: "A"), at: start)
        _ = history.undo(from: deck(title: "B"))
        #expect(history.canRedo)

        history.record(deck(title: "A"), at: start.addingTimeInterval(10))

        #expect(history.canRedo == false)
    }

    /// A long session cannot grow without limit, and the oldest steps are the
    /// ones to lose.
    @Test func thehistoryIsBounded() {
        let history = LampDeckEditHistory()
        for index in 0...(LampDeckEditHistory.limit + 20) {
            history.record(
                deck(title: "Step \(index)"),
                at: start.addingTimeInterval(Double(index) * 5)
            )
        }

        var steps = 0
        var current = deck(title: "Last")
        while let previous = history.undo(from: current) {
            current = previous
            steps += 1
        }

        #expect(steps == LampDeckEditHistory.limit)
        #expect(current.title == "Step 21", "the oldest steps were dropped, not the newest")
    }
}
