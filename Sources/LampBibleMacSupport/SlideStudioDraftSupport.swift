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

extension LampPresentationDeck {
    /// This deck as Slide Studio stores, presents and exports it: without
    /// text blocks whose words have all been cleared.
    ///
    /// Clearing a heading's words is how an author takes the heading off a
    /// slide, so a video or a picture can stand alone. An empty text block
    /// is an error to the validator, and to every older Lamp that reads the
    /// deck, so it is left out of what is saved rather than kept as a deck
    /// that cannot be presented. The editor keeps the block, so the author
    /// can type into it again.
    public var withoutEmptyTextBlocks: LampPresentationDeck {
        var copy = self
        for index in copy.slides.indices {
            copy.slides[index].blocks.removeAll { block in
                block.kind != .image && block.kind != .chart
                    && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return copy
    }
}

extension LampPresentationBlock {
    /// What Slide Studio calls this block: its role, except that a picture
    /// block is named for what it shows. A video is kept as a picture block
    /// with its still, but an author who added a clip looks for a clip, not
    /// an image.
    public var studioName: String {
        guard kind == .image else { return kind.displayName }
        if clip != nil { return "Clip" }
        if video != nil { return "Looping Video" }
        return kind.displayName
    }
}

/// Names for files Slide Studio copies into a deck's assets.
public enum SlideStudioAssetName {
    /// A copy of `source` named after it, so an author can tell which file
    /// a picture came from, with eight random hex digits so two files of
    /// one name never meet: `sunset-3f2a1b9c.heic`. Lower case, letters,
    /// digits and dashes only, which every file system and sync keeps.
    public static func copy(of source: URL, extension pathExtension: String, fallback: String) -> String {
        stem(source.deletingPathExtension().lastPathComponent, fallback: fallback)
            + "-" + UUID().uuidString.lowercased().prefix(8)
            + "." + pathExtension.lowercased()
    }

    static func stem(_ name: String, fallback: String) -> String {
        var result = ""
        var lastWasDash = true
        for character in name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
            if result.count >= 40 { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? fallback : result
    }
}

/// How Slide Studio names where an issue is, for a person rather than a
/// parser: "Slide 3, Clip" for `slides[2].blocks[1].altText`.
public enum SlideStudioIssuePlace {
    public static func name(of path: String, in deck: LampPresentationDeck) -> String {
        guard let slideMatch = path.firstMatch(of: #/^slides\[(\d+)\]/#),
              let slideIndex = Int(slideMatch.1)
        else { return "Deck" }
        let slide = "Slide \(slideIndex + 1)"
        guard let blockMatch = path.firstMatch(of: #/\.blocks\[(\d+)\]/#),
              let blockIndex = Int(blockMatch.1),
              deck.slides.indices.contains(slideIndex),
              deck.slides[slideIndex].blocks.indices.contains(blockIndex)
        else { return slide }
        return "\(slide), \(deck.slides[slideIndex].blocks[blockIndex].studioName)"
    }
}
