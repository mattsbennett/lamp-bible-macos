import Foundation
import LampCore

/// Writing imports an agent has asked Lamp to review.
///
/// `import_writings` runs in `lamp-mcp`, a process of its own, and Lamp has
/// the library open, so the helper writes down what was asked for and Lamp
/// shows it in its review sheet. Nothing an agent asks for is imported until
/// the person chooses it there (owner decision, 2026-11-15).
///
/// The files' text is copied into the request when it is made, so the agent's
/// folder can change afterwards without changing what is reviewed. In
/// Application Support beside the descriptor, outside the library, so a
/// request is never synced as a side effect of where it was left.
public enum LampWritingImportRequests {
    public static let directoryName = "WritingImports"

    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let markdown: String
        public let modified: Date?
        public let created: Date?
        /// The folders above the one chosen, so Lamp's plan finds writings
        /// imported before from a folder further up, as the helper's did.
        public let ancestry: [String]?

        public init(_ file: LampWritingImportFile) {
            path = file.path
            markdown = file.markdown
            modified = file.modified
            created = file.created
            ancestry = file.ancestry
        }

        public var importFile: LampWritingImportFile {
            LampWritingImportFile(
                path: path, markdown: markdown, modified: modified, created: created,
                ancestry: ancestry ?? []
            )
        }
    }

    public struct Request: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        /// What was imported, as the agent named it: a folder's name, or a
        /// count of documents.
        public let sourceName: String
        public let files: [File]
        /// What the agent wants the person to know, shown in the sheet.
        public let note: String?
        public let askedAt: Date

        public init(
            id: String = UUID().uuidString,
            sourceName: String,
            files: [File],
            note: String? = nil,
            askedAt: Date = Date()
        ) {
            self.id = id
            self.sourceName = sourceName
            self.files = files
            self.note = note
            self.askedAt = askedAt
        }
    }

    /// What the person decided, left for `writing_import_status`.
    public struct Outcome: Codable, Equatable, Sendable {
        public let requestID: String
        public let decidedAt: Date
        /// The paths of the files whose writings were imported.
        public let imported: [String]
        /// Chosen, but changed in Lamp while the person was choosing, so left
        /// as they were.
        public let refused: [String]
        /// The person cancelled the review, so nothing was imported.
        public let cancelled: Bool

        public init(requestID: String, decidedAt: Date = Date(), imported: [String], refused: [String], cancelled: Bool) {
            self.requestID = requestID
            self.decidedAt = decidedAt
            self.imported = imported
            self.refused = refused
            self.cancelled = cancelled
        }
    }

    public enum RequestError: Error, LocalizedError, Equatable {
        case unusableIdentifier(String)

        public var errorDescription: String? {
            switch self {
            case .unusableIdentifier(let id): "‘\(id)’ cannot name a writing import."
            }
        }
    }

    public static func directoryURL(inApplicationSupport root: URL) -> URL {
        LampAgentDescriptorStore.directoryURL(inApplicationSupport: root)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func requestURL(_ root: URL, id: String) -> URL {
        directoryURL(inApplicationSupport: root).appendingPathComponent("\(id).json")
    }

    private static func outcomeURL(_ root: URL, id: String) -> URL {
        directoryURL(inApplicationSupport: root)
            .appendingPathComponent("Decided", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    public static func isUsableIdentifier(_ id: String) -> Bool {
        LampReadingPlanAdditions.isUsableIdentifier(id)
    }

    @discardableResult
    public static func write(
        _ request: Request,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isUsableIdentifier(request.id) else { throw RequestError.unusableIdentifier(request.id) }
        return try save(request, to: requestURL(root, id: request.id), fileManager: fileManager)
    }

    /// The imports waiting for review, oldest first. A file that cannot be
    /// read is left where it is.
    public static func pending(
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) -> [Request] {
        let directory = directoryURL(inApplicationSupport: root)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(Request.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
            .sorted { $0.askedAt < $1.askedAt }
    }

    /// Records what the person decided and takes the request off the queue.
    public static func decide(
        _ outcome: Outcome,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws {
        guard isUsableIdentifier(outcome.requestID) else {
            throw RequestError.unusableIdentifier(outcome.requestID)
        }
        try save(outcome, to: outcomeURL(root, id: outcome.requestID), fileManager: fileManager)
        try? fileManager.removeItem(at: requestURL(root, id: outcome.requestID))
    }

    public enum Status: Equatable, Sendable {
        case waiting
        case decided(Outcome)
        case unknown
    }

    public static func status(id: String, inApplicationSupport root: URL) -> Status {
        guard isUsableIdentifier(id) else { return .unknown }
        if let outcome = try? decoder.decode(Outcome.self, from: Data(contentsOf: outcomeURL(root, id: id))) {
            return .decided(outcome)
        }
        return FileManager.default.fileExists(atPath: requestURL(root, id: id).path) ? .waiting : .unknown
    }

    private static func save<Value: Encodable>(
        _ value: Value, to url: URL, fileManager: FileManager
    ) throws -> URL {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        return url
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
