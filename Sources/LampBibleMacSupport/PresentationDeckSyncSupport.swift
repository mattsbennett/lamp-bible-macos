import Foundation
import LampCore
import LampModuleKit

/// Carries presentation decks between Macs, and out to iPhone and iPad.
///
/// Each deck is one `.lampdeck` file, so decks merge the way workspace files do:
/// the most recently saved copy of each wins. Deletions are recorded too —
/// without that, the next sync would bring a deleted deck back from a copy that
/// predates its deletion. A deck saved after it was deleted elsewhere is kept,
/// as the newer change.
///
/// The paths, the deletion ledger, and the merge decision all live in
/// `LampCore` so the read-only iOS deck viewer resolves exactly the same
/// winners this does.
public enum LampPresentationDeckSync {
    static var portableDirectoryName: String { LampPresentationDeckStore.directoryName }
    static var deletionsFilename: String { LampPresentationDeckPortableLayout.deletionsFilename }
    private static var deckExtension: String { LampPresentationDeckPortableLayout.deckExtension }

    /// Records that a deck was deleted on this Mac, for sync to pass on.
    public static func recordDeletion(
        of deckID: String,
        in libraryRoot: URL,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        let directory = decksDirectory(in: libraryRoot)
        var deletions = try loadDeletions(in: directory, fileManager: fileManager)
        deletions.record(deckID, at: date)
        try saveDeletions(deletions, in: directory, fileManager: fileManager)
    }

    public static func exportDecks(
        from libraryRoot: URL,
        to backupRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let source = decksDirectory(in: libraryRoot)
        let destination = portableDirectory(in: backupRoot)
        for deck in try deckFiles(in: source, fileManager: fileManager) {
            // A deck this Mac can't read stays where it is rather than spreading.
            guard (try? LampPresentationDeckStore.decode(Data(contentsOf: deck.url))) != nil
            else { continue }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let copy = destination.appendingPathComponent(deck.url.lastPathComponent)
            if fileManager.fileExists(atPath: copy.path) { try fileManager.removeItem(at: copy) }
            try fileManager.copyItem(at: deck.url, to: copy)
            try fileManager.setAttributes([.modificationDate: deck.modified], ofItemAtPath: copy.path)
        }
        let deletions = try loadDeletions(in: source, fileManager: fileManager)
        if !deletions.isEmpty {
            try saveDeletions(deletions, in: destination, fileManager: fileManager)
        }
    }

    public static func importDecks(
        from backupRoot: URL,
        into libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let source = portableDirectory(in: backupRoot)
        let destination = decksDirectory(in: libraryRoot)
        guard isPlainDirectory(source, fileManager: fileManager) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            guard isPlainDirectory(destination, fileManager: fileManager) else { return }
        }

        var deletions = try loadDeletions(in: destination, fileManager: fileManager)
        deletions.merge(try loadDeletions(in: source, fileManager: fileManager))

        // Found by the deck's ID rather than its filename, so each deck keeps
        // the one file the store would give it.
        var localFiles: [String: URL] = [:]
        var local: [LampPresentationDeckRevision] = []
        for file in try deckFiles(in: destination, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: file.url),
                  let deck = try? LampPresentationDeckStore.decode(data)
            else { continue }
            localFiles[deck.id] = file.url
            local.append(.init(deck: deck, data: data, modifiedAt: file.modified))
        }

        var incomingFilenames: [String: String] = [:]
        var incoming: [LampPresentationDeckRevision] = []
        for file in try deckFiles(in: source, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: file.url),
                  let deck = try? LampPresentationDeckStore.decode(data)
            else { continue }
            incomingFilenames[deck.id] = file.url.lastPathComponent
            incoming.append(.init(deck: deck, data: data, modifiedAt: file.modified))
        }

        let plan = LampPresentationDeckPortablePull.plan(
            incoming: incoming,
            deletions: deletions,
            local: local
        )

        for revision in plan.decksToSave {
            let target = localFiles[revision.id]
                ?? destination.appendingPathComponent(
                    incomingFilenames[revision.id] ?? "\(revision.id).\(deckExtension)"
                )
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            try revision.data.write(to: target, options: .atomic)
            try fileManager.setAttributes(
                [.modificationDate: revision.modifiedAt],
                ofItemAtPath: target.path
            )
            localFiles[revision.id] = target
        }

        // Deleted elsewhere since this copy was last saved.
        for id in plan.deckIDsToDelete {
            guard let url = localFiles[id] else { continue }
            try fileManager.removeItem(at: url)
        }

        if !deletions.isEmpty {
            try saveDeletions(deletions, in: destination, fileManager: fileManager)
        }
    }

    // MARK: - Files

    private struct DeckFile {
        let url: URL
        let modified: Date
    }

    private static func decksDirectory(in libraryRoot: URL) -> URL {
        LampPresentationDeckStore(rootURL: libraryRoot).decksDirectoryURL
    }

    private static func portableDirectory(in backupRoot: URL) -> URL {
        backupRoot
            .appendingPathComponent(LampPortableBackupLayout.workspacesDirectory, isDirectory: true)
            .appendingPathComponent(portableDirectoryName, isDirectory: true)
    }

    /// Regular `.lampdeck` files directly in `directory`, never followed links.
    private static func deckFiles(in directory: URL, fileManager: FileManager) throws -> [DeckFile] {
        guard isPlainDirectory(directory, fileManager: fileManager) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == deckExtension }
        .compactMap { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return DeckFile(url: url, modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private static func isPlainDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        else { return false }
        return true
    }

    // MARK: - Deletions

    private static func loadDeletions(
        in directory: URL,
        fileManager: FileManager
    ) throws -> LampPresentationDeckDeletionLedger {
        let url = directory.appendingPathComponent(deletionsFilename)
        guard fileManager.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let data = try? Data(contentsOf: url)
        else { return LampPresentationDeckDeletionLedger() }
        return LampPresentationDeckDeletionLedger.decoded(from: data)
    }

    private static func saveDeletions(
        _ deletions: LampPresentationDeckDeletionLedger,
        in directory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try deletions.encoded()
            .write(to: directory.appendingPathComponent(deletionsFilename), options: .atomic)
    }
}
