import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// Import runs in the app, and its outcome used to appear only in the agent
/// pane — so an agent could not tell whether its deck had been taken or why it
/// had not. These cover the file that answers that.
struct PresentationImportStatusTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func roundTripsThroughTheWorkspace() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        let status = LampPresentationImportStatus(
            outcome: .imported,
            message: "Imported Two Ways into Slide Studio.",
            deckID: "deck-1",
            deckTitle: "Two Ways",
            slideCount: 9,
            slideIdentity: .init(reused: 7, added: 2, removed: 1),
            importedAssets: ["Assets/cover.png"],
            missingAssets: ["Assets/absent.png"],
            issues: [.init(severity: "warning", path: "slides[2]", message: "Too dense.")]
        )
        LampPresentationImportStatusStore.write(status, in: directory)

        let read = try #require(LampPresentationImportStatusStore.read(in: directory))
        #expect(read.outcome == .imported)
        #expect(read.deckTitle == "Two Ways")
        #expect(read.slideIdentity?.reused == 7)
        #expect(read.missingAssets == ["Assets/absent.png"])
        #expect(read.issues.first?.message == "Too dense.")
    }

    @Test func isWrittenWhereTheAgentCanFindIt() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        LampPresentationImportStatusStore.write(
            .init(outcome: .failed, message: "Nope."),
            in: directory
        )
        // Named in the skill, so it must stay at the workspace root.
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("presentation-import.json").path
        ))
    }

    @Test func countsSlidesKeptAndSlidesReplaced() {
        func deck(_ ids: [String]) -> LampPresentationDeck {
            LampPresentationDeck(title: "Deck", slides: ids.map {
                LampPresentationSlide(id: $0, layout: .blank, blocks: [
                    .init(kind: .body, text: "text"),
                ])
            })
        }

        let carried = LampPresentationImportStatus.slideIdentity(
            importing: deck(["a", "b", "c"]),
            over: deck(["a", "b", "z"])
        )
        #expect(carried == .init(reused: 2, added: 1, removed: 1))

        // Regenerating a deck with all-new identifiers throws away the link
        // between a slide and anything done to it, which is worth reporting.
        let rewritten = LampPresentationImportStatus.slideIdentity(
            importing: deck(["x", "y"]),
            over: deck(["a", "b"])
        )
        #expect(rewritten == .init(reused: 0, added: 2, removed: 2))

        let first = LampPresentationImportStatus.slideIdentity(
            importing: deck(["a"]),
            over: nil
        )
        #expect(first == .init(reused: 0, added: 1, removed: 0))
    }

    @Test func doesNotRewriteAnUnchangedAnswer() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("presentation-import.json")

        LampPresentationImportStatusStore.writeIfChanged(
            .init(outcome: .unchanged, message: "No change since the last import."),
            in: directory
        )
        let first = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )

        // Lamp looks at the artifact several times a second; the same answer
        // again must not churn the workspace.
        LampPresentationImportStatusStore.writeIfChanged(
            .init(outcome: .unchanged, message: "No change since the last import."),
            in: directory
        )
        let second = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
        #expect(first == second)

        LampPresentationImportStatusStore.writeIfChanged(
            .init(outcome: .failed, message: "Deck not imported."),
            in: directory
        )
        #expect(LampPresentationImportStatusStore.read(in: directory)?.outcome == .failed)
    }

    @Test func keepsTheLastRealImportThroughLaterChecks() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        LampPresentationImportStatusStore.writeIfChanged(
            .init(
                outcome: .imported,
                message: "Imported Two Ways into Slide Studio.",
                deckID: "deck-1",
                deckTitle: "Two Ways",
                slideCount: 74,
                slideIdentity: .init(reused: 70, added: 4, removed: 0),
                importedAssets: ["Assets/cover.png"],
                missingAssets: []
            ),
            in: directory
        )

        // Lamp looks again within the second and finds nothing new. The import
        // that just happened used to be gone before anyone could read it.
        LampPresentationImportStatusStore.writeIfChanged(
            .init(outcome: .unchanged, message: "No change since the last import."),
            in: directory
        )

        let read = try #require(LampPresentationImportStatusStore.read(in: directory))
        #expect(read.outcome == .unchanged)
        let completed = try #require(read.lastImport)
        #expect(completed.deckTitle == "Two Ways")
        #expect(completed.slideCount == 74)
        #expect(completed.slideIdentity == .init(reused: 70, added: 4, removed: 0))
        #expect(completed.importedAssets == ["Assets/cover.png"])
    }

    @Test func keepsTheLastRealImportThroughAFailure() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        LampPresentationImportStatusStore.writeIfChanged(
            .init(outcome: .imported, message: "Imported.", deckID: "deck-1", deckTitle: "Two Ways"),
            in: directory
        )
        LampPresentationImportStatusStore.writeIfChanged(
            .init(outcome: .failed, message: "Deck not imported: bad JSON."),
            in: directory
        )

        let read = try #require(LampPresentationImportStatusStore.read(in: directory))
        #expect(read.outcome == .failed)
        // What is in Slide Studio right now is still the earlier import.
        #expect(read.lastImport?.deckTitle == "Two Ways")
    }

    @Test func keepsTheSpeakerNotesSummaryThroughLaterChecks() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        LampPresentationImportStatusStore.writeIfChanged(
            .init(
                outcome: .imported,
                message: "Imported.",
                deckID: "deck-1",
                deckTitle: "Two Dials",
                slideCount: 74,
                speakerNotes: .init(
                    source: "manuscript",
                    resolved: 73,
                    stale: 0,
                    problems: [],
                    resolvedAt: Date(timeIntervalSince1970: 1_000)
                )
            ),
            in: directory
        )
        LampPresentationImportStatusStore.writeIfChanged(
            .init(outcome: .unchanged, message: "No change since the last import."),
            in: directory
        )

        let read = try #require(LampPresentationImportStatusStore.read(in: directory))
        // How the notes were arrived at is as much a part of the import as the
        // slide identity, and must survive the same way.
        #expect(read.lastImport?.speakerNotes?.resolved == 73)
        #expect(read.speakerNotes?.resolved == 73)
    }
}

/// The notes follow the writing, so the summary of how they were split has to
/// follow it too. It used to be written only by the import, which re-reads the
/// notes only when the deck file itself changes — so a reworded opening broke a
/// slide's anchor and the status went on reporting every slide resolved.
struct ManuscriptNotesRefreshTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func deck(anchors: [String], id: String = "deck-1") -> LampPresentationDeck {
        LampPresentationDeck(
            id: id,
            title: "Two Dials",
            source: .init(kind: .devotional, id: "writing-1"),
            slides: anchors.enumerated().map { offset, anchor in
                LampPresentationSlide(
                    id: "slide-\(offset + 1)",
                    layout: .titleAndBody,
                    blocks: [.init(kind: .title, text: "Slide \(offset + 1)")],
                    notesAnchor: anchor
                )
            },
            speakerNotesSource: .manuscript
        )
    }

    /// A problem that names only its message says *what* broke but not *where*,
    /// so an agent had to search the deck for the phrase it quoted.
    @Test func aProblemNamesItsSlideAndItsPositionInTheDeck() throws {
        let deck = deck(anchors: ["The first thing", "The second thing", "The third thing"])
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: deck,
            manuscript: "The first thing happened. The third thing happened."
        )
        let summary = LampPresentationImportStatus.SpeakerNotes(
            resolution: resolution,
            deck: deck,
            resolvedAt: Date(timeIntervalSince1970: 50)
        )

        #expect(summary.resolved == 2)
        #expect(summary.stale == 1)
        let problem = try #require(summary.problems.first)
        #expect(problem.slideID == "slide-2")
        #expect(problem.slide == 2)
        #expect(problem.message.contains("no longer in the manuscript"))
        #expect(summary.resolvedAt == Date(timeIntervalSince1970: 50))
    }

    /// A status written before problems named their slide must still decode, or
    /// the import it records would be dropped and rebuilt from nothing.
    @Test func readsTheBareMessagesWrittenByEarlierVersions() throws {
        let workspace = try directory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try """
        {
          "checkedAt" : "2026-10-19T09:00:00Z",
          "formatVersion" : 1,
          "importedAssets" : [],
          "issues" : [],
          "message" : "Imported.",
          "missingAssets" : [],
          "outcome" : "imported",
          "speakerNotes" : {
            "problems" : ["The notes anchor “So on capacity” is no longer in the manuscript."],
            "resolved" : 76,
            "source" : "manuscript",
            "stale" : 1
          }
        }
        """.write(
            to: LampPresentationImportStatusStore.url(in: workspace),
            atomically: true,
            encoding: .utf8
        )

        let read = try #require(LampPresentationImportStatusStore.read(in: workspace))
        #expect(read.speakerNotes?.problems.count == 1)
        #expect(read.speakerNotes?.problems.first?.message.contains("So on capacity") == true)
        #expect(read.speakerNotes?.problems.first?.slide == nil)
        #expect(read.speakerNotes?.resolvedAt == nil)
    }

    @Test func amendsTheSummaryWithoutClaimingAnImport() throws {
        let workspace = try directory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let checked = Date(timeIntervalSince1970: 2_000)
        LampPresentationImportStatusStore.write(
            .init(
                outcome: .imported,
                checkedAt: checked,
                message: "Imported Two Dials into Slide Studio.",
                deckID: "deck-1",
                deckTitle: "Two Dials",
                slideCount: 3
            ),
            in: workspace
        )

        let summary = LampPresentationImportStatus.SpeakerNotes(
            source: "manuscript",
            resolved: 2,
            stale: 1,
            problems: [.init(slideID: "slide-2", slide: 2, message: "Anchor gone.")],
            resolvedAt: Date(timeIntervalSince1970: 3_000)
        )
        #expect(LampPresentationImportStatusStore.updateSpeakerNotesIfChanged(
            summary, in: workspace
        ))
        // The same summary again says nothing new, and must not churn a file an
        // agent is watching.
        #expect(!LampPresentationImportStatusStore.updateSpeakerNotesIfChanged(
            summary, in: workspace
        ))

        let read = try #require(LampPresentationImportStatusStore.read(in: workspace))
        #expect(read.speakerNotes == summary)
        // A save is not a look at `presentation.lampdeck`: the outcome and the
        // time of the last check still describe the artifact.
        #expect(read.outcome == .imported)
        #expect(read.checkedAt == checked)
        #expect(read.lastImport?.deckTitle == "Two Dials")
    }

    /// Nothing has ever looked at a deck in this workspace, so there is no
    /// status to amend and writing one would invent an import.
    @Test func saysNothingInAWorkspaceWithNoStatus() throws {
        let workspace = try directory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(!LampPresentationImportStatusStore.updateSpeakerNotesIfChanged(
            .init(source: "manuscript", resolved: 1, stale: 0, problems: []),
            in: workspace
        ))
        #expect(LampPresentationImportStatusStore.read(in: workspace) == nil)
    }

    /// The case from the talk: the writer rewords the opening of a passage, the
    /// slide anchored to the old words goes stale, and its passage runs on under
    /// the slide before it.
    @Test func reportsAnAnchorBrokenByRewordingTheWriting() async throws {
        let library = try directory()
        let workspace = try directory()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = LampPresentationDeckStore(rootURL: library)
        let original = deck(anchors: [
            "Everyone agrees on the first point",
            "So on capacity there has been no meaningful change",
            "Which brings us to the last thing",
        ])
        _ = try store.save(original)
        LampPresentationImportStatusStore.write(
            .init(
                outcome: .imported,
                message: "Imported.",
                deckID: original.id,
                deckTitle: original.title,
                slideCount: 3
            ),
            in: workspace
        )

        let refresh = LampManuscriptNotesRefresh()
        let settled = """
        Everyone agrees on the first point, and we can move on.

        So on capacity there has been no meaningful change, whatever anyone says.

        Which brings us to the last thing, and then I am done.
        """
        await refresh.refresh(.init(
            libraryRootURL: library,
            devotionalID: "writing-1",
            manuscript: settled,
            workspaceURL: workspace
        ))
        let current = try #require(
            LampPresentationImportStatusStore.read(in: workspace)?.speakerNotes
        )
        #expect(current.resolved == 3)
        #expect(current.stale == 0)
        #expect(current.resolvedAt != nil)

        // The writer rewords the opening of the second slide's passage.
        await refresh.refresh(.init(
            libraryRootURL: library,
            devotionalID: "writing-1",
            manuscript: settled.replacingOccurrences(
                of: "So on capacity there has been no meaningful change",
                with: "But on this question of capacity, there has been no meaningful change"
            ),
            workspaceURL: workspace
        ))

        let broken = try #require(
            LampPresentationImportStatusStore.read(in: workspace)?.speakerNotes
        )
        #expect(broken.stale == 1)
        #expect(broken.resolved == 2)
        #expect(broken.problems.map(\.slide) == [2])
        #expect(broken.problems.first?.slideID == "slide-2")
    }

    /// A burst of autosaves must do the work once, at the end, and against the
    /// newest writing — not once per keystroke, and never against an older copy.
    @Test func aBurstOfSavesSplitsTheWritingOnce() async throws {
        let library = try directory()
        let workspace = try directory()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = LampPresentationDeckStore(rootURL: library)
        _ = try store.save(deck(anchors: ["The opening words", "The closing words"]))
        LampPresentationImportStatusStore.write(
            .init(outcome: .imported, message: "Imported.", deckID: "deck-1", slideCount: 2),
            in: workspace
        )

        let refresh = LampManuscriptNotesRefresh(settleInterval: .milliseconds(30))
        for suffix in ["", " a", " ab", " abc"] {
            await refresh.schedule(.init(
                libraryRootURL: library,
                devotionalID: "writing-1",
                manuscript: "The opening words\(suffix). The closing words, at last.",
                workspaceURL: workspace
            ))
        }

        try await Task.sleep(for: .milliseconds(400))
        let saved = try #require(try store.deck(id: "deck-1"))
        // The last writing in the burst is the one that reached the deck.
        #expect(saved.slides.first?.speakerNotes.contains("abc") == true)
        #expect(LampPresentationImportStatusStore.read(in: workspace)?.speakerNotes?.stale == 0)
    }
}
