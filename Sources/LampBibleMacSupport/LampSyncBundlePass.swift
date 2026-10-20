import Foundation
import LampModuleKit

/// What a pass needs the library to do. Everything about content lives behind
/// this, so the pass itself only orders the work and keeps the records.
public protocol LampSyncPassLibrary {
    /// Installs a file taken from the server, whose body is already on disk.
    func install(_ path: String, from url: URL) async throws

    /// Reconciles the files both sides changed, having downloaded each.
    ///
    /// One call for the whole group, because the Mac merges personal content
    /// in a single staged transaction rather than file by file. Returns the
    /// file to publish for each path — the merge rewrites local content, so
    /// what to upload is what the transaction produced, not what the pass
    /// digested before it.
    func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL]

    /// Removes the local copy of a file deleted elsewhere.
    func deleteLocally(_ path: String) async throws

    /// Called once after every download and merge, before anything is
    /// published.
    ///
    /// Most files are complete on their own. A workspace is not: its
    /// documents, context, skills and conversations are a tree with one
    /// importer, so they are staged as they arrive and taken in here
    /// together. Nothing to do for a library that met none.
    func finishInstalling() async throws
}

public extension LampSyncPassLibrary {
    func finishInstalling() async throws {}
}

/// One Design B pass: read the bundle, work out what moved, move it, and
/// record what happened in a single bundle update.
///
/// The order is the whole substance of this, and each step of it is a rule
/// somewhere else:
///
/// 1. `readOrClaim` rather than `read`. A pass that found nothing and wrote
///    its files first would be told `notMigrated` by its own closing update,
///    on every pass, because its own files are what make the library look
///    like an earlier one.
/// 2. Downloads and merges before uploads, so what this client publishes
///    already contains what the other side changed.
/// 3. One bundle update, carrying every write, tombstone and adoption the
///    pass made. Not one per file: the bundle is a single small object every
///    device contends for, and its read-merge-retry is bounded.
/// 4. Reaps only after that update. A file deleted from the server before the
///    bundle tombstones it reads to every other device as a member that was
///    never uploaded.
///
/// A pass that dies between its files and its update leaves written-but-
/// unrecorded revisions in `LampSyncFileRecords`, and the next pass records
/// them. That is safe only because a file and the manifest disagreeing means
/// "changed, compare by value" and never a conflict — the invariant the
/// model holds as `anUnknownFileIsAdopted`.
///
/// Not `Sendable`: it holds a store, and a pass runs where its caller is —
/// on the Mac, the main actor.
public struct LampSyncBundlePass {
    public struct Outcome {
        public var installed: [String] = []
        public var reconciled: [String] = []
        public var uploaded: [String] = []
        public var deletedLocally: [String] = []
        public var tombstoned: [String] = []
        public var reaped: [String] = []
        /// Files the server's copy turned out to be byte-for-byte the one
        /// this client already held: fetched, compared, and left alone.
        public var alreadyInStep: [String] = []
        /// A file the server would not take, or one whose work failed. The
        /// pass carries on and reports, rather than abandoning the rest.
        public var failures: [String] = []
        /// The bundle revision this pass left behind.
        public var bundleRevision: String?
    }

    private let store: any LampSyncRemoteStore
    private let library: any LampSyncPassLibrary
    private let source: String
    private let now: () -> Int64

    public init(
        store: any LampSyncRemoteStore,
        library: any LampSyncPassLibrary,
        source: String,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.store = store
        self.library = library
        self.source = source
        self.now = now
    }

    /// Runs one pass.
    ///
    /// `local` is what this Mac holds, `deletedLocally` what it has deleted
    /// since its last pass, and `extraListing` the revisions of paths that no
    /// folder listing reaches — media and workspace files, which the manifest
    /// names and the caller checks one at a time.
    ///
    /// `records` is updated in place and saved by the caller, so a pass that
    /// throws still leaves behind what it had already written.
    /// What this client holds, as the plan reads it.
    public struct Gathered {
        /// Every local file: its remote path, its kind and its digest.
        public var local: [LampSyncLocalFile] = []
        /// What this client has deleted since its last pass, by remote path.
        public var deletedLocally: [String: Int64] = [:]
        /// Revisions for paths no folder listing reaches — writing
        /// attachments, book pictures and workspace files, which the manifest
        /// names and the caller checks one at a time.
        public var extraListing: [String: String] = [:]

        public init() {}
    }

    /// `receiving` is handed the bundle as it was read, once, before anything
    /// is published — settings and deletion records are applied there, so what
    /// this client publishes already holds what came down. `contributing`
    /// writes this client's own half into the bundle, inside the pass's single
    /// update. It must only compute: `update` re-applies its change against a
    /// newer bundle when another device writes first, so anything that needs
    /// to read local state asynchronously is read in `receiving` and kept for
    /// `contributing` to use.
    ///
    /// `gathering` runs **after** `receiving`, and that order is load-bearing:
    /// applying the deletion records removes content from this library, so a
    /// library read before them would publish the very notes and writings it
    /// had just been told were deleted, and the next pass on the other device
    /// would resurrect them.
    public func run(
        gathering: () async throws -> Gathered,
        records: inout LampSyncFileRecords,
        receiving: (LampSyncSettingsBundle) async throws -> Void = { _ in },
        contributing: (inout LampSyncSettingsBundle) throws -> Void = { _ in }
    ) async throws -> Outcome {
        var outcome = Outcome()
        // Deliberately without `knownArchiveRevision`. That parameter names a
        // revision at which an *archive* is known to sit, and a read that
        // still finds it there throws `notMigrated`. Handing it a bundle's
        // revision makes a migrated library report itself unmigrated on every
        // pass — which is what it did.
        let opened = try await LampSyncSettingsStore.readOrClaim(from: store)
        try await receiving(opened.bundle)

        // Only now: the library has had the other devices' deletions applied
        // to it, so this is what it actually holds.
        let gathered = try await gathering()

        var listing = try await LampSyncFilePlan.listing(
            in: store, manifest: opened.bundle.manifest
        )
        listing.merge(gathered.extraListing) { _, extra in extra }

        let filesByPath = Dictionary(
            gathered.local.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }
        )
        let plan = LampSyncFilePlan.plan(
            manifest: opened.bundle.manifest,
            local: LampSyncLocalFiles.locals(gathered.local, records: records, source: source),
            deletedLocally: gathered.deletedLocally,
            listing: listing
        )

        // 1. Take what the other side has.
        for path in plan.downloads.sorted() {
            do {
                try await LampSyncScratchFile.with { scratch in
                    guard let downloaded = try await store.read(path: path, into: scratch) else {
                        // Nothing there. For media that is "not uploaded yet",
                        // and for anything else the next pass sees it again.
                        return
                    }
                    try await library.install(path, from: downloaded.url)
                    records.recordInstall(
                        path, in: source, revision: downloaded.revision,
                        digest: try? LampSyncContentRevision.digest(forFileAt: downloaded.url)
                    )
                    outcome.installed.append(path)
                }
            } catch {
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // 2. Reconcile what both sides changed, as one transaction, and
        //    publish the result under the revision the plan named.
        var republish: [String: URL] = [:]
        if !plan.merge.isEmpty {
            do {
                republish = try await reconcile(
                    plan.merge, local: filesByPath, records: &records, outcome: &outcome
                )
            } catch {
                outcome.failures.append("merging: \(error.localizedDescription)")
            }
        }

        // 3. Let whatever arrived as part of a tree be taken in together.
        do {
            try await library.finishInstalling()
        } catch {
            outcome.failures.append("installing: \(error.localizedDescription)")
        }

        // 4. Publish, both what only changed here and what was just merged.
        //    A merged path carries its own condition — the revision that was
        //    downloaded — and publishes the file the transaction produced,
        //    never the one digested before it ran. Each success is remembered
        //    as pending until the bundle below names it.
        var toPublish = plan.uploads
        for (path, revision) in plan.merge where republish[path] != nil {
            toPublish[path] = .ifRevision(revision)
        }
        var written: [String: (revision: String?, previous: String?)] = [:]
        for (path, condition) in toPublish.sorted(by: { $0.key < $1.key }) {
            // A merged file is only ever the merge's own output: falling back
            // to the pre-merge copy would publish the other side's changes
            // straight back out of the library.
            guard let url = plan.merge[path] == nil
                ? (republish[path] ?? filesByPath[path]?.url)
                : republish[path]
            else { continue }
            let digest = url == filesByPath[path]?.url
                ? filesByPath[path]?.digest
                : (try? LampSyncContentRevision.digest(forFileAt: url))
            guard let digest else {
                outcome.failures.append("\(path): its file could not be read")
                continue
            }
            do {
                // A PUT that answers without an ETag leaves this client with
                // no revision for a file it has just written. The next pass
                // then finds a revision in the listing where it recorded
                // none, reads that as the other side having changed the file,
                // and downloads its own upload back — 601 of them, on the
                // first pass after the workspaces went up. Media is worse
                // still: with no revision it is offered `.ifAbsent` for ever
                // against a file that is plainly there, and every attempt is
                // refused.
                //
                // So a write that names no revision is asked for one. A HEAD,
                // not a read-back: the PUT was accepted, and what is wanted
                // here is the name of what is now there, not proof that it
                // arrived.
                //
                // Deliberately not `LampSyncConditionalWrite.write`, which
                // confirms by reading the body back. The phone uses it for
                // its module uploads and is right to; here the bodies are
                // the Mac's own modules, and confirming a translation would
                // mean downloading it again to see it had arrived. A server
                // that answers 2xx without storing the file would go unseen,
                // and that is the trade: a module-sized download on every
                // publish, against a server that lies about success.
                var revision = try await store.write(fileAt: url, to: path, condition: condition)
                if revision == nil {
                    revision = try? await store.revision(path: path)
                }
                records.recordUpload(path, in: source, digest: digest, revision: revision)
                written[path] = (revision, condition.revision)
                outcome.uploaded.append(path)
            } catch where LampSyncConditionalWrite.isRefusal(error)
                && condition == .ifAbsent
                && (LampSyncFolderLayout.kind(of: path)?.isMedia ?? false) {
                // A refused `.ifAbsent` means the file is already there, and
                // for media that is the whole answer: a path's bytes never
                // change, so an existing copy is either ours or a genuine
                // clash. Without settling it the pass offers the same write
                // every time and is refused every time — which is what two
                // deck images did, on every pass, for ever.
                do {
                    try await settleExistingMedia(
                        at: path, ours: digest, records: &records, outcome: &outcome
                    )
                } catch {
                    outcome.failures.append("\(path): \(error.localizedDescription)")
                }
            } catch {
                // A refusal is another device having written first, which the
                // next pass plans again from what won. Neither is fatal here.
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // 5. Drop what was deleted elsewhere.
        for path in plan.deleteLocally.sorted() {
            do {
                try await library.deleteLocally(path)
                records.forget(path, in: source)
                outcome.deletedLocally.append(path)
            } catch {
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // 6. One update, carrying everything this pass did.
        let time = now()
        let adopt = plan.adopt
        let tombstone = plan.tombstone
        let snapshot = try await LampSyncSettingsStore.update(
            in: store,
            mergingVersion: { bundle, version in try bundle.merge(version: version.bundle) }
        ) { bundle in
            try contributing(&bundle)
            for (path, write) in written {
                bundle.manifest = try bundle.manifest.recordingWrite(
                    path, revision: write.revision, replacing: write.previous, at: time
                )
            }
            for (path, revision) in adopt where written[path] == nil {
                bundle.manifest = try bundle.manifest.adopting(path, revision: revision, at: time)
            }
            for (path, deletedAt) in tombstone {
                bundle.manifest = try bundle.manifest.removing(
                    path, at: deletedAt, revision: listing[path]
                )
            }
            // Old enough to forget, and gone from the server. `present` is
            // the **whole** listing, never a filtered one: a tombstone whose
            // file is still waiting to be reaped must be kept, or the next
            // pass finds a file no manifest knows and adopts the deletion
            // back into the library. ios-92 hit exactly that on the phone by
            // pruning against a listing it had filtered for planning.
            bundle.manifest = bundle.manifest.pruned(
                now: time, present: Set(listing.keys)
            )
        }
        outcome.bundleRevision = snapshot.revision
        outcome.tombstoned = tombstone.keys.sorted()
        records.confirmRecorded(
            written.compactMapValues(\.revision), in: source
        )

        // 7. Only now may the bytes go. Before the bundle named the deletion,
        //    a missing file reads as one nobody has uploaded yet.
        for (path, revision) in plan.reap.sorted(by: { $0.key < $1.key }) {
            do {
                try await store.delete(path: path, condition: .ifRevision(revision))
                records.forget(path, in: source)
                outcome.reaped.append(path)
            } catch {
                outcome.failures.append("\(path): \(error.localizedDescription)")
            }
        }

        return outcome
    }

    /// Downloads everything the plan says both sides changed, and merges what
    /// is genuinely different.
    ///
    /// A file whose downloaded bytes are the ones this client already holds
    /// needs neither merging nor installing — it is only *recorded*, as
    /// having been uploaded from here at the server's revision, which is the
    /// plain truth about it: these bytes, that revision. Without that, a pass
    /// with no records to go on treats every file as changed on both sides
    /// and reinstalls the whole library, module by module, having just
    /// proved each one identical. It also leaves nothing recorded, so the
    /// next pass does it again.
    ///
    /// The comparison is of real downloaded bytes, not an assumption that
    /// two clients encode alike. That distinction is the whole reason this
    /// is safe where seeding records from a guess would not be.
    /// What to do about a file that would not go up because one is already
    /// there, at a path whose bytes never change.
    ///
    /// Reading it is the only way to tell the two cases apart. If it is the
    /// same file, this client simply had no record of having sent it — so it
    /// records one, and the path is finished with. If it is a different file,
    /// that is a real clash at an immutable path: reported, never
    /// overwritten, because the other copy is as much somebody's as this one.
    private func settleExistingMedia(
        at path: String,
        ours digest: String,
        records: inout LampSyncFileRecords,
        outcome: inout Outcome
    ) async throws {
        try await LampSyncScratchFile.with { scratch in
            guard let theirs = try await store.read(path: path, into: scratch) else {
                // Gone between the refusal and now. The next pass sends it.
                return
            }
            guard try LampSyncContentRevision.digest(forFileAt: theirs.url) == digest else {
                outcome.failures.append(
                    "\(path): a different file is already there, so this one was not sent"
                )
                return
            }
            records.recordUpload(
                path, in: source, digest: digest, revision: theirs.revision
            )
            records.confirmRecorded(
                theirs.revision.map { [path: $0] } ?? [:], in: source
            )
            outcome.alreadyInStep.append(path)
        }
    }

    private func reconcile(
        _ merge: [String: String],
        local: [String: LampSyncLocalFile],
        records: inout LampSyncFileRecords,
        outcome: inout Outcome
    ) async throws -> [String: URL] {
        var downloaded: [String: URL] = [:]
        var scratch: [URL] = []
        defer { for url in scratch { try? FileManager.default.removeItem(at: url) } }
        var unchanged: [String] = []
        for path in merge.keys.sorted() {
            let url = LampSyncScratchFile.url()
            scratch.append(url)
            guard let file = try await store.read(path: path, into: url) else { continue }
            if let held = local[path],
               let fetched = try? LampSyncContentRevision.digest(forFileAt: file.url),
               fetched == held.digest {
                records.recordUpload(
                    path, in: source, digest: held.digest, revision: file.revision
                )
                records.confirmRecorded(
                    file.revision.map { [path: $0] } ?? [:], in: source
                )
                unchanged.append(path)
                continue
            }
            downloaded[path] = file.url
            records.recordInstall(
                path, in: source, revision: file.revision,
                digest: try? LampSyncContentRevision.digest(forFileAt: file.url)
            )
        }
        outcome.alreadyInStep.append(contentsOf: unchanged)
        guard !downloaded.isEmpty else { return [:] }
        let republish = try await library.reconcile(downloaded)
        outcome.reconciled = downloaded.keys.sorted()
        return republish
    }
}

private extension LampSyncWriteCondition {
    /// The revision a conditional write replaces, for the manifest to record
    /// the new one as its successor.
    var revision: String? {
        switch self {
        case .ifRevision(let revision): revision
        case .unconditional, .ifAbsent: nil
        }
    }
}
