import Foundation
import LampCore
import LampModuleKit

/// Which module each highlight set is published under.
///
/// The mapping is not derivable: a set's module ID is chosen once, written
/// inside the module as `highlight_meta.id`, and thereafter exists only
/// there. A Mac that has lost it — a fresh install, a library moved, a sync
/// source it has not used before — must read it back off the server, because
/// choosing a new one publishes a second module for a set that already has
/// one, and the person then has the same highlights twice.
///
/// Before this, the Mac learned the ID only when it *installed* a highlights
/// module, which never happened for a module whose bytes it already had. A
/// set in that state was skipped every pass, for ever, reported as waiting on
/// a server that was never going to be asked.
public enum LampSyncHighlightModules {
    /// Every set ID the server's highlight modules claim, by the module ID
    /// each is published under.
    ///
    /// One listing of the highlights folder, and one read per module. Small:
    /// a highlights module holds one set. Only worth doing when some set has
    /// no recorded ID, which the caller decides.
    public static func discover(
        in store: any LampSyncRemoteStore
    ) async throws -> [String: String] {
        guard let entries = try await store.list(
            directory: LampSyncContentKind.highlights.rawValue
        ) else { return [:] }

        var found: [String: String] = [:]
        for entry in entries where !entry.isDirectory {
            guard let moduleID = LampSyncFolderLayout.remoteModuleID(of: entry.path),
                  let file = try? await store.read(path: entry.path),
                  let setID = (try? LampWebDAVPersonalArchiveAdapter.highlightSetID(
                      in: file.data
                  )) ?? nil
            else { continue }
            found[setID] = moduleID
        }
        return found
    }

    /// A module ID for a set the server has never heard of.
    ///
    /// Only after `discover` has shown that nothing there claims it —
    /// otherwise this is how a library ends up with the same highlights under
    /// two modules. Derived from the set's own ID so it is recognisable, and
    /// made safe for a path.
    public static func mintedModuleID(forSet setID: String) -> String {
        let safe = String(setID.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? Character(character.lowercased())
                : "-"
        })
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmed.isEmpty ? "set" : trimmed)-highlights"
    }
}
