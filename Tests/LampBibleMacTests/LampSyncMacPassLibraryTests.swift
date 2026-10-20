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

    /// A path outside the layout, and one whose kind this does not place, are
    /// both reported. A pass that silently skipped them would publish or hold
    /// a library quietly missing a file.
    @Test(arguments: [
        "Workspaces/Presentations/deleted-decks.json",
        "lamp-bible.lampsync",
        "DevotionalMedia/devotionals/writing-1/photo.jpg",
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

    @Test func theCollectionsArePublishedUnderThePhonesIdentities() {
        // The Mac's own are `personal-notes` and `personal-devotionals`; the
        // adapter rewrites them, and these are what the stem must be.
        #expect(LampSyncMacPassLibrary.remoteNotesModuleID == "notes")
        #expect(LampSyncMacPassLibrary.remoteWritingModuleID == "devotionals")
    }
}
