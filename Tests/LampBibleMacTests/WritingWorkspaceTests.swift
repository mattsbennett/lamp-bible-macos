import Foundation
import Testing
@testable import LampBibleMacSupport

/// Finding a writing's workspace from its identifier, which is how a writing
/// tool reaches one: by identifier, never by a path an outside app chose.
struct WritingWorkspaceTests {
    private let libraryRoot = URL(fileURLWithPath: "/Users/someone/Lamp/Library")

    /// The folder name is a stored format in all but name: every workspace on
    /// every device already has one. If this value ever changes, the app stops
    /// finding workspaces it made yesterday — and it would find nothing rather
    /// than fail, so nothing else would notice.
    ///
    /// The expected names were computed from the algorithm independently —
    /// FNV-1a over the identifier's UTF-8, basis 14695981039346656037, prime
    /// 1099511628211 — and not read out of this function's own output, so they
    /// would catch the function changing rather than agree with it.
    ///
    /// These are not values to update when they disagree. A disagreement means
    /// the derivation has moved and every existing workspace has been
    /// orphaned.
    @Test func aknownIdentifierKeepsItsFolderName() {
        #expect(
            LampWritingWorkspace.directoryName(for: "7B4E2A10-9C3F-4D21-8A56-0E1F2C3D4B5A")
                == "7B4E2A10-9C3F-4D21-8A56-0E1F2C3D4B5A-e1288be9a6ffbc1d"
        )
        #expect(LampWritingWorkspace.directoryName(for: "abc") == "abc-e71fa2190541574b")
        #expect(LampWritingWorkspace.directoryName(for: "///") == "devotional-eed41417e7153e64")
    }

    @Test func thepathIsUnderTheLibrarysAgentWorkspaces() {
        let url = LampWritingWorkspace.url(libraryRootURL: libraryRoot, writingID: "abc")

        #expect(url.deletingLastPathComponent().path
            == "/Users/someone/Lamp/Library/AgentWorkspaces/Devotionals")
        #expect(url.lastPathComponent == LampWritingWorkspace.directoryName(for: "abc"))
    }

    /// An identifier is not a path, and nothing in it can become one: every
    /// character that is not a letter, digit, hyphen or underscore is replaced,
    /// so a separator or a parent reference cannot survive into the name.
    @Test func anidentifierCannotClimbOutOfTheWorkspacesFolder() {
        for hostile in [
            "../../../../etc/passwd",
            "/etc/passwd",
            "..",
            "a/b/c",
            "~/Library",
        ] {
            let name = LampWritingWorkspace.directoryName(for: hostile)
            #expect(!name.contains("/"), "\(hostile) kept a separator")
            #expect(!name.contains(".."), "\(hostile) kept a parent reference")

            let url = LampWritingWorkspace.url(libraryRootURL: libraryRoot, writingID: hostile)
            #expect(
                url.standardizedFileURL.path.hasPrefix(
                    "/Users/someone/Lamp/Library/AgentWorkspaces/Devotionals/"
                ),
                "\(hostile) escaped the workspaces folder"
            )
        }
    }

    /// Two writings must never share a folder, however alike their identifiers
    /// read once the unusable characters are replaced.
    @Test func identifiersThatReadAlikeStillGetTheirOwnFolder() {
        let first = LampWritingWorkspace.directoryName(for: "a/b")
        let second = LampWritingWorkspace.directoryName(for: "a:b")

        #expect(first != second, "the hash is what keeps these apart")
        #expect(first.hasPrefix("a_b-"))
        #expect(second.hasPrefix("a_b-"))
    }

    @Test func anidentifierWithNothingUsableStillNamesAFolder() {
        let name = LampWritingWorkspace.directoryName(for: "///")

        #expect(name.hasPrefix("devotional-"))
        #expect(name != "devotional-")
    }

    // MARK: - Reading one

    @Test func awritingWithNoWorkspaceHasNone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-writing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            LampWritingWorkspace.exists(libraryRootURL: root, writingID: "never-opened") == false
        )
    }

    @Test func thedraftAndItsContextAreReadFromTheWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-writing-\(UUID().uuidString)", isDirectory: true)
        let workspace = LampWritingWorkspace.url(libraryRootURL: root, writingID: "living-hope")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Living Hope\n\nIt asks that we hold to it.\n".utf8).write(
            to: workspace.appendingPathComponent(LampWritingWorkspace.draftFilename)
        )

        #expect(LampWritingWorkspace.exists(libraryRootURL: root, writingID: "living-hope"))
        #expect(
            try LampWritingWorkspace.readDraft(libraryRootURL: root, writingID: "living-hope")
                .contains("hold to it")
        )
        // A workspace without a context document is still usable.
        #expect(
            LampWritingWorkspace.readContext(libraryRootURL: root, writingID: "living-hope") == nil
        )

        try Data("Audience: the Sunday class.\n".utf8).write(
            to: workspace.appendingPathComponent(LampWritingWorkspace.contextFilename)
        )
        #expect(
            LampWritingWorkspace.readContext(libraryRootURL: root, writingID: "living-hope")?
                .contains("Sunday class") == true
        )
    }
}
