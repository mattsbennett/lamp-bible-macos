import Foundation
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Two Macs syncing one devotional's workspace through a real sync archive.
struct WorkspaceFileDeletionSyncTests {
    // In the past, as real modification times are.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let devotional = "talk-123"

    private struct Macs {
        let root: URL
        let a: URL
        let b: URL

        init(devotional: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-workspace-deletions-\(UUID().uuidString)", isDirectory: true)
            a = root.appendingPathComponent("Mac A", isDirectory: true)
            b = root.appendingPathComponent("Mac B", isDirectory: true)
            for library in [a, b] {
                try FileManager.default.createDirectory(
                    at: library.appendingPathComponent("AgentWorkspaces/Writing/\(devotional)"),
                    withIntermediateDirectories: true
                )
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func sync(from source: URL, to destination: URL) async throws {
            let outgoing = root.appendingPathComponent("outgoing-\(UUID().uuidString)", isDirectory: true)
            try await LampWorkspaceSync.exportPortableWorkspaces(from: source, to: outgoing, installID: "mac")
            let archive = try LampSyncArchive.decode(
                compressedData: LampSyncArchive.create(from: outgoing).compressedData()
            )
            let incoming = root.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
            try archive.extract(to: incoming)
            try await LampWorkspaceSync.importPortableWorkspaces(from: incoming, into: destination)
        }
    }

    private func workspace(_ library: URL) -> URL {
        library.appendingPathComponent("AgentWorkspaces/Writing/\(devotional)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL, at offset: TimeInterval) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(offset)],
            ofItemAtPath: url.path
        )
    }

    private func documents(_ library: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace(library).path)
            .filter { $0.hasSuffix(".md") }
            .sorted()
    }

    private func contextFiles(_ library: URL) async -> [String] {
        let context = workspace(library).appendingPathComponent("context").path
        let all = FileManager.default.enumerator(atPath: context)?.allObjects as? [String] ?? []
        return all.filter { !$0.hasPrefix(".") && $0.contains(".") }.sorted()
    }

    // MARK: - Documents

    /// A document deleted on this Mac is written down for the next pass to
    /// tombstone, under its name in NFC, so the phone deletes its copy too;
    /// one a pass removed, as another device's deletion, is not.
    @Test func aDocumentDeletedHereIsRecordedForEveryDevice() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let decomposed = "Ro\u{308}mer.md"
        try write("outline", to: workspace(macs.a).appendingPathComponent("outline.md"), at: 0)
        try write("notes", to: workspace(macs.a).appendingPathComponent(decomposed), at: 0)
        try write("kept", to: workspace(macs.a).appendingPathComponent("kept.md"), at: 0)
        let outgoing = macs.root.appendingPathComponent("out", isDirectory: true)
        try await LampWorkspaceSync.exportPortableWorkspaces(from: macs.a, to: outgoing, installID: "mac")
        #expect(LampSyncRemovedModules.load(fromLibraryAt: macs.a).removedAt.isEmpty)

        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("outline.md"))
        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent(decomposed))
        // Removed by a pass carrying out another device's deletion.
        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("kept.md"))
        var ledger = WorkspaceFileLedger.load(in: workspace(macs.a))
        ledger.noteSynced(WorkspaceFileLedger.documentKey("kept.md"), modified: nil)
        try ledger.save(in: workspace(macs.a))

        try await LampWorkspaceSync.exportPortableWorkspaces(
            from: macs.a, to: macs.root.appendingPathComponent("out2", isDirectory: true), installID: "mac"
        )
        let recorded = Set(LampSyncRemovedModules.load(fromLibraryAt: macs.a).removedAt.keys)
        #expect(recorded == [
            try LampWritingWorkspaceLayout.documentPath(folder: devotional, name: "outline.md"),
            try LampWritingWorkspaceLayout.documentPath(folder: devotional, name: "R\u{F6}mer.md"),
        ])
    }

    @Test func aDocumentDeletedOnOneMacIsRemovedFromTheOther() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Outline", to: workspace(macs.a).appendingPathComponent("outline.md"), at: 0)
        try write("Notes", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)
        #expect(try await documents(macs.b) == ["notes.md", "outline.md"])

        // An agent or Finder removes it: Lamp only sees that it's gone.
        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))
        // B, which still has it, publishes first.
        try await macs.sync(from: macs.b, to: macs.a)
        #expect(try await documents(macs.a) == ["outline.md"])
        try await macs.sync(from: macs.a, to: macs.b)
        #expect(try await documents(macs.b) == ["outline.md"])
    }

    @Test func aDocumentEditedElsewhereAfterItsDeletionIsKept() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Draft", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)

        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))
        try write("Still wanted", to: workspace(macs.b).appendingPathComponent("notes.md"), at: 60)

        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)
        #expect(try String(contentsOf: workspace(macs.a).appendingPathComponent("notes.md"), encoding: .utf8)
            == "Still wanted")
        #expect(try await documents(macs.b) == ["notes.md"])
    }

    @Test func aMacSyncingForTheFirstTimeSinceUpgradingCannotUndoADeletion() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Notes", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try write("Notes", to: workspace(macs.b).appendingPathComponent("notes.md"), at: 0)
        // A already tracks the file; B has never synced with this version.
        try await macs.sync(from: macs.b, to: macs.a)

        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))
        try await macs.sync(from: macs.b, to: macs.a)
        try await macs.sync(from: macs.a, to: macs.b)

        #expect(try await documents(macs.a).isEmpty)
        #expect(try await documents(macs.b).isEmpty)
    }

    // MARK: - Context

    @Test func aRemovedContextFileIsRemovedFromTheOtherMac() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let context = workspace(macs.a).appendingPathComponent("context")
        try write("Commentary", to: context.appendingPathComponent("sources/commentary.txt"), at: 0)
        try write("Map", to: context.appendingPathComponent("map.txt"), at: 0)
        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)
        #expect(await contextFiles(macs.b) == ["map.txt", "sources/commentary.txt"])

        // Deleted through the act. Taking it off the disk is no longer a
        // deletion — see `aSourceThatMerelyGoesMissingIsNotDeletedEverywhere`.
        // Through the app's own Remove, which is the act that records it.
        try await WorkspaceContextFileStore.removeContextItem(
            at: context.appendingPathComponent("sources"),
            from: workspace(macs.a),
            libraryRootURL: macs.a
        )
        try await macs.sync(from: macs.b, to: macs.a)
        #expect(await contextFiles(macs.a) == ["map.txt"])
        try await macs.sync(from: macs.a, to: macs.b)
        #expect(await contextFiles(macs.b) == ["map.txt"])
    }

    /// Removing a source queues it for the **server**, so the store stops
    /// holding the bytes.
    ///
    /// Until a source became a deletable kind its removal travelled only
    /// inside the workspace tree: every device dropped its copy and the store
    /// kept the file for ever. On the measured library that was 355 MB of
    /// PDFs nothing could reclaim (`decisions/0019`).
    @Test func removingAsourceQueuesItForTheServer() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let context = workspace(macs.a).appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("sources/history.pdf"), at: 0)
        try await macs.sync(from: macs.a, to: macs.b)

        try await WorkspaceContextFileStore.removeContextItem(
            at: context.appendingPathComponent("sources"),
            from: workspace(macs.a),
            libraryRootURL: macs.a
        )

        let queued = LampSyncRemovedModules.load(fromLibraryAt: macs.a).removedAt.keys
        let expected = try LampWritingWorkspaceLayout.contextPath(
            folder: workspace(macs.a).lastPathComponent,
            relativePath: "sources/history.pdf"
        )
        #expect(
            queued.contains(expected),
            "the file, by its published path, so the pass tombstones and reaps it"
        )
        #expect(
            !queued.contains { $0.hasSuffix("/Context/sources") },
            "the folder is not a member and nothing on the server is named that"
        )
    }

    /// A deletion arriving from another device removes the local copy and
    /// prunes the shared object, and is content with the file being absent —
    /// this Mac may have offloaded it.
    @Test func adeletionFromElsewhereToleratesAnOffloadedSource() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let relative = "sources/history.pdf"

        try await WorkspaceContextFileStore.removeDeletedSource(
            relativePath: relative,
            in: workspace(macs.b),
            libraryRootURL: macs.b
        )

        #expect(await contextFiles(macs.b).isEmpty, "nothing to remove, and no complaint")
    }

    /// A source that merely goes missing is **not** deleted everywhere.
    ///
    /// Absence says nothing about intent: a file may be gone because the
    /// reader removed it in Finder, because this Mac offloaded it to free
    /// space, or because something in the workspace tidied up. Reading any of
    /// those as "delete it from every device" is how an 86 MB source nobody
    /// meant to touch disappears — the mistake `decisions/0016` and `0017`
    /// were each written about. The other Mac keeps its copy, and this one
    /// withholds the member rather than refetching it.
    @Test func aSourceThatMerelyGoesMissingIsNotDeletedEverywhere() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let context = workspace(macs.a).appendingPathComponent("context")
        try write("Map", to: context.appendingPathComponent("map.txt"), at: 0)
        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)
        try #require(await contextFiles(macs.b) == ["map.txt"])

        try FileManager.default.removeItem(at: context.appendingPathComponent("map.txt"))
        try await macs.sync(from: macs.a, to: macs.b)

        #expect(
            await contextFiles(macs.b) == ["map.txt"],
            "the other Mac keeps a source this one merely stopped holding"
        )
    }

    @Test func aContextFileAddedAgainAfterRemovalStays() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let contextA = workspace(macs.a).appendingPathComponent("context")
        try write("Map", to: contextA.appendingPathComponent("map.txt"), at: 0)
        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)

        try await WorkspaceContextFileStore.removeContextItem(
            at: contextA.appendingPathComponent("map.txt"),
            from: workspace(macs.a),
            libraryRootURL: macs.a
        )
        try await macs.sync(from: macs.a, to: macs.b)
        #expect(await contextFiles(macs.b).isEmpty)

        // The same file, added again: still carrying its original, older date.
        try write("Map", to: workspace(macs.b).appendingPathComponent("context/map.txt"), at: 0)
        try await macs.sync(from: macs.b, to: macs.a)
        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)
        #expect(await contextFiles(macs.a) == ["map.txt"])
        #expect(await contextFiles(macs.b) == ["map.txt"])
    }

    // MARK: - Format

    @Test func deletionsTravelBesideTheWorkspaceRatherThanAsAFile() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Notes", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try await macs.sync(from: macs.a, to: macs.b)
        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))

        let outgoing = macs.root.appendingPathComponent("outgoing", isDirectory: true)
        try await LampWorkspaceSync.exportPortableWorkspaces(from: macs.a, to: outgoing, installID: "mac")
        let paths = try LampSyncArchive.create(from: outgoing).entries.map(\.path)
        #expect(paths.contains("Workspaces/Devotionals/\(devotional)/DeletedFiles.json"))
        // Earlier versions import only Documents and Context as files.
        #expect(!paths.contains { $0.contains("/Documents/") || $0.contains("/Context/") })
    }
}
