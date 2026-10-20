import Foundation
import LampCore
import LampModuleKit

/// The deletion records a pass carries in the settings bundle.
///
/// Sync merges content as a union, so on its own a deletion is undone by the
/// next device that still has a copy. These two ledgers are what let each
/// device tell a copy that predates a deletion — dropped — from a change made
/// after it — kept.
///
/// They live in the bundle rather than beside the content for a reason worth
/// keeping in mind: a ledger published as an ordinary file would be *won*
/// rather than merged, so two devices deleting different things would
/// overwrite each other's record and whatever the loser deleted would come
/// back. In the bundle they go through `update`'s read-merge-retry.
///
/// Note which fields this touches. `userSettings` is the phone's and is left
/// alone — the Mac has never read it, and because `update` applies a change
/// to the bundle *read from the server*, leaving a field untouched preserves
/// it. That is the same guarantee the archive pass got from
/// `LampSyncSettingsArchive.preservingRemoteEntry`, for free.
public enum LampSyncBundleLedgers {
    public struct Applied: Equatable, Sendable {
        /// Writings, notes and highlights the ledger said had gone.
        public var personalDeletionsApplied = false
        /// The decks that went, by ID.
        public var decksRemoved: [String] = []
    }

    /// Takes the bundle's records, folds them into this library's, and carries
    /// out what they say.
    ///
    /// Personal items first: `applyPersonalDeletionLedger` is what makes a
    /// note deleted on the phone actually leave this Mac, and it has to run
    /// before the pass publishes, or this device would republish the very
    /// items it was told were deleted.
    @discardableResult
    public static func apply(
        _ bundle: LampSyncSettingsBundle,
        to library: LampLibrary,
        fileManager: FileManager = .default
    ) async throws -> Applied {
        var applied = Applied()

        if let data = bundle.personalDeletions {
            // An unreadable ledger is not a reason to stop syncing content,
            // but it is a reason not to pretend a deletion was applied.
            let incoming = try? LampPersonalDeletionLedger.decode(data)
            if let incoming {
                try await library.mergePersonalDeletionLedger(incoming)
                try await library.applyPersonalDeletionLedger()
                applied.personalDeletionsApplied = true
            }
        }

        if let data = bundle.deckDeletions {
            applied.decksRemoved = try LampPresentationDeckSync.applyDeletions(
                LampPresentationDeckDeletionLedger.decoded(from: data),
                in: library.rootURL,
                fileManager: fileManager
            )
        }

        return applied
    }

    /// Puts this library's records into the bundle, merged with whatever is
    /// already there.
    ///
    /// Merged rather than replaced: the bundle being written may be newer than
    /// the one this pass read — `update` re-applies its change against a newer
    /// copy when another device writes first — so overwriting would drop that
    /// device's deletions. Both ledgers join by the later of each entry's
    /// times, so merging in either order gives the same answer.
    public static func contribute(
        from library: LampLibrary,
        to bundle: inout LampSyncSettingsBundle,
        fileManager: FileManager = .default
    ) async throws {
        var personal = try await library.personalDeletionLedger()
        if let data = bundle.personalDeletions,
           let existing = try? LampPersonalDeletionLedger.decode(data) {
            personal.merge(existing)
        }
        bundle.personalDeletions = personal.isEmpty
            ? bundle.personalDeletions
            : try personal.encoded()

        var decks = try LampPresentationDeckSync.deletions(
            in: library.rootURL, fileManager: fileManager
        )
        if let data = bundle.deckDeletions {
            decks.merge(LampPresentationDeckDeletionLedger.decoded(from: data))
        }
        bundle.deckDeletions = decks.isEmpty
            ? bundle.deckDeletions
            : try decks.encoded()
    }
}
