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

    @Test func aPersonalModuleIsPlacedUnderTheIdentityThePhoneUses() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.lamp")

        // The adapter rewrites the Mac's `personal-notes` to the phone's
        // `notes` on the way out, so the published stem is the phone's.
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
        #expect(found.candidates.map(\.path) == ["DevotionalMedia/devotionals/writing-1/sunrise.jpg"])
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
            remoteModuleID: "devotionals",
            inLibraryAt: library
        )

        #expect(
            found.candidates.map(\.path) == ["DevotionalMedia/devotionals/writing-2/kept.jpg"],
            "the bad writing must not hide the good one's attachments"
        )
        #expect(found.missing.map(\.path) == ["DevotionalMedia/devotionals/writing-1/gone.jpg"])
    }

    /// A gap the server already covers needs nothing from this device and
    /// resolves everywhere, so saying so would be noise. One in neither place
    /// is a reference nothing will supply, and worth knowing about. Read from
    /// the manifest, never probed.
    @Test func onlyAGapTheServerDoesNotCoverIsWorthReporting() throws {
        let onServer = "DevotionalMedia/devotionals/writing-1/elsewhere.jpg"
        let nowhere = "DevotionalMedia/devotionals/writing-2/nowhere.jpg"
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
    @Test func workspaceFilesComeOutInTheShapeTheyArePublishedIn() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let scratch = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        try write(
            "# Notes toward Sunday",
            at: "AgentWorkspaces/Devotionals/talk-123/outline.md",
            in: library
        )
        try write(
            "a gathered fact",
            at: "AgentWorkspaces/Devotionals/talk-123/context/fact.md",
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

        let found = try LampSyncLocalFiles.workspaceFiles(
            inLibraryAt: library, stagingIn: scratch
        )

        #expect(found.allSatisfy { $0.kind == .workspaceFile })
        #expect(found.contains { $0.path == "Workspaces/Devotionals/talk-123/Documents/outline.md" })
        #expect(found.contains { $0.path == "Workspaces/Devotionals/talk-123/Context/fact.md" })
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

    /// A book's pictures are not inside its module: `media_json` holds only
    /// their metadata, so these files are the library's only copy. Gathered
    /// from every root the reader looks in, in its order, so what is
    /// published is what the reader would show.
    @Test func aBooksPicturesAreGatheredFromEveryRootTheReaderLooksIn() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        // `Media/Modules` wins over `Media/Books` for the same relative path,
        // as it does in BookReaderMediaResolver.
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

    @Test func aLibraryWithNoDecksYieldsNothingRatherThanFailing() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let found = LampSyncLocalFiles.decks(inLibraryAt: library)
        #expect(found.candidates.isEmpty)
        #expect(found.unplaceable.isEmpty)
    }
}
