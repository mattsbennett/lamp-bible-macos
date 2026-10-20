import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// The Mac's own memory of what it uploaded and installed. Design B decides
/// whether to upload by comparing a file with this client's last upload rather
/// than with another client's bytes, so these records are the only place that
/// answer lives — and getting them wrong is not visible as an error, it is
/// visible as a library that re-uploads itself or as duplicate modules.
struct LampSyncFileRecordsTests {
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let webDAV = LampSyncFileRecords.webDAVSource(
        URL(string: "https://dav.example.com/sync/")!
    )

    @Test func recordsSurviveARoundTripThroughTheLibrary() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }

        var records = LampSyncFileRecords()
        records.recordUpload(
            "Notes/notes.lamp", in: webDAV,
            digest: "sha-notes", revision: "\"notes-v2\"",
            size: 2_048, modifiedAt: 1_800_000_000
        )
        records.setHighlightModuleID("psalms-set", forSet: "set-1", in: webDAV)
        try records.save(toLibraryAt: library)

        let reloaded = LampSyncFileRecords.load(fromLibraryAt: library)
        #expect(reloaded == records)
        #expect(reloaded.record("Notes/notes.lamp", in: webDAV)?.uploadedDigest == "sha-notes")
        #expect(reloaded.highlightModuleID(forSet: "set-1", in: webDAV) == "psalms-set")
    }

    /// Local state must never reach the server. It is kept in a dot-prefixed
    /// file for that reason, and archive creation skips dot-prefixed
    /// components — proved here against the real archive builder rather than
    /// by trusting the filename.
    @Test func theRecordsFileCannotTravelInAnArchive() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }

        var records = LampSyncFileRecords()
        records.recordUpload("Notes/notes.lamp", in: webDAV, digest: "d", revision: "r")
        try records.save(toLibraryAt: library)
        try Data("a real payload".utf8).write(
            to: library.appendingPathComponent("manifest.json")
        )

        let archive = try LampSyncArchive.create(from: library)
        #expect(archive.entries.map(\.path) == ["manifest.json"])
    }

    @Test func eachSourceKeepsItsOwnRecordsAndCanBeDiscardedAlone() throws {
        let folder = LampSyncFileRecords.folderSource(URL(fileURLWithPath: "/Users/x/Lamp"))
        var records = LampSyncFileRecords()
        records.recordUpload("Notes/notes.lamp", in: webDAV, digest: "web", revision: "\"w1\"")
        records.recordUpload("Notes/notes.lamp", in: folder, digest: "fold", revision: "sha256:ff")

        // A revision from one provider means nothing in the other's namespace.
        #expect(records.record("Notes/notes.lamp", in: webDAV)?.uploadedDigest == "web")
        #expect(records.record("Notes/notes.lamp", in: folder)?.uploadedDigest == "fold")

        records.removeSource(folder)
        #expect(records.record("Notes/notes.lamp", in: folder) == nil)
        #expect(records.record("Notes/notes.lamp", in: webDAV)?.uploadedDigest == "web")
    }

    @Test func aFileThisClientHasNeverUploadedCountsAsChanged() {
        var records = LampSyncFileRecords()
        // No record at all: the plan must not read this as "already uploaded"
        // and skip it, nor as grounds to write over a server copy never seen.
        #expect(records.changedSinceUpload("Translations/kjv.lamp", in: webDAV, digest: "a"))

        records.recordUpload("Translations/kjv.lamp", in: webDAV, digest: "a", revision: "\"v1\"")
        #expect(!records.changedSinceUpload("Translations/kjv.lamp", in: webDAV, digest: "a"))
        #expect(records.changedSinceUpload("Translations/kjv.lamp", in: webDAV, digest: "b"))
    }

    @Test func aWrittenRevisionStaysPendingUntilABundleNamesIt() {
        var records = LampSyncFileRecords()
        records.recordUpload("Notes/notes.lamp", in: webDAV, digest: "d1", revision: "\"v1\"")

        // A pass writes its files, then makes one bundle update. Until that
        // update lands, the write is real but unrecorded — and it is still the
        // newest thing this client knows, so it is what to plan against.
        let pending = records.record("Notes/notes.lamp", in: webDAV)
        #expect(pending?.pendingRevision == "\"v1\"")
        #expect(pending?.installedRevision == nil)
        #expect(pending?.effectiveRevision == "\"v1\"")

        records.confirmRecorded(["Notes/notes.lamp": "\"v1\""], in: webDAV)
        let confirmed = records.record("Notes/notes.lamp", in: webDAV)
        #expect(confirmed?.pendingRevision == nil)
        #expect(confirmed?.installedRevision == "\"v1\"")
    }

    @Test func aBundleDoesNotConfirmAWriteMadeAfterItWasBuilt() {
        var records = LampSyncFileRecords()
        records.recordUpload("Notes/notes.lamp", in: webDAV, digest: "d1", revision: "\"v1\"")
        // The file was written again before the bundle naming v1 was applied.
        records.recordUpload("Notes/notes.lamp", in: webDAV, digest: "d2", revision: "\"v2\"")

        records.confirmRecorded(["Notes/notes.lamp": "\"v1\""], in: webDAV)
        let record = records.record("Notes/notes.lamp", in: webDAV)
        #expect(record?.pendingRevision == "\"v2\"", "v2 is still unrecorded and must stay pending")
        #expect(record?.installedRevision == nil)
    }

    @Test func installingAFileClearsWhatThisClientHadUploaded() {
        var records = LampSyncFileRecords()
        records.recordUpload("Notes/notes.lamp", in: webDAV, digest: "mine", revision: "\"v1\"")
        records.recordInstall("Notes/notes.lamp", in: webDAV, revision: "\"v2\"")

        let record = records.record("Notes/notes.lamp", in: webDAV)
        #expect(record?.installedRevision == "\"v2\"")
        #expect(record?.uploadedDigest == nil, "an imported file has no last upload from here")
        // So the next pass compares by value and republishes this client's own
        // encoding, rather than believing the imported bytes were its own.
        #expect(records.changedSinceUpload("Notes/notes.lamp", in: webDAV, digest: "mine"))
    }

    @Test func seedingFillsOnlyWhatIsMissing() {
        var records = LampSyncFileRecords()
        records.setHighlightModuleID("learned-from-server", forSet: "set-1", in: webDAV)
        records.seedHighlightModuleIDs(
            ["set-1": "stale-default", "set-2": "from-defaults"], in: webDAV
        )

        #expect(records.highlightModuleID(forSet: "set-1", in: webDAV) == "learned-from-server")
        #expect(records.highlightModuleID(forSet: "set-2", in: webDAV) == "from-defaults")
    }

    @Test func anUnchangedFileNeedNotBeReadAgain() {
        var records = LampSyncFileRecords()
        #expect(records.needsDigest("Translations/kjv.lamp", in: webDAV, size: 10, modifiedAt: 1))

        records.recordUpload(
            "Translations/kjv.lamp", in: webDAV, digest: "a", revision: "\"v1\"",
            size: 10, modifiedAt: 1
        )
        #expect(!records.needsDigest("Translations/kjv.lamp", in: webDAV, size: 10, modifiedAt: 1))
        #expect(records.needsDigest("Translations/kjv.lamp", in: webDAV, size: 11, modifiedAt: 1))
        #expect(records.needsDigest("Translations/kjv.lamp", in: webDAV, size: 10, modifiedAt: 2))
        #expect(records.needsDigest("Translations/kjv.lamp", in: webDAV, size: nil, modifiedAt: nil))
    }

    @Test func damagedOrNewerRecordsStartFreshRatherThanFailing() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        let url = LampSyncFileRecords.url(inLibraryAt: library)

        try Data("{ not json".utf8).write(to: url)
        #expect(LampSyncFileRecords.load(fromLibraryAt: library).sources.isEmpty)

        // Every record here can be rebuilt by comparing with the server, so a
        // newer format costs one re-comparison rather than a refusal to sync.
        try Data(#"{"formatVersion":99,"sources":{}}"#.utf8).write(to: url)
        #expect(LampSyncFileRecords.load(fromLibraryAt: library).sources.isEmpty)
    }

    @Test func aLocalIsBuiltInTheFormThePlanReads() {
        var records = LampSyncFileRecords()
        records.recordUpload("Notes/notes.lamp", in: webDAV, digest: "d1", revision: "\"v1\"")

        let unchanged = records.local("Notes/notes.lamp", in: webDAV, digest: "d1", savedAt: 42)
        #expect(unchanged.path == "Notes/notes.lamp")
        #expect(!unchanged.changedSinceUpload)
        #expect(unchanged.lastRevision == "\"v1\"")
        #expect(unchanged.savedAt == 42)

        let edited = records.local("Notes/notes.lamp", in: webDAV, digest: "d2", savedAt: 43)
        #expect(edited.changedSinceUpload)
    }
}
