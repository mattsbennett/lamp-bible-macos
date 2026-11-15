import Foundation
import LampCore

/// Writing imports an agent has asked Lamp to review.
///
/// `import_writings` runs in `lamp-mcp`, a process of its own, and Lamp has
/// the library open, so the helper writes down what was asked for and Lamp
/// shows it in its review sheet. Nothing an agent asks for is imported until
/// the person chooses it there (owner decision, 2026-11-15).
///
/// The files' text, and the pictures, recordings and decks they bring, are
/// copied into the request when it is made — the text into its JSON, the
/// files into a folder of the same name — so the agent's folder can change
/// afterwards without changing what is reviewed. In Application Support
/// beside the descriptor, outside the library, so a request is never synced
/// as a side effect of where it was left.
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
        /// Each picture or recording, by the link as written, as a path in
        /// the request's folder.
        public let attachments: [String: String]?
        public let deck: Deck?
        /// Why the file could not be read, carried so Lamp shows the same
        /// reason the helper saw.
        public let readError: String?

        public struct Deck: Codable, Equatable, Sendable {
            public let path: String
            public let data: Data
            /// The folder in the request's folder holding its `Assets`.
            public let assets: String
        }

        init(
            path: String, markdown: String, modified: Date?, created: Date?,
            ancestry: [String]?, attachments: [String: String]?, deck: Deck?, readError: String?
        ) {
            self.readError = readError
            self.path = path
            self.markdown = markdown
            self.modified = modified
            self.created = created
            self.ancestry = ancestry
            self.attachments = attachments
            self.deck = deck
        }

        /// The file as an import reads it, its pictures and deck found in
        /// `folder`, the request's own.
        public func importFile(in folder: URL) -> LampWritingImportFile {
            LampWritingImportFile(
                path: path, markdown: markdown, modified: modified, created: created,
                ancestry: ancestry ?? [],
                attachments: (attachments ?? [:]).mapValues { folder.appendingPathComponent($0) },
                deck: deck.map {
                    LampWritingImportDeckFile(
                        path: $0.path, data: $0.data,
                        assetsDirectory: folder.appendingPathComponent($0.assets, isDirectory: true)
                    )
                },
                readError: readError
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
        /// Chosen, but not imported because something went wrong, with why.
        public let failed: [String: String]?

        public init(
            requestID: String, decidedAt: Date = Date(), imported: [String], refused: [String],
            cancelled: Bool, failed: [String: String]? = nil
        ) {
            self.requestID = requestID
            self.decidedAt = decidedAt
            self.imported = imported
            self.refused = refused
            self.cancelled = cancelled
            self.failed = failed
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

    /// The folder a request's pictures, recordings and decks were copied to.
    public static func folderURL(inApplicationSupport root: URL, id: String) -> URL {
        directoryURL(inApplicationSupport: root).appendingPathComponent(id, isDirectory: true)
    }

    /// Writes a request down, copying each file's pictures, recordings and
    /// deck (with the pictures it names) into the request's folder.
    @discardableResult
    public static func write(
        sourceName: String,
        files: [LampWritingImportFile],
        note: String?,
        inApplicationSupport root: URL,
        id: String = UUID().uuidString,
        fileManager: FileManager = .default
    ) throws -> Request {
        guard isUsableIdentifier(id) else { throw RequestError.unusableIdentifier(id) }
        let folder = folderURL(inApplicationSupport: root, id: id)
        var copied = 0
        func copy(_ source: URL, into relativeFolder: String, as name: String? = nil) throws -> String {
            copied += 1
            let relative = relativeFolder + "/" + (name ?? "\(copied)-\(source.lastPathComponent)")
            let destination = folder.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
            return relative
        }
        var entries: [File] = []
        for (index, file) in files.enumerated() {
            var attachments: [String: String] = [:]
            for (target, url) in file.attachments.sorted(by: { $0.key < $1.key }) {
                attachments[target] = try copy(url, into: "media")
            }
            var deck: File.Deck?
            if let delivered = file.deck {
                let assets = "deck-\(index + 1)"
                if let directory = delivered.assetsDirectory,
                   let parsed = try? LampPresentationDeckStore.decodeUnvalidated(delivered.data) {
                    let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
                    for path in Set(parsed.slides.flatMap(\.blocks).compactMap(\.assetPath))
                    where LampPresentationDeckValidator.isSafeAssetPath(path) {
                        // Only a file truly inside the deck's folder: a linked
                        // `Assets` must not carry in one from elsewhere.
                        let source = directory.appendingPathComponent(path)
                            .resolvingSymlinksInPath().standardizedFileURL
                        guard source.path.hasPrefix(base + "/"),
                              (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                        else { continue }
                        _ = try copy(source, into: assets + "/" + (path as NSString).deletingLastPathComponent,
                                     as: (path as NSString).lastPathComponent)
                    }
                }
                deck = File.Deck(path: delivered.path, data: delivered.data, assets: assets)
            }
            entries.append(File(
                path: file.path, markdown: file.markdown, modified: file.modified,
                created: file.created, ancestry: file.ancestry,
                attachments: attachments.isEmpty ? nil : attachments, deck: deck,
                readError: file.readError
            ))
        }
        let request = Request(id: id, sourceName: sourceName, files: entries, note: note)
        _ = try save(request, to: requestURL(root, id: id), fileManager: fileManager)
        return request
    }

    /// The request's files as an import reads them.
    public static func importFiles(
        of request: Request, inApplicationSupport root: URL
    ) -> [LampWritingImportFile] {
        let folder = folderURL(inApplicationSupport: root, id: request.id)
        return request.files.map { $0.importFile(in: folder) }
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
        try? fileManager.removeItem(at: folderURL(inApplicationSupport: root, id: outcome.requestID))
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
