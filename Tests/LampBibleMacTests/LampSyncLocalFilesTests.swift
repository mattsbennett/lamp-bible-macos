import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

/// Gathering what this Mac holds, in the form the plan reads.
struct LampSyncLocalFilesTests {
    private let webDAV = LampSyncFileRecords.webDAVSource(
        URL(string: "https://dav.example.com/sync/")!
    )

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-local-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func module(
        id: String,
        kind: LampModuleKind,
        at url: URL
    ) -> LampInstalledModuleFile {
        LampInstalledModuleFile(
            module: LampInstalledModule(id: id, kind: kind, name: id),
            fileURL: url
        )
    }

    private func write(_ contents: String, at relativePath: String, in library: URL) throws {
        let url = library.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func writing(id: String, attachment: String) -> LampDevotional {
        let reference = LampDevotionalMediaReference(
            id: "ref-\(attachment)", type: .image, filename: attachment, mimeType: "image/jpeg"
        )
        return LampDevotional(
            id: id,
            moduleID: "personal-devotionals",
            moduleName: "Writing",
            title: "Morning",
            content: "Light on the water.",
            mediaJSON: String(
                decoding: try! JSONEncoder().encode([reference]), as: UTF8.self
            )
        )
    }

    private func write(
        _ contents: String,
        as filename: String,
        for devotionalID: String,
        in library: URL
    ) throws {
        let directory = library
            .appendingPathComponent("Media/Devotionals/\(devotionalID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appendingPathComponent(filename))
    }

    /// The property the phone enforces: it inspects a downloaded module and
    /// refuses one whose identity disagrees with its filename's stem. The
    /// library names its files by a storage key — a hash of the ID — so
    /// publishing on-disk names would fail every import on the phone.
    @Test func aModuleIsPlacedByItsIdentityAndNotByItsFilename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let onDisk = directory.appendingPathComponent("9f86d081884c7d65.lamp")
        try Data("a translation".utf8).write(to: onDisk)

        let placed = LampSyncLocalFiles.installedModules([
            module(id: "KJVs", kind: .translation, at: onDisk),
            module(id: "wsd_greek", kind: .dictionary, at: onDisk),
            module(id: "a-light-to-the-gentiles", kind: .book, at: onDisk),
        ])

        #expect(placed.unplaceable.isEmpty)
        #expect(placed.candidates.map(\.path) == [
            "Translations/KJVs.lamp",
            "Dictionaries/wsd_greek.lamp",
            "Books/a-light-to-the-gentiles.lamp",
        ])
        #expect(placed.candidates.first?.kind == .module(.translations))
        #expect(placed.candidates.first?.url == onDisk)
    }

    @Test func aModuleWhoseIdentityCannotBeAPathIsReportedRatherThanMisplaced() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let onDisk = directory.appendingPathComponent("stored.lamp")
        try Data("x".utf8).write(to: onDisk)

        let placed = LampSyncLocalFiles.installedModules([
            module(id: "../escape", kind: .translation, at: onDisk),
            module(id: "fine", kind: .translation, at: onDisk),
        ])

        #expect(placed.candidates.map(\.path) == ["Translations/fine.lamp"])
        #expect(placed.unplaceable.map(\.path) == ["translation/../escape"])
    }

    /// An installed writing module called `writing` would be published at
    /// `Writing/writing.lamp`, where every writing is, and hide them. It is
    /// kept here and said so, and an installed one called `notes` too.
    @Test func anInstalledModuleNamedForACollectionIsKeptHere() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let onDisk = directory.appendingPathComponent("stored.lamp")
        try Data("x".utf8).write(to: onDisk)

        let placed = LampSyncLocalFiles.installedModules([
            module(id: "writing", kind: .devotional, at: onDisk),
            module(id: "notes", kind: .notes, at: onDisk),
            module(id: "sermons", kind: .devotional, at: onDisk),
        ])

        #expect(placed.candidates.map(\.path) == ["Writing/sermons.lamp"])
        #expect(placed.unplaceable.map(\.path) == ["Writing/writing.lamp", "Notes/notes.lamp"])
    }

    @Test func aPersonalModuleIsPlacedUnderTheIdentityThePhoneUses() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.lamp")

        // The Mac's `personal-notes` is published under the phone's
        // `notes`, so the published stem is the phone's.
        let notes = try LampSyncLocalFiles.personalModuleCandidate(
            remoteModuleID: "notes", kind: .notes, at: url
        )
        #expect(notes.path == "Notes/notes.lamp")

        let highlights = try LampSyncLocalFiles.personalModuleCandidate(
            remoteModuleID: "esvs-highlights", kind: .highlights, at: url
        )
        #expect(highlights.path == "Highlights/esvs-highlights.lamp")
    }

    /// Attachments are immutable at a path and published before the module
    /// that names them.
    @Test func theFilesAWritingEmbedsAreGatheredFromTheLibrary() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        try write("a photograph", as: "sunrise.jpg", for: "writing-1", in: library)

        let found = LampSyncLocalFiles.devotionalMedia(
            for: [writing(id: "writing-1", attachment: "sunrise.jpg")],
            remoteModuleID: LampSyncMacPassLibrary.remoteWritingModuleID,
            inLibraryAt: library
        )

        #expect(found.missing.isEmpty)
        #expect(found.candidates.map(\.path) == ["WritingMedia/writing/writing-1/sunrise.jpg"])
        #expect(found.candidates.first?.kind.isMedia == true, "never merged, written only where absent")
        #expect(try Data(contentsOf: #require(found.candidates.first).url) == Data("a photograph".utf8))
    }

    /// Every writing shares one module file, so withholding over one missing
    /// image would stop them all. And the gap heals by itself: an immutable
    /// path is a predictable one, so if the file comes back a later pass
    /// writes it there and every device's reference resolves.
    @Test func aMissingAttachmentIsReportedWithoutHidingTheOthers() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        try write("kept", as: "kept.jpg", for: "writing-2", in: library)

        let found = LampSyncLocalFiles.devotionalMedia(
            for: [
                writing(id: "writing-1", attachment: "gone.jpg"),
                writing(id: "writing-2", attachment: "kept.jpg"),
            ],
            remoteModuleID: "writing",
            inLibraryAt: library
        )

        #expect(
            found.candidates.map(\.path) == ["WritingMedia/writing/writing-2/kept.jpg"],
            "the bad writing must not hide the good one's attachments"
        )
        #expect(found.missing.map(\.path) == ["WritingMedia/writing/writing-1/gone.jpg"])
    }

    /// A gap the server already covers needs nothing from this device and
    /// resolves everywhere, so saying so would be noise. One in neither place
    /// is a reference nothing will supply, and worth knowing about. Read from
    /// the manifest, never probed.
    @Test func onlyAGapTheServerDoesNotCoverIsWorthReporting() throws {
        let onServer = "WritingMedia/writing/writing-1/elsewhere.jpg"
        let nowhere = "WritingMedia/writing/writing-2/nowhere.jpg"
        var manifest = LampSyncLibraryManifest()
        manifest = try manifest.recordingWrite(onServer, revision: "\"m1\"", replacing: nil, at: 10)

        let missing = [
            LampSyncLocalFiles.Unreadable(path: onServer, reason: "elsewhere"),
            LampSyncLocalFiles.Unreadable(path: nowhere, reason: "nowhere"),
        ]
        let unresolved = LampSyncLocalFiles.unresolved(
            missing, candidates: [], manifest: manifest
        )

        #expect(unresolved.map(\.path) == [nowhere])
    }

    /// Enumerated by running the real exporter into a scratch directory,
    /// because the published shape is not the stored one — a document moves
    /// into `Documents/`, context into `Context/`, and so on. Decks come out
    /// of the same exporter and are skipped here: they are their own kind.
    @Test func workspaceFilesComeOutInTheShapeTheyArePublishedIn() async throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let scratch = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        try write(
            "# Notes toward Sunday",
            at: "AgentWorkspaces/Writing/talk-123/outline.md",
            in: library
        )
        try write(
            "a gathered fact",
            at: "AgentWorkspaces/Writing/talk-123/context/fact.md",
            in: library
        )
        // A deck, which the same exporter also writes.
        let store = LampPresentationDeckStore(rootURL: library)
        try FileManager.default.createDirectory(
            at: store.decksDirectoryURL, withIntermediateDirectories: true
        )
        try Data("a deck".utf8).write(
            to: store.decksDirectoryURL.appendingPathComponent("sunday.lampdeck")
        )

        let found = try await LampSyncLocalFiles.workspaceFiles(
            inLibraryAt: library, stagingIn: scratch
        )

        #expect(found.allSatisfy { $0.kind == .workspaceFile || $0.kind == .writingDocument })
        #expect(found.contains {
            $0.path == "Workspaces/Writing/talk-123/Documents/outline.md" && $0.kind == .writingDocument
        })
        #expect(found.contains { $0.path == "Workspaces/Writing/talk-123/Context/fact.md" })
        #expect(
            !found.contains { $0.path.hasPrefix("Workspaces/Presentations/") },
            "decks and their images are their own kinds, enumerated from the library"
        )
        #expect(
            try Data(contentsOf: #require(
                found.first { $0.path.hasSuffix("Documents/outline.md") }
            ).url) == Data("# Notes toward Sunday".utf8)
        )
    }

    /// A tool's output under a writing's sources is not gathered: the
    /// writer's own files beside it are (`decisions/0023`).
    @Test func atoolsOutputIsNotGatheredButTheFilesBesideItAre() async throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let scratch = library.appendingPathComponent("scratch", isDirectory: true)
        try write("build", at: "AgentWorkspaces/Writing/talk-123/context/deck-build/build.js", in: library)
        try write("{}", at: "AgentWorkspaces/Writing/talk-123/context/deck-build/package.json", in: library)
        try write("lib", at: "AgentWorkspaces/Writing/talk-123/context/deck-build/node_modules/a/index.js", in: library)
        try write("pyc", at: "AgentWorkspaces/Writing/talk-123/context/tool/__pycache__/m.pyc", in: library)

        let found = try await LampSyncLocalFiles.workspaceFiles(inLibraryAt: library, stagingIn: scratch)
        let paths = Set(found.map(\.path))
        #expect(paths.contains("Workspaces/Writing/talk-123/Context/deck-build/build.js"))
        #expect(paths.contains("Workspaces/Writing/talk-123/Context/deck-build/package.json"))
        #expect(!paths.contains { $0.contains("/node_modules/") || $0.contains("/__pycache__/") })
    }

    /// With workspace sync off, the gather offers a writing's documents and
    /// nothing else of its workspace.
    @Test func withWorkspaceSyncOffOnlyDocumentsAreGathered() async throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let scratch = library.appendingPathComponent("scratch", isDirectory: true)
        try write("# Outline", at: "AgentWorkspaces/Writing/talk-123/outline.md", in: library)
        try write("a fact", at: "AgentWorkspaces/Writing/talk-123/context/fact.md", in: library)

        let found = try await LampSyncLocalFiles.workspaceFiles(
            inLibraryAt: library, stagingIn: scratch, includingWorkspaceFiles: false
        )
        #expect(found.map(\.kind) == [.writingDocument])
        #expect(found.first?.path == "Workspaces/Writing/talk-123/Documents/outline.md")
    }

    /// A library this Mac has synced before keeps syncing its workspaces;
    /// a new one starts without, and the choice, once made, is kept.
    @Test func workspaceSyncDefaultsByWhetherThisMacHasSyncedBefore() throws {
        let suite = "lamp-workspace-sync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!WorkspaceFilesSync.resolve(in: defaults, hasCompletedAPass: false))
        #expect(!WorkspaceFilesSync.resolve(in: defaults, hasCompletedAPass: true), "decided once")
        defaults.removeObject(forKey: WorkspaceFilesSync.key)
        #expect(WorkspaceFilesSync.resolve(in: defaults, hasCompletedAPass: true))
        defaults.set(false, forKey: WorkspaceFilesSync.key)
        #expect(!WorkspaceFilesSync.resolve(in: defaults, hasCompletedAPass: true), "the reader's choice stands")
    }

    /// A book's pictures are not inside its module: `media_json` holds only
    /// their metadata, so these files are the library's only copy. Gathered
    /// from every root the reader looks in, in its order, so what is
    /// published is what the reader would show.
    @Test func aBooksPicturesAreGatheredFromEveryRootTheReaderLooksIn() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        // `Media/Modules` wins over `Media/Books` for the same relative path,
        // as it does for the reader (`LampBookMediaFiles`).
        try write("preferred", at: "Media/Modules/atonement/plates/one.jpg", in: library)
        try write("shadowed", at: "Media/Books/atonement/plates/one.jpg", in: library)
        try write("only here", at: "Media/Books/atonement/two.jpg", in: library)
        try write("legacy", at: "Modules/atonement/media/three.jpg", in: library)
        try write("another book", at: "Media/Books/ignored/four.jpg", in: library)

        let found = LampSyncLocalFiles.bookMedia(
            forBookModuleIDs: ["atonement"], inLibraryAt: library
        )

        #expect(found.unplaceable.isEmpty)
        #expect(found.candidates.map(\.path) == [
            "BookMedia/atonement/plates/one.jpg",
            "BookMedia/atonement/two.jpg",
            "BookMedia/atonement/three.jpg",
        ])
        #expect(found.candidates.allSatisfy { $0.kind == .bookMedia })
        #expect(
            try Data(contentsOf: #require(found.candidates.first).url) == Data("preferred".utf8),
            "the root the reader checks first is the copy that is published"
        )
        // A book nobody asked about stays where it is.
        #expect(!found.candidates.contains { $0.path.contains("ignored") })
    }

    /// A book `Study` beside a commentary `study`: only `Media/Books/Study`
    /// is the book's for certain, since no other kind of module writes there.
    @Test func aBookSharingItsIDPublishesOnlyFromItsOwnFolder() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        try write("the book's", at: "Media/Books/Study/map.jpg", in: library)
        try write("the commentary's", at: "Media/Modules/study/notes.jpg", in: library)

        let found = LampSyncLocalFiles.bookMedia(
            books: ["Study"], otherModules: ["study"], remotePaths: [], inLibraryAt: library
        )

        #expect(found.candidates.map(\.path) == ["BookMedia/Study/map.jpg"])
    }

    @Test func aLibraryWithNoBookPicturesYieldsNothing() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let found = LampSyncLocalFiles.bookMedia(
            forBookModuleIDs: ["atonement"], inLibraryAt: library
        )
        #expect(found.candidates.isEmpty)
        #expect(found.unplaceable.isEmpty)
    }

    /// The deck folder also holds the deletion ledger, which must never be
    /// published as a file: it is merged in the settings bundle, and as a file
    /// it would be won instead — two Macs deleting different decks would
    /// overwrite each other's record and a deleted deck would come back.
    @Test func decksAndTheirImagesArePublishedButTheLedgerIsNot() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let store = LampPresentationDeckStore(rootURL: library)
        try FileManager.default.createDirectory(
            at: store.assetsDirectoryURL, withIntermediateDirectories: true
        )
        for (name, directory) in [
            ("sunday-evening.lampdeck", store.decksDirectoryURL),
            ("deleted-decks.json", store.decksDirectoryURL),
            ("notes.txt", store.decksDirectoryURL),
            ("a1b2c3.jpg", store.assetsDirectoryURL),
        ] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }

        let found = LampSyncLocalFiles.decks(inLibraryAt: library)

        #expect(found.unplaceable.isEmpty)
        #expect(found.candidates.map(\.path) == [
            "Workspaces/Presentations/sunday-evening.lampdeck",
            "Workspaces/Presentations/Assets/a1b2c3.jpg",
        ])
        #expect(found.candidates.map(\.kind) == [.deck, .deckAsset])
        // And the layout agrees that the ledger is outside the library.
        #expect(LampSyncFolderLayout.kind(of: "Workspaces/Presentations/deleted-decks.json") == nil)
    }

    /// The per-file pass gathers decks from the library itself, so the
    /// staging the workspace exporter does must not carry them: it used to
    /// copy every deck and every deck image into a scratch directory on
    /// every pass, for `workspaceFiles` to skip.
    @WritingWorkspaceFiles
    @Test func theWorkspaceStagingDoesNotCarryDecks() async throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let scratch = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = LampPresentationDeckStore(rootURL: library)
        try FileManager.default.createDirectory(
            at: store.assetsDirectoryURL, withIntermediateDirectories: true
        )
        try Data("a deck".utf8).write(
            to: store.decksDirectoryURL.appendingPathComponent("sunday.lampdeck")
        )
        try Data("an image".utf8).write(
            to: store.assetsDirectoryURL.appendingPathComponent("a1b2c3.jpg")
        )

        _ = try LampSyncLocalFiles.workspaceFiles(inLibraryAt: library, stagingIn: scratch)

        let staged = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil)
        let paths = (staged?.compactMap { ($0 as? URL)?.lastPathComponent } ?? [])
        #expect(!paths.contains("sunday.lampdeck"))
        #expect(!paths.contains("a1b2c3.jpg"))
    }

    @Test func aLibraryWithNoDecksYieldsNothingRatherThanFailing() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let found = LampSyncLocalFiles.decks(inLibraryAt: library)
        #expect(found.candidates.isEmpty)
        #expect(found.unplaceable.isEmpty)
    }

    // MARK: - Every kind of content

    /// Which gatherer produces each kind of file, and the proof that it does.
    ///
    /// Exhaustive on purpose, so a kind added to `LampSyncFileKind` or
    /// `LampSyncContentKind` stops this compiling until somebody says what
    /// gathers it. The cost of not saying is the whole of the bug this
    /// session chased: a client that does not claim a path it holds fetches
    /// the file again on every pass, for ever, and never carries out a
    /// deletion made on another device
    /// (`LampSyncUnclaimedInstalls`). A kind with no gatherer here is that,
    /// for every file of that kind at once.
    ///
    /// `LibrarySyncController.gather()` is where these are called, and the
    /// one thing this cannot check is that it still calls them all. What it
    /// does check is that nothing in the layout is without a home.
    @Test func everyKindOfSyncedFileIsGatheredFromSomewhere() async throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }

        // One module of every kind, each with its file where the library
        // keeps it, and the pictures and attachments of two of them.
        var modules: [LampInstalledModuleFile] = []
        for kind in LampModuleKind.allCases {
            let url = library.appendingPathComponent("Modules/\(kind.rawValue).lamp")
            try write("a \(kind.rawValue)", at: "Modules/\(kind.rawValue).lamp", in: library)
            // Not named for its kind: `notes` is the notes collection's ID,
            // which an installed module never publishes under.
            modules.append(module(id: "installed-\(kind.rawValue)", kind: kind, at: url))
        }
        try write("a picture", at: "Media/Books/atonement/plates/one.jpg", in: library)
        try write("an attachment", as: "sunrise.jpg", for: "w1", in: library)

        let store = LampPresentationDeckStore(rootURL: library)
        try FileManager.default.createDirectory(
            at: store.assetsDirectoryURL, withIntermediateDirectories: true
        )
        try Data("a deck".utf8).write(
            to: store.decksDirectoryURL.appendingPathComponent("sunday.lampdeck")
        )
        try Data("an image".utf8).write(
            to: store.assetsDirectoryURL.appendingPathComponent("a1b2c3.jpg")
        )
        try write(
            "Notes on Isaiah.",
            at: "AgentWorkspaces/Writing/advent/context/isaiah.md",
            in: library
        )
        try write("An outline.", at: "AgentWorkspaces/Writing/advent/outline.md", in: library)

        let staging = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let gathered =
            LampSyncLocalFiles.installedModules(modules).candidates
            + LampSyncLocalFiles.devotionalMedia(
                for: [writing(id: "w1", attachment: "sunrise.jpg")],
                remoteModuleID: "writing",
                inLibraryAt: library
            ).candidates
            + LampSyncLocalFiles.bookMedia(
                forBookModuleIDs: ["atonement"], inLibraryAt: library
            ).candidates
            + LampSyncLocalFiles.decks(inLibraryAt: library).candidates
            + (try await LampSyncLocalFiles.workspaceFiles(inLibraryAt: library, stagingIn: staging))

        let found = Set(gathered.map(\.kind))
        let kinds: [LampSyncFileKind] =
            LampSyncContentKind.allCases.map { .module($0) }
                + [.devotionalMedia, .bookMedia, .deck, .deckAsset, .workspaceFile, .writingDocument]
        for kind in kinds {
            #expect(found.contains(kind), "nothing here gathers \(kind)")
        }
        // And every path produced is one the layout places, which is what
        // keeps a gatherer from inventing a path no other client reads.
        for candidate in gathered {
            #expect(
                LampSyncFolderLayout.kind(of: candidate.path) == candidate.kind,
                "\(candidate.path) is not where a \(candidate.kind) goes"
            )
        }
    }
}
