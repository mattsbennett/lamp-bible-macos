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
}
