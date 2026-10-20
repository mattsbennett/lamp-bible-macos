import Foundation
import LampModuleKit

/// What this Mac knows about each file it has synced: what it last uploaded,
/// the revision it last installed, and any write the server took that no
/// manifest names yet.
///
/// Design B decides "should I upload this?" by comparing a file against **this
/// client's own last upload**, never against another client's bytes — the two
/// clients encode the same content differently, so a cross-client digest
/// reports constant change. Nothing on the server holds that answer, so it is
/// kept here.
///
/// Everything is scoped by sync source — `webdav:<url>` or `folder:<path>`, as
/// the preference ledger already scopes its bases. A revision is the
/// provider's: an ETag on WebDAV, a content digest on a folder. Carried across
/// a provider change they would be compared against revisions from another
/// namespace, so every file would read as changed and the first pass would
/// re-upload the library. Scoping means a switch starts from nothing, and a
/// switch back finds its records where it left them.
///
/// Held in a dot-prefixed file in the library root, which is both where
/// `LampSyncSettingsCommit` keeps its journal and the reason this never
/// travels: `LampSyncArchive.create(from:)` skips any path with a
/// dot-prefixed component, so local state cannot leak into a published
/// archive.
public struct LampSyncFileRecords: Codable, Equatable, Sendable {
    public static let filename = ".lamp-sync-file-records.json"
    public static let currentFormatVersion = 1

    /// One file, as this Mac last left it.
    public struct Record: Codable, Equatable, Sendable {
        /// The digest of what this client last uploaded, which is what
        /// `changedSinceUpload` is judged against.
        public var uploadedDigest: String?
        /// The provider's revision for the copy this client last installed or
        /// wrote. `LampSyncFilePlan.Local.lastRevision`.
        public var installedRevision: String?
        /// A revision the server took that no bundle this client wrote names
        /// yet. A pass writes its files and then makes one bundle update, so
        /// a pass that dies in between leaves this behind; the next pass
        /// records it rather than treating the file as never uploaded.
        public var pendingRevision: String?
        public init(
            uploadedDigest: String? = nil,
            installedRevision: String? = nil,
            pendingRevision: String? = nil
        ) {
            self.uploadedDigest = uploadedDigest
            self.installedRevision = installedRevision
            self.pendingRevision = pendingRevision
        }

        /// The revision to plan against: a pending write is the newest thing
        /// this client knows, even though no manifest names it.
        public var effectiveRevision: String? { pendingRevision ?? installedRevision }
    }

    /// One sync source's records.
    public struct Source: Codable, Equatable, Sendable {
        public var files: [String: Record] = [:]
        /// Highlight set ID to the module ID it is published under. Per source
        /// because a different server holds different modules, and kept at all
        /// because under B the Mac stops downloading highlight modules whose
        /// revision has not moved — so it stops re-deriving this from each
        /// module's `highlight_meta.id`. Without it a Mac mints a module ID by
        /// sanitising the set ID and publishes a second module for a set that
        /// already has one.
        public var highlightModuleIDsBySet: [String: String] = [:]

        public init() {}
    }

    public var formatVersion = LampSyncFileRecords.currentFormatVersion
    public var sources: [String: Source] = [:]

    public init() {}

    // MARK: - Reading

    public func record(_ path: String, in source: String) -> Record? {
        sources[source]?.files[path]
    }

    /// Whether a file whose current digest is `digest` differs from what this
    /// client last uploaded. No record means "never uploaded from here", which
    /// is a change: the plan's job is then to download or merge, never to
    /// upload over a server copy this client has never seen.
    public func changedSinceUpload(_ path: String, in source: String, digest: String) -> Bool {
        guard let uploaded = sources[source]?.files[path]?.uploadedDigest else { return true }
        return uploaded != digest
    }

    public func highlightModuleID(forSet setID: String, in source: String) -> String? {
        sources[source]?.highlightModuleIDsBySet[setID]
    }

    // MARK: - Writing

    /// Records a write the server took. `pending` until a bundle this client
    /// writes names the revision, at which point `confirmRecorded` moves it.
    public mutating func recordUpload(
        _ path: String,
        in source: String,
        digest: String,
        revision: String?
    ) {
        var record = sources[source, default: Source()].files[path] ?? Record()
        record.uploadedDigest = digest
        record.pendingRevision = revision
        sources[source, default: Source()].files[path] = record
    }

    /// Records a copy taken from the server. The digest is this client's own
    /// only once it has published its own encoding, so installing clears it:
    /// an imported file has no last-upload from here.
    public mutating func recordInstall(
        _ path: String,
        in source: String,
        revision: String?
    ) {
        var record = sources[source, default: Source()].files[path] ?? Record()
        record.installedRevision = revision
        record.pendingRevision = nil
        record.uploadedDigest = nil
        sources[source, default: Source()].files[path] = record
    }

    /// Moves each pending revision into place, once a bundle this client wrote
    /// names it. A path whose pending revision has since moved on is left
    /// alone, so a write made after the bundle was built is not confirmed by it.
    public mutating func confirmRecorded(_ revisionsByPath: [String: String], in source: String) {
        for (path, revision) in revisionsByPath {
            guard var record = sources[source]?.files[path],
                  record.pendingRevision == revision else { continue }
            record.installedRevision = revision
            record.pendingRevision = nil
            sources[source]?.files[path] = record
        }
    }

    public mutating func forget(_ path: String, in source: String) {
        sources[source]?.files[path] = nil
    }

    public mutating func setHighlightModuleID(
        _ moduleID: String,
        forSet setID: String,
        in source: String
    ) {
        sources[source, default: Source()].highlightModuleIDsBySet[setID] = moduleID
    }

    /// Fills in highlight module IDs this source has no record of, from the
    /// mapping the Mac kept in `UserDefaults` before these records existed.
    /// Only absent entries, so it can never overwrite what a pass has learned
    /// from the server — and seeding matters rather than being tidy: an
    /// unseeded Mac mints fresh module IDs and duplicates every highlight
    /// module it already published.
    public mutating func seedHighlightModuleIDs(
        _ legacy: [String: String],
        in source: String
    ) {
        var mapping = sources[source, default: Source()].highlightModuleIDsBySet
        for (setID, moduleID) in legacy where mapping[setID] == nil {
            mapping[setID] = moduleID
        }
        sources[source, default: Source()].highlightModuleIDsBySet = mapping
    }

    /// Everything this Mac remembers about one source, discarded. A provider
    /// change rather than a repair: the revisions are in the old provider's
    /// namespace and mean nothing in the new one.
    public mutating func removeSource(_ source: String) {
        sources[source] = nil
    }

    // MARK: - Storage

    public static func url(inLibraryAt libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(filename)
    }

    /// Reads the records, or starts fresh. Unreadable or newer-format records
    /// start fresh rather than throwing: every record here can be rebuilt by
    /// a pass that compares with the server, so losing them costs one
    /// re-comparison, and refusing to sync would cost rather more.
    public static func load(
        fromLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> LampSyncFileRecords {
        let url = url(inLibraryAt: libraryRoot)
        guard fileManager.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode(LampSyncFileRecords.self, from: data),
              records.formatVersion <= currentFormatVersion
        else { return LampSyncFileRecords() }
        return records
    }

    public func save(
        toLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(
            to: Self.url(inLibraryAt: libraryRoot), options: .atomic
        )
    }
}

public extension LampSyncFileRecords {
    /// The sync source string for a provider, matching the one the preference
    /// ledger already uses so both are scoped the same way.
    static func webDAVSource(_ endpoint: URL) -> String { "webdav:\(endpoint.absoluteString)" }

    static func folderSource(_ folder: URL) -> String {
        "folder:\(folder.standardizedFileURL.path)"
    }

    /// One file's state, in the form `LampSyncFilePlan.plan` reads.
    func local(
        _ path: String,
        in source: String,
        digest: String,
        savedAt: Int64?
    ) -> LampSyncFilePlan.Local {
        LampSyncFilePlan.Local(
            path: path,
            changedSinceUpload: changedSinceUpload(path, in: source, digest: digest),
            lastRevision: record(path, in: source)?.effectiveRevision,
            savedAt: savedAt
        )
    }
}
