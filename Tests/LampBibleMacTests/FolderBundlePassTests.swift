import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// A whole pass over a real folder, through core's directory store rather
/// than a double. Everything else holds the pass against a fake server with
/// strong ETags; this holds it against the provider where a revision is the
/// digest of the bytes and every write is coordinated — which is where the
/// two could disagree without either side being wrong on its own.
struct FolderBundlePassTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-folder-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func localFile(_ contents: String, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func gathered(_ files: [LampSyncLocalFile]) -> LampSyncBundlePass.Gathered {
        var gathered = LampSyncBundlePass.Gathered()
        gathered.local = files
        return gathered
    }

    private func local(_ path: String, _ url: URL, _ contents: String) -> LampSyncLocalFile {
        LampSyncLocalFile(
            path: path,
            kind: LampSyncFolderLayout.kind(of: path) ?? .module(.translations),
            url: url,
            digest: LampSyncContentRevision.digest(for: Data(contents.utf8))
        )
    }

    @Test func afirstPassOverAFolderClaimsItAndPublishesTheLibrary() async throws {
        let server = try makeFolder()
        let workspace = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: server)
            try? FileManager.default.removeItem(at: workspace)
        }
        let module = try localFile("a translation", named: "kjv.lamp", in: workspace)
        var records = LampSyncFileRecords()
        let source = LampSyncFileRecords.folderSource(server)

        let outcome = try await LampSyncBundlePass(
            store: LampSyncDirectoryStore(root: server),
            library: NoopPassLibrary(),
            source: source
        ).run(
            gathering: { gathered([local("Translations/KJVs.lamp", module, "a translation")]) },
            records: &records
        )

        #expect(outcome.uploaded == ["Translations/KJVs.lamp"])
        #expect(outcome.failures.isEmpty)
        #expect(
            try Data(contentsOf: server.appendingPathComponent("Translations/KJVs.lamp"))
                == Data("a translation".utf8)
        )
        let bundle = try LampSyncSettingsBundle.decode(
            try Data(contentsOf: server.appendingPathComponent(LampSyncFolderLayout.bundlePath))
        )
        #expect(bundle.manifest.members.map(\.path) == ["Translations/KJVs.lamp"])
        // A digest revision, quoted like a strong ETag so every check made of
        // revisions elsewhere holds unchanged.
        #expect(bundle.manifest.entry(at: "Translations/KJVs.lamp")?.revision?.hasPrefix("\"") == true)
    }

    /// The point of the whole design: a second pass over an unchanged library
    /// writes nothing. On a folder that also means it reads no file body,
    /// since a member's revision comes from the manifest rather than from
    /// digesting what is there.
    @Test func asecondPassOverAnUnchangedFolderWritesNothing() async throws {
        let server = try makeFolder()
        let workspace = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: server)
            try? FileManager.default.removeItem(at: workspace)
        }
        let module = try localFile("a translation", named: "kjv.lamp", in: workspace)
        var records = LampSyncFileRecords()
        let source = LampSyncFileRecords.folderSource(server)
        let store = LampSyncDirectoryStore(root: server)

        func pass() async throws -> LampSyncBundlePass.Outcome {
            try await LampSyncBundlePass(
                store: store, library: NoopPassLibrary(), source: source
            ).run(
                gathering: { gathered([local("Translations/KJVs.lamp", module, "a translation")]) },
                records: &records
            )
        }

        _ = try await pass()
        let published = server.appendingPathComponent("Translations/KJVs.lamp")
        let bundlePath = server.appendingPathComponent(LampSyncFolderLayout.bundlePath)
        let moduleWritten = try modified(published)
        let bundleWritten = try modified(bundlePath)

        let second = try await pass()

        #expect(second.uploaded.isEmpty)
        #expect(second.installed.isEmpty)
        #expect(second.failures.isEmpty)
        #expect(try modified(published) == moduleWritten, "the module was not rewritten")
        #expect(try modified(bundlePath) == bundleWritten, "the bundle was not rewritten")
    }

    /// An edit here reaches the folder, and the manifest follows it.
    @Test func anEditedFileIsRepublishedUnderItsNewRevision() async throws {
        let server = try makeFolder()
        let workspace = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: server)
            try? FileManager.default.removeItem(at: workspace)
        }
        var records = LampSyncFileRecords()
        let source = LampSyncFileRecords.folderSource(server)
        let store = LampSyncDirectoryStore(root: server)

        let notes = try localFile("my notes", named: "notes.lamp", in: workspace)
        _ = try await LampSyncBundlePass(
            store: store, library: NoopPassLibrary(), source: source
        ).run(
            gathering: { self.gathered([self.local("Notes/notes.lamp", notes, "my notes")]) },
            records: &records
        )
        let first = try LampSyncSettingsBundle.decode(
            try Data(contentsOf: server.appendingPathComponent(LampSyncFolderLayout.bundlePath))
        ).manifest.entry(at: "Notes/notes.lamp")?.revision

        try Data("my notes, and one more".utf8).write(to: notes)
        let outcome = try await LampSyncBundlePass(
            store: store, library: NoopPassLibrary(), source: source
        ).run(
            gathering: {
                self.gathered([self.local("Notes/notes.lamp", notes, "my notes, and one more")])
            },
            records: &records
        )

        #expect(outcome.uploaded == ["Notes/notes.lamp"])
        #expect(
            try Data(contentsOf: server.appendingPathComponent("Notes/notes.lamp"))
                == Data("my notes, and one more".utf8)
        )
        let second = try LampSyncSettingsBundle.decode(
            try Data(contentsOf: server.appendingPathComponent(LampSyncFolderLayout.bundlePath))
        ).manifest.entry(at: "Notes/notes.lamp")?.revision
        #expect(first != nil)
        #expect(second != first, "the manifest follows the bytes")
    }

    private func modified(_ url: URL) throws -> Date {
        try #require(
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
    }
}

/// A library that installs nothing, for a pass whose point is the store.
private struct NoopPassLibrary: LampSyncPassLibrary {
    func install(_ path: String, from url: URL) async throws {}
    func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL] { [:] }
    func deleteLocally(_ path: String) async throws {}
}
