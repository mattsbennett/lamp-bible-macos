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
    ) async throws -> Bool {
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

    public func saveImportedDeck(_ deck: LampPresentationDeck, assetsFrom directory: URL?) async throws {
        try await library.saveImportedDeck(deck, assetsFrom: directory)
    }

    public func deleteImportedDeck(id: String) async throws {
        try LampPresentationDeckSync.recordDeletion(of: id, in: library.rootURL)
        try await library.deleteImportedDeck(id: id)
        try? LampPresentationDeckSync.pruneUnreferencedAssets(in: library.rootURL)
    }
}
