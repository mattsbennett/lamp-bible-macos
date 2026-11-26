import Foundation
import LampCore
import LampModuleKit

/// Modules removed on this Mac, written down as they go.
///
/// Sync merges as a union, so a module deleted here and not recorded is
/// simply a file this Mac no longer has — and a member nobody holds is
/// fetched. Delete a translation and the next pass brings it back, which is
/// not a subtle failure but it is a silent one: the deletion looks as though
/// it worked until the sync runs.
///
/// Nothing else records it. A note, a writing and a highlight set each leave
/// a trace in the personal deletion ledger as they go, and a deck in its own;
/// removing a module leaves none, because a module is not a thing the library
/// tracks the life of. So it is written down at the moment it happens, which
/// is the only moment the fact exists.
///
/// Kept in a dot-prefixed file in the library root: local state, like the
/// per-path records, and skipped by `LampSyncArchive.create(from:)` so it can
/// never travel.
public struct LampSyncRemovedModules: Codable, Equatable, Sendable {
    public static let filename = ".lamp-sync-removed-modules.json"

    /// Remote path to when it was removed here, in milliseconds since 1970.
    public private(set) var removedAt: [String: Int64] = [:]

    public init() {}

    public static func url(inLibraryAt libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(filename)
    }

    public static func load(
        fromLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> LampSyncRemovedModules {
        let url = url(inLibraryAt: libraryRoot)
        guard fileManager.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode(Self.self, from: data)
        else { return LampSyncRemovedModules() }
        return records.atFormatFourPaths()
    }

    /// These removals with any recorded at bundle format 3's writing paths,
    /// `Devotionals/<id>.lamp`, carried to format 4's, `Writing/<id>.lamp`:
    /// the server's move takes the module there, and a removal still to be
    /// told must follow it, or the moved copy comes back.
    func atFormatFourPaths() -> Self {
        var moved = Self()
        for (path, time) in removedAt {
            let renamed = LampSyncFolderLayout.formatFourPath(ofFormatThree: path)
            moved.record(renamed.flatMap { $0 == path ? nil : $0 } ?? path, at: time)
        }
        return moved
    }

    /// Reads, changes and writes the library's queue under one lock, writing
    /// only if the change moved it.
    ///
    /// Every writer goes through here. They run on different actors — a
    /// module removed on the main actor, a source removed and tool output
    /// queued on `WritingWorkspaceFiles`, the pass's bookkeeping on the main
    /// actor — and two reading the same copy and each saving its own would
    /// lose the other's entry: a removed module or source would come back.
    /// The lock spans the read to the write, which an atomic write alone
    /// does not.
    @discardableResult
    public static func update<Result>(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default,
        _ change: (inout LampSyncRemovedModules) throws -> Result
    ) throws -> Result {
        queueLock.lock()
        defer { queueLock.unlock() }
        let before = load(fromLibraryAt: libraryRoot, fileManager: fileManager)
        var records = before
        let result = try change(&records)
        if records != before { try records.save(toLibraryAt: libraryRoot, fileManager: fileManager) }
        return result
    }

    private static let queueLock = NSLock()

    public func save(
        toLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: Self.url(inLibraryAt: libraryRoot), options: .atomic)
    }

    public mutating func record(_ path: String, at time: Int64) {
        removedAt[path] = max(removedAt[path] ?? .min, time)
    }

    /// Forgotten once the manifest carries the deletion, since from then on
    /// the tombstone is what every device reads.
    ///
    /// `carried`, where given, is when each deletion the pass carried was
    /// made: a path is forgotten only if it was removed then or before, and
    /// a removal made again while the pass ran waits for the next one.
    /// Forgotten by path alone, that later removal went unrecorded, and the
    /// module came back.
    public mutating func forget(_ paths: some Sequence<String>, carried: [String: Int64]? = nil) {
        for path in paths {
            if let carried {
                guard let at = carried[path], let removed = removedAt[path], removed <= at else { continue }
            }
            removedAt[path] = nil
        }
    }

    /// Forgets `paths` in the library's record, writing only if that moved
    /// it. Says whether it wrote.
    ///
    /// The write has to be conditional, and the reason is not tidiness.
    /// `LampSyncLocalWork` reads this file's date — it has to, since a module
    /// removed here leaves no other trace — so rewriting it with the bytes it
    /// already held tells this Mac it has work to publish. The next check
    /// starts a pass, which rewrites it again: a pass every six seconds for
    /// as long as the app is open, which is what this Mac was doing.
    ///
    /// Core now hands over only the deletions the manifest actually took
    /// (`LampSyncLibraryManifest.recordsAdeletion`), so there is usually
    /// nothing here to forget and this usually writes nothing. That is the
    /// first line and this is the second: a file the local-work reading
    /// watches is written when its content moved, and never because something
    /// asked.
    @discardableResult
    public static func forget(
        _ paths: some Sequence<String>,
        carried: [String: Int64]? = nil,
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        try update(inLibraryAt: libraryRoot, fileManager: fileManager) { records in
            let before = records
            records.forget(paths, carried: carried)
            return records != before
        }
    }

    /// Queues for removal every member that is a tool's output under a
    /// writing's sources (`LampWritingWorkspaceLayout.isToolOutput`) and is
    /// not queued yet, as a reader's removal of it would be. Such files are
    /// no longer gathered (`decisions/0023`), and a member left on the server
    /// with nothing here would be planned as a download on every pass.
    ///
    /// Written only when something was added: this file's date is what tells
    /// this Mac it has work to publish, and rewriting it on every pass is how
    /// a Mac once synced every six seconds. Returns what was added.
    ///
    /// Dated past the member's own write, however this Mac's clock reads: a
    /// deletion dated before the write it means to remove loses to it, and
    /// the file would be fetched instead of removed.
    ///
    /// On `WritingWorkspaceFiles`, as the reader's own removals are queued,
    /// so neither overwrites the other's entry.
    @discardableResult
    @WritingWorkspaceFiles
    public static func queueToolOutput(
        amongMembers members: [(path: String, presentSince: Int64?)],
        inLibraryAt libraryRoot: URL,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> [String] {
        // Offloaded or not: tool output is not a source, and nothing under
        // it is kept for an act. None is gathered or offloaded any more, and
        // keeping one an older build had offloaded cost two review rounds a
        // check that could delete the wrong copy (`decisions/0023`).
        let toolOutput = members.filter { member in
            LampWritingWorkspaceLayout.contextFile(ofPath: member.path).map {
                LampWritingWorkspaceLayout.isToolOutput(relativePath: $0.relativePath)
            } ?? false
        }
        guard !toolOutput.isEmpty else { return [] }
        let now = Int64(date.timeIntervalSince1970 * 1_000)
        return try update(inLibraryAt: libraryRoot, fileManager: fileManager) { records in
            let fresh = toolOutput.filter { records.removedAt[$0.path] == nil }.sorted { $0.path < $1.path }
            for member in fresh {
                records.record(member.path, at: max(now, (member.presentSince ?? .min) &+ 1))
            }
            return fresh.map(\.path)
        }
    }

    /// Records a module's removal, at the path it is published under.
    @discardableResult
    public static func record(
        _ module: LampInstalledModule,
        inLibraryAt libraryRoot: URL,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> String? {
        guard let path = try? LampSyncFolderLayout.modulePath(
            kind: LampSyncContentKind(module.kind), moduleID: module.id
        ), LampSyncLocalDeletion.target(of: path).isAllowed else { return nil }
        // Refused by core's rule, which is the same rule every client's
        // `deleteLocally` answers to. Recording a deletion no client carries
        // out is how an imported module whose ID is `notes` would tombstone
        // the file every note lives in.
        try update(inLibraryAt: libraryRoot, fileManager: fileManager) { records in
            records.record(path, at: Int64(date.timeIntervalSince1970 * 1_000))
        }
        return path
    }
}
