import Foundation
import LampCore
import Testing

@testable import LampBibleMac

/// Whether a passage the writer undid is kept for a Redo.
///
/// The page is the only thing that knows, and it reports two facts that
/// are easy to confuse: whether a Redo can be done now, and whether an
/// ordinary edit has just thrown the branch away. Using up the last
/// Redo makes the first false without the second being true — and a
/// host that dropped on the first would let the passage go at the very
/// moment the Redo brought it back. The iOS session found that in the
/// first round against their own version; these hold the Mac to the
/// same rules.
@MainActor
struct WritingRedoBranchTests {
    private func obligations() -> WritingReviewObligations {
        WritingReviewObligations(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("redo-\(UUID().uuidString).json")
        )
    }

    private func owed(_ marks: Set<UUID>, dormant: Set<UUID>) -> WritingReviewSession.OwedRestore {
        var restore = WritingReviewSession.OwedRestore(
            restore: .init(base: "", restored: "", plan: .init(edits: [])), held: ""
        )
        restore.pending = marks
        restore.dormant = dormant
        return restore
    }

    @Test func thelastRedoBeingUsedDoesNotDropThePassage() {
        let store = obligations()
        let mark = UUID()
        store.owe(owed([mark], dormant: [mark]), for: "w")
        // A Redo is performed: none left available, but nothing discarded.
        store.redo(available: false, discarded: false, standingIn: nil, for: "w")
        #expect(
            store.owing(for: .init(writingID: "w", document: nil)).first?.dormantMarks == [mark],
            "the passage was let go at the moment the Redo brought it back"
        )
    }

    @Test func anordinaryEditAfterAnUndoDropsThePassage() {
        let store = obligations()
        let mark = UUID()
        store.owe(owed([mark], dormant: [mark]), for: "w")
        store.redo(available: true, discarded: false, standingIn: nil, for: "w")
        #expect(store.canRedo("w"))
        store.redo(available: false, discarded: true, standingIn: nil, for: "w")
        #expect(
            store.owing(for: .init(writingID: "w", document: nil)).isEmpty,
            "a passage past the end of its redo branch must not be kept"
        )
        #expect(!store.canRedo("w"))
    }

    /// A fresh page has no history, so nothing may be held for a branch
    /// that does not exist.
    @Test func afreshPageLetsGoOfEverythingHeld() {
        let store = obligations()
        let mark = UUID()
        store.owe(owed([mark], dormant: [mark]), for: "w")
        store.redo(available: false, discarded: true, standingIn: nil, for: "w")
        #expect(store.owing(for: .init(writingID: "w", document: nil)).isEmpty)
    }

    /// A discard leaves alone what is not dormant.
    @Test func adiscardKeepsWhatIsStillWaiting() {
        let store = obligations()
        let waiting = UUID()
        let undone = UUID()
        store.owe(owed([waiting, undone], dormant: [undone]), for: "w")
        store.redo(available: false, discarded: true, standingIn: nil, for: "w")
        let left = store.owing(for: .init(writingID: "w", document: nil))
        #expect(left.count == 1)
        #expect(left.first?.pendingMarks == [waiting])
        #expect(left.first?.dormantMarks.isEmpty == true)
    }
}
