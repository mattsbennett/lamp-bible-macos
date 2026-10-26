import Foundation
import LampCore

/// Tells the writer's edits in Slide Studio apart from Lamp's own changes to a
/// deck, so an agent can be warned before it overwrites them.
///
/// There are three copies of a deck, and until this only two of them were ever
/// compared. `presentation.lampdeck` is the agent's; the library's is Slide
/// Studio's; and `.lamp/presentation-imported.lampdeck` records the artifact
/// Lamp last took, which is how it knows the *agent* has written something new.
/// Nothing watched the library copy, so an editor's work was invisible to the
/// next import that replaced it.
public enum LampPresentationStudioEdits {
    /// A copy of the deck exactly as Lamp last wrote it into the library.
    ///
    /// Deliberately not the workspace artifact. Lamp changes a deck on its way
    /// in — it stamps the source, resolves the speaker notes, rewrites asset
    /// paths — so the artifact and the library copy are never identical, and
    /// comparing against the artifact would report every clean import as an
    /// edit. Comparing against what Lamp *wrote* reports only what someone
    /// else has done since.
    static let filename = "presentation-in-library.lampdeck"

    public static func markerURL(in workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".lamp", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Records the deck Lamp has just written into the library.
    ///
    /// Never throws into the import path: a marker that cannot be written
    /// costs a warning, and must not stop a deck that otherwise imported.
    public static func recordWritten(_ deck: LampPresentationDeck, in workspace: URL) {
        let url = markerURL(in: workspace)
        guard let data = try? LampPresentationDeckStore.encodedUnvalidated(deck) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    public static func lastWritten(in workspace: URL) -> LampPresentationDeck? {
        guard let data = try? Data(contentsOf: markerURL(in: workspace)) else { return nil }
        return try? LampPresentationDeckStore.decodeUnvalidated(data)
    }

    /// What the library's copy of `deckID` has that Lamp's last write did not.
    ///
    /// Nil when there is nothing to compare — no marker from a previous
    /// import, or no deck in the library — rather than an empty answer, which
    /// would claim the two agree.
    public static func edits(
        in workspace: URL,
        deckID: String,
        store: LampPresentationDeckStore,
        fileManager: FileManager = .default
    ) -> LampPresentationImportStatus.StudioEdits? {
        guard let written = lastWritten(in: workspace),
              let library = try? store.deck(id: deckID)
        else { return nil }
        let url = store.deckFileURL(for: deckID)
        let changedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return compare(library: library, against: written, changedAt: changedAt)
    }

    /// Compares the deck in the library with the one Lamp last wrote there.
    ///
    /// Speaker notes are left out when the deck's notes follow the manuscript.
    /// Lamp derives those from the writing and saves the deck again every time
    /// the writing is saved, so comparing them would report Lamp's own work as
    /// the writer's — and a warning that fires on every prose edit is one an
    /// agent learns to ignore. On a deck whose notes do not follow the
    /// manuscript they are the author's, and are compared like anything else.
    public static func compare(
        library: LampPresentationDeck,
        against written: LampPresentationDeck,
        changedAt: Date? = nil
    ) -> LampPresentationImportStatus.StudioEdits {
        let notesAreDerived = library.followsManuscript || written.followsManuscript
        func comparable(_ slide: LampPresentationSlide) -> LampPresentationSlide {
            guard notesAreDerived else { return slide }
            var slide = slide
            slide.speakerNotes = ""
            return slide
        }

        // A deck should never hold two slides with one identifier — the
        // validator refuses it — but this reads decks off disk, so it keeps the
        // first rather than trapping on one that slipped through.
        let before = Dictionary(
            written.slides.map { ($0.id, comparable($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let after = Dictionary(
            library.slides.map { ($0.id, comparable($0)) },
            uniquingKeysWith: { first, _ in first }
        )

        let shared = Set(before.keys).intersection(after.keys)
        var settings = library
        settings.slides = []
        var writtenSettings = written
        writtenSettings.slides = []

        return .init(
            addedSlideIDs: library.slides.map(\.id).filter { before[$0] == nil },
            removedSlideIDs: written.slides.map(\.id).filter { after[$0] == nil },
            changedSlideIDs: library.slides.map(\.id)
                .filter { shared.contains($0) && before[$0] != after[$0] },
            reordered: written.slides.map(\.id).filter(shared.contains)
                != library.slides.map(\.id).filter(shared.contains),
            deckSettingsChanged: settings != writtenSettings,
            changedAt: changedAt
        )
    }

    /// Enough of the library deck's file to tell whether it is worth reading
    /// again. The workspace is looked at several times a second and decoding a
    /// deck with its notes in it is not cheap, so the file is only read when
    /// this has moved.
    public struct Stamp: Equatable, Sendable {
        public var size: Int
        public var modifiedAt: Date

        public init(size: Int, modifiedAt: Date) {
            self.size = size
            self.modifiedAt = modifiedAt
        }
    }

    public static func stamp(
        deckID: String,
        store: LampPresentationDeckStore
    ) -> Stamp? {
        let values = try? store.deckFileURL(for: deckID)
            .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate
        else { return nil }
        return Stamp(size: size, modifiedAt: modified)
    }
}
