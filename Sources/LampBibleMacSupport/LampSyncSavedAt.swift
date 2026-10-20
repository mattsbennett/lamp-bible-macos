import Foundation
import LampCore
import LampModuleKit

/// When this Mac last saved each thing it publishes.
///
/// The plan needs it to decide one question: a file deleted on another device
/// and edited here *since* survives and goes back up, while one last touched
/// before the deletion goes. Without a time it can only assume the second, so
/// a collection edited here after another device deleted it would be deleted
/// rather than kept — someone's writing, lost to a rule meant to protect it.
///
/// Times are milliseconds since 1970, as the manifest records them.
public enum LampSyncSavedAt {
    /// A collection's last save, from the ledger that records a presence for
    /// every item as it is written.
    public static func lastSaved(
        _ kind: LampPersonalItemKind,
        in ledger: LampPersonalDeletionLedger
    ) -> Int64? {
        (ledger.entries[kind] ?? [:]).values.compactMap(\.presentSince).max()
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    /// The editable collections and decks, by the path each is published at.
    public static func paths(
        notesLastSaved: Int64?,
        writingsLastSaved: Date?,
        highlightSets: [(setID: String, lastModified: Date)],
        highlightModuleIDs: [String: String],
        decks: [(path: String, modifiedAt: Date)]
    ) -> [String: Int64] {
        var savedAt: [String: Int64] = [:]
        if let notesLastSaved,
           let path = try? LampSyncFolderLayout.modulePath(
               kind: .notes, moduleID: LampSyncMacPassLibrary.remoteNotesModuleID
           ) {
            savedAt[path] = notesLastSaved
        }
        if let writingsLastSaved,
           let path = try? LampSyncFolderLayout.modulePath(
               kind: .devotionals, moduleID: LampSyncMacPassLibrary.remoteWritingModuleID
           ) {
            savedAt[path] = milliseconds(writingsLastSaved)
        }
        for set in highlightSets {
            guard let moduleID = highlightModuleIDs[set.setID],
                  let path = try? LampSyncFolderLayout.modulePath(
                      kind: .highlights, moduleID: moduleID
                  )
            else { continue }
            savedAt[path] = milliseconds(set.lastModified)
        }
        for deck in decks {
            savedAt[deck.path] = milliseconds(deck.modifiedAt)
        }
        return savedAt
    }
}
