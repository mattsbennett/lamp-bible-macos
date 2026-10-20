import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// The pass is responsible for the *order* of a sync and for what it records.
/// What each file deserves is core's plan, and what each file contains is the
/// library's; both are stubbed here so the ordering rules can be asserted on
/// their own. Each one, got wrong, loses data somewhere other than where the
/// mistake is.
struct LampSyncBundlePassTests {
    private let source = LampSyncFileRecords.webDAVSource(
        URL(string: "https://dav.example.com/sync/")!
    )
    private let bundlePath = LampSyncFolderLayout.bundlePath

    // MARK: - Fixtures

    private func makeFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-pass-\(UUID().uuidString).lamp")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func local(_ path: String, _ url: URL, _ contents: String) -> LampSyncLocalFile {
        LampSyncLocalFile(
            path: path,
            kind: LampSyncFolderLayout.kind(of: path) ?? .module(.translations),
            url: url,
            digest: LampSyncContentRevision.digest(for: Data(contents.utf8))
        )
    }

    /// A library already on Design B, holding one module at `revision`.
    private func seeded(
        path: String,
        revision: String,
        deletedAt: Int64? = nil
    ) throws -> FakeStore {
        var manifest = LampSyncLibraryManifest()
        manifest = try manifest.recordingWrite(path, revision: revision, replacing: nil, at: 1_000)
        if let deletedAt {
            manifest = try manifest.removing(path, at: deletedAt, revision: revision)
        }
        var bundle = LampSyncSettingsBundle()
        bundle.manifest = manifest
        let store = FakeStore()
        store.bodies[bundlePath] = try bundle.encoded()
        store.revisions[bundlePath] = "\"bundle-1\""
        store.bodies[path] = Data("remote".utf8)
        store.revisions[path] = revision
        store.operations.removeAll()
        return store
    }

    // MARK: - Tests

    /// A pass on an untouched library must write the bundle before any file.
    /// Its own files are what make the next read call the library an earlier
    /// one, so a pass that uploaded first would be told `notMigrated` by its
    /// own closing update, for ever.
    @Test func afreshLibraryIsClaimedBeforeAnyFileIsWritten() async throws {
        let store = FakeStore()
        let url = try makeFile("a translation")
        defer { try? FileManager.default.removeItem(at: url) }
        var records = LampSyncFileRecords()

        let outcome = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [local("Translations/KJVs.lamp", url, "a translation")],
            deletedLocally: [:],
            records: &records
        )

        #expect(outcome.uploaded == ["Translations/KJVs.lamp"])
        let writes = store.operations.filter { $0.hasPrefix("write ") }
        #expect(writes.first == "write \(bundlePath)", "the bundle is claimed first")
        #expect(writes.contains("write Translations/KJVs.lamp"))
        #expect(
            writes.firstIndex(of: "write \(bundlePath)")! < writes.firstIndex(of: "write Translations/KJVs.lamp")!
        )
    }

    /// Every write, tombstone and adoption goes into one update. The bundle is
    /// one small object every device contends for, and `update`'s retry is
    /// bounded, so a pass that updated per file would spend that budget on
    /// itself.
    @Test func onePassMakesOneBundleUpdate() async throws {
        let store = try seeded(path: "Notes/notes.lamp", revision: "\"notes-1\"")
        let url = try makeFile("my notes")
        defer { try? FileManager.default.removeItem(at: url) }
        var records = LampSyncFileRecords()
        records.recordInstall("Notes/notes.lamp", in: source, revision: "\"notes-1\"")

        _ = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [local("Notes/notes.lamp", url, "my notes")],
            deletedLocally: [:],
            records: &records
        )

        #expect(store.operations.filter { $0 == "write \(bundlePath)" }.count == 1)
    }

    /// Bytes may only go after the bundle says they were deleted. Reaped
    /// first, a missing file reads to every other device as a member nobody
    /// has uploaded yet — so another device would publish it again.
    ///
    /// A file deleted here is tombstoned and reaped in the same pass, so the
    /// order inside one pass is what matters.
    @Test func aFileIsReapedOnlyAfterTheBundleRecordsItsDeletion() async throws {
        let store = try seeded(path: "Translations/old.lamp", revision: "\"old-1\"")
        var records = LampSyncFileRecords()
        records.recordInstall("Translations/old.lamp", in: source, revision: "\"old-1\"")

        let outcome = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [],
            deletedLocally: ["Translations/old.lamp": 1_900],
            records: &records
        )

        #expect(outcome.tombstoned == ["Translations/old.lamp"])
        #expect(outcome.reaped == ["Translations/old.lamp"])
        let bundleWrite = try #require(store.operations.lastIndex(of: "write \(bundlePath)"))
        let delete = try #require(store.operations.firstIndex(of: "delete Translations/old.lamp"))
        #expect(bundleWrite < delete, "the deletion is recorded before the bytes go")
        #expect(records.record("Translations/old.lamp", in: source) == nil)
    }

    /// A written revision is this client's newest knowledge even before any
    /// manifest names it, so a pass that dies in between can be recovered by
    /// the next one rather than re-uploading.
    @Test func anUploadIsPendingUntilTheBundleConfirmsIt() async throws {
        let store = FakeStore()
        store.revisionAfterWrite = "\"written-1\""
        let url = try makeFile("fresh")
        defer { try? FileManager.default.removeItem(at: url) }
        var records = LampSyncFileRecords()

        _ = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [local("Translations/new.lamp", url, "fresh")],
            deletedLocally: [:],
            records: &records
        )

        let record = try #require(records.record("Translations/new.lamp", in: source))
        #expect(record.installedRevision == "\"written-1\"", "confirmed by this pass's own bundle")
        #expect(record.pendingRevision == nil)
        #expect(record.uploadedDigest == LampSyncContentRevision.digest(for: Data("fresh".utf8)))
    }

    /// One file the server refuses must not cost the rest of the pass. A
    /// refusal is usually another device having written first, which the next
    /// pass plans again from whatever won.
    @Test func aRefusedUploadIsReportedAndTheRestOfThePassContinues() async throws {
        let store = FakeStore()
        store.refusedWrites = ["Translations/refused.lamp"]
        let refused = try makeFile("refused")
        let accepted = try makeFile("accepted")
        defer {
            try? FileManager.default.removeItem(at: refused)
            try? FileManager.default.removeItem(at: accepted)
        }
        var records = LampSyncFileRecords()

        let outcome = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [
                local("Translations/refused.lamp", refused, "refused"),
                local("Translations/accepted.lamp", accepted, "accepted"),
            ],
            deletedLocally: [:],
            records: &records
        )

        #expect(outcome.uploaded == ["Translations/accepted.lamp"])
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.hasPrefix("Translations/refused.lamp") == true)
        #expect(records.record("Translations/refused.lamp", in: source) == nil)
    }

    /// The Mac merges personal content in one staged transaction, not file by
    /// file, and the transaction rewrites local content — so what gets
    /// published is what it produced, never what was digested before it ran.
    @Test func aMergeIsOneCallAndItsResultIsWhatGetsPublished() async throws {
        let store = try seeded(path: "Notes/notes.lamp", revision: "\"notes-2\"")
        let stale = try makeFile("mine, before merging")
        let merged = try makeFile("mine and theirs")
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: merged)
        }
        let library = StubLibrary()
        library.reconciled = { _ in ["Notes/notes.lamp": merged] }
        var records = LampSyncFileRecords()
        // Changed here since this client's upload, and moved on the server too.
        records.recordUpload(
            "Notes/notes.lamp", in: source, digest: "an older digest", revision: "\"notes-1\""
        )

        let outcome = try await LampSyncBundlePass(
            store: store, library: library, source: source, now: { 2_000 }
        ).run(
            local: [local("Notes/notes.lamp", stale, "mine, before merging")],
            deletedLocally: [:],
            records: &records
        )

        #expect(outcome.reconciled == ["Notes/notes.lamp"])
        #expect(library.reconcileCalls == 1, "one transaction for the whole group")
        #expect(outcome.uploaded == ["Notes/notes.lamp"])
        #expect(store.bodies["Notes/notes.lamp"] == Data("mine and theirs".utf8))
        #expect(
            records.record("Notes/notes.lamp", in: source)?.uploadedDigest
                == LampSyncContentRevision.digest(for: Data("mine and theirs".utf8))
        )
    }

    @Test func anUnchangedLibraryWritesNothingAtAll() async throws {
        let store = try seeded(path: "Translations/KJVs.lamp", revision: "\"kjv-1\"")
        let url = try makeFile("a translation")
        defer { try? FileManager.default.removeItem(at: url) }
        var records = LampSyncFileRecords()
        records.recordUpload(
            "Translations/KJVs.lamp", in: source,
            digest: LampSyncContentRevision.digest(for: Data("a translation".utf8)),
            revision: "\"kjv-1\""
        )
        records.confirmRecorded(["Translations/KJVs.lamp": "\"kjv-1\""], in: source)

        let outcome = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [local("Translations/KJVs.lamp", url, "a translation")],
            deletedLocally: [:],
            records: &records
        )

        #expect(outcome.uploaded.isEmpty)
        #expect(outcome.installed.isEmpty)
        #expect(outcome.failures.isEmpty)
        #expect(
            store.operations.filter { $0.hasPrefix("write ") || $0.hasPrefix("delete ") }.isEmpty,
            "a quiet pass costs reads only, not a rewritten bundle"
        )
    }

    /// Settings and deletion records are taken from the bundle before
    /// anything goes up, so what this client publishes already holds what
    /// came down — the same order the archive pass published in.
    @Test func whatCameDownIsTakenBeforeAnythingGoesUp() async throws {
        let store = FakeStore()
        let url = try makeFile("a translation")
        defer { try? FileManager.default.removeItem(at: url) }
        var records = LampSyncFileRecords()
        var receivedAfter: [String] = []

        _ = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [local("Translations/KJVs.lamp", url, "a translation")],
            deletedLocally: [:],
            records: &records,
            receiving: { _ in receivedAfter = store.operations }
        )

        #expect(
            !receivedAfter.contains("write Translations/KJVs.lamp"),
            "the bundle is read and taken from before a file is published"
        )
    }

    /// This client's own half of the bundle is written inside the pass's
    /// single update, beside the manifest changes, rather than in a write of
    /// its own.
    @Test func whatThisClientContributesTravelsInTheOneUpdate() async throws {
        let store = FakeStore()
        let url = try makeFile("a translation")
        defer { try? FileManager.default.removeItem(at: url) }
        var records = LampSyncFileRecords()

        _ = try await LampSyncBundlePass(
            store: store, library: StubLibrary(), source: source, now: { 2_000 }
        ).run(
            local: [local("Translations/KJVs.lamp", url, "a translation")],
            deletedLocally: [:],
            records: &records,
            contributing: { bundle in
                bundle.macSettings = Data("this Mac's settings".utf8)
            }
        )

        let written = try #require(store.bodies[bundlePath])
        let bundle = try LampSyncSettingsBundle.decode(written)
        #expect(bundle.macSettings == Data("this Mac's settings".utf8))
        #expect(bundle.manifest.members.map(\.path) == ["Translations/KJVs.lamp"])
        // The claim plus one update, and no third write of the bundle.
        #expect(store.operations.filter { $0 == "write \(bundlePath)" }.count == 2)
    }
}

// MARK: - Doubles

private final class StubLibrary: LampSyncPassLibrary, @unchecked Sendable {
    var installed: [String] = []
    var deleted: [String] = []
    var reconcileCalls = 0
    var reconciled: (([String: URL]) -> [String: URL]) = { _ in [:] }

    func install(_ path: String, from url: URL) async throws { installed.append(path) }

    func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL] {
        reconcileCalls += 1
        return reconciled(downloaded)
    }

    func deleteLocally(_ path: String) async throws { deleted.append(path) }
}

/// A WebDAV server with strong revisions, which records the order it was
/// asked to do things in — the order being what these tests are about.
private final class FakeStore: LampSyncRemoteStore, @unchecked Sendable {
    var bodies: [String: Data] = [:]
    var revisions: [String: String] = [:]
    var operations: [String] = []
    var refusedWrites: Set<String> = []
    var revisionAfterWrite: String?
    private var counter = 0

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        operations.append("list \(directory)")
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        let entries = bodies.keys.filter { $0.hasPrefix(prefix) }.sorted().map { path in
            LampSyncRemoteEntry(
                path: path,
                name: String(path.dropFirst(prefix.count)),
                isDirectory: false,
                revision: revisions[path],
                modifiedAt: nil,
                size: Int64(bodies[path]?.count ?? 0)
            )
        }
        return entries.isEmpty ? nil : entries
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        operations.append("read \(path)")
        guard let data = bodies[path] else { return nil }
        return LampSyncRemoteFile(data: data, revision: revisions[path])
    }

    func revision(path: String) async throws -> String? {
        operations.append("revision \(path)")
        return revisions[path]
    }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        operations.append("write \(path)")
        if refusedWrites.contains(path) {
            throw LampSyncConditionalWrite.WriteError.conflict
        }
        switch condition {
        case .ifAbsent where bodies[path] != nil:
            throw LampSyncConditionalWrite.WriteError.conflict
        case .ifRevision(let expected) where revisions[path] != expected:
            throw LampSyncConditionalWrite.WriteError.conflict
        default: break
        }
        counter += 1
        let revision = revisionAfterWrite ?? "\"\(path)-\(counter)\""
        bodies[path] = data
        revisions[path] = revision
        return revision
    }

    func delete(path: String, condition: LampSyncWriteCondition) async throws {
        operations.append("delete \(path)")
        if case .ifRevision(let expected) = condition, revisions[path] != expected {
            throw LampSyncConditionalWrite.WriteError.conflict
        }
        bodies[path] = nil
        revisions[path] = nil
    }
}
