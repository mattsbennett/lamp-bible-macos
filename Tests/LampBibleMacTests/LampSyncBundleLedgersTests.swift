import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

/// The deletion records a pass carries in the bundle. Without them sync is a
/// union and every deletion is undone by the next device that still has a
/// copy, so these are the tests for things *going* — and for one thing not
/// going, which is another device's record.
struct LampSyncBundleLedgersTests {
    private func makeLibrary() throws -> (library: LampLibrary, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-bundle-ledgers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LampLibrary(rootURL: root), root)
    }

    /// A real deck, encoded by the store, because the deletion planner only
    /// sees decks it can decode — a hand-written one would make these tests
    /// pass by finding nothing at all.
    private func deck(_ id: String) throws -> Data {
        try LampPresentationDeckStore.encodedUnvalidated(
            LampPresentationDeck(
                id: id,
                title: "A deck",
                slides: [LampPresentationSlide(
                    id: "\(id)-1",
                    layout: .title,
                    blocks: [LampPresentationBlock(
                        id: "\(id)-1-title", kind: .title, text: "A deck"
                    )]
                )]
            )
        )
    }

    @Test func aDeckDeletedElsewhereGoesWhenItsRecordArrives() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        try FileManager.default.createDirectory(
            at: store.decksDirectoryURL, withIntermediateDirectories: true
        )
        let url = store.decksDirectoryURL.appendingPathComponent("sunday.lampdeck")
        try deck("sunday").write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path
        )

        var incoming = LampPresentationDeckDeletionLedger()
        incoming.record("sunday", at: Date(timeIntervalSince1970: 2_000))

        let removed = try LampPresentationDeckSync.applyDeletions(incoming, in: root)
        #expect(removed == ["sunday"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = library
    }

    /// A deck saved here *after* the deletion survives it. The newer change
    /// wins, which is the same rule the archive pass used.
    @Test func aDeckSavedSinceTheDeletionSurvivesIt() throws {
        let (_, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        try FileManager.default.createDirectory(
            at: store.decksDirectoryURL, withIntermediateDirectories: true
        )
        let url = store.decksDirectoryURL.appendingPathComponent("sunday.lampdeck")
        try deck("sunday").write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: url.path
        )

        var incoming = LampPresentationDeckDeletionLedger()
        incoming.record("sunday", at: Date(timeIntervalSince1970: 2_000))

        #expect(try LampPresentationDeckSync.applyDeletions(incoming, in: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The reason these live in the bundle at all. `update` re-applies its
    /// change against a newer bundle when another device writes first, so a
    /// contribution that *replaced* the field would drop that device's
    /// deletions — exactly the loss the ledger exists to prevent.
    @Test func contributingKeepsAnotherDevicesDeletions() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampPresentationDeckSync.recordDeletion(
            of: "deleted-here", in: root, at: Date(timeIntervalSince1970: 1_000)
        )

        var theirs = LampPresentationDeckDeletionLedger()
        theirs.record("deleted-there", at: Date(timeIntervalSince1970: 2_000))
        var bundle = LampSyncSettingsBundle()
        bundle.deckDeletions = try theirs.encoded()

        try await LampSyncBundleLedgers.contribute(from: library, to: &bundle)

        let merged = LampPresentationDeckDeletionLedger.decoded(
            from: try #require(bundle.deckDeletions)
        )
        #expect(merged.deletedAt.keys.sorted() == ["deleted-here", "deleted-there"])
    }

    @Test func anEmptyLibraryContributesNothingAndErasesNothing() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var theirs = LampPresentationDeckDeletionLedger()
        theirs.record("deleted-there", at: Date(timeIntervalSince1970: 2_000))
        var bundle = LampSyncSettingsBundle()
        bundle.deckDeletions = try theirs.encoded()
        let before = bundle.deckDeletions

        try await LampSyncBundleLedgers.contribute(from: library, to: &bundle)

        #expect(bundle.deckDeletions == before, "nothing of our own is not a reason to clear theirs")
    }

    /// The phone's settings entry is not the Mac's to carry. Because `update`
    /// applies a change to the bundle read from the server, leaving the field
    /// alone preserves it — the same guarantee the archive pass got from
    /// `preservingRemoteEntry`, without any code.
    @Test func thePhonesOwnSettingsAreLeftExactlyAsTheyWere() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var bundle = LampSyncSettingsBundle()
        bundle.userSettings = Data("the phone's settings database".utf8)
        try await LampSyncBundleLedgers.contribute(from: library, to: &bundle)
        _ = try await LampSyncBundleLedgers.apply(bundle, to: library)

        #expect(bundle.userSettings == Data("the phone's settings database".utf8))
    }

    @Test func anUnreadableLedgerDoesNotClaimToHaveBeenApplied() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var bundle = LampSyncSettingsBundle()
        bundle.personalDeletions = Data("{ not a ledger".utf8)

        // Content must still sync: an unreadable record is not a reason to
        // stop, only a reason not to pretend a deletion was carried out.
        let applied = try await LampSyncBundleLedgers.apply(bundle, to: library)
        #expect(!applied.personalDeletionsApplied)
    }
}
