import Foundation

public enum DevotionalAgentRevisionKind: String, Codable, Sendable {
    case agentEdit
    case restoration
}

/// A durable, reversible transition made through the devotional agent workspace.
/// Both sides are retained so restoring an older version never destroys the
/// version that was current immediately before the restore.
public struct DevotionalAgentRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let kind: DevotionalAgentRevisionKind
    public let providerName: String?
    public let beforeMarkdown: String
    public let afterMarkdown: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: DevotionalAgentRevisionKind,
        providerName: String? = nil,
        beforeMarkdown: String,
        afterMarkdown: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.providerName = providerName
        self.beforeMarkdown = beforeMarkdown
        self.afterMarkdown = afterMarkdown
    }
}

public enum DevotionalAgentRevisionStore {
    private struct SyncState: Codable {
        let version: Int
        let markdown: String
    }

    private static let metadataDirectoryName = ".lamp"
    private static let revisionsDirectoryName = "revisions"
    private static let syncStateFilename = "draft-sync.json"

    public static func revisions(in workspace: URL) throws -> [DevotionalAgentRevision] {
        let directory = revisionsDirectory(in: workspace)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(DevotionalAgentRevision.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public static func record(
        kind: DevotionalAgentRevisionKind,
        providerName: String? = nil,
        before beforeMarkdown: String,
        after afterMarkdown: String,
        in workspace: URL,
        createdAt: Date = Date()
    ) throws -> DevotionalAgentRevision? {
        guard beforeMarkdown != afterMarkdown else { return nil }

        // File notifications and polling can report the same atomic replacement
        // more than once. Only the newest identical transition is a duplicate.
        if let latest = try revisions(in: workspace).first,
           latest.kind == kind,
           latest.beforeMarkdown == beforeMarkdown,
           latest.afterMarkdown == afterMarkdown {
            return nil
        }

        let revision = DevotionalAgentRevision(
            createdAt: createdAt,
            kind: kind,
            providerName: providerName,
            beforeMarkdown: beforeMarkdown,
            afterMarkdown: afterMarkdown
        )
        let directory = revisionsDirectory(in: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Int64(createdAt.timeIntervalSince1970 * 1_000)
        let url = directory.appendingPathComponent("\(timestamp)-\(revision.id.uuidString).json")
        try encoder.encode(revision).write(to: url, options: .atomic)
        return revision
    }

    public static func lastSyncedDraft(in workspace: URL) throws -> String? {
        let url = metadataDirectory(in: workspace).appendingPathComponent(syncStateFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(SyncState.self, from: Data(contentsOf: url)).markdown
    }

    public static func markSynced(_ markdown: String, in workspace: URL) throws {
        let directory = metadataDirectory(in: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = SyncState(version: 1, markdown: markdown)
        try encoder.encode(state).write(
            to: directory.appendingPathComponent(syncStateFilename),
            options: .atomic
        )
    }

    private static func metadataDirectory(in workspace: URL) -> URL {
        workspace.appendingPathComponent(metadataDirectoryName, isDirectory: true)
    }

    private static func revisionsDirectory(in workspace: URL) -> URL {
        metadataDirectory(in: workspace)
            .appendingPathComponent(revisionsDirectoryName, isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
