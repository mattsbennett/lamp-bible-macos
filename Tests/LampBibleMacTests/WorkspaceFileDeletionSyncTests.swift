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

    // MARK: - Offloading

    /// A source is not offloaded unless the server has it.
    ///
    /// Offloading deletes the only local copy, so this is the rule the whole
    /// feature rests on: without a record of a completed upload, "free up
    /// space" would be "lose the source".
    @Test func refusesToOffloadAsourceTheServerHasNotTaken() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let context = workspace(macs.a).appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)

        await #expect(throws: WorkspaceContextFileStore.OffloadError.self) {
            try await WorkspaceContextFileStore.offloadSource(
                relativePath: "history.pdf", in: workspace(macs.a), libraryRootURL: macs.a,
                source: "webdav:example", seen: [:]
            )
        }
        #expect(
            await contextFiles(macs.a) == ["history.pdf"],
            "and the file is still here"
        )
    }

    /// Offloaded with the server's copy recorded: the file goes, the note
    /// stays, and asking for it back clears the note so a pass fetches it.
    @Test func offloadsAsourceTheServerHolds() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)

        // As a completed upload leaves it.
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: context.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        try await WorkspaceContextFileStore.offloadSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: [path: "\"r1\""]
        )

        #expect(await contextFiles(macs.a).isEmpty, "the space is back")
        #expect(
            await LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(path),
            "and the pass withholds it rather than fetching it"
        )

        try await WorkspaceContextFileStore.fetchSource(
            relativePath: "history.pdf", in: workspaceURL
        )
        #expect(
            await !LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(path),
            "asked for, it is no longer withheld, so the next pass brings it"
        )
    }

    /// The unattended sweep's batch: the records are read once, every note is
    /// written before any file goes, and the two checks the pane does not make
    /// are made here.
    @Test func offloadsAbatchAgainstTheCurrentServerAndTheUploadedBytes() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        for name in ["one.pdf", "two.pdf", "stale.pdf", "elsewhere.pdf"] {
            try write(name, to: context.appendingPathComponent(name), at: 0)
        }
        func path(_ name: String) throws -> String {
            try LampWritingWorkspaceLayout.contextPath(
                folder: workspaceURL.lastPathComponent, relativePath: name
            )
        }
        func digest(_ name: String) throws -> String {
            try LampSyncContentRevision.digest(
                forFileAt: context.appendingPathComponent(name)
            )
        }

        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        let other = LampSyncFileRecords.webDAVSource(URL(string: "https://old.example.com/s/")!)
        var records = LampSyncFileRecords()
        var confirmations: [String: String] = [:]
        for name in ["one.pdf", "two.pdf"] {
            records.recordUpload(
                try path(name), in: source, digest: try digest(name), revision: "\"r1\""
            )
            confirmations[try path(name)] = "\"r1\""
        }
        // Uploaded, then changed on disk since: the digest recorded is not the
        // digest of what is here now.
        records.recordUpload(
            try path("stale.pdf"), in: source, digest: "something-else", revision: "\"r1\""
        )
        confirmations[try path("stale.pdf")] = "\"r1\""
        records.confirmRecorded(confirmations, in: source)
        // Confirmed, but against a server this Mac no longer syncs with.
        records.recordUpload(
            try path("elsewhere.pdf"), in: other,
            digest: try digest("elsewhere.pdf"), revision: "\"r1\""
        )
        records.confirmRecorded([try path("elsewhere.pdf"): "\"r1\""], in: other)
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["one.pdf", "two.pdf", "stale.pdf", "elsewhere.pdf"],
            in: workspaceURL, libraryRootURL: macs.a, source: source, seen: nil
        )

        #expect(result.offloaded == ["one.pdf", "two.pdf"])
        #expect(
            result.skipped["stale.pdf"] == .changedSinceUpload,
            """
            A confirmed revision says an upload completed, not that nothing has \
            happened since. The sweep runs with nobody watching, so it checks \
            the bytes it is about to delete are the bytes that went up.
            """
        )
        #expect(
            result.skipped["elsewhere.pdf"] == .notOnTheServer,
            """
            `mayOffload` accepts a confirmation from any server this Mac has \
            ever synced with; after a change of server that would delete the \
            only copy of a file the new one never took.
            """
        )
        #expect(
            await contextFiles(macs.a).sorted() == ["elsewhere.pdf", "stale.pdf"],
            "and the two it would not take are still here"
        )
        let withheld = await LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a)
        #expect(withheld.contains(try path("one.pdf")))
        #expect(withheld.contains(try path("two.pdf")))
        #expect(
            !withheld.contains(try path("stale.pdf")),
            "nothing is noted for a source that stayed, or the pass would withhold a file this Mac holds"
        )
    }

    /// A file that will not go leaves no note behind.
    ///
    /// A note saying "offloaded" on a file that is still here is a lie in the
    /// one direction that shows: the pass would withhold a member this Mac
    /// holds, and the pane would offer Download for a file on disk.
    @Test func asourceThatWillNotGoIsNotMarkedOffloaded() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let folder = context.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("stuck", to: folder.appendingPathComponent("stuck.pdf"), at: 0)

        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "locked/stuck.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: folder.appendingPathComponent("stuck.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        // Unlinking needs write permission on the containing folder, not the file.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: folder.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder.path
            )
        }

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["locked/stuck.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: nil
        )

        #expect(result.offloaded.isEmpty)
        #expect(result.skipped["locked/stuck.pdf"] == .couldNotRemove)
        #expect(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("stuck.pdf").path
            ),
            "the file is still here"
        )
        #expect(
            await !LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(path),
            "so it must not be withheld from the pass"
        )
    }

    /// A source put back at an offloaded path is this Mac's again.
    ///
    /// Withholding on the note alone left it withheld for ever and never
    /// uploaded: nothing on the attaching side knew a note was there to
    /// clear. The note says what this Mac let go of; a file at that path says
    /// it has one again, however it got there.
    @Test func asourceAttachedWhereOneWasOffloadedIsNoLongerWithheld() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("first", to: context.appendingPathComponent("history.pdf"), at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: context.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        try await WorkspaceContextFileStore.offloadSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: [path: "\"r1\""]
        )
        #expect(await LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(path))

        // The reader attaches something new under the same name.
        try write("second", to: context.appendingPathComponent("history.pdf"), at: 1)
        #expect(
            await !LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(path),
            """
            Otherwise the pane shows it as local while the pass withholds it, \
            and the replacement never reaches the server or the phone.
            """
        )
    }

    /// A nested source is offloaded and fetched by its path, not its name.
    @Test func anestedSourceIsWithheldUnderItsOwnPath() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let notes = context.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try write("nested", to: notes.appendingPathComponent("history.pdf"), at: 0)

        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "notes/history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: notes.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["notes/history.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: nil
        )
        #expect(result.offloaded == ["notes/history.pdf"])
        #expect(
            await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL)
                == ["notes/history.pdf"],
            """
            The ledger holds the path under the context directory. A row that \
            actioned this by its last component would clear a note on a \
            top-level “history.pdf” that does not exist, and leave this one \
            withheld.
            """
        )

        try await WorkspaceContextFileStore.fetchSource(
            relativePath: "notes/history.pdf", in: workspaceURL
        )
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL).isEmpty)
    }

    /// Remove works on a source this Mac is not holding.
    ///
    /// `removeContextItem` needs a file on disk and an entry directly under
    /// the context directory; an offloaded row has neither, so Remove on one
    /// returned early and did nothing at all — no row cleared, no tombstone
    /// queued, the server keeping the bytes for ever.
    @Test func removingAsourceThatIsOnlyOnTheServerStillDeletesItEverywhere() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let notes = context.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try write("nested", to: notes.appendingPathComponent("history.pdf"), at: 0)
        let member = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "notes/history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            member, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: notes.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([member: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        _ = try await WorkspaceContextFileStore.offloadSources(
            ["notes/history.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: nil
        )

        try await WorkspaceContextFileStore.removeOffloadedSource(
            relativePath: "notes/history.pdf", in: workspaceURL, libraryRootURL: macs.a
        )

        let removed = await LampSyncRemovedModules.load(fromLibraryAt: macs.a)
        #expect(
            removed.removedAt[member] != nil,
            "queued for the server, which is the whole point of Remove (decisions/0019)"
        )
        #expect(
            await !LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(member),
            """
            and no longer withheld: a path being tombstoned must not also be \
            one the pane offers Download for.
            """
        )
    }

    /// Removing an offloaded source never removes a tree.
    ///
    /// The Context listing is shallow and drawn from the ledger as well as
    /// the disk, so a row can name a path a *folder* has since taken. The
    /// removal unlinks recursively, so without a regular-file check a click
    /// on that row would erase the folder and everything unrelated in it.
    @Test func removingAnOffloadedSourceWillNotDeleteAfolderAtItsPath() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let taken = context.appendingPathComponent("history.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try write("unrelated", to: taken.appendingPathComponent("something else.md"), at: 0)

        try await WorkspaceContextFileStore.removeOffloadedSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a
        )

        #expect(
            FileManager.default.fileExists(
                atPath: taken.appendingPathComponent("something else.md").path
            ),
            "the folder that took the path, and its contents, are untouched"
        )
    }

    /// The batch deletes the file it checked, not whatever is at the path.
    ///
    /// Every candidate is hashed before any is deleted, so a batch leaves a
    /// window in which Finder, a restore, or an agent running in this very
    /// workspace can put different bytes at an already-checked path — and
    /// those bytes were never on the server. Here the replacement lands while
    /// the batch is deleting the file before it.
    @Test func abatchWillNotDeleteBytesItDidNotVerify() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        for name in ["a.pdf", "b.pdf"] {
            try write(name, to: context.appendingPathComponent(name), at: 0)
            let path = try LampWritingWorkspaceLayout.contextPath(
                folder: workspaceURL.lastPathComponent, relativePath: name
            )
            records.recordUpload(
                path, in: source,
                digest: try LampSyncContentRevision.digest(
                    forFileAt: context.appendingPathComponent(name)
                ),
                revision: "\"r1\""
            )
            records.confirmRecorded([path: "\"r1\""], in: source)
        }
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["a.pdf", "b.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: nil,
            fileManager: ReplacingFileManager(
                whenRemoving: context.appendingPathComponent("a.pdf"),
                replace: context.appendingPathComponent("b.pdf"),
                with: "different bytes entirely"
            )
        )

        #expect(result.offloaded == ["a.pdf"], "the one it verified and nothing changed")
        #expect(
            result.skipped["b.pdf"] == .changedSinceUpload,
            "and the one that changed under it is left alone"
        )
        #expect(
            try String(
                contentsOf: context.appendingPathComponent("b.pdf"), encoding: .utf8
            ) == "different bytes entirely",
            "the bytes that arrived in the window are still here"
        )
        let member = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "b.pdf"
        )
        #expect(
            await !LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(member),
            "and it is not withheld, so the new bytes go up on the next pass"
        )
    }

    /// A source asked back stays on the list until it arrives.
    ///
    /// Clearing the note is what lets a pass fetch it, and that also took it
    /// off the list — so a download that failed, or whose server was briefly
    /// unreachable, left no row, no reason and nothing to press again.
    @Test func asourceAskedBackIsStillListedUntilItArrives() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: context.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        try await WorkspaceContextFileStore.offloadSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: [path: "\"r1\""]
        )

        try await WorkspaceContextFileStore.fetchSource(
            relativePath: "history.pdf", in: workspaceURL
        )
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL).isEmpty)
        #expect(
            await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL) == ["history.pdf"],
            "still something to show, and something to press again"
        )

        // The pass brings it home.
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 1)
        #expect(
            await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL).isEmpty,
            "and once it is here it is simply a source again"
        )

        // Offloaded a second time: one row, not two.
        try await WorkspaceContextFileStore.offloadSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: [path: "\"r1\""]
        )
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["history.pdf"])
        #expect(
            await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL).isEmpty,
            """
            A source that has been asked back once and let go of again is on \
            the server, not on its way here — otherwise the pane draws it \
            twice, once as each.
            """
        )
    }

    /// Another device's removal of a source neither Mac holds is noticed.
    ///
    /// There is no local file for the plan to delete, so nothing carries the
    /// deletion out here: without this the note survives, the row keeps
    /// saying “On the server”, and a later attachment at that path is
    /// withheld against a member that no longer exists.
    @Test func anOffloadIsForgottenWhenTheServerNoLongerCountsItAmember() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: context.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        try await WorkspaceContextFileStore.offloadSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: [path: "\"r1\""]
        )

        // A manifest that still counts it changes nothing.
        await LampWorkspaceSync.forgetOffloadsNoLongerOnTheServer(
            inLibraryAt: macs.a, members: [path]
        )
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["history.pdf"])

        // One that does not is the other Mac's removal arriving.
        let forgotten = await LampWorkspaceSync.forgetOffloadsNoLongerOnTheServer(
            inLibraryAt: macs.a, members: ["something/else"]
        )
        #expect(forgotten == [path])
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL).isEmpty)
        #expect(
            await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL).isEmpty,
            "and it is not left waiting for something that is never coming"
        )
    }

    /// Opening the writing part way through a batch stops the rest of it.
    @Test func abatchStopsWhenTheWritingIsOpened() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        for name in ["a.pdf", "b.pdf"] {
            try write(name, to: context.appendingPathComponent(name), at: 0)
            let path = try LampWritingWorkspaceLayout.contextPath(
                folder: workspaceURL.lastPathComponent, relativePath: name
            )
            records.recordUpload(
                path, in: source,
                digest: try LampSyncContentRevision.digest(
                    forFileAt: context.appendingPathComponent(name)
                ),
                revision: "\"r1\""
            )
            records.confirmRecorded([path: "\"r1\""], in: source)
        }
        try records.save(toLibraryAt: macs.a)

        let opened = OpenedPartWay()
        let result = try await WorkspaceContextFileStore.offloadSources(
            ["a.pdf", "b.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: nil,
            while: { await opened.stillClosed() }
        )
        #expect(result.offloaded == ["a.pdf"])
        #expect(result.skipped["b.pdf"] == .nowHeld)
        #expect(
            FileManager.default.fileExists(atPath: context.appendingPathComponent("b.pdf").path),
            "the rest of the workspace's sources stay where the reader can see them"
        )
    }

    /// Removing a folder takes the sources under it that are not here.
    ///
    /// The walk that lists what is going enumerates files on disk, and an
    /// offloaded one has none — so without this they stay on the server for
    /// ever with nothing here left to name them. The first attempt at this
    /// asked `offloadedMembers(under:)` for relative paths; it answers in
    /// published ones and filters anything that is not shaped like one, so it
    /// returned nothing and the fix did nothing. There was no test.
    @Test func removingAfolderTakesItsOffloadedChildrenToo() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let notes = context.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try write("kept", to: notes.appendingPathComponent("stays.pdf"), at: 0)
        try write("gone", to: notes.appendingPathComponent("offloaded.pdf"), at: 0)

        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        let offloadedPath = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "notes/offloaded.pdf"
        )
        var records = LampSyncFileRecords()
        records.recordUpload(
            offloadedPath, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: notes.appendingPathComponent("offloaded.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([offloadedPath: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        _ = try await WorkspaceContextFileStore.offloadSources(
            ["notes/offloaded.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: nil
        )

        try await WorkspaceContextFileStore.removeContextItem(
            at: notes, from: workspaceURL, libraryRootURL: macs.a
        )

        let removed = await LampSyncRemovedModules.load(fromLibraryAt: macs.a)
        #expect(
            removed.removedAt[offloadedPath] != nil,
            "the child that was only on the server is queued for the server too"
        )
        let staysPath = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "notes/stays.pdf"
        )
        #expect(removed.removedAt[staysPath] != nil, "and so is the one that was here")
        #expect(
            await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL).isEmpty,
            "and nothing is left withheld for a member being deleted"
        )
    }

    /// Remove works on a row that is waiting for a download.
    ///
    /// It has no local file either, so the ordinary removal returns without
    /// queuing anything — the reader confirms “remove from every device” and
    /// the source downloads a minute later.
    @Test func removingAsourceThatIsOnItsWayStillDeletesItEverywhere() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: context.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        try await WorkspaceContextFileStore.offloadSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: [path: "\"r1\""]
        )
        try await WorkspaceContextFileStore.fetchSource(
            relativePath: "history.pdf", in: workspaceURL
        )
        #expect(await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL) == ["history.pdf"])

        try await WorkspaceContextFileStore.removeOffloadedSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a
        )

        let removed = await LampSyncRemovedModules.load(fromLibraryAt: macs.a)
        #expect(removed.removedAt[path] != nil)
        #expect(
            await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL).isEmpty,
            "and it is no longer on its way"
        )
    }

    /// Another device's deletion leaves no row waiting for it.
    ///
    /// Asking for a source back records the ask, so that a failed download
    /// still has a row and something to press. Carrying out somebody else's
    /// deletion goes through the same note — and recording an ask there would
    /// leave the pane saying "Coming back" for something that is never
    /// coming.
    @Test func adeletionFromElsewhereLeavesNothingComingBack() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source,
            digest: try LampSyncContentRevision.digest(
                forFileAt: context.appendingPathComponent("history.pdf")
            ),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        try await WorkspaceContextFileStore.offloadSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: [path: "\"r1\""]
        )

        try await WorkspaceContextFileStore.removeDeletedSource(
            relativePath: "history.pdf", in: workspaceURL, libraryRootURL: macs.a
        )

        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL).isEmpty)
        #expect(
            await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL).isEmpty,
            "and nothing is drawn as on its way"
        )
    }

    /// Two sources that are the same file are both offloaded.
    ///
    /// A source is a hard link into the library's object store, so a
    /// workspace holding the same file twice holds two links to one inode.
    /// Unlinking either moves that inode's change time, which made the
    /// sibling look replaced — and the shared bytes then stayed on disk for
    /// ever while the pane said they had gone.
    @Test func twoCopiesOfOneFileBothGo() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("identical", to: context.appendingPathComponent("one.pdf"), at: 0)
        try FileManager.default.linkItem(
            at: context.appendingPathComponent("one.pdf"),
            to: context.appendingPathComponent("two.pdf")
        )

        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        for name in ["one.pdf", "two.pdf"] {
            let path = try LampWritingWorkspaceLayout.contextPath(
                folder: workspaceURL.lastPathComponent, relativePath: name
            )
            records.recordUpload(
                path, in: source,
                digest: try LampSyncContentRevision.digest(
                    forFileAt: context.appendingPathComponent(name)
                ),
                revision: "\"r1\""
            )
            records.confirmRecorded([path: "\"r1\""], in: source)
        }
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["one.pdf", "two.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            source: source, seen: nil
        )
        #expect(
            result.offloaded.sorted() == ["one.pdf", "two.pdf"],
            "the second is not a replacement just because the first was unlinked"
        )
        #expect(await contextFiles(macs.a).isEmpty)
    }

    /// Asked for nothing, it reads nothing and writes nothing.
    @Test func anEmptyBatchTouchesNeitherRecordsNorLedger() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("kept", to: context.appendingPathComponent("kept.pdf"), at: 0)

        let result = try await WorkspaceContextFileStore.offloadSources(
            [], in: workspaceURL, libraryRootURL: macs.a,
            source: "webdav:example", seen: nil
        )
        #expect(result.offloaded.isEmpty)
        #expect(result.skipped.isEmpty)
        #expect(await contextFiles(macs.a) == ["kept.pdf"])
        #expect(await LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).isEmpty)
    }

    /// A tombstone naming one source does not remove a folder put at that
    /// path since.
    ///
    /// `removeSyncedContextFile` removes recursively, so accepting a
    /// directory here would take everything inside it on the strength of a
    /// tombstone for a single file.
    @Test func adeletionDoesNotRemoveAfolderStandingWhereTheSourceWas() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let context = workspace(macs.a).appendingPathComponent("context")
        try FileManager.default.createDirectory(
            at: context.appendingPathComponent("history.pdf"), withIntermediateDirectories: true
        )
        try write("Inside", to: context.appendingPathComponent("history.pdf/page.txt"), at: 0)

        try await WorkspaceContextFileStore.removeDeletedSource(
            relativePath: "history.pdf", in: workspace(macs.a), libraryRootURL: macs.a
        )

        #expect(
            FileManager.default.fileExists(
                atPath: context.appendingPathComponent("history.pdf/page.txt").path
            ),
            "a folder is not the file the tombstone named"
        )
    }

    /// A source carries when it was attached here, so a replacement can
    /// supersede another Mac's deletion of the same path.
    ///
    /// Without it the plan takes the replacement for the copy the deletion
    /// was of, removes it, and prunes its stored object — so the new file is
    /// gone for good.
    @Test func asourceCarriesWhenItWasAttached() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let context = workspace(macs.a).appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)
        // A sync is what notices it and stamps `presentSince`.
        try await macs.sync(from: macs.a, to: macs.b)

        let times = await LampWorkspaceSync.sourceAttachmentTimes(inLibraryAt: macs.a)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspace(macs.a).lastPathComponent, relativePath: "history.pdf"
        )

        #expect(times[path] != nil, "the plan can tell a replacement from the deleted copy")
    }

    /// A ledger written before `offloaded` existed still decodes.
    ///
    /// Adding a property to a `Codable` struct does **not** make its key
    /// optional: Swift's synthesized `Decodable` still demands it, and
    /// `load` answers a *fresh* ledger when decoding fails. Every
    /// `sync-files.json` on disk would have been discarded on the first
    /// launch after this change, losing `synced` — so a file removed before
    /// the next sync would have come back. A reviewer caught it.
    @Test func readsAledgerWrittenBeforeOffloadingExisted() throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(".lamp"), withIntermediateDirectories: true
        )
        // Exactly the shape an older build wrote: no `offloaded` key.
        let old = """
            {
              "formatVersion": 1,
              "synced": { "Context/map.txt": 1000 },
              "deletedAt": { "Context/gone.txt": 2000 },
              "presentSince": { "Context/map.txt": 1000 }
            }
            """
        try Data(old.utf8).write(
            to: workspaceURL.appendingPathComponent(".lamp/sync-files.json")
        )

        let ledger = WorkspaceFileLedger.load(in: workspaceURL)

        #expect(ledger.synced?["Context/map.txt"] == 1_000, "what was present survived")
        #expect(ledger.deletedAt["Context/gone.txt"] == 2_000, "and what was deleted")
        #expect(ledger.offloaded.isEmpty)
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

/// A `FileManager` that writes over one file while another is being removed —
/// standing in for Finder, a restore, or an agent running in the workspace,
/// arriving in the window between the batch's check and its unlink.
private final class ReplacingFileManager: FileManager, @unchecked Sendable {
    private let trigger: URL
    private let target: URL
    private let contents: String

    init(whenRemoving trigger: URL, replace target: URL, with contents: String) {
        self.trigger = trigger
        self.target = target
        self.contents = contents
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if url.standardizedFileURL == trigger.standardizedFileURL {
            // In place, keeping the inode: the harder case, and the one a
            // process writing over an open path actually produces.
            try? contents.write(to: target, atomically: false, encoding: .utf8)
        }
        try super.removeItem(at: url)
    }
}

/// Says the writing is closed once, then open: the reader arriving while the
/// batch is working.
private actor OpenedPartWay {
    private var asked = 0

    func stillClosed() -> Bool {
        asked += 1
        return asked <= 1
    }
}
