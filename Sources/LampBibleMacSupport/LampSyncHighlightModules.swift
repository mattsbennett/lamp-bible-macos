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
    ///
    /// `taken` is every module ID already spoken for: the ones discovered on
    /// the server and the ones this Mac has recorded for other sets. Without
    /// it the name is a pure function of the set ID, and two different sets
    /// can land on one module — a Mac set called "ESVs" mints
    /// `esvs-highlights`, which is exactly what the phone names an ESVs set
    /// of its own. The two sets would then share a file and merge into each
    /// other. A taken name takes a number, as the phone does.
    public static func mintedModuleID(
        forSet setID: String,
        avoiding taken: Set<String> = []
    ) -> String {
        let safe = String(setID.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? Character(character.lowercased())
                : "-"
        })
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = "\(trimmed.isEmpty ? "set" : trimmed)-highlights"
        guard taken.contains(base) else { return base }
        for suffix in 2...99 where !taken.contains("\(base)-\(suffix)") {
            return "\(base)-\(suffix)"
        }
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

public extension LampSyncHighlightModules {
    /// Which highlight set each module ID stands for, for a pass that has to
    /// act on a path rather than a set.
    ///
    /// Built from the sets that **exist**, not from the whole recorded
    /// mapping, because the mapping outlives the sets in it. A record of a
    /// file is forgotten when the file goes; a set's module ID is not, so a
    /// set deleted here leaves its entry behind. Meanwhile the phone names a
    /// new set on the same translation `<translation>-highlights` again — the
    /// `-2` suffix is only used while a module of that ID still exists there
    /// — so the same module ID comes back pointing at a different set.
    ///
    /// Inverting the whole mapping then leaves that module ID resolving to
    /// whichever entry came out of the dictionary first, which is unordered
    /// and seeded per process: the same library would act on the right set
    /// one run and on a set that no longer exists the next, reporting success
    /// either way. Restricting it to live sets makes the stale entry
    /// unreachable rather than merely unlikely.
    static func setIDsByModule(
        _ moduleIDsBySet: [String: String],
        existingSetIDs: some Sequence<String>
    ) -> [String: String] {
        Dictionary(
            existingSetIDs.compactMap { setID in
                moduleIDsBySet[setID].map { ($0, setID) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
