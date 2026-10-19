import Foundation

/// What has changed in the writing, as diffs an agent can read.
///
/// An agent working on a deck is told `draft.md` changed, and has to tell the
/// writer's edits from its own before deciding where a slide's passage now
/// begins. Lamp already keeps the revisions in `.lamp/`, which agents are told
/// not to touch — so this reads them out instead. Read-only throughout: nothing
/// here writes to a workspace.
public enum LampWritingChanges {
    /// Who made a change, in the words an agent needs rather than the store's.
    public enum Source: String, Sendable {
        case editor
        case agent
        case restoration

        init(_ kind: DevotionalAgentRevisionKind) {
            switch kind {
            case .userEdit: self = .editor
            case .agentEdit: self = .agent
            case .restoration: self = .restoration
            }
        }
    }

    /// One recorded change to one document.
    public struct Change: Sendable {
        public var id: UUID
        /// When the version this change produced came into being. For a run of
        /// edits merged into one revision, the time of the last of them.
        public var at: Date
        /// When the run began, on a change that stands for several.
        public var startedAt: Date
        public var source: Source
        /// The CLI that made an agent's change, when the store recorded one.
        public var providerName: String?
        public var documentPath: String
        public var diff: String
        public var addedLines: Int
        public var removedLines: Int

        public init(
            id: UUID,
            at: Date,
            startedAt: Date,
            source: Source,
            providerName: String?,
            documentPath: String,
            diff: String,
            addedLines: Int,
            removedLines: Int
        ) {
            self.id = id
            self.at = at
            self.startedAt = startedAt
            self.source = source
            self.providerName = providerName
            self.documentPath = documentPath
            self.diff = diff
            self.addedLines = addedLines
            self.removedLines = removedLines
        }
    }

    /// Where a caller wants the history to start.
    public enum Since: Sendable {
        /// Everything after the revision with this ID, which is what an agent
        /// that has read the history before should pass.
        case revision(UUID)
        case time(Date)
        /// The most recent changes, however old.
        case latest
    }

    /// The changes to one document since `since`, oldest first — the order they
    /// happened, which is the order they read in.
    ///
    /// A revision the store has merged away, or one that ends where it began,
    /// is not a change anyone made and is not reported.
    public static func changes(
        in workspace: URL,
        documentPath: String = DevotionalAgentRevisionStore.primaryDocumentPath,
        since: Since = .latest,
        limit: Int = 20,
        context: Int = LampUnifiedDiff.defaultContext
    ) throws -> [Change] {
        // The store answers newest first; these read oldest first.
        let history = try DevotionalAgentRevisionStore.revisions(
            in: workspace,
            documentPath: documentPath
        ).reversed()

        var wanted = Array(history)
        switch since {
        case .revision(let id):
            if let index = wanted.firstIndex(where: { $0.coveredRevisionIDs.contains(id) }) {
                wanted = Array(wanted[wanted.index(after: index)...])
            }
        case .time(let date):
            wanted = wanted.filter { $0.effectiveDate > date }
        case .latest:
            break
        }
        // With more than asked for, the most recent are the ones that matter.
        if wanted.count > max(limit, 0) { wanted = Array(wanted.suffix(max(limit, 0))) }

        return wanted.map { revision in
            let diff = LampUnifiedDiff.diff(
                before: revision.beforeMarkdown,
                after: revision.afterMarkdown,
                beforeLabel: "\(revision.resolvedDocumentPath) before",
                afterLabel: "\(revision.resolvedDocumentPath) after",
                context: context
            )
            let counted = countingLines(in: diff)
            return Change(
                id: revision.id,
                at: revision.effectiveDate,
                startedAt: revision.createdAt,
                source: Source(revision.kind),
                providerName: revision.providerName,
                documentPath: revision.resolvedDocumentPath,
                diff: diff,
                addedLines: counted.added,
                removedLines: counted.removed
            )
        }
    }

    private static func countingLines(in diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    /// Reads what a caller passed as `since`: a revision ID, an ISO 8601 time,
    /// or nothing at all.
    public static func since(_ value: String?) -> Since {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return .latest }
        if let id = UUID(uuidString: value) { return .revision(id) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return .time(date) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return .time(date) }
        return .latest
    }
}
