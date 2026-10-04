import CryptoKit
import Foundation

public enum DevotionalAgentRevisionKind: String, Codable, Sendable {
    case agentEdit
    case userEdit
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
    /// Missing in revision records created before multi-file history. Those
    /// records are interpreted as revisions of the primary `draft.md` document.
    public let documentPath: String?
    public let beforeMarkdown: String
    public let afterMarkdown: String
    /// For a revision that stands for a merged run of changes, the time of the
    /// last of them. Missing on a single change, whose time is `createdAt`.
    public let updatedAt: Date?
    /// For a merged revision, the ids of every recorded change it replaced.
    ///
    /// Sync merges revision folders by union, so an original removed here comes
    /// back from any Mac that still has it. This list is what lets it be
    /// recognised as already accounted for and dropped again.
    public let replacedRevisionIDs: [UUID]?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: DevotionalAgentRevisionKind,
        providerName: String? = nil,
        documentPath: String? = nil,
        beforeMarkdown: String,
        afterMarkdown: String,
        updatedAt: Date? = nil,
        replacedRevisionIDs: [UUID]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.providerName = providerName
        self.documentPath = documentPath
        self.beforeMarkdown = beforeMarkdown
        self.afterMarkdown = afterMarkdown
        self.updatedAt = updatedAt
        self.replacedRevisionIDs = replacedRevisionIDs
    }

    public var resolvedDocumentPath: String {
        documentPath ?? DevotionalAgentRevisionStore.primaryDocumentPath
    }

    /// When the version this revision produced came into being.
    public var effectiveDate: Date {
        updatedAt ?? createdAt
    }

    /// The recorded changes this revision accounts for: itself, or everything it
    /// was merged from.
    public var coveredRevisionIDs: Set<UUID> {
        replacedRevisionIDs.map(Set.init) ?? [id]
    }

    /// A merged run that ends where it began — text typed and then removed —
    /// changes nothing worth showing. It is still stored, because its list of
    /// replaced ids keeps the originals from being imported back.
    public var isNoOp: Bool {
        beforeMarkdown == afterMarkdown
    }
}

/// Collapses revision history into the units a writer thinks in.
///
/// Autosave records a revision every few seconds while someone types, which left
/// one workspace holding 1,535 revisions — every one a full copy of the
/// document, twice over — for two days of editing. Runs of consecutive changes
/// of the same kind are merged into one revision spanning the run, more coarsely
/// the older they get:
///
/// - within the last day, a pause of more than five minutes ends a run;
/// - within the last thirty days, a pause of more than an hour;
/// - beyond that, a pause of more than a day.
///
/// Agent edits always use the five-minute rule, so each agent turn stays its own
/// revision however old it is; undoing a particular turn is the reason agent
/// history exists. Restorations are never merged — each is a deliberate act.
///
/// Only *contiguous* changes merge: the later one must start exactly where the
/// earlier one finished. Merging is then exact — the result restores to the run's
/// first `before` and its last `after`, and loses only the intermediate states.
public enum DevotionalAgentRevisionCompactor {
    public struct Tier: Equatable, Sendable {
        /// Revisions younger than this use `gap`.
        public var maximumAge: TimeInterval
        /// The longest pause that still continues a run.
        public var gap: TimeInterval

        public init(maximumAge: TimeInterval, gap: TimeInterval) {
            self.maximumAge = maximumAge
            self.gap = gap
        }
    }

    public struct Policy: Equatable, Sendable {
        public var tiers: [Tier]
        /// The gap for anything older than every tier.
        public var oldestGap: TimeInterval
        public var agentEditGap: TimeInterval

        public init(tiers: [Tier], oldestGap: TimeInterval, agentEditGap: TimeInterval) {
            self.tiers = tiers
            self.oldestGap = oldestGap
            self.agentEditGap = agentEditGap
        }

        private static let minute: TimeInterval = 60
        private static let hour: TimeInterval = 3_600
        private static let day: TimeInterval = 86_400

        public static let standard = Policy(
            tiers: [
                Tier(maximumAge: day, gap: 5 * minute),
                Tier(maximumAge: 30 * day, gap: hour),
            ],
            oldestGap: day,
            agentEditGap: 5 * minute
        )

        func allowedGap(for kind: DevotionalAgentRevisionKind, age: TimeInterval) -> TimeInterval {
            if kind == .agentEdit { return agentEditGap }
            return tiers.first { age < $0.maximumAge }?.gap ?? oldestGap
        }
    }

    public static func compact(
        _ revisions: [DevotionalAgentRevision],
        now: Date,
        policy: Policy = .standard
    ) -> [DevotionalAgentRevision] {
        let current = removingReplaced(revisions)
        var compacted: [DevotionalAgentRevision] = []
        for documentRevisions in Dictionary(grouping: current, by: \.resolvedDocumentPath).values {
            var run: DevotionalAgentRevision?
            for revision in documentRevisions.sorted(by: chronologically) {
                guard let open = run else {
                    run = revision
                    continue
                }
                if canMerge(open, revision, now: now, policy: policy) {
                    run = merge(open, revision)
                } else {
                    compacted.append(open)
                    run = revision
                }
            }
            if let run { compacted.append(run) }
        }
        return compacted.sorted(by: chronologically)
    }

    /// Drops every revision another revision already accounts for.
    ///
    /// A revision is redundant when its covered changes are a strict subset of
    /// another's — an original that came back through sync, or an earlier merge
    /// of a run that has since grown. Two revisions covering exactly the same
    /// changes are the same merge made twice; one is kept, chosen the same way on
    /// every Mac so the history converges.
    public static func removingReplaced(
        _ revisions: [DevotionalAgentRevision]
    ) -> [DevotionalAgentRevision] {
        let coverage = revisions.map(\.coveredRevisionIDs)
        var holders: [UUID: [Int]] = [:]
        for (index, covered) in coverage.enumerated() {
            for identifier in covered { holders[identifier, default: []].append(index) }
        }

        return revisions.indices.compactMap { index in
            let covered = coverage[index]
            // Anything that covers all of this revision's changes also covers
            // whichever one is probed, so only those holders can replace it.
            guard let probe = covered.first else { return revisions[index] }
            let isReplaced = holders[probe, default: []].contains { other in
                guard other != index, covered.isSubset(of: coverage[other]) else { return false }
                if coverage[other].count != covered.count { return true }
                return (revisions[other].id.uuidString, other)
                    < (revisions[index].id.uuidString, index)
            }
            return isReplaced ? nil : revisions[index]
        }
    }

    static func canMerge(
        _ earlier: DevotionalAgentRevision,
        _ later: DevotionalAgentRevision,
        now: Date,
        policy: Policy
    ) -> Bool {
        guard earlier.kind == later.kind,
              earlier.kind != .restoration,
              earlier.providerName == later.providerName,
              later.beforeMarkdown == earlier.afterMarkdown
        else { return false }
        let gap = later.createdAt.timeIntervalSince(earlier.effectiveDate)
        guard gap >= 0 else { return false }
        let age = now.timeIntervalSince(later.effectiveDate)
        return gap <= policy.allowedGap(for: later.kind, age: age)
    }

    static func merge(
        _ earlier: DevotionalAgentRevision,
        _ later: DevotionalAgentRevision
    ) -> DevotionalAgentRevision {
        let replaced = earlier.coveredRevisionIDs
            .union(later.coveredRevisionIDs)
            .sorted { $0.uuidString < $1.uuidString }
        return DevotionalAgentRevision(
            id: mergedID(for: replaced),
            createdAt: earlier.createdAt,
            kind: earlier.kind,
            providerName: earlier.providerName,
            documentPath: earlier.documentPath ?? later.documentPath,
            beforeMarkdown: earlier.beforeMarkdown,
            afterMarkdown: later.afterMarkdown,
            updatedAt: later.effectiveDate,
            replacedRevisionIDs: replaced
        )
    }

    /// Derived from the merged changes rather than random, so two Macs that
    /// compact the same history write the same file instead of two copies of it.
    static func mergedID(for replaced: [UUID]) -> UUID {
        let digest = SHA256.hash(data: Data(replaced.map(\.uuidString).joined(separator: "\n").utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func chronologically(
        _ lhs: DevotionalAgentRevision,
        _ rhs: DevotionalAgentRevision
    ) -> Bool {
        (lhs.createdAt, lhs.effectiveDate, lhs.id.uuidString)
            < (rhs.createdAt, rhs.effectiveDate, rhs.id.uuidString)
    }
}

public enum DevotionalAgentRevisionStore {
    public static let primaryDocumentPath = "draft.md"

    private struct SyncState: Codable {
        let version: Int
        let markdown: String
    }

    private struct StoredRevision {
        let url: URL
        let revision: DevotionalAgentRevision
    }

    private static let metadataDirectoryName = ".lamp"
    private static let revisionsDirectoryName = "revisions"
    private static let syncStateFilename = "draft-sync.json"
    /// Recording and compacting both rewrite the revision folder. Compaction of a
    /// large backlog runs in the background when a workspace opens, so an
    /// autosave arriving meanwhile waits for it rather than racing it. Recursive,
    /// because recording compacts.
    private static let mutationLock = NSRecursiveLock()

    /// The history to show for one document, newest first.
    public static func revisions(
        in workspace: URL,
        documentPath: String = primaryDocumentPath
    ) throws -> [DevotionalAgentRevision] {
        DevotionalAgentRevisionCompactor
            .removingReplaced(try storedRevisions(in: workspace).map(\.revision))
            .filter { $0.resolvedDocumentPath == documentPath && !$0.isNoOp }
            .sorted {
                ($0.effectiveDate, $0.createdAt, $0.id.uuidString)
                    > ($1.effectiveDate, $1.createdAt, $1.id.uuidString)
            }
    }

    @discardableResult
    public static func record(
        kind: DevotionalAgentRevisionKind,
        providerName: String? = nil,
        documentPath: String = primaryDocumentPath,
        before beforeMarkdown: String,
        after afterMarkdown: String,
        in workspace: URL,
        createdAt: Date = Date()
    ) throws -> DevotionalAgentRevision? {
        guard beforeMarkdown != afterMarkdown else { return nil }
        mutationLock.lock()
        defer { mutationLock.unlock() }

        // File notifications and polling can report the same atomic replacement
        // more than once. A change that lands on the state the latest revision
        // already ended at adds nothing — and once runs are merged, the latest
        // revision's `before` is the start of its run rather than this change's.
        if let latest = try revisions(in: workspace, documentPath: documentPath).first,
           latest.kind == kind,
           latest.afterMarkdown == afterMarkdown {
            return nil
        }

        let revision = DevotionalAgentRevision(
            createdAt: createdAt,
            kind: kind,
            providerName: providerName,
            documentPath: documentPath,
            beforeMarkdown: beforeMarkdown,
            afterMarkdown: afterMarkdown
        )
        try write(revision, in: workspace)
        // Measured from the change itself, which is the newest thing in the
        // history; the run it extends is judged by the most recent tier.
        try compact(in: workspace, now: createdAt)
        return revision
    }

    /// Merges this workspace's stored history according to `policy`, writing the
    /// merged revisions and removing the files they replace.
    ///
    /// Files that cannot be decoded are left exactly as they are: history this
    /// version cannot read is not history it is entitled to discard.
    public static func compact(
        in workspace: URL,
        now: Date = Date(),
        policy: DevotionalAgentRevisionCompactor.Policy = .standard
    ) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let stored = try storedRevisions(in: workspace)
        guard stored.count > 1 else { return }

        let compacted = DevotionalAgentRevisionCompactor.compact(
            stored.map(\.revision),
            now: now,
            policy: policy
        )
        let storedIDs = Set(stored.map(\.revision.id))
        let keptIDs = Set(compacted.map(\.id))
        guard keptIDs != storedIDs || compacted.count != stored.count else { return }

        // Every replacement is on disk before anything it replaces is removed, so
        // an interruption leaves extra history rather than missing history.
        for revision in compacted where !storedIDs.contains(revision.id) {
            try write(revision, in: workspace)
        }
        var removed = Set<URL>()
        for entry in stored where !keptIDs.contains(entry.revision.id) {
            try FileManager.default.removeItem(at: entry.url)
            removed.insert(entry.url)
        }
        // The same revision stored under two names keeps only one of them.
        var seen = Set<UUID>()
        for entry in stored.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent })
        where !removed.contains(entry.url) && !seen.insert(entry.revision.id).inserted {
            try FileManager.default.removeItem(at: entry.url)
        }
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

    private static func storedRevisions(in workspace: URL) throws -> [StoredRevision] {
        let directory = revisionsDirectory(in: workspace)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let revision = try? decoder.decode(DevotionalAgentRevision.self, from: data)
            else { return nil }
            return StoredRevision(url: url, revision: revision)
        }
    }

    private static func write(_ revision: DevotionalAgentRevision, in workspace: URL) throws {
        let directory = revisionsDirectory(in: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Int64(revision.createdAt.timeIntervalSince1970 * 1_000)
        let url = directory.appendingPathComponent("\(timestamp)-\(revision.id.uuidString).json")
        try encoder.encode(revision).write(to: url, options: .atomic)
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
