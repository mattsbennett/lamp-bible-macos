import Foundation
import LampCore

/// The writing imports this Mac can still undo, newest first.
///
/// Kept in Application Support beside the requests, not in the library: an
/// undo belongs to the Mac it was made on, and a record synced to another
/// device would undo there what that device has since built on.
public enum LampWritingImportUndoHistory {
    public static let directoryName = "WritingImportUndo"
    /// How many imports are kept to undo.
    public static let limit = 10

    public static func directoryURL(inApplicationSupport root: URL) -> URL {
        LampAgentDescriptorStore.directoryURL(inApplicationSupport: root)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// One import that can be undone, with what it was imported from.
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public let sourceName: String
        public let undo: LampWritingImportUndo
        public var id: String { undo.id }
    }

    public static func record(
        _ undo: LampWritingImportUndo,
        sourceName: String,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !undo.isEmpty, LampReadingPlanAdditions.isUsableIdentifier(undo.id) else { return }
        let directory = directoryURL(inApplicationSupport: root)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Entry(sourceName: sourceName, undo: undo))
            .write(to: directory.appendingPathComponent("\(undo.id).json"), options: .atomic)
        for old in entries(inApplicationSupport: root).dropFirst(limit) {
            forget(id: old.id, inApplicationSupport: root, fileManager: fileManager)
        }
    }

    public static func entries(inApplicationSupport root: URL) -> [Entry] {
        let directory = directoryURL(inApplicationSupport: root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(Entry.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
            .sorted { $0.undo.importedAt > $1.undo.importedAt }
    }

    /// The pictures the decks in the history show, before and after their
    /// imports, which pruning must leave while the imports can be undone.
    public static func deckAssetNames(inApplicationSupport root: URL) -> Set<String> {
        Set(entries(inApplicationSupport: root).flatMap { entry in
            entry.undo.decks.flatMap { deck in
                Array(deck.previous?.referencedAssetNames ?? []) + Array(deck.written.referencedAssetNames)
            }
        })
    }

    /// After an undo put writings back, each earlier import that left
    /// them so takes them as its own again (`LampWritingImportUndo.carrying`),
    /// so it can still be undone in turn.
    public static func carry(restored: [String: String], inApplicationSupport root: URL) throws {
        guard !restored.isEmpty else { return }
        for entry in entries(inApplicationSupport: root) {
            let carried = entry.undo.carrying(restored: restored)
            guard carried != entry.undo else { continue }
            try record(carried, sourceName: entry.sourceName, inApplicationSupport: root)
        }
    }

    public static func forget(
        id: String, inApplicationSupport root: URL, fileManager: FileManager = .default
    ) {
        guard LampReadingPlanAdditions.isUsableIdentifier(id) else { return }
        try? fileManager.removeItem(
            at: directoryURL(inApplicationSupport: root).appendingPathComponent("\(id).json")
        )
    }
}

/// The library as a writing import's store on this Mac. A deck an undo takes
/// away is recorded as deleted, so other Macs take it away too rather than
/// bring it back; the library alone does not keep that record.
public struct LampMacWritingImportStore: LampWritingImportStore {
    public let library: LampLibrary

    public init(library: LampLibrary) {
        self.library = library
    }

    public func importableWritings() async throws -> [LampDevotional] {
        try await library.importableWritings()
    }

    public func writingDeletion(id: String) async throws -> LampPersonalDeletionLedger.Entry? {
        try await library.writingDeletion(id: id)
    }

    public func writingRefusal(id: String) async throws -> String? {
        try await library.writingRefusal(id: id)
    }

    public func saveImportedWriting(
        _ writing: LampDevotional, expecting current: LampDevotional?
    ) async throws -> LampDevotional? {
        try await library.saveImportedWriting(writing, expecting: current)
    }

    public func recordWritingsPresent(_ ids: [String]) async throws {
        try await library.recordWritingsPresent(ids)
    }

    public func deleteImportedWriting(id: String, expecting current: LampDevotional) async throws -> Bool {
        try await library.deleteImportedWriting(id: id, expecting: current)
    }

    public func storeImportedMedia(from url: URL, writingID: String) async throws -> String {
        try await library.storeImportedMedia(from: url, writingID: writingID)
    }

    public func removeImportedMedia(writingID: String, filename: String) async throws {
        try await library.removeImportedMedia(writingID: writingID, filename: filename)
    }

    public var supportsDecks: Bool { true }

    public func importableDecks() async throws -> [LampPresentationDeck] {
        try await library.importableDecks()
    }

    public func saveImportedDeck(
        _ deck: LampPresentationDeck, assets: [String: URL], expecting current: LampPresentationDeck?
    ) async throws -> Bool {
        try await library.saveImportedDeck(deck, assets: assets, expecting: current)
    }

    public func deleteImportedDeck(id: String, expecting current: LampPresentationDeck) async throws -> Bool {
        guard try await library.deleteImportedDeck(id: id, expecting: current) else { return false }
        try LampPresentationDeckSync.recordDeletion(of: id, in: library.rootURL)
        try? LampPresentationDeckSync.pruneUnreferencedAssets(in: library.rootURL)
        return true
    }
}
