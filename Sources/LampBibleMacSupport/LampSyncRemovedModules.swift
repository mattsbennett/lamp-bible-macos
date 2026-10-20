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
        return records
    }

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
    public mutating func forget(_ paths: some Sequence<String>) {
        for path in paths { removedAt[path] = nil }
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
        var records = load(fromLibraryAt: libraryRoot, fileManager: fileManager)
        records.record(path, at: Int64(date.timeIntervalSince1970 * 1_000))
        try records.save(toLibraryAt: libraryRoot, fileManager: fileManager)
        return path
    }
}
