import Foundation
import Testing
@testable import LampBibleMacSupport

struct WorkspaceTextFileSupportTests {
    @Test func discoversOnlyTopLevelUserFacingTextDocuments() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "# Outline".write(
            to: workspace.appendingPathComponent("outline.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Summary".write(
            to: workspace.appendingPathComponent("summary.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "Main".write(
            to: workspace.appendingPathComponent("draft.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0, 1, 2]).write(to: workspace.appendingPathComponent("presentation.lampdeck"))
        let nested = workspace.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "Source".write(
            to: nested.appendingPathComponent("source.md"),
            atomically: true,
            encoding: .utf8
        )

        let snapshots = try WorkspaceTextFileStore.snapshots(
            in: workspace,
            excludingFilenames: ["draft.md"]
        )

        #expect(snapshots.map(\.id) == ["outline.md", "summary.txt"])
        #expect(snapshots.map(\.contents) == ["# Outline", "Summary"])
    }

    @Test func writesOnlySupportedTopLevelDocuments() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outline = workspace.appendingPathComponent("outline.md")
        try WorkspaceTextFileStore.write("# Revised", to: outline, in: workspace)
        #expect(try String(contentsOf: outline, encoding: .utf8) == "# Revised")

        let nested = workspace.appendingPathComponent("context/source.md")
        #expect(throws: (any Error).self) {
            try WorkspaceTextFileStore.write("No", to: nested, in: workspace)
        }

        let deck = workspace.appendingPathComponent("slides.lampdeck")
        #expect(throws: (any Error).self) {
            try WorkspaceTextFileStore.write("No", to: deck, in: workspace)
        }
    }

    @Test func createsSafeUniquelyNamedMarkdownDocuments() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(WorkspaceTextFileStore.normalizedMarkdownFilename("Series Outline") == "Series Outline.md")
        #expect(WorkspaceTextFileStore.normalizedMarkdownFilename("research.markdown") == "research.markdown")
        #expect(WorkspaceTextFileStore.normalizedMarkdownFilename("notes.txt") == nil)
        #expect(WorkspaceTextFileStore.normalizedMarkdownFilename("../notes.md") == nil)
        #expect(WorkspaceTextFileStore.normalizedMarkdownFilename("draft.md") == nil)
        #expect(WorkspaceTextFileStore.normalizedMarkdownFilename("draft.markdown") == nil)
        #expect(WorkspaceTextFileStore.normalizedMarkdownFilename("AGENTS.md") == nil)

        let snapshot = try WorkspaceTextFileStore.createMarkdownDocument(
            named: "Series Outline",
            in: workspace,
            initialContents: "# Series Outline\n"
        )
        #expect(snapshot.id == "Series Outline.md")
        #expect(snapshot.contents == "# Series Outline\n")
        #expect(try String(contentsOf: snapshot.url, encoding: .utf8) == "# Series Outline\n")

        #expect(throws: (any Error).self) {
            try WorkspaceTextFileStore.createMarkdownDocument(
                named: "series outline.MD",
                in: workspace
            )
        }
    }
}
