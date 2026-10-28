import Foundation
import LampCore

/// A deck being edited that the library will not take yet.
///
/// `LampPresentationDeckStore` holds valid decks only — it checks on save, on
/// encode and on decode — because the presenter, the agent and sync all read
/// from it, and a broken deck reaching any of them is a worse problem than a
/// deck that cannot be stored for a minute.
///
/// But every error the validator raises is a state someone passes through while
/// editing: a title cleared to retype, a half-typed hex colour, every slide
/// deleted to start again. With nowhere to put those, Slide Studio simply threw
/// away everything typed since the deck last validated, as soon as the window
/// closed or the deck was changed.
///
/// So the work is kept here instead, beside the app rather than inside the
/// library. A draft is this machine's unfinished business: syncing a broken
/// deck to another device would spread the problem rather than back the work
/// up, and the library is what syncs.
public enum LampSlideStudioDrafts {
    /// Where drafts live under a given Application Support directory.
    public static func directoryURL(inApplicationSupport root: URL) -> URL {
        root
            .appendingPathComponent("Lamp Bible", isDirectory: true)
            .appendingPathComponent("SlideStudioDrafts", isDirectory: true)
    }

    public static func url(forDeck id: String, inApplicationSupport root: URL) -> URL {
        directoryURL(inApplicationSupport: root)
            .appendingPathComponent(storageKey(for: id))
            .appendingPathExtension("json")
    }

    /// Keeps `deck` as the unfinished version of itself.
    ///
    /// Encoded directly rather than through the store, whose `encoded(_:)`
    /// rejects exactly the decks this exists to hold.
    public static func write(
        _ deck: LampPresentationDeck,
        inApplicationSupport root: URL
    ) throws {
        let directory = directoryURL(inApplicationSupport: root)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(deck).write(
            to: url(forDeck: deck.id, inApplicationSupport: root),
            options: .atomic
        )
    }

    /// The unfinished version of a deck, if one was kept.
    ///
    /// Decoded directly, for the same reason it is encoded directly. A draft
    /// that will not decode is treated as no draft: it is a recovery copy, and
    /// failing to open one must not stop the stored deck opening.
    public static func read(
        forDeck id: String,
        inApplicationSupport root: URL
    ) -> LampPresentationDeck? {
        let url = url(forDeck: id, inApplicationSupport: root)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LampPresentationDeck.self, from: data)
    }

    /// Forgets the draft, once the real deck has been stored.
    public static func discard(forDeck id: String, inApplicationSupport root: URL) {
        try? FileManager.default.removeItem(
            at: url(forDeck: id, inApplicationSupport: root)
        )
    }

    /// A deck ID as a filename, by the same rule the deck store uses, so a
    /// draft sits under a recognisable name beside its deck.
    private static func storageKey(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let readable = id.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(readable.prefix(96))
        return result.isEmpty ? "deck" : result
    }
}
