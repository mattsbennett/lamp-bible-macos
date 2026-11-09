import Foundation
import LampCore
import LampModuleKit

extension LampPresentationBlockKind {
    /// The roles Slide Studio can add by hand.
    ///
    /// Every one of them. A chart was held back while Studio could draw one
    /// but not build one — adding it then made a block that was invalid the
    /// moment it appeared — and it came back when the editor did, which adds
    /// a chart with its translation already chosen.
    public static var authorableHere: [LampPresentationBlockKind] {
        allCases
    }

    /// The same list, with `kind` in it whether or not it is authorable.
    ///
    /// Kept for a picker bound to an existing block: a selection with no
    /// matching tag draws blank and can be reset to the first entry, silently
    /// turning one kind of block into another. Nothing is held back today, so
    /// this is the same list — and it is the guard that has to stay if
    /// anything is held back again.
    public static func authorableHere(
        including kind: LampPresentationBlockKind
    ) -> [LampPresentationBlockKind] {
        authorableHere.contains(kind) ? authorableHere : authorableHere + [kind]
    }
}

/// Reading the Mac's search history, old shape or new.
///
/// The history moved into core so that the Mac and the phone keep and match
/// searches the same way. The Mac's own entries predate it and live under
/// the same defaults key, so they are read once and carried over rather than
/// quietly dropped.
public enum LampSearchHistoryMigration {
    public static func history(from data: Data) -> LampSearchHistory {
        guard !data.isEmpty else { return LampSearchHistory() }
        guard isOlderShape(data) else { return LampSearchHistory.decoded(from: data) }
        return LampSearchHistory(
            entries: (try? JSONDecoder().decode([Older].self, from: data))?.map { entry in
                LampSearchHistory.Entry(
                    query: entry.query,
                    kinds: entry.kind.map { [$0] },
                    moduleIDs: entry.moduleID.map { [$0] },
                    searchedAt: entry.searchedAt
                )
            } ?? []
        )
    }

    /// The Mac's entry as it used to be written. Kept here, private to the
    /// migration, rather than as a type the app still has: nothing writes
    /// this shape any more, and the only thing left to do with it is read it
    /// once.
    private struct Older: Codable {
        let query: String
        let kind: LampModuleKind?
        let moduleID: String?
        let searchedAt: Date
    }

    /// Whether these bytes are the Mac's older entries.
    ///
    /// Decided on the keys, not on whether a decode succeeds. Every field of
    /// core's entry is optional, so core decodes the *old* array quite
    /// happily — giving back the queries with every filter dropped, which
    /// looks like a successful read and silently loses what the entry was
    /// filtered by. Only the singular `kind` and `moduleID` tell the two
    /// shapes apart; an old entry carrying neither decodes the same either
    /// way, so it does not matter which reads it.
    private static func isOlderShape(_ data: Data) -> Bool {
        guard let objects = try? JSONSerialization.jsonObject(with: data),
              let entries = objects as? [[String: Any]] else { return false }
        return entries.contains { $0["kind"] != nil || $0["moduleID"] != nil }
    }
}

/// Core marks each matched term in a search snippet so a list can highlight
/// it. Anything that is not a list wants the words.
public enum LampSearchSnippet {
    public static let openingMark = "<mark>"
    public static let closingMark = "</mark>"

    /// The snippet as prose: what belongs on the pasteboard, in a file, or
    /// spoken aloud.
    public static func plainText(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: openingMark, with: "")
            .replacingOccurrences(of: closingMark, with: "")
    }
}

/// Reading the item out of a search result's identifier.
///
/// Core builds these as `<kind>:<module>:<entry>`, which is the only place a
/// writing's result says *which* writing it is — the module alone names the
/// collection, not the item. A dictionary hit's entry part is its row's id;
/// its key comes in `entryKey`. Parsed in one place, and pinned by
/// tests, because the shape is core's rather than ours.
public enum LampSearchResultIdentity {
    public static func entryID(
        in identifier: String,
        kind: String,
        moduleID: String
    ) -> String? {
        let prefix = "\(kind):\(moduleID):"
        guard identifier.hasPrefix(prefix) else { return nil }
        let entry = String(identifier.dropFirst(prefix.count))
        return entry.isEmpty ? nil : entry
    }
}
