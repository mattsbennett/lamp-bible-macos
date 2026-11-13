import Foundation

/// Writings an agent has asked Lamp to start.
///
/// `start_writing` runs in `lamp-mcp`, a process of its own, and Lamp has the
/// library open. As with a reading plan, the helper writes down what was
/// asked for and Lamp makes the writing — at once when the request came from
/// a reader chat whose reply has finished, otherwise when it next reads its
/// library.
///
/// In Application Support beside the descriptor, outside the library, so a
/// request is never synced to the user's server as a side effect of where it
/// was left.
public enum LampWritingStarts {
    public static let directoryName = "WritingStarts"

    public struct Start: Codable, Equatable, Identifiable, Sendable {
        /// The identifier the writing will have, chosen when it was asked for
        /// so the tool could name it in its reply.
        public let id: String
        public let title: String
        /// As the agent gave it. Lamp keeps a writing's kind as written.
        public let category: String?
        /// Markdown to begin the writing with. Nil or empty starts it empty.
        public let draft: String?
        /// The reader chat that asked, whose conversation goes into the
        /// writing. Nil for an app outside Lamp, which has no conversation
        /// here to bring.
        public let readerChatID: UUID?
        /// Whose conversation in that chat asked: the provider whose helper
        /// took the request. Nil from a helper that was not told, where the
        /// chat's current provider is the best answer there is.
        public let readerChatProviderID: String?
        public let askedAt: Date

        public init(
            id: String,
            title: String,
            category: String? = nil,
            draft: String? = nil,
            readerChatID: UUID? = nil,
            readerChatProviderID: String? = nil,
            askedAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.category = category
            self.draft = draft
            self.readerChatID = readerChatID
            self.readerChatProviderID = readerChatProviderID
            self.askedAt = askedAt
        }
    }

    public enum StartError: Error, LocalizedError, Equatable {
        case unusableIdentifier(String)

        public var errorDescription: String? {
            switch self {
            case .unusableIdentifier(let id):
                "‘\(id)’ cannot be a writing's identifier."
            }
        }
    }

    public static func directoryURL(inApplicationSupport root: URL) -> URL {
        LampAgentDescriptorStore.directoryURL(inApplicationSupport: root)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func url(inApplicationSupport root: URL, id: String) -> URL {
        directoryURL(inApplicationSupport: root).appendingPathComponent("\(id).json")
    }

    /// The same rule a reading plan's identifier answers to: safe as a file
    /// name here and as an identifier in the library.
    public static func isUsableIdentifier(_ id: String) -> Bool {
        LampReadingPlanAdditions.isUsableIdentifier(id)
    }

    @discardableResult
    public static func write(
        _ start: Start,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isUsableIdentifier(start.id) else { throw StartError.unusableIdentifier(start.id) }
        let destination = url(inApplicationSupport: root, id: start.id)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.preciseDates.string(from: date))
        }
        try encoder.encode(start).write(to: destination, options: .atomic)
        return destination
    }

    /// The writings waiting to be started, oldest first. A file that cannot
    /// be read is left where it is, as a plan's is.
    public static func pending(
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) -> [Start] {
        let directory = directoryURL(inApplicationSupport: root)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.preciseDates.date(from: text) ?? Self.wholeSecondDates.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"
                ))
            }
            return date
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                    return nil
                }
                return try? decoder.decode(Start.self, from: data)
            }
            .sorted { $0.askedAt < $1.askedAt }
    }

    /// When a request was made, to the millisecond. A whole second is not
    /// close enough: whether a request is ready is decided by comparing this
    /// with when the chat's transcript was written, and a second rounded off
    /// lets a save made just before the request pass for one made after it.
    /// Made when needed rather than shared: a formatter is not safe to share
    /// between threads, and a request is read a handful of times at most.
    private static var preciseDates: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var wholeSecondDates: ISO8601DateFormatter { ISO8601DateFormatter() }

    public static func forget(
        id: String,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) {
        guard isUsableIdentifier(id) else { return }
        try? fileManager.removeItem(at: url(inApplicationSupport: root, id: id))
    }
}
