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
                observation: ServerObservation(source: "webdav:example", members: []),
                server: serverAsUploaded(in: "webdav:example", library: macs.a)
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
            observation: ServerObservation(source: source, members: [path]),
            server: serverAsUploaded(in: source, library: macs.a)
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
            in: workspaceURL, libraryRootURL: macs.a, observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
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
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
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
            observation: ServerObservation(source: source, members: [path]),
            server: serverAsUploaded(in: source, library: macs.a)
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
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
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

    /// The batch deletes the file it checked, not whatever is at the path.
    ///
    /// Every candidate is read before any is deleted, so a batch leaves a
    /// window in which Finder, a restore, or an agent running in this very
    /// workspace can put other bytes at an already-checked path — and those
    /// bytes were never on the server. The hold check runs in exactly that
    /// window, between the verification and each unlink, so it is where the
    /// replacement is made: through the real batch, not a stand-in for it.
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

        // Written in place, keeping the inode — the harder case, and the one
        // a process writing over an open path produces.
        let b = context.appendingPathComponent("b.pdf")
        let result = try await WorkspaceContextFileStore.offloadSources(
            ["a.pdf", "b.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a),
            while: {
                if let handle = try? FileHandle(forWritingTo: b) {
                    try? handle.write(contentsOf: Data("different bytes entirely".utf8))
                    try? handle.close()
                }
                return true
            }
        )

        #expect(result.offloaded == ["a.pdf"], "the one whose bytes did not change goes")
        #expect(
            result.skipped["b.pdf"] == .changedSinceUpload,
            "and the one that changed under it is left alone"
        )
        #expect(
            try String(contentsOf: b, encoding: .utf8) == "different bytes entirely",
            "the bytes that arrived in the window are still here"
        )
        let member = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "b.pdf"
        )
        #expect(
            await !LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(member),
            "and nothing is left noted, so the new bytes go up on the next pass"
        )
    }

    /// A folder at an offloaded file's path does not count as the file
    /// being here.
    ///
    /// Counting it lifted the withholding, so the next pass tried to install
    /// the server's copy over a directory and broke the workspace's import.
    @Test func afolderAtAnOffloadedPathKeepsItWithheld() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let member = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("history.pdf"))
        try await ledger.save(in: workspaceURL)
        try FileManager.default.createDirectory(
            at: context.appendingPathComponent("history.pdf", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(await LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(member))
    }

    /// The unlink will not remove a folder, whatever has been put at a
    /// checked path. `unlink(2)` refuses one, and the identity check before it
    /// refuses anything that is not a regular file.
    @Test func theUnlinkWillNotRemoveAfolderPutAtAcheckedPath() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)
        let verified = try #require(
            await VerifiedSource.verify(relativePath: "history.pdf", inContext: context)
        )

        try FileManager.default.removeItem(at: context.appendingPathComponent("history.pdf"))
        let folder = context.appendingPathComponent("history.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("unrelated", to: folder.appendingPathComponent("inside.md"), at: 0)

        await #expect(throws: (any Error).self) {
            try await WorkspaceContextFileStore.unlink(verified, libraryRootURL: macs.a)
        }
        #expect(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("inside.md").path)
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
            observation: ServerObservation(source: source, members: [path]),
            server: serverAsUploaded(in: source, library: macs.a)
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
            observation: ServerObservation(source: source, members: [path]),
            server: serverAsUploaded(in: source, library: macs.a)
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
            observation: ServerObservation(source: source, members: [path]),
            server: serverAsUploaded(in: source, library: macs.a)
        )

        // A manifest that still counts it changes nothing.
        await LampWorkspaceSync.forgetActsNoLongerOnTheServer(
            inLibraryAt: macs.a, members: [path]
        )
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["history.pdf"])

        // One that does not is the other Mac's removal arriving.
        let forgotten = await LampWorkspaceSync.forgetActsNoLongerOnTheServer(
            inLibraryAt: macs.a, members: ["something/else"]
        )
        #expect(forgotten == [path])
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL).isEmpty)
        #expect(
            await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL).isEmpty,
            "and it is not left waiting for something that is never coming"
        )
    }

    /// Only the manifest of the server the offloads went to may settle them.
    ///
    /// Another server's manifest never counted them; forgetting them on its
    /// word made them vanish while their only copy sat on the server they
    /// went to. And within that server, a missing record is no reason to
    /// keep a row: another device's deletion reaps the record, and requiring
    /// one left the source drawn as on the server for ever.
    @Test func onlyTheHoldingServersManifestSettlesAnOffload() async throws {
        let held = "webdav:https://nas.example.com/s/"
        #expect(LampWorkspaceSync.mayReconcileOffloads(withManifestOf: held, heldBy: held))
        #expect(!LampWorkspaceSync.mayReconcileOffloads(withManifestOf: "webdav:https://other/", heldBy: held))

        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("history.pdf"))
        try await ledger.save(in: workspaceURL)
        // No record at all: reaped when another device deleted it.

        let gone = await LampWorkspaceSync.forgetActsNoLongerOnTheServer(
            inLibraryAt: macs.a, members: []
        )
        #expect(gone == [path])
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL).isEmpty)
    }

    /// Attaching a file under an offloaded source's name gives it another
    /// name.
    ///
    /// The disk shows the path free. Given it, the new file would have been
    /// published over the server's copy on the next pass — the reader's
    /// offloaded source overwritten by something else, unasked.
    @Test func anAttachmentDoesNotTakeAnOffloadedSourcesName() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("notes.pdf"))
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("folder/inside.pdf"))
        try await ledger.save(in: workspaceURL)

        let outside = macs.root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("a different notes", to: outside.appendingPathComponent("notes.pdf"), at: 0)
        let folder = outside.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("x", to: folder.appendingPathComponent("other.pdf"), at: 0)

        let file = try await WorkspaceContextFileStore.addContextItem(
            from: outside.appendingPathComponent("notes.pdf"), to: workspaceURL, libraryRootURL: macs.a
        )
        #expect(file?.lastPathComponent == "notes 2.pdf")
        let added = try await WorkspaceContextFileStore.addContextItem(
            from: folder, to: workspaceURL, libraryRootURL: macs.a
        )
        #expect(
            added?.lastPathComponent == "folder 2",
            "a folder cannot land among offloaded files either"
        )
    }

    /// While offloads are outstanding, sync can be turned off and back on to
    /// the server they went to, and pointed nowhere else (owner's decision,
    /// `decisions/0021`).
    ///
    /// The server is the one written down when the first offload began, not
    /// one inferred from records: a record is a memory of a past upload, and
    /// an old server holding one may since have lost or replaced the file.
    @Test func syncCannotLeaveTheServerTheOffloadsWentTo() {
        let held = "webdav:https://nas.example.com/s/"
        let other = "webdav:https://other.example.com/s/"
        #expect(LampWorkspaceSync.mayPointSync(at: nil, heldBy: held), "off changes no server")
        #expect(LampWorkspaceSync.mayPointSync(at: held, heldBy: held), "and back on returns to it")
        #expect(!LampWorkspaceSync.mayPointSync(at: other, heldBy: held), "but nowhere else")
        #expect(LampWorkspaceSync.mayPointSync(at: other, heldBy: nil), "and with nothing held, anywhere")
    }

    /// Download All is the way out: every offloaded source is asked back, and
    /// the list the lock is shown from holds until they have arrived, not
    /// merely been asked for — one on its way still exists only on the old
    /// server.
    @Test func downloadAllAsksForEverySourceAndTheLockHoldsUntilTheyArrive() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        for name in ["a.pdf", "b.pdf"] {
            ledger.noteOffloaded(WorkspaceFileLedger.contextKey(name))
        }
        try await ledger.save(in: workspaceURL)

        #expect(await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a)?.count == 2)

        let asked = await LampWorkspaceSync.askForEverySourceOnTheServer(inLibraryAt: macs.a)
        #expect(asked == 2)
        #expect(await LampWorkspaceSync.awaitedSourceNames(in: workspaceURL) == ["a.pdf", "b.pdf"])
        #expect(
            await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a)?.count == 2,
            "asked for is not here"
        )

        try write("a", to: context.appendingPathComponent("a.pdf"), at: 0)
        try write("b", to: context.appendingPathComponent("b.pdf"), at: 0)
        #expect(
            await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a)?.isEmpty == true,
            "arrived"
        )
    }

    /// A folder on the way replaced by a link does not make an offloaded
    /// source look present.
    ///
    /// The leaf is a regular file through the link, but the gather follows
    /// no links and has no source there. Counting it as here would hide the
    /// Download row and lift the lock on the server with nothing restored.
    @Test func anOffloadedSourceBehindALinkedFolderIsStillOnTheServer() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("notes/history.pdf"))
        try await ledger.save(in: workspaceURL)

        let elsewhere = macs.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try write("a file of the same name", to: elsewhere.appendingPathComponent("history.pdf"), at: 0)
        try FileManager.default.createSymbolicLink(
            at: context.appendingPathComponent("notes"), withDestinationURL: elsewhere
        )

        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["notes/history.pdf"])
        #expect(await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a)?.count == 1)
    }

    /// Offload deletes nothing when pressed: it records a request, which
    /// survives the file being here, is not withheld from the server, and can
    /// be withdrawn (owner's decision, `decisions/0021`).
    @Test func offloadIsArequestUntilTheNextSync() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("Daniell", to: context.appendingPathComponent("history.pdf"), at: 0)

        try await WorkspaceContextFileStore.queueOffload(relativePath: "history.pdf", in: workspaceURL)
        #expect(FileManager.default.fileExists(atPath: context.appendingPathComponent("history.pdf").path))
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspaceURL) == ["history.pdf"])
        #expect(
            await LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).isEmpty,
            "still here, so still the server's to receive"
        )
        #expect(await LampWorkspaceSync.requestedOffloads(inLibraryAt: macs.a).first?.paths == ["history.pdf"])

        // A pass's gather sees the file present; the request is about exactly
        // that file, and must survive it.
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.synced = [:]
        ledger.noteChanges(present: [WorkspaceFileLedger.contextKey("history.pdf"): 1])
        try await ledger.save(in: workspaceURL)
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspaceURL) == ["history.pdf"])

        try await WorkspaceContextFileStore.cancelOffload(relativePath: "history.pdf", in: workspaceURL)
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspaceURL).isEmpty)
    }

    /// A request to offload a source that is not on the server yet is not
    /// forgotten by the server's manifest not counting it — it waits.
    @Test func arequestToOffloadSurvivesReconciliation() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        try write("new", to: context.appendingPathComponent("fresh.pdf"), at: 0)
        try await WorkspaceContextFileStore.queueOffload(relativePath: "fresh.pdf", in: workspaceURL)

        let forgotten = await LampWorkspaceSync.forgetActsNoLongerOnTheServer(
            inLibraryAt: macs.a, members: []
        )
        #expect(forgotten.isEmpty)
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspaceURL) == ["fresh.pdf"])
    }

    /// A request that can never be met is dropped and said, rather than tried
    /// after every sync for ever; one that may succeed later stays.
    @Test func arequestIsDroppedOnlyForReasonsThatWillNotChange() {
        typealias Skipped = WorkspaceContextFileStore.Skipped
        #expect(Skipped.untrustedVolume.isLasting)
        #expect(Skipped.wouldLoseWhatNoStoreKeeps.isLasting)
        #expect(Skipped.notAsource.isLasting)
        #expect(!Skipped.notOnTheServer.isLasting, "it may finish uploading")
        #expect(!Skipped.serverCopyDiffers.isLasting)
        #expect(!Skipped.changedSinceUpload.isLasting, "it goes up on the next sync")
        #expect(!Skipped.couldNotRemove.isLasting)
    }

    /// A source with a resource fork is not offloaded: neither the digest nor
    /// any store carries the fork, so no download could bring it back.
    @Test func asourceWithAresourceForkStaysHere() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let file = context.appendingPathComponent("forked.pdf")
        try write("data", to: file, at: 0)
        let fork = Data("the resource fork".utf8)
        let set = fork.withUnsafeBytes { bytes in
            setxattr(file.path, XATTR_RESOURCEFORK_NAME, bytes.baseAddress, bytes.count, 0, 0)
        }
        #expect(set == 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "forked.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["forked.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(result.skipped["forked.pdf"] == .wouldLoseWhatNoStoreKeeps)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A source the reader has tagged in Finder stays here: the tags are not
    /// in the bytes, no store keeps them, and a download would bring the file
    /// back without them.
    @Test func atTaggedSourceStaysHere() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let file = context.appendingPathComponent("tagged.pdf")
        try write("data", to: file, at: 0)
        try (file as NSURL).setResourceValue(["Reading"], forKey: .tagNamesKey)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "tagged.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["tagged.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(result.skipped["tagged.pdf"] == .wouldLoseWhatNoStoreKeeps)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Keep Here wins even after the batch has begun: the request is read
    /// again at the moment the offload would be noted, with nothing
    /// suspending in between.
    @Test func keepHereWinsAfterTheBatchHasStarted() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let file = context.appendingPathComponent("history.pdf")
        try write("Daniell", to: file, at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        try await WorkspaceContextFileStore.queueOffload(relativePath: "history.pdf", in: workspaceURL)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a),
            onlyWhileRequested: true,
            while: {
                // Pressed while the batch was reading the file.
                try? await WorkspaceContextFileStore.cancelOffload(
                    relativePath: "history.pdf", in: workspaceURL
                )
                return true
            }
        )
        #expect(result.offloaded.isEmpty)
        #expect(result.skipped["history.pdf"] == .withdrawn)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// An inventory that could not be read says so, rather than reading as
    /// empty — which would lift the lock that guards the only copies.
    @Test(.enabled(if: geteuid() != 0, "root is not refused by permission bits"))
    func anUnreadableInventoryIsNotAnEmptyOne() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let writing = workspace(macs.a).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workspace(macs.a), withIntermediateDirectories: true)
        #expect(await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a) == [], "readable and empty")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: writing.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: writing.path)
        }
        #expect(
            await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a) == nil,
            "unreadable, which is not the same"
        )
    }

    /// A ledger in a folder Lamp may not search is unreadable, not absent:
    /// asking whether it exists answers no, and an empty ledger then would
    /// lift the lock with sources only on the server.
    @Test(.enabled(if: geteuid() != 0, "root is not refused by permission bits"))
    func aledgerBehindAdeniedFolderIsUnreadable() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        var ledger = WorkspaceFileLedger()
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("history.pdf"))
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try await ledger.save(in: workspaceURL)
        let lamp = workspaceURL.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lamp.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lamp.path) }

        #expect(WorkspaceFileLedger.loadIfReadable(in: workspaceURL) == nil)
        #expect(await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a) == nil)
    }

    /// Attaching needs the ledger that says which names offloaded sources
    /// still hold; one that will not read refuses the attachment rather than
    /// guess none, which could put a new file over an offloaded one's copy.
    @Test func attachingRefusesOverAnUnreadableLedger() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("context"), withIntermediateDirectories: true
        )
        let ledgerFile = workspaceURL.appendingPathComponent(".lamp/sync-files.json")
        try FileManager.default.createDirectory(
            at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a ledger".utf8).write(to: ledgerFile)
        let outside = macs.root.appendingPathComponent("history.pdf")
        try write("another", to: outside, at: 0)

        await #expect(throws: WorkspaceFileLedger.UnreadableLedger.self) {
            try await WorkspaceContextFileStore.addContextItem(
                from: outside, to: workspaceURL, libraryRootURL: macs.a
            )
        }
        #expect(await contextFiles(macs.a).isEmpty)
    }

    /// A copy that came back by an import which failed before checking it is
    /// checked at the next gather: the same bytes get their mark back, and
    /// the record of what left is not dropped unchecked.
    @Test func acopyAnInterruptedImportLeftIsCheckedAtTheNextGather() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let a = workspace(macs.a)
        let file = a.appendingPathComponent("context/history.pdf")
        try write("Daniell", to: file, at: 0)
        let mark = "0083;6750a1b2;Safari;"
        _ = Data(mark.utf8).withUnsafeBytes {
            setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: a.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: a, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(result.offloaded == ["history.pdf"])
        try await WorkspaceContextFileStore.fetchSource(relativePath: "history.pdf", in: a)
        // The import wrote it and stopped: no check ran.
        try write("Daniell", to: file, at: 0)

        let outgoing = macs.root.appendingPathComponent("outgoing", isDirectory: true)
        try await LampWorkspaceSync.exportPortableWorkspaces(from: macs.a, to: outgoing, installID: "mac")

        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(size > 0, "marked at the gather")
    }

    /// A file the reader puts where an offloaded source was is not news from
    /// the server: the gather drops what it kept about the old one and says
    /// nothing, and gives the new file no mark.
    @Test func afileTheReaderPutsInPlaceIsNotSaidToHaveComeBack() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let a = workspace(macs.a)
        let file = a.appendingPathComponent("context/history.pdf")
        try write("Daniell", to: file, at: 0)
        _ = Data("0083;6750a1b2;Safari;".utf8).withUnsafeBytes {
            setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: a.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: a, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(result.offloaded == ["history.pdf"])
        try write("my own notes", to: file, at: 0)

        let outgoing = macs.root.appendingPathComponent("outgoing", isDirectory: true)
        try await LampWorkspaceSync.exportPortableWorkspaces(from: macs.a, to: outgoing, installID: "mac")

        #expect(await LampWorkspaceSync.takeReturnNotices(inLibraryAt: macs.a).changed.isEmpty)
        #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
    }

    /// A context folder that is itself a link is no way to a source: the
    /// gather never goes there.
    @Test func alinkedContextFolderIsNotPresence() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        try? FileManager.default.removeItem(at: workspaceURL.appendingPathComponent("context"))
        let elsewhere = macs.root.appendingPathComponent("elsewhere-context", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try write("same name", to: elsewhere.appendingPathComponent("history.pdf"), at: 0)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspaceURL.appendingPathComponent("context"), withDestinationURL: elsewhere
        )
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("history.pdf"))
        try await ledger.save(in: workspaceURL)

        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["history.pdf"])
    }

    /// A ledger that is there and will not read keeps the lock: it may hold
    /// the last offload, and reading it as empty would lift the lock while
    /// the only copy sat on the server.
    @Test func anUnreadableLedgerKeepsTheLock() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("history.pdf"))
        try await ledger.save(in: workspaceURL)
        #expect(await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a)?.count == 1)

        try Data("not a ledger".utf8).write(
            to: workspaceURL.appendingPathComponent(".lamp/sync-files.json")
        )
        #expect(await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.a) == nil)
    }

    /// A source comes back from the server with the quarantine it left with.
    ///
    /// No store carries extended attributes. The mark is kept while the
    /// source is away and put back when it arrives — after consolidation has
    /// made it a read-only shared object, which macOS will not write an
    /// attribute to unless the write bit is lifted for the call.
    @Test func asourceComesBackWithItsQuarantine() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let a = workspace(macs.a)
        let file = a.appendingPathComponent("context/history.pdf")
        try write("Daniell", to: file, at: 0)
        let mark = "0083;6750a1b2;Safari;"
        let set = Data(mark.utf8).withUnsafeBytes {
            setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        #expect(set == 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: a.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        // Mac B holds the same source, as the server does.
        try write("Daniell", to: workspace(macs.b).appendingPathComponent("context/history.pdf"), at: 0)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: a, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(result.offloaded == ["history.pdf"])
        try await WorkspaceContextFileStore.fetchSource(relativePath: "history.pdf", in: a)

        try await macs.sync(from: macs.b, to: macs.a)

        #expect(FileManager.default.fileExists(atPath: file.path), "downloaded")
        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(size > 0, "and marked again")
        var value = [UInt8](repeating: 0, count: max(size, 0))
        _ = getxattr(file.path, "com.apple.quarantine", &value, value.count, 0, 0)
        #expect(String(decoding: value, as: UTF8.self) == mark)
    }

    /// A download whose quarantine will not take is left where it is, and
    /// said: a missing mark is a thing to tell the reader, never a reason to
    /// delete a file (`decisions/0022`).
    @Test func adownloadWhoseQuarantineWillNotTakeIsKeptAndSaid() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let a = workspace(macs.a)
        let context = a.appendingPathComponent("context")
        let file = context.appendingPathComponent("history.pdf")
        try write("Daniell", to: file, at: 0)
        let mark = "0083;6750a1b2;Safari;"
        _ = Data(mark.utf8).withUnsafeBytes {
            setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: a.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        try write("Daniell", to: workspace(macs.b).appendingPathComponent("context/history.pdf"), at: 0)
        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: a, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(result.offloaded == ["history.pdf"])
        try await WorkspaceContextFileStore.fetchSource(relativePath: "history.pdf", in: a)

        // Every attribute write refused in this Mac's library, as an ACL
        // would; removing a file is still allowed.
        let deny = Process()
        deny.executableURL = URL(fileURLWithPath: "/bin/chmod")
        deny.arguments = ["-R", "+a", "everyone deny writeextattr,file_inherit,directory_inherit", macs.a.path]
        try deny.run()
        deny.waitUntilExit()
        #expect(deny.terminationStatus == 0)

        try await macs.sync(from: macs.b, to: macs.a)

        #expect(FileManager.default.fileExists(atPath: file.path), "kept")
        #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) < 0, "unmarked")
        let notices = await LampWorkspaceSync.takeReturnNotices(inLibraryAt: macs.a)
        #expect(notices.unmarked == ["history.pdf"], "and said")
        #expect(await LampWorkspaceSync.takeReturnNotices(inLibraryAt: macs.a).unmarked.isEmpty, "once")
    }

    /// A copy that comes back different from the one that left is said, and
    /// does not get the old file's quarantine: the mark was about that file.
    /// A file the reader put at the path is the same case, and is never
    /// touched.
    @Test func acopyComingBackDifferentIsSaidAndNotMarked() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let a = workspace(macs.a)
        let file = a.appendingPathComponent("context/history.pdf")
        try write("Daniell", to: file, at: 0)
        _ = Data("0083;6750a1b2;Safari;".utf8).withUnsafeBytes {
            setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: a.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)
        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: a, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(result.offloaded == ["history.pdf"])
        try await WorkspaceContextFileStore.fetchSource(relativePath: "history.pdf", in: a)
        // Edited on Mac B meanwhile: the server's copy is another one.
        try write("Daniell, revised", to: workspace(macs.b).appendingPathComponent("context/history.pdf"), at: 10)

        try await macs.sync(from: macs.b, to: macs.a)

        #expect(try String(contentsOf: file, encoding: .utf8) == "Daniell, revised", "kept")
        #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) < 0, "and not given the old mark")
        #expect(await LampWorkspaceSync.takeReturnNotices(inLibraryAt: macs.a).changed == ["history.pdf"])
    }

    /// A request to offload is about the file it was made about. One put in
    /// its place under the same name is not sent away.
    @Test func arequestGoesWithItsFileNotItsName() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let file = workspaceURL.appendingPathComponent("context/history.pdf")
        try write("Daniell", to: file, at: 0)
        try await WorkspaceContextFileStore.queueOffload(relativePath: "history.pdf", in: workspaceURL)
        // Deleted in Finder and another dropped in under the name, with the
        // same bytes, so only which file it is differs.
        try FileManager.default.removeItem(at: file)
        try write("Daniell", to: file, at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a),
            onlyWhileRequested: true
        )
        #expect(result.offloaded.isEmpty)
        #expect(result.skipped["history.pdf"] == .withdrawn)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspaceURL).isEmpty)
    }

    /// Remove reads the ledger before it touches anything: one that will not
    /// read cannot name a folder's offloaded sources, and the save that
    /// refuses it would come after the files had gone.
    @Test func removeTouchesNothingOverAnUnreadableLedger() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let file = workspaceURL.appendingPathComponent("context/history.pdf")
        try write("Daniell", to: file, at: 0)
        let ledgerFile = workspaceURL.appendingPathComponent(".lamp/sync-files.json")
        try FileManager.default.createDirectory(
            at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a ledger".utf8).write(to: ledgerFile)

        await #expect(throws: WorkspaceFileLedger.UnreadableLedger.self) {
            try await WorkspaceContextFileStore.removeContextItem(
                at: file, from: workspaceURL, libraryRootURL: macs.a
            )
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await LampSyncRemovedModules.load(fromLibraryAt: macs.a).removedAt.isEmpty)
    }

    /// A pass never saves a fresh ledger over one it could not read: the file
    /// may hold the last offload, and left as it is, the lock on where sync
    /// points keeps reading it as unknown and holds.
    @Test func apassLeavesAnUnreadableLedgerAsItIs() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let b = workspace(macs.b)
        let ledgerFile = b.appendingPathComponent(".lamp/sync-files.json")
        try FileManager.default.createDirectory(
            at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let damaged = Data("not a ledger".utf8)
        try damaged.write(to: ledgerFile)
        try write("from A", to: workspace(macs.a).appendingPathComponent("context/notes.pdf"), at: 0)

        try await macs.sync(from: macs.a, to: macs.b)
        try await macs.sync(from: macs.b, to: macs.a)

        #expect(try Data(contentsOf: ledgerFile) == damaged, "left exactly as it was")
        #expect(await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: macs.b) == nil)
    }

    /// A folder's removal is queued for the server before its acts are
    /// cleared, as a single source's is.
    @Test func afoldersRemovalIsQueuedBeforeItsActsAreCleared() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMacSupport/WorkspaceTextFileSupport.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "public static func removeContextItem("))
        let end = try #require(source.range(of: "\n    /// ", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        let queued = try #require(body.range(of: "removed.save("))
        let cleared = try #require(body.range(of: "ledger.recordDeletion("))
        #expect(queued.lowerBound < cleared.lowerBound)
    }

    /// Removing a file that stands where a folder of offloaded sources used
    /// to be removes the file, and nothing of the folder's.
    @Test func removingAfileTakesNoneOfAfoldersOffloadedChildren() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("notes/history.pdf"))
        try await ledger.save(in: workspaceURL)
        // A file put where the folder was.
        try write("a file now", to: workspaceURL.appendingPathComponent("context/notes"), at: 0)

        try await WorkspaceContextFileStore.removeContextItem(
            at: workspaceURL.appendingPathComponent("context/notes"),
            from: workspaceURL, libraryRootURL: macs.a
        )

        let child = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "notes/history.pdf"
        )
        #expect(await LampSyncRemovedModules.load(fromLibraryAt: macs.a).removedAt[child] == nil)
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["notes/history.pdf"])
    }

    /// No mutation writes a fresh ledger over one that will not read: the
    /// button fails instead, and the file is left for the lock to keep
    /// reading as unknown.
    @Test func amutationRefusesToWriteOverAnUnreadableLedger() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let ledgerFile = workspaceURL.appendingPathComponent(".lamp/sync-files.json")
        try FileManager.default.createDirectory(
            at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let damaged = Data("not a ledger".utf8)
        try damaged.write(to: ledgerFile)
        try write("x", to: workspaceURL.appendingPathComponent("context/other.pdf"), at: 0)

        await #expect(throws: WorkspaceFileLedger.UnreadableLedger.self) {
            try await WorkspaceContextFileStore.queueOffload(relativePath: "other.pdf", in: workspaceURL)
        }
        await #expect(throws: WorkspaceFileLedger.UnreadableLedger.self) {
            try await WorkspaceContextFileStore.fetchSource(relativePath: "other.pdf", in: workspaceURL)
        }
        #expect(try Data(contentsOf: ledgerFile) == damaged)
    }

    /// A folder linked to another folder inside the context directory is not
    /// a way to an offloaded source: it resolves inside, and the gather still
    /// follows no links.
    @Test func afolderLinkedWithinTheContextDirectoryIsNotPresence() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let other = context.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try write("same name", to: other.appendingPathComponent("history.pdf"), at: 0)
        try FileManager.default.createSymbolicLink(
            at: context.appendingPathComponent("maps"), withDestinationURL: other
        )
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("maps/history.pdf"))
        try await ledger.save(in: workspaceURL)

        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["maps/history.pdf"])
    }

    /// On a case-insensitive volume `History.pdf` and an offloaded
    /// `history.pdf` are one path, so the attachment takes another name —
    /// whichever side carries the capital.
    @Test func anAttachmentDoesNotTakeAnOffloadedNameInAnotherCase() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        var ledger = await WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("history.pdf"))
        ledger.noteOffloaded(WorkspaceFileLedger.contextKey("NOTES.pdf"))
        try await ledger.save(in: workspaceURL)
        let outside = macs.root.appendingPathComponent("incoming-case", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // Different bytes each: an attachment whose bytes are already in the
        // workspace is the file already there, whatever it is called.
        try write("a different history", to: outside.appendingPathComponent("History.pdf"), at: 0)
        try write("different notes", to: outside.appendingPathComponent("notes.pdf"), at: 0)

        let upper = try await WorkspaceContextFileStore.addContextItem(
            from: outside.appendingPathComponent("History.pdf"), to: workspaceURL, libraryRootURL: macs.a
        )
        #expect(upper?.lastPathComponent == "History 2.pdf")
        let lower = try await WorkspaceContextFileStore.addContextItem(
            from: outside.appendingPathComponent("notes.pdf"), to: workspaceURL, libraryRootURL: macs.a
        )
        #expect(lower?.lastPathComponent == "notes 2.pdf")
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
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a),
            while: { await opened.stillClosed() }
        )
        #expect(result.offloaded == ["a.pdf"])
        #expect(result.skipped["b.pdf"] == .nowHeld)
        #expect(
            FileManager.default.fileExists(atPath: context.appendingPathComponent("b.pdf").path),
            "the rest of the workspace's sources stay where the reader can see them"
        )
    }

    /// A folder holding a source that is only on the server is not removed:
    /// that would delete the only copy. Download it first (`decisions/0022`).
    @Test func afolderHoldingAnOffloadedSourceWaitsForItsDownload() async throws {
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
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )

        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["notes/offloaded.pdf"])

        await #expect(throws: WorkspaceContextFileStore.OffloadError.waitsForDownload("notes")) {
            try await WorkspaceContextFileStore.removeContextItem(
                at: notes, from: workspaceURL, libraryRootURL: macs.a
            )
        }
        #expect(FileManager.default.fileExists(atPath: notes.appendingPathComponent("stays.pdf").path))
        #expect(await LampSyncRemovedModules.load(fromLibraryAt: macs.a).removedAt.isEmpty)
        #expect(await LampWorkspaceSync.offloadedSourceNames(in: workspaceURL) == ["notes/offloaded.pdf"])
    }

    /// The server's copy is the proof: an offload goes only where the copy
    /// read back is these bytes. A server holding something else at the path
    /// — whatever the records, the listing or the tags say — keeps the file
    /// here; one that cannot be read does too.
    @Test func anOffloadGoesOnlyWhereTheServersCopyIsTheseBytes() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        var paths: [String: String] = [:]
        for name in ["same.pdf", "other.pdf", "missing.pdf", "unreadable.pdf"] {
            try write(name, to: context.appendingPathComponent(name), at: 0)
            let path = try LampWritingWorkspaceLayout.contextPath(
                folder: workspaceURL.lastPathComponent, relativePath: name
            )
            paths[name] = path
            records.recordUpload(
                path, in: source,
                digest: try LampSyncContentRevision.digest(forFileAt: context.appendingPathComponent(name)),
                revision: "\"r1\""
            )
            records.confirmRecorded([path: "\"r1\""], in: source)
        }
        try records.save(toLibraryAt: macs.a)
        let held: [String: Data] = [
            paths["same.pdf"]!: Data("same.pdf".utf8),
            paths["other.pdf"]!: Data("another copy".utf8),
        ]
        let unreadable = paths["unreadable.pdf"]!
        let server = OffloadServer(source: source, account: "") { path, destination in
            if path == unreadable { throw URLError(.timedOut) }
            guard let data = held[path] else { return false }
            try data.write(to: destination)
            return true
        }

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["same.pdf", "other.pdf", "missing.pdf", "unreadable.pdf"],
            in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a), server: server
        )
        #expect(result.offloaded == ["same.pdf"])
        #expect(result.skipped["other.pdf"] == .serverCopyDiffers)
        #expect(result.skipped["missing.pdf"] == .serverCopyDiffers)
        #expect(result.skipped["unreadable.pdf"] == .couldNotReadTheServer)
        #expect(await contextFiles(macs.a) == ["missing.pdf", "other.pdf", "unreadable.pdf"])
    }

    /// The server is read only as the look was taken: reached as another
    /// account, nothing is read and nothing goes.
    @Test func anOffloadReadsOnlyAsTheLooksAccount() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let file = workspaceURL.appendingPathComponent("context/history.pdf")
        try write("Daniell", to: file, at: 0)
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        var records = LampSyncFileRecords()
        records.recordUpload(path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file), revision: "\"r1\"")
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: ServerObservation(source: source, account: "user:anna", members: [path]),
            server: serverAsUploaded(in: source, library: macs.a, account: "user:ben")
        )
        #expect(result.offloaded.isEmpty)
        #expect(result.skipped["history.pdf"] == .couldNotReadTheServer)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// One run reads back only so much; the rest wait for the next.
    @Test func anOffloadRunReadsBackOnlyItsBudget() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        for name in ["a.pdf", "b.pdf"] {
            try write("twelve bytes", to: context.appendingPathComponent(name), at: 0)
            let path = try LampWritingWorkspaceLayout.contextPath(
                folder: workspaceURL.lastPathComponent, relativePath: name
            )
            records.recordUpload(
                path, in: source,
                digest: try LampSyncContentRevision.digest(forFileAt: context.appendingPathComponent(name)),
                revision: "\"r1\""
            )
            records.confirmRecorded([path: "\"r1\""], in: source)
        }
        try records.save(toLibraryAt: macs.a)
        let result = try await WorkspaceContextFileStore.offloadSources(
            ["a.pdf", "b.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a),
            readBudget: 12
        )
        #expect(result.offloaded.count == 1)
        #expect(result.skipped.values.first == .later)

        // What is left of a run's allowance is checked before a read: a file
        // larger than what remains waits, rather than going over.
        let rest = try await WorkspaceContextFileStore.offloadSources(
            result.skipped.keys.sorted(), in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a),
            readBudget: 5
        )
        #expect(rest.offloaded.isEmpty)
        #expect(rest.read == 0)
    }

    /// A request to offload is made about a file that is here, or not made.
    @Test func arequestNeedsAfileToBeAbout() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("context"), withIntermediateDirectories: true
        )
        await #expect(throws: WorkspaceContextFileStore.OffloadError.self) {
            try await WorkspaceContextFileStore.queueOffload(relativePath: "gone.pdf", in: workspaceURL)
        }
        // Nor through a linked folder, which the gather follows no more than
        // the offload does: the file there is not a source here.
        let elsewhere = macs.a.appendingPathComponent("elsewhere", isDirectory: true)
        try write("x", to: elsewhere.appendingPathComponent("x.pdf"), at: 0)
        try FileManager.default.createSymbolicLink(
            at: workspaceURL.appendingPathComponent("context/linked"), withDestinationURL: elsewhere
        )
        await #expect(throws: WorkspaceContextFileStore.OffloadError.self) {
            try await WorkspaceContextFileStore.queueOffload(relativePath: "linked/x.pdf", in: workspaceURL)
        }
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspaceURL).isEmpty)
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
            observation: ServerObservation(source: source, members: [path]),
            server: serverAsUploaded(in: source, library: macs.a)
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

    /// A workspace holding the same file twice offloads one copy now and the
    /// other on the next sweep.
    ///
    /// A source is a hard link into the library's object store, so two copies
    /// of one file are two links to one inode — and unlinking either moves
    /// that inode's change time. The unlink requires the whole identity,
    /// change time included, because that is the only thing that notices a
    /// file rewritten at the same size with its date put back
    /// (`decisions/0007`). So the twin reads as changed and waits: it is
    /// left un-noted, and the next sweep reads it afresh. Ignoring the change
    /// time made both go at once, and cost that guard.
    @Test func atwinCopyWaitsForTheNextSweep() async throws {
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

        let first = try await WorkspaceContextFileStore.offloadSources(
            ["one.pdf", "two.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(first.offloaded == ["one.pdf"])
        #expect(first.skipped["two.pdf"] == .changedSinceUpload)
        let twin = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "two.pdf"
        )
        #expect(
            await !LampWorkspaceSync.offloadedSources(inLibraryAt: macs.a).contains(twin),
            "left un-noted, so nothing is withheld for a file still here"
        )

        let second = try await WorkspaceContextFileStore.offloadSources(
            ["two.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a)
        )
        #expect(second.offloaded == ["two.pdf"], "read afresh, it goes")
        #expect(await contextFiles(macs.a).isEmpty)
    }

    /// A source rewritten in place at the same size, with its date put back,
    /// between being verified and being unlinked, is left alone.
    ///
    /// The change time is the only thing that notices it (`decisions/0007`),
    /// and those bytes were never on the server.
    @Test func asourceRewrittenWithItsDatePutBackIsNotDeleted() async throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let workspaceURL = workspace(macs.a)
        let context = workspaceURL.appendingPathComponent("context")
        let file = context.appendingPathComponent("history.pdf")
        try write("first", to: file, at: 0)
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: "history.pdf"
        )
        let source = LampSyncFileRecords.webDAVSource(URL(string: "https://dav.example.com/s/")!)
        var records = LampSyncFileRecords()
        records.recordUpload(
            path, in: source, digest: try LampSyncContentRevision.digest(forFileAt: file),
            revision: "\"r1\""
        )
        records.confirmRecorded([path: "\"r1\""], in: source)
        try records.save(toLibraryAt: macs.a)

        let result = try await WorkspaceContextFileStore.offloadSources(
            ["history.pdf"], in: workspaceURL, libraryRootURL: macs.a,
            observation: everythingRecorded(in: source, library: macs.a),
            server: serverAsUploaded(in: source, library: macs.a),
            while: {
                // Same size, written in place, and the exact times put back.
                var original = stat()
                guard stat(file.path, &original) == 0,
                      let handle = try? FileHandle(forWritingTo: file)
                else { return true }
                try? handle.write(contentsOf: Data("other".utf8))
                try? handle.close()
                var times = [original.st_atimespec, original.st_mtimespec]
                _ = utimensat(AT_FDCWD, file.path, &times, 0)
                return true
            }
        )
        #expect(result.offloaded.isEmpty)
        #expect(result.skipped["history.pdf"] == .changedSinceUpload)
        #expect(try String(contentsOf: file, encoding: .utf8) == "other", "the new bytes are still here")
    }

    /// Nothing reopens the source between the check and the unlink.
    ///
    /// The ordinary removal hashes the file and then deletes it, which put a
    /// second read — of a source that may be 90 MB — after the check that
    /// said deleting was safe; anything arriving in that window went
    /// unchecked. The batch carries the digest it already took instead.
    ///
    /// Read from the source, as `WorkspaceFileOwnershipTests` does: the
    /// window is between two calls inside one function, with no seam a test
    /// can reach, and an assertion about the file afterwards passes either
    /// way.
    @Test func thebatchDoesNotReopenAsourceAfterCheckingIt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMacSupport/WorkspaceTextFileSupport.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "public static func offloadSources("))
        // To the next declaration at this level: the function holds nested
        // closures, so the first `}` at four spaces is not its end.
        let end = try #require(
            source.range(of: "\n    /// ", range: start.upperBound..<source.endIndex)
        )
        // Code only: the function's own comment names the call it avoids.
        let body = source[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(
            body.contains("try unlink(verified"),
            "the unlink that takes the digest already taken"
        )
        #expect(
            !body.contains("removeSyncedContextFile"),
            """
            `removeSyncedContextFile` hashes the file and then unlinks it, so \
            using it here reopens a source the batch has just finished \
            checking — and deletes whatever the second read found.
            """
        )
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
            observation: ServerObservation(source: "webdav:example", members: []),
            server: serverAsUploaded(in: "webdav:example", library: macs.a)
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
        #expect(ledger.acts.isEmpty)
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


/// Says the writing is closed once, then open: the reader arriving while the
/// batch is working.
private actor OpenedPartWay {
    private var asked = 0

    func stillClosed() -> Bool {
        asked += 1
        // Asked twice a file: before its server copy is read, and again
        // after, before anything is noted.
        return asked <= 2
    }
}

/// A look at the server whose manifest counts every source this Mac has a
/// record of uploading or downloading — what a pass would see had nothing
/// changed on the server since. Which of them the server really holds is
/// `serverAsUploaded`'s to say.
private func everythingRecorded(in source: String, library: URL) -> ServerObservation {
    let records = LampSyncFileRecords.load(fromLibraryAt: library)
    let members = (records.sources[source]?.files ?? [:]).filter { $0.value.uploadedDigest != nil }.keys
    return ServerObservation(source: source, members: Set(members))
}

/// A server holding, at each path this Mac has a record for, the bytes it
/// uploaded: the local file as it is when this is called, where its digest is
/// the recorded one. What `offloadSources` reads back to decide.
func serverAsUploaded(in source: String, library: URL, account: String = "") -> OffloadServer {
    let records = LampSyncFileRecords.load(fromLibraryAt: library)
    var held: [String: Data] = [:]
    for (path, record) in records.sources[source]?.files ?? [:] {
        guard let (folder, relative) = LampWritingWorkspaceLayout.contextFile(ofPath: path) else { continue }
        let file = library.appendingPathComponent("AgentWorkspaces/Writing/\(folder)/context/\(relative)")
        guard let digest = try? LampSyncContentRevision.digest(forFileAt: file),
              digest == record.uploadedDigest,
              let data = try? Data(contentsOf: file) else { continue }
        held[path] = data
    }
    return serverHolding(held, source: source, account: account)
}

/// A server holding exactly `held`.
func serverHolding(_ held: [String: Data], source: String, account: String = "") -> OffloadServer {
    OffloadServer(source: source, account: account) { path, destination in
        guard let data = held[path] else { return false }
        try data.write(to: destination)
        return true
    }
}

