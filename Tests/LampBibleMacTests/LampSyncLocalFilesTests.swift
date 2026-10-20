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

    @Test func eachCandidateIsDigestedAndAnUnreadableOneIsReported() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let present = directory.appendingPathComponent("present.lamp")
        try Data("bytes".utf8).write(to: present)
        let absent = directory.appendingPathComponent("absent.lamp")

        let described = LampSyncLocalFiles.describe([
            .init(path: "Translations/present.lamp", kind: .module(.translations), url: present),
            .init(path: "Translations/absent.lamp", kind: .module(.translations), url: absent),
        ])

        #expect(described.files.map(\.path) == ["Translations/present.lamp"])
        #expect(
            described.files.first?.digest == LampSyncContentRevision.digest(for: Data("bytes".utf8))
        )
        // Reported rather than dropped: a pass that publishes a shorter
        // library without saying so is how a file goes missing quietly.
        #expect(described.unreadable.map(\.path) == ["Translations/absent.lamp"])
    }

    /// A file is digested every pass. An earlier version of this skipped the
    /// read when size and modification date matched what was recorded, which
    /// would have silently never uploaded a file replaced at the same size
    /// with its date preserved — a restore, `cp -p`, `rsync -t`.
    @Test func aReplacedFileIsSeenEvenWithItsSizeAndDatePreserved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("module.lamp")
        try Data("aaaaa".utf8).write(to: url)
        let date = try #require(
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )

        let candidate = LampSyncLocalFiles.Candidate(
            path: "Translations/module.lamp", kind: .module(.translations), url: url
        )
        let before = LampSyncLocalFiles.describe([candidate]).files.first?.digest

        try Data("bbbbb".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
        let after = LampSyncLocalFiles.describe([candidate]).files.first?.digest

        #expect(before != nil)
        #expect(before != after, "the same size and date must not hide different bytes")
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
    /// that names them. A missing one stops the pass rather than being
    /// reported, because a writing published without its picture is worse
    /// than a pass that did not run.
    @Test func theFilesAWritingEmbedsAreGatheredFromTheLibrary() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let attachments = library
            .appendingPathComponent("Media/Devotionals/writing-1", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("a photograph".utf8).write(
            to: attachments.appendingPathComponent("sunrise.jpg")
        )
        let reference = LampDevotionalMediaReference(
            id: "m1", type: .image, filename: "sunrise.jpg", mimeType: "image/jpeg"
        )
        let writing = LampDevotional(
            id: "writing-1",
            moduleID: "personal-devotionals",
            moduleName: "Writing",
            title: "Morning",
            content: "Light on the water.",
            mediaJSON: String(decoding: try JSONEncoder().encode([reference]), as: UTF8.self)
        )

        let found = try LampSyncLocalFiles.devotionalMedia(
            for: [writing],
            remoteModuleID: LampSyncMacPassLibrary.remoteWritingModuleID,
            inLibraryAt: library
        )

        #expect(found.map(\.path) == ["DevotionalMedia/devotionals/writing-1/sunrise.jpg"])
        #expect(found.first?.kind == .devotionalMedia)
        #expect(found.first?.kind.isMedia == true, "never merged, written only where absent")
        #expect(try Data(contentsOf: #require(found.first).url) == Data("a photograph".utf8))
    }

    @Test func aMissingAttachmentStopsThePass() throws {
        let library = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let reference = LampDevotionalMediaReference(
            id: "m1", type: .image, filename: "gone.jpg", mimeType: "image/jpeg"
        )
        let writing = LampDevotional(
            id: "writing-1",
            moduleID: "personal-devotionals",
            moduleName: "Writing",
            title: "Morning",
            content: "Light on the water.",
            mediaJSON: String(decoding: try JSONEncoder().encode([reference]), as: UTF8.self)
        )

        #expect(throws: (any Error).self) {
            try LampSyncLocalFiles.devotionalMedia(
                for: [writing], remoteModuleID: "devotionals", inLibraryAt: library
            )
        }
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

    @Test func localsCarryWhatThisClientLastUploaded() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unchanged = directory.appendingPathComponent("unchanged.lamp")
        let edited = directory.appendingPathComponent("edited.lamp")
        try Data("same".utf8).write(to: unchanged)
        try Data("new".utf8).write(to: edited)

        var records = LampSyncFileRecords()
        records.recordUpload(
            "Translations/unchanged.lamp", in: webDAV,
            digest: LampSyncContentRevision.digest(for: Data("same".utf8)),
            revision: "\"v1\""
        )
        records.recordUpload(
            "Translations/edited.lamp", in: webDAV,
            digest: LampSyncContentRevision.digest(for: Data("old".utf8)),
            revision: "\"v2\""
        )

        let described = LampSyncLocalFiles.describe([
            .init(path: "Translations/unchanged.lamp", kind: .module(.translations), url: unchanged),
            .init(path: "Translations/edited.lamp", kind: .module(.translations), url: edited),
        ])
        let locals = LampSyncLocalFiles.locals(described.files, records: records, source: webDAV)

        #expect(locals.count == 2)
        #expect(locals.first?.changedSinceUpload == false)
        #expect(locals.first?.lastRevision == "\"v1\"")
        #expect(locals.last?.changedSinceUpload == true)
    }
}
