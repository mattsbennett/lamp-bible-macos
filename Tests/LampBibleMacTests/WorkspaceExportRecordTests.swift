import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// A pass asks the exporter what it would place rather than having it copy
/// everything into a scratch directory first.
///
/// The one thing that must hold: **what is published is the same**. So this
/// runs the export both ways over the same workspace and compares the
/// published path to the bytes behind it, which is all a pass ever uses.
@WritingWorkspaceFiles
struct WorkspaceExportRecordTests {
    private func makeWorkspace(in libraryRoot: URL, writingID: String = "w1") throws {
        let workspace = LampWritingWorkspace.url(
            libraryRootURL: libraryRoot, writingID: writingID
        )
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        let revisions = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        let skill = WorkspaceSkillStore.catalogDirectory(in: libraryRoot)
            .appendingPathComponent("a-custom-skill", isDirectory: true)
        for directory in [workspace, context, revisions, skill] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("# A custom skill".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        try Data(#"["a-custom-skill"]"#.utf8)
            .write(to: WorkspaceSkillStore.selectionURL(in: workspace))
        try Data("# The draft\n\nAs it stands.".utf8)
            .write(to: workspace.appendingPathComponent("draft.md"))
        try Data("The outline.".utf8)
            .write(to: workspace.appendingPathComponent("outline.md"))
        try Data("A passage gathered.".utf8)
            .write(to: context.appendingPathComponent("passage.md"))
        try Data(#"{"id":"abc","createdAt":1700000000}"#.utf8)
            .write(to: revisions.appendingPathComponent("1700000000-abc.json"))
    }

    /// Both ways, reduced to what a pass uses: the published path, and the
    /// bytes at the URL behind it.
    private func published(
        recording: Bool, from libraryRoot: URL, into scratch: URL
    ) throws -> [String: Data] {
        if recording {
            let record = LampWorkspaceSync.WorkspaceExportRecord()
            try LampWorkspaceSync.exportPortableWorkspaces(
                from: libraryRoot, to: scratch, writingFolder: .perFile, recording: record
            )
            return Dictionary(
                record.placed.compactMap { path, url, _ in
                    (try? Data(contentsOf: url)).map { (path, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: libraryRoot, to: scratch, writingFolder: .perFile
        )
        var found: [String: Data] = [:]
        let prefix = scratch.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(
            at: scratch, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return found }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            found[String(path.dropFirst(prefix.count))] = data
        }
        return found
    }

    @Test func recordingPublishesWhatCopyingPublishes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-export-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let copied = root.appendingPathComponent("copied-library")
        try makeWorkspace(in: copied)
        let byCopying = try published(
            recording: false, from: copied, into: root.appendingPathComponent("scratch-copy")
        )

        // A second library with the same content, since exporting records
        // deletions into the first one's ledger and the two runs must not
        // see each other's bookkeeping.
        let recorded = root.appendingPathComponent("recorded-library")
        try makeWorkspace(in: recorded)
        let byRecording = try published(
            recording: true, from: recorded, into: root.appendingPathComponent("scratch-record")
        )

        #expect(!byCopying.isEmpty)
        #expect(byRecording.keys.sorted() == byCopying.keys.sorted())
        for (path, bytes) in byCopying {
            #expect(byRecording[path] == bytes, "the bytes at \(path)")
        }
        // And the writer's own document is there under the name the phone
        // reads it by. Not `draft.md`: that is a generated name, and it
        // travels as the writing itself rather than as a document.
        #expect(byRecording.keys.contains { $0.hasSuffix("Documents/outline.md") })
        #expect(byRecording.keys.contains { $0.hasSuffix("Revisions/1700000000-abc.json") })
    }

    /// What a writer can rewrite at its path mid-pass is still copied into
    /// the staging directory, because the digest taken at the gather is the
    /// one the upload sends under. What cannot is pointed at where it lives.
    @Test func whatCanChangeUnderAPassIsStagedAndTheRestPointedAt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-export-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        try makeWorkspace(in: library)
        let scratch = root.appendingPathComponent("scratch")

        let record = LampWorkspaceSync.WorkspaceExportRecord()
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: library, to: scratch, writingFolder: .perFile, recording: record
        )

        let placed = Dictionary(
            record.placed.map { ($0.path, $0.url) }, uniquingKeysWith: { first, _ in first }
        )
        // Resolved on both sides: the temporary directory is reached through
        // a symlink (`/var` for `/private/var`), and the enumerator hands
        // back the resolved form while these URLs were built from the
        // unresolved one.
        func sits(_ url: URL, under directory: URL) -> Bool {
            url.resolvingSymlinksInPath().path
                .hasPrefix(directory.resolvingSymlinksInPath().path + "/")
        }
        func recorded(_ suffix: String) throws -> URL {
            try #require(
                placed.first { $0.key.hasSuffix(suffix) }?.value,
                "nothing was published at \(suffix)"
            )
        }

        // A pane or an agent rewrites each of these at its own path while a
        // pass runs, so the plan would be made from bytes nobody holds by
        // the time it publishes — these are snapshots.
        for staged in [
            "Documents/outline.md",
            "Skills/a-custom-skill/SKILL.md",
            "EnabledSkills.json",
        ] {
            #expect(
                sits(try recorded(staged), under: scratch),
                "\(staged) is staged, so what was hashed is what is sent"
            )
        }

        // These cannot be: a revision is written once under a timestamped
        // name, and a context file is content-addressed and read-only.
        for pointed in ["Revisions/1700000000-abc.json", "Context/passage.md"] {
            let url = try recorded(pointed)
            #expect(
                sits(url, under: library),
                "\(pointed) is written once, so the live file is published"
            )
            #expect(!sits(url, under: scratch), "and it is not copied there first")
        }
    }

    /// The export says, per file, whether nothing rewrites it where it sits.
    ///
    /// That claim is what lets a pass keep a digest against the file's
    /// identity for a kind whose other half is staged afresh every pass, and
    /// what lets it refuse to publish a file that has moved under it
    /// (`lamp-bible-core/Documentation/decisions/0011`). It is true of
    /// exactly the files recorded where they live, and false of everything
    /// this export put in the scratch directory — including the two it wrote
    /// there itself, a transcript and the portable ledger, whose paths are
    /// new every pass.
    @Test func theExportSaysWhichFilesAreFixedWhereTheySit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-export-fixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        try makeWorkspace(in: library)
        let scratch = root.appendingPathComponent("scratch")

        // A transcript and a non-empty deletion ledger, which are the two
        // files the export *writes* into the scratch directory rather than
        // copying — and so the two whose claim must be false although their
        // source is nowhere near the scratch directory. Without them in the
        // fixture this test passed whatever they claimed.
        let workspace = LampWritingWorkspace.url(libraryRootURL: library, writingID: "w1")
        try Data(#"{"messages":[]}"#.utf8).write(
            to: AgentChatTranscriptStore.directory(in: workspace)
                .appendingPathComponent("\(AgentChatTranscriptStore.filenamePrefix)test.json")
        )
        // The ledger lists what a workspace held; it names a deletion only
        // once a file it had noted has gone. So: export, remove a document,
        // export again.
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: library, to: root.appendingPathComponent("first"), writingFolder: .perFile,
            recording: LampWorkspaceSync.WorkspaceExportRecord()
        )
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("outline.md"))

        let record = LampWorkspaceSync.WorkspaceExportRecord()
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: library, to: scratch, writingFolder: .perFile, recording: record
        )

        func sits(_ url: URL, under directory: URL) -> Bool {
            url.resolvingSymlinksInPath().path
                .hasPrefix(directory.resolvingSymlinksInPath().path + "/")
        }
        #expect(!record.placed.isEmpty)
        for placed in record.placed {
            // The claim and where the file is are the same question asked
            // twice: a file left where it lives is fixed there, and a copy in
            // the scratch directory never is.
            #expect(
                placed.isFixedAtItsPath == sits(placed.url, under: library),
                "\(placed.path) says \(placed.isFixedAtItsPath)"
            )
            #expect(placed.isFixedAtItsPath != sits(placed.url, under: scratch))
        }
        // Both written files are there to have been asked about, and both
        // say false.
        for written in ["native-chat-test.json", WorkspaceFileLedger.portableFilename] {
            let placed = try #require(
                record.placed.first { $0.path.hasSuffix(written) },
                "nothing was published for \(written)"
            )
            #expect(!placed.isFixedAtItsPath, "\(written) claims to be fixed where it sits")
        }

        // And the candidates carry it through.
        let candidates = try LampSyncLocalFiles.workspaceFiles(
            inLibraryAt: library, stagingIn: root.appendingPathComponent("scratch-2")
        )
        let revision = try #require(
            candidates.first { $0.path.hasSuffix("Revisions/1700000000-abc.json") }
        )
        let context = try #require(
            candidates.first { $0.path.hasSuffix("Context/passage.md") }
        )
        #expect(revision.isFixedAtItsPath)
        #expect(context.isFixedAtItsPath)
        #expect(candidates.contains { !$0.isFixedAtItsPath }, "and not everything claims it")
    }

    /// No two published paths are ever staged to the same file.
    ///
    /// This is the invariant, not a reproduction of the fault: a library on
    /// a **case-sensitive** volume can hold both `Outline.md` and
    /// `outline.md`, while the scratch directory sits on the system volume,
    /// which is not case sensitive — so staging both at their destination
    /// put the second's bytes where the first's should be, and the record
    /// carried both spellings, publishing one document twice under two names
    /// with the other's content. Caught by a Codex review. The suite's own
    /// temporary directory is case insensitive, so the two files cannot be
    /// created here to watch it happen; what holds it is that a staged copy
    /// now goes in a directory named by its published path's digest, which
    /// is unique by construction.
    @Test func noTwoPublishedPathsShareAStagedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-export-case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        // Two workspaces, so the same document and skill names appear twice
        // over — the ordinary way two published paths come to share a
        // filename.
        try makeWorkspace(in: library)
        try makeWorkspace(in: library, writingID: "w2")

        let record = LampWorkspaceSync.WorkspaceExportRecord()
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: library, to: root.appendingPathComponent("scratch"),
            writingFolder: .perFile, recording: record
        )

        var paths: [URL: [String]] = [:]
        for placed in record.placed { paths[placed.url, default: []].append(placed.path) }
        #expect(!record.placed.isEmpty)
        for (url, sharing) in paths {
            #expect(sharing.count == 1, "\(url.lastPathComponent) is published as \(sharing)")
        }
        // And each document is published with its own bytes.
        let outlines = record.placed.filter { $0.path.hasSuffix("Documents/outline.md") }
        #expect(outlines.count == 2)
        for outline in outlines {
            #expect(try Data(contentsOf: outline.url) == Data("The outline.".utf8))
        }

        // The case the volume will not let the export produce, asked of the
        // mapping itself: two published paths differing only in case are
        // staged at two files, and at two that a case-insensitive filesystem
        // also tells apart. Going back to staging at the published path
        // fails this.
        let scratch = root.appendingPathComponent("scratch")
        let upper = LampWorkspaceSync.stagedURL(
            for: "Workspaces/Writings/w1/Documents/Outline.md", under: scratch
        )
        let lower = LampWorkspaceSync.stagedURL(
            for: "Workspaces/Writings/w1/Documents/outline.md", under: scratch
        )
        #expect(upper != lower)
        #expect(upper.path.lowercased() != lower.path.lowercased())
    }

    /// A symlink where the enabled-skills selection should be is not
    /// published — not as itself and not as whatever it points at.
    ///
    /// Copying one left a link in the staging directory that the enumeration
    /// then skipped, because it asked for regular files. Recording its path
    /// instead would have a pass stat it, hash it and send the bytes at the
    /// far end, which can be any file this app can read.
    @Test func aSymlinkedSelectionIsNotPublished() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-export-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        try makeWorkspace(in: library)

        let secret = root.appendingPathComponent("not-for-the-server.txt")
        try Data("The contents of another file entirely.".utf8).write(to: secret)
        let selection = WorkspaceSkillStore.selectionURL(
            in: LampWritingWorkspace.url(libraryRootURL: library, writingID: "w1")
        )
        try FileManager.default.removeItem(at: selection)
        try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: secret)

        let record = LampWorkspaceSync.WorkspaceExportRecord()
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: library, to: root.appendingPathComponent("scratch"),
            writingFolder: .perFile, recording: record
        )

        let secretBytes = try Data(contentsOf: secret)
        #expect(!record.placed.contains { $0.path.hasSuffix("EnabledSkills.json") })
        for placed in record.placed {
            #expect(
                (try? Data(contentsOf: placed.url)) != secretBytes,
                "the bytes published at \(placed.path)"
            )
        }
    }
}
