import Foundation

/// What a library still on the old layout can be offered, and what the person
/// is told before they choose.
///
/// The words matter more than usual here. Moving a library is the one action
/// in sync that changes what every other device sees, and two of its
/// consequences are invisible from this Mac: an iPhone or iPad still on an
/// older version stops receiving deletions, and the first sync afterwards
/// fetches the library once to check it. Someone who is not told the first
/// will think their phone is broken weeks later; someone who is not told the
/// second will think the move hung.
public enum LampSyncMoveOffer: Equatable, Sendable {
    /// This Mac's own library: its files are a backup's layout, so only the
    /// Mac's move can rearrange it.
    case migrate
    /// Only another device has ever synced here, and its files are already
    /// per-file. Joining republishes this Mac's whole library into that one,
    /// so it is never done by a background pass.
    case join

    public var title: String {
        switch self {
        case .migrate: "Move this library to one file per module"
        case .join: "Join the library already on this server"
        }
    }

    public var buttonTitle: String {
        switch self {
        case .migrate: "Move Library"
        case .join: "Join Library"
        }
    }

    /// The minimum version of the other apps, and where someone reads it.
    /// Confirmed against the phone's own Settings screen rather than guessed:
    /// the build that reads the new layout is 1.2.0, and until it is
    /// installed the phone shows the previous number, which is why the
    /// instruction names where to look.
    public static let updateDevicesFirst = """
        Update Lamp Bible on your iPhone and iPad to 1.2.0 or later first. \
        You can check under About in Lamp Bible's Settings: it shows \
        'Version 1.2.0 (1)' or later.
        """

    public var explanation: String {
        switch self {
        case .migrate:
            """
            \(Self.updateDevicesFirst)

            A device still on an older version keeps the writings, notes and \
            highlights it already has, and stops syncing rather than losing \
            anything — but it will no longer be told about anything you \
            delete, so deleted items linger there until it is updated.

            The first sync after the move checks every file against the \
            server once, so it will take considerably longer than usual. \
            After that, only what has changed is carried.

            Nothing is deleted from the server by the move, and it is safe to \
            run again if it is interrupted.
            """
        case .join:
            """
            This server holds a library synced from another device. Joining \
            merges this Mac's library into it and publishes everything this \
            Mac has.

            If this is not the library you meant, check the sync address \
            before joining: there is no undo, and the two libraries would be \
            merged rather than kept apart.
            """
        }
    }
}
