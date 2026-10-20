import Foundation
import LampModuleKit

/// Turns a sync failure into a sentence someone can act on.
///
/// Core's `LampSyncSettingsStore.StoreError` carries no `errorDescription`,
/// so it reaches a person as "LampSyncSettingsStore.StoreError error 2",
/// which says nothing about what happened, whether anything was changed, or
/// what to do next. Each case here answers those three.
public enum LampSyncErrorText {
    public static func sentence(for error: any Error) -> String {
        if let store = error as? LampSyncSettingsStore.StoreError {
            return sentence(for: store)
        }
        return error.localizedDescription
    }

    public static func sentence(for error: LampSyncSettingsStore.StoreError) -> String {
        switch error {
        case .notMigrated:
            """
            The server still holds the older library layout, so the new sync \
            did not run. Nothing was changed. Sync Now, then use the move \
            offered in Sync settings.
            """
        case .unversioned:
            """
            The server did not give the sync file a strong ETag, so it could \
            not be written over safely. Nothing was changed. This is a server \
            setting rather than something Lamp Bible can work around.
            """
        case .tooManyAttempts:
            """
            The sync file could not be written: every attempt was refused, \
            either because another device wrote first each time or because \
            the server did not confirm the write. Nothing was lost — the next \
            sync starts again from whatever is there.
            """
        case .unreadableVersion(let detail):
            """
            The server holds a copy of the sync file this version cannot \
            read, so it was left alone rather than written over: \(detail). \
            Nothing was changed.
            """
        case .versionsNeedAMerge:
            """
            iCloud is holding more than one version of the sync file and this \
            sync had no way to merge them. Nothing was changed. Resolve the \
            conflict in iCloud Drive, then sync again.
            """
        }
    }
}
