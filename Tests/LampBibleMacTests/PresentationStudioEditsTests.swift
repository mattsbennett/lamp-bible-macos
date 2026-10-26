import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// Telling what the writer changed in Slide Studio from what Lamp changed
/// itself.
///
/// The point of all this is a warning an agent can act on before it
/// regenerates `presentation.lampdeck` and throws the writer's editing away.
/// A warning that fires when nothing happened is worse than none, because it
/// is the one an agent learns to skip — so most of what is held here is about
/// staying quiet.
struct PresentationStudioEditsTests {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-studio-edits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func deck() -> LampPresentationDeck {
        var deck = LampPresentationDeck.starter(title: "Psalm 23")
        deck.slides = (1...3).map { index in
            LampPresentationSlide(
                id: "slide-\(index)",
                layout: .titleAndBody,
                blocks: [
                    .init(kind: .title, text: "Heading \(index)"),
                    .init(kind: .body, text: "Body \(index)"),
                ],
                speakerNotes: "Notes \(index)"
            )
        }
        return deck
    }

    private func compare(
        _ change: (inout LampPresentationDeck) -> Void
    ) -> LampPresentationImportStatus.StudioEdits {
        let written = deck()
        var library = written
        change(&library)
        return LampPresentationStudioEdits.compare(library: library, against: written)
    }

    @Test func anuntouchedDeckReportsNothing() {
        #expect(compare { _ in }.isEmpty)
    }

    @Test func aneditedSlideIsNamed() {
        let edits = compare { $0.slides[1].blocks[1].text = "Rewritten by hand" }

        #expect(edits.changedSlideIDs == ["slide-2"])
        #expect(edits.addedSlideIDs.isEmpty)
        #expect(edits.removedSlideIDs.isEmpty)
        #expect(edits.isEmpty == false)
    }

    @Test func anaddedSlideIsNamedAsAddedRatherThanChanged() {
        let edits = compare {
            $0.slides.append(
                LampPresentationSlide(id: "slide-4", layout: .blank, blocks: [])
            )
        }

        #expect(edits.addedSlideIDs == ["slide-4"])
        #expect(edits.changedSlideIDs.isEmpty)
    }

    @Test func adeletedSlideIsNamed() {
        let edits = compare { $0.slides.removeFirst() }

        #expect(edits.removedSlideIDs == ["slide-1"])
        #expect(edits.changedSlideIDs.isEmpty)
    }

    /// Reordering is an edit an agent would silently undo, and nothing about
    /// the slides themselves shows it.
    @Test func reorderingTheSlidesIsReportedThoughNoSlideChanged() {
        let edits = compare { $0.slides.reverse() }

        #expect(edits.reordered)
        #expect(edits.changedSlideIDs.isEmpty)
        #expect(edits.addedSlideIDs.isEmpty)
        #expect(edits.removedSlideIDs.isEmpty)
    }

    @Test func thedecksOwnSettingsAreReportedApartFromItsSlides() {
        #expect(compare { $0.theme.accentColor = "#FF0000" }.deckSettingsChanged)
        #expect(compare { $0.title = "A New Title" }.deckSettingsChanged)
        #expect(compare { $0.aspectRatio = .standard }.deckSettingsChanged)
        #expect(compare { $0.slides[0].blocks[0].text = "x" }.deckSettingsChanged == false)
    }

    // MARK: - What Lamp does itself

    /// The case the whole design turns on. Lamp re-derives a manuscript deck's
    /// notes and saves it again every time the writing is saved, so comparing
    /// the notes would report Lamp's own work as the writer's — on every prose
    /// edit, for ever.
    @Test func notesLampDerivesFromTheWritingAreNotTheWritersEdits() {
        var written = deck()
        written.speakerNotesSource = .manuscript
        var library = written
        library.slides[0].speakerNotes = "Re-split from the writing just now"
        library.slides[2].speakerNotes = ""

        let edits = LampPresentationStudioEdits.compare(library: library, against: written)

        #expect(edits.isEmpty, "a deck whose notes follow the writing is not edited by a re-split")
    }

    /// The other half: where the notes are the author's, editing them counts.
    @Test func notesTypedOnADeckThatDoesNotFollowTheWritingAreTheWritersEdits() {
        var written = deck()
        written.speakerNotesSource = .authored
        var library = written
        library.slides[0].speakerNotes = "Typed into the editor"

        let edits = LampPresentationStudioEdits.compare(library: library, against: written)

        #expect(edits.changedSlideIDs == ["slide-1"])
    }

    /// Notes are the only thing excused. A manuscript deck edited anywhere
    /// else is still reported.
    @Test func amanuscriptDecksOtherEditsAreStillReported() {
        var written = deck()
        written.speakerNotesSource = .manuscript
        var library = written
        library.slides[1].speakerNotes = "re-split"
        library.slides[1].blocks[0].text = "Edited by hand"

        let edits = LampPresentationStudioEdits.compare(library: library, against: written)

        #expect(edits.changedSlideIDs == ["slide-2"])
    }

    // MARK: - Against the workspace and the library

    @Test func whatLampWroteIsReadBackAsItWentIn() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let written = deck()

        LampPresentationStudioEdits.recordWritten(written, in: workspace)

        #expect(LampPresentationStudioEdits.lastWritten(in: workspace) == written)
    }

    /// The marker belongs with Lamp's other bookkeeping, not beside the
    /// artifact where an agent would find it and take it for one of its own.
    @Test func themarkerIsKeptOutOfTheAgentsWayInDotLamp() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = LampPresentationStudioEdits.markerURL(in: workspace)

        #expect(url.deletingLastPathComponent().lastPathComponent == ".lamp")
    }

    @Test func aworkspaceWithNoImportYetComparesToNothing() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let library = workspace.appendingPathComponent("library", isDirectory: true)
        let store = LampPresentationDeckStore(rootURL: library)
        try store.save(deck())

        #expect(
            LampPresentationStudioEdits.edits(
                in: workspace, deckID: deck().id, store: store
            ) == nil,
            "nothing has been imported, so there is nothing the writer could have changed since"
        )
    }

    @Test func adeckNoLongerInTheLibraryComparesToNothing() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LampPresentationDeckStore(
            rootURL: workspace.appendingPathComponent("library", isDirectory: true)
        )
        LampPresentationStudioEdits.recordWritten(deck(), in: workspace)

        #expect(
            LampPresentationStudioEdits.edits(
                in: workspace, deckID: deck().id, store: store
            ) == nil
        )
    }

    @Test func aneditInTheLibraryIsFoundThroughTheStore() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LampPresentationDeckStore(
            rootURL: workspace.appendingPathComponent("library", isDirectory: true)
        )
        let written = deck()
        LampPresentationStudioEdits.recordWritten(written, in: workspace)
        var edited = written
        edited.slides[0].blocks[0].text = "Edited in Slide Studio"
        try store.save(edited)

        let edits = try #require(
            LampPresentationStudioEdits.edits(in: workspace, deckID: written.id, store: store)
        )

        #expect(edits.changedSlideIDs == ["slide-1"])
        #expect(edits.changedAt != nil, "the status says when the library's copy was written")
    }

    /// Unlike the import summary and the notes summary, this one is not
    /// carried forward when a later check does not supply it.
    ///
    /// Those two describe things that happened and stay true. This describes
    /// how two copies stand *now*, and a stale copy of that is the exact bug
    /// it exists to prevent: an agent told the writer has edits long after an
    /// import took them, or told nothing while they sit there.
    @Test func thewarningIsNeverCarriedForwardIntoACheckThatDidNotFindIt() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        LampPresentationImportStatusStore.write(
            LampPresentationImportStatus(
                outcome: .unchanged,
                message: "No change since the last import.",
                deckID: "deck-1",
                studioEdits: .init(changedSlideIDs: ["slide-1"])
            ),
            in: workspace
        )

        LampPresentationImportStatusStore.writeIfChanged(
            LampPresentationImportStatus(
                outcome: .imported, message: "Imported.", deckID: "deck-1"
            ),
            in: workspace
        )

        let stored = try #require(LampPresentationImportStatusStore.read(in: workspace))
        #expect(stored.studioEdits == nil, "the import took those edits; the warning must go")
        #expect(stored.lastImport != nil, "the import summary is still carried as before")
    }

    /// The gate that keeps the poll cheap has to actually notice a save.
    @Test func thestampMovesWhenTheLibrarysCopyIsSavedAgain() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LampPresentationDeckStore(
            rootURL: workspace.appendingPathComponent("library", isDirectory: true)
        )
        var written = deck()
        try store.save(written)
        let before = try #require(
            LampPresentationStudioEdits.stamp(deckID: written.id, store: store)
        )

        written.slides[0].blocks[1].text = String(repeating: "Longer now. ", count: 20)
        try store.save(written)

        #expect(LampPresentationStudioEdits.stamp(deckID: written.id, store: store) != before)
    }
}
