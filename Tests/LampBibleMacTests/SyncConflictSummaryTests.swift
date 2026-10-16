import Foundation
import LampBibleMacSupport
import LampCore
import Testing

/// The line above the decisions waiting in the Sync pane. Counting by kind
/// means the sentence has to survive every mix of them.
struct SyncConflictSummaryTests {
    private func conflict(_ kind: LampSyncConflict.Kind, _ key: String) -> LampSyncConflict {
        LampSyncConflict(
            id: LampSyncConflict.identifier(kind: kind, itemKey: key),
            kind: kind,
            itemKey: key,
            title: key,
            thisDeviceModified: nil,
            otherDeviceModified: nil,
            thisDevicePreview: "here",
            otherDevicePreview: "there",
            detected: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func oneOfEitherKindReadsAsOne() {
        #expect(SyncConflictSummary.text(for: [conflict(.devotional, "w")]).hasPrefix(
            "One writing was changed on two devices"
        ))
        #expect(SyncConflictSummary.text(for: [conflict(.note, "n")]).hasPrefix(
            "One note was changed on two devices"
        ))
    }

    @Test func severalOfOneKindAreCounted() {
        let notes = [conflict(.note, "a"), conflict(.note, "b"), conflict(.note, "c")]
        #expect(SyncConflictSummary.text(for: notes).hasPrefix("3 notes were changed"))
    }

    /// A mix names both, and the sentence still agrees with the total rather
    /// than with whichever kind came last.
    @Test func aMixNamesBothKinds() {
        let mixed = [conflict(.devotional, "w"), conflict(.note, "a"), conflict(.note, "b")]
        let text = SyncConflictSummary.text(for: mixed)
        #expect(text.hasPrefix("One writing and 2 notes were changed"))
        #expect(text.contains("Your copies are the ones being kept"))
    }

    /// The pane hides the whole section when nothing is waiting, but a sentence
    /// with no subject is still not a sentence.
    @Test func nothingWaitingSaysNothing() {
        #expect(SyncConflictSummary.text(for: []).isEmpty)
    }

    @Test func oneCopyIsSingularThroughout() {
        let text = SyncConflictSummary.text(for: [conflict(.note, "a")])
        #expect(text.contains("Your copy is the one being kept until you choose."))
    }
}
