import Foundation
import Testing
@testable import LampBibleMacSupport

/// Tabs beside "Main Prose" used to read as raw filenames, and only the
/// writing's top-level Markdown companions could be opened at all.
struct WorkspaceDocumentTitleTests {
    @Test(arguments: [
        ("outline.md", "Outline"),
        ("deck-format.md", "Deck Format"),
        ("two-column-slides.json", "Two Column Slides"),
        ("validate_deck.py", "Validate Deck"),
        ("presentation.lampdeck", "Presentation"),
        ("deck/lamp-quotation-layout-spec.md", "Lamp Quotation Layout Spec"),
    ])
    func aFilenameReadsAsAName(file: String, title: String) {
        #expect(WorkspaceDocumentTitle.formatted(file) == title)
    }

    /// A word an author capitalised is theirs, not something to retitle.
    @Test(arguments: ["README.md", "AGENTS.md", "SKILL.md", "DEVOTIONAL_ID"])
    func capitalisedNamesAreLeftAsTyped(file: String) {
        let stem = (file as NSString).deletingPathExtension
        #expect(WorkspaceDocumentTitle.formatted(file) == stem.replacingOccurrences(of: "_", with: " "))
    }

    /// `.mcp.json` means something to the person who put it there; "Mcp"
    /// does not.
    @Test func aDotfileKeepsItsNameExactly() {
        #expect(WorkspaceDocumentTitle.formatted(".mcp.json") == ".mcp.json")
        #expect(WorkspaceDocumentTitle.formatted("deck/.gitignore") == ".gitignore")
    }

    @Test func namesThatWouldReadAlikeShowTheirPathsInstead() {
        let titles = WorkspaceDocumentTitle.titles(for: ["outline.md", "deck/outline.md", "notes.md"])
        #expect(titles["outline.md"] == "outline.md")
        #expect(titles["deck/outline.md"] == "deck/outline.md")
        // Untouched: nothing else formats to "Notes".
        #expect(titles["notes.md"] == "Notes")
    }

    @Test func oneFileKeepsItsPrettyTitle() {
        #expect(WorkspaceDocumentTitle.titles(for: ["outline.md"])["outline.md"] == "Outline")
    }
}

/// Any file inside the workspace can now be opened, at any depth — but only
/// inside it, and only if it is text.
struct WorkspaceFileOpeningTests {
    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lamp-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("deck"), withIntermediateDirectories: true
        )
        return root
    }

    @Test func aFileInASubdirectoryOpens() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("deck/presentation.lampdeck")
        try #"{"slides":[]}"#.write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try WorkspaceTextFileStore.openableSnapshot(at: file, in: workspace)
        #expect(snapshot.contents == #"{"slides":[]}"#)
        #expect(WorkspaceTextFileStore.relativePath(of: file, in: workspace)
            == "deck/presentation.lampdeck")
    }

    /// The listing deliberately leaves these out; that is a reason not to show
    /// them, not a reason to refuse to open them.
    @Test func aFileTheListingLeavesOutStillOpens() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("AGENTS.md")
        try "Instructions".write(to: file, atomically: true, encoding: .utf8)

        let listed = try WorkspaceTextFileStore.snapshots(
            in: workspace, excludingFilenames: ["AGENTS.md"]
        )
        #expect(listed.isEmpty)
        #expect(try WorkspaceTextFileStore.openableSnapshot(at: file, in: workspace).contents
            == "Instructions")
    }

    @Test func aFileOutsideTheWorkspaceIsRefused() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = workspace.deletingLastPathComponent()
            .appendingPathComponent("elsewhere-\(UUID().uuidString).md")
        try "Not yours".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(WorkspaceTextFileStore.relativePath(of: outside, in: workspace) == nil)
        #expect(throws: (any Error).self) {
            try WorkspaceTextFileStore.openableSnapshot(at: outside, in: workspace)
        }
    }

    /// `..` must not be a way out, however the path is spelled.
    @Test func climbingOutWithDotDotIsRefused() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = workspace.deletingLastPathComponent()
            .appendingPathComponent("climb-\(UUID().uuidString).md")
        try "Not yours".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let climbed = workspace
            .appendingPathComponent("deck")
            .appendingPathComponent("..")
            .appendingPathComponent("..")
            .appendingPathComponent(outside.lastPathComponent)
        #expect(WorkspaceTextFileStore.relativePath(of: climbed, in: workspace) == nil)
    }

    @Test func bytesThatAreNotTextAreRefused() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0xFF, 0xFE]).write(to: file)

        #expect(throws: (any Error).self) {
            try WorkspaceTextFileStore.openableSnapshot(at: file, in: workspace)
        }
    }

    @Test func aFileOpenedInASubdirectoryCanBeSavedBack() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("deck/notes.md")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        try WorkspaceTextFileStore.writeOpened("after", to: file, in: workspace)
        #expect(try String(contentsOf: file, encoding: .utf8) == "after")
    }

    @Test func savingOutsideTheWorkspaceIsRefused() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = workspace.deletingLastPathComponent()
            .appendingPathComponent("escape-\(UUID().uuidString).md")
        #expect(throws: (any Error).self) {
            try WorkspaceTextFileStore.writeOpened("x", to: outside, in: workspace)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }
}
