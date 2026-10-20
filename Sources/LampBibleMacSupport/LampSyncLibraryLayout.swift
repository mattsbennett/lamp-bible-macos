import Foundation
import LampModuleKit

/// Which layout a synced library is in, and so which pass it gets.
///
/// This one decision is what keeps a library that has not moved syncing
/// exactly as it did: a server still holding an archive takes the archive
/// path untouched, and only a library on the per-file layout goes to the
/// Design B pass.
public enum LampSyncLibraryLayout {
    /// On the per-file layout. The snapshot is nil for a library nobody has
    /// synced to yet, which a first pass claims — nothing there at all is
    /// the new layout with nothing in it, and only a library already holding
    /// something of an earlier shape has to be moved.
    case perFile(LampSyncSettingsStore.Snapshot?)
    /// Still an archive, so the archive pass carries it and the move is
    /// offered.
    case archive

    public static func of(_ store: any LampSyncRemoteStore) async throws -> Self {
        do {
            return .perFile(try await LampSyncSettingsStore.read(from: store))
        } catch LampSyncSettingsStore.StoreError.notMigrated {
            return .archive
        }
    }
}
