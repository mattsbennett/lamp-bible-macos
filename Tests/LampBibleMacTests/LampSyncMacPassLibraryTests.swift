import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

/// Installing and removing one file at a time, which is what Design B asks of
/// the Mac. The tests here are the refusals rather than the happy paths: a
/// pass nobody is watching must not be able to delete a person's writing, and
/// a file it does not understand must be reported rather than skipped.
struct LampSyncMacPassLibraryTests {
    private func makeLibrary() throws -> (library: LampLibrary, root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-pass-library-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (LampLibrary(rootURL: root), root, workspace)
    }

    private func passLibrary(
        _ library: LampLibrary,
        workspace: URL
    ) -> LampSyncMacPassLibrary {
        LampSyncMacPassLibrary(library: library, workspace: workspace) { _ in Data() }
    }

    /// The one that matters most. Those collections exist in every library, so
    /// a tombstone naming one is a mistake somewhere else, not an instruction
    /// — and obeying it would delete everything the person has written.
    @Test(arguments: [
        "Notes/notes.lamp",
        "Devotionals/devotionals.lamp",
        "Highlights/esvs-highlights.lamp",
    ])
    func syncRefusesToDeleteAnEditableCollection(path: String) async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: LampSyncMacPassLibrary.PassError.refusedToDeleteACollection(path)) {
            try await passLibrary(library, workspace: workspace).deleteLocally(path)
        }
    }

    /// A tombstone arriving from another device for a module this Mac holds
    /// must remove *that* module. The engine decides to delete; this decides
    /// what. Getting the path-to-identity step wrong would either remove
    /// nothing or, worse, remove something else.
    ///
    /// The library here is empty, so it answers "not installed" — which is
    /// the proof wanted: the removal got as far as naming `wsd_greek`, rather
    /// than failing on the path.
    @Test func atombstonedModulePathNamesTheModuleToRemove() async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try await passLibrary(library, workspace: workspace)
                .deleteLocally("Dictionaries/wsd_greek.lamp")
            Issue.record("an empty library cannot have removed anything")
        } catch {
            let message = error.localizedDescription
            #expect(
                message.contains("wsd_greek"),
                "it must name the module the path points at, not fail on the path: \(message)"
            )
            #expect(!message.contains("does not yet handle"))
        }
    }

    @Test func aDeckAndItsImageAreInstalledBesideTheOthers() async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = workspace.appendingPathComponent("incoming")
        try Data("a deck".utf8).write(to: incoming)
        let pass = passLibrary(library, workspace: workspace)
        let store = LampPresentationDeckStore(rootURL: root)

        try await pass.install("Workspaces/Presentations/sunday.lampdeck", from: incoming)
        try await pass.install("Workspaces/Presentations/Assets/a1b2.jpg", from: incoming)

        #expect(
            try Data(contentsOf: store.decksDirectoryURL.appendingPathComponent("sunday.lampdeck"))
                == Data("a deck".utf8)
        )
        #expect(
            FileManager.default.fileExists(
                atPath: store.assetsDirectoryURL.appendingPathComponent("a1b2.jpg").path
            )
        )
    }

    @Test func installingADeckTwiceReplacesItRatherThanFailing() async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = workspace.appendingPathComponent("first")
        let second = workspace.appendingPathComponent("second")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let pass = passLibrary(library, workspace: workspace)

        try await pass.install("Workspaces/Presentations/sunday.lampdeck", from: first)
        try await pass.install("Workspaces/Presentations/sunday.lampdeck", from: second)

        let installed = LampPresentationDeckStore(rootURL: root)
            .decksDirectoryURL.appendingPathComponent("sunday.lampdeck")
        #expect(try Data(contentsOf: installed) == Data("second".utf8))
    }

    @Test func aDeckDeletedElsewhereIsRemovedAndAMissingOneIsNotAnError() async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = workspace.appendingPathComponent("incoming")
        try Data("a deck".utf8).write(to: incoming)
        let pass = passLibrary(library, workspace: workspace)
        try await pass.install("Workspaces/Presentations/sunday.lampdeck", from: incoming)

        try await pass.deleteLocally("Workspaces/Presentations/sunday.lampdeck")
        #expect(
            !FileManager.default.fileExists(
                atPath: LampPresentationDeckStore(rootURL: root)
                    .decksDirectoryURL.appendingPathComponent("sunday.lampdeck").path
            )
        )
        // Already gone is the outcome the deletion wanted.
        try await pass.deleteLocally("Workspaces/Presentations/sunday.lampdeck")
    }

    /// Installed under the root the reader checks second, which is the only
    /// one a sync writes — so what arrives is what the reader finds.
    @Test func aBooksPictureIsInstalledWhereTheReaderLooks() async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = workspace.appendingPathComponent("incoming")
        try Data("a plate".utf8).write(to: incoming)

        try await passLibrary(library, workspace: workspace)
            .install("BookMedia/atonement/plates/one.jpg", from: incoming)

        let installed = root.appendingPathComponent("Media/Books/atonement/plates/one.jpg")
        #expect(try Data(contentsOf: installed) == Data("a plate".utf8))
        #expect(
            LampSyncLocalFiles.bookMediaRoots(for: "atonement", inLibraryAt: root)[1]
                == root.appendingPathComponent("Media/Books/atonement", isDirectory: true),
            "the install root is the reader's second root"
        )
    }

    /// A path outside the layout, and one whose kind this does not place, are
    /// both reported. A pass that silently skipped them would publish or hold
    /// a library quietly missing a file.
    @Test(arguments: [
        "Workspaces/Presentations/deleted-decks.json",
        "lamp-bible.lampsync",
        "DevotionalMedia/devotionals/writing-1/photo.jpg",
        // The copy the old sync left under notes' former ID. Installed, it
        // would arrive as a second notes module holding old notes.
        "Notes/bible-notes.lamp",
    ])
    func aFileThisDoesNotPlaceIsReported(path: String) async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = workspace.appendingPathComponent("incoming")
        try Data("x".utf8).write(to: incoming)

        await #expect(throws: LampSyncMacPassLibrary.PassError.unsupported(path)) {
            try await passLibrary(library, workspace: workspace).install(path, from: incoming)
        }
    }

    /// The library decides what a file is by its extension, and a pass
    /// downloads to a scratch file that has none. Handed one as it is, every
    /// module import fails with "Choose a file with the .lamp extension" —
    /// which is exactly what the first real pass reported. The name the
    /// library sees must carry the remote path's extension.
    @Test(arguments: [
        "Translations/KJVs.lamp",
        "Notes/notes.lamp",
        "Highlights/esvs-highlights.lamp",
        "Devotionals/devotionals.lamp",
    ])
    func adownloadIsNamedSoTheLibraryWillAcceptIt(path: String) async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        // A scratch file exactly as the pass produces: no extension at all.
        let scratch = workspace.appendingPathComponent("lamp-sync-\(UUID().uuidString)")
        try Data("not a real module".utf8).write(to: scratch)

        // The import fails on the content, as it must — these are not real
        // modules — but never again on the file's name.
        do {
            try await passLibrary(library, workspace: workspace).install(path, from: scratch)
        } catch {
            let message = error.localizedDescription
            #expect(!message.contains(".lamp extension"), "named wrongly: \(message)")
            #expect(!message.contains(".json or .lamp file"), "named wrongly: \(message)")
        }
    }

    @Test func installingAHighlightModuleRemembersWhichSetItIsFor() async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let learned = LampSyncMacPassLibrary.Learned()
        let scratch = workspace.appendingPathComponent("lamp-sync-\(UUID().uuidString)")
        try Data("not a real module".utf8).write(to: scratch)

        // Unreadable content, so nothing is learned — and nothing is claimed.
        try? await LampSyncMacPassLibrary(
            library: library, workspace: workspace, learned: learned
        ) { _ in Data() }.install("Highlights/esvs-highlights.lamp", from: scratch)

        #expect(
            learned.highlightModuleIDsBySet.isEmpty,
            "a set's module ID is only ever read from a module that could be read"
        )
    }

    @Test func theCollectionsArePublishedUnderThePhonesIdentities() {
        // The Mac's own are `personal-notes` and `personal-devotionals`; the
        // adapter rewrites them, and these are what the stem must be.
        #expect(LampSyncMacPassLibrary.remoteNotesModuleID == "notes")
        #expect(LampSyncMacPassLibrary.remoteWritingModuleID == "devotionals")
    }
}
