import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

/// When this Mac last saved each thing. The plan uses it for one decision —
/// a file deleted on another device but edited here *since* survives — so
/// without it, content edited here after another device deleted it is
/// deleted rather than kept.
struct LampSyncSavedAtTests {
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eachCollectionIsTimedAtThePathItIsPublishedAt() {
        let savedAt = LampSyncSavedAt.paths(
            notesLastSaved: 1_700_000_000_000,
            writingsLastSaved: moment,
            highlightSets: [("set-1", moment), ("set-2", moment)],
            highlightModuleIDs: ["set-1": "esvs-highlights"],
            decks: [("Workspaces/Presentations/sunday.lampdeck", moment)]
        )

        #expect(savedAt["Notes/notes.lamp"] == 1_700_000_000_000)
        #expect(savedAt["Devotionals/devotionals.lamp"] == 1_800_000_000_000)
        #expect(savedAt["Highlights/esvs-highlights.lamp"] == 1_800_000_000_000)
        #expect(savedAt["Workspaces/Presentations/sunday.lampdeck"] == 1_800_000_000_000)
        // A set with no module ID has no path to be timed at, and is not
        // guessed at.
        #expect(savedAt.count == 4)
    }

    @Test func nothingSavedMeansNothingClaimed() {
        let savedAt = LampSyncSavedAt.paths(
            notesLastSaved: nil,
            writingsLastSaved: nil,
            highlightSets: [],
            highlightModuleIDs: [:],
            decks: []
        )
        #expect(savedAt.isEmpty, "a time nobody knows must not become a time of zero")
    }

    /// Milliseconds, as the manifest records them — seconds would read as
    /// 1970 beside a deletion and lose every contest.
    @Test func timesAreInMillisecondsLikeTheManifest() {
        #expect(LampSyncSavedAt.milliseconds(moment) == 1_800_000_000_000)
    }

    @Test func aCollectionIsTimedByItsLatestItem() {
        var ledger = LampPersonalDeletionLedger()
        ledger.set(.init(presentSince: 100), kind: .note, key: "a")
        ledger.set(.init(presentSince: 900), kind: .note, key: "b")
        ledger.set(.init(presentSince: 500), kind: .note, key: "c")
        // A note deleted rather than saved says nothing about the last save.
        ledger.set(.init(presentSince: nil, deletedAt: 2_000), kind: .note, key: "d")

        #expect(LampSyncSavedAt.lastSaved(.note, in: ledger) == 900)
        #expect(LampSyncSavedAt.lastSaved(.devotional, in: ledger) == nil)
    }
}
