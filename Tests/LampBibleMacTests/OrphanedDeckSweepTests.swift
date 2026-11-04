import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Deleting a writing used to leave its decks behind for ever — nothing on
/// either delete path touched them — so they sat in Slide Studio pointing at
/// nothing, and showed on the phone too.
///
/// The sweep reads the deletion ledger rather than being told what a pass
/// removed, which is what lets it answer the three cases a report cannot: a
/// crash between the writing's transaction and its decks, a deck arriving
/// after its writing was already deleted, and a deletion made on the phone,
/// which reaches this Mac as a ledger entry and nothing else.
struct OrphanedDeckSweepTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func library() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func deck(
        _ title: String, of writingID: String?, in library: URL, savedAt offset: TimeInterval
    ) throws -> LampPresentationDeck {
        var deck = LampPresentationDeck(title: title, slides: [
            .init(layout: .scripture, blocks: [.init(kind: .title, text: title)]),
        ])
        if let writingID {
            deck.source = LampPresentationSource(kind: .devotional, id: writingID)
        }
        let url = try LampPresentationDeckStore(rootURL: library).save(deck)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(offset)], ofItemAtPath: url.path
        )
        return deck
    }

    /// The ledger counts in milliseconds; everything about decks counts in
    /// seconds.
    private func ledgerDeleting(_ writingID: String, at offset: TimeInterval)
        -> LampPersonalDeletionLedger
    {
        var ledger = LampPersonalDeletionLedger()
        let when = Int64((base.addingTimeInterval(offset)).timeIntervalSince1970 * 1000)
        ledger.recordDeletion(.devotional, writingID, at: when)
        return ledger
    }

    private func titles(in library: URL) throws -> [String] {
        try LampPresentationDeckStore(rootURL: library).decks().map(\.title).sorted()
    }

    @Test func adeckGoesWhenItsWritingHasBeenDeleted() throws {
        let library = try library()
        try deck("Gone", of: "W1", in: library, savedAt: 0)
        try deck("Kept", of: "W2", in: library, savedAt: 0)

        let removed = try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: ["W2"],
            deletedWritings: ledgerDeleting("W1", at: 60),
            in: library
        )
        #expect(removed.count == 1)
        #expect(try titles(in: library) == ["Kept"])
    }

    /// The deletion has to be recorded for the phone, or the phone's copy
    /// brings the deck straight back.
    @Test func thedeckSdeletionIsRecordedAtTheWritingSOwnTime() throws {
        let library = try library()
        let gone = try deck("Gone", of: "W1", in: library, savedAt: 0)
        try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: [], deletedWritings: ledgerDeleting("W1", at: 60), in: library
        )
        let recorded = try LampPresentationDeckSync.deletions(in: library).deletedAt[gone.id]
        // The writing's own time, to the second, not the moment of the sweep:
        // the ledgers count in different units and a slip would be silent.
        #expect(recorded == base.addingTimeInterval(60))
    }

    /// A writing's identifier is not spelled the same on every platform.
    @Test func thewritingIsMatchedWhateverCaseItIsSpelledIn() throws {
        let library = try library()
        try deck("Gone", of: "9ADB692A-FE3C-4291-A012-074FFDB3AC53", in: library, savedAt: 0)
        let removed = try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: [],
            deletedWritings: ledgerDeleting("9adb692a-fe3c-4291-a012-074ffdb3ac53", at: 60),
            in: library
        )
        #expect(removed.count == 1)
        #expect(try titles(in: library).isEmpty)
    }

    /// The reason this is keyed on the ledger and not on "no writing holds
    /// it": a library part way through its first sync holds no writings at
    /// all, and must not take that as licence to delete every deck — a
    /// deletion it records would reach every other device.
    @Test func alibraryThatHasNotLoadedYetDeletesNothing() throws {
        let library = try library()
        try deck("Untouched", of: "W1", in: library, savedAt: 0)
        let removed = try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: [], deletedWritings: LampPersonalDeletionLedger(), in: library
        )
        #expect(removed.isEmpty)
        #expect(try titles(in: library) == ["Untouched"])
        #expect(try LampPresentationDeckSync.deletions(in: library).isEmpty)
    }

    @Test func awritingStillHeldKeepsItsDecks() throws {
        let library = try library()
        try deck("Kept", of: "W1", in: library, savedAt: 0)
        let removed = try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: ["W1"], deletedWritings: ledgerDeleting("W1", at: 60), in: library
        )
        #expect(removed.isEmpty)
        #expect(try titles(in: library) == ["Kept"])
    }

    /// A deck saved after its writing went is newer than the deletion, and the
    /// rule that keeps a deck edited since it was deleted elsewhere keeps this
    /// one too.
    @Test func adeckEditedSinceTheWritingWentIsKept() throws {
        let library = try library()
        try deck("Edited since", of: "W1", in: library, savedAt: 120)
        let removed = try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: [], deletedWritings: ledgerDeleting("W1", at: 60), in: library
        )
        #expect(removed.isEmpty)
        #expect(try titles(in: library) == ["Edited since"])
    }

    @Test func adeckOfNoWritingIsLeftAlone() throws {
        let library = try library()
        try deck("Standalone", of: nil, in: library, savedAt: 0)
        let removed = try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: [], deletedWritings: ledgerDeleting("W1", at: 60), in: library
        )
        #expect(removed.isEmpty)
        #expect(try titles(in: library) == ["Standalone"])
    }

    /// It runs on every pass, so running it twice has to be the same as once.
    @Test func sweepingTwiceIsTheSameAsSweepingOnce() throws {
        let library = try library()
        try deck("Gone", of: "W1", in: library, savedAt: 0)
        let ledger = ledgerDeleting("W1", at: 60)
        #expect(try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: [], deletedWritings: ledger, in: library
        ).count == 1)
        let after = try LampPresentationDeckSync.deletions(in: library)
        #expect(try LampPresentationDeckSync.removeDecksOfDeletedWritings(
            heldWritingIDs: [], deletedWritings: ledger, in: library
        ).isEmpty)
        #expect(try LampPresentationDeckSync.deletions(in: library) == after)
    }
}
