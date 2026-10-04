import Foundation
import Testing
@testable import LampBibleMacSupport

struct AgentRevisionSupportTests {
    @Test func revisionsAreDurableOrderedAndReversible() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            providerName: "Codex",
            before: "Original",
            after: "Agent draft",
            in: workspace,
            createdAt: firstDate
        )
        try DevotionalAgentRevisionStore.record(
            kind: .restoration,
            before: "Agent draft",
            after: "Original",
            in: workspace,
            createdAt: secondDate
        )

        let revisions = try DevotionalAgentRevisionStore.revisions(in: workspace)
        #expect(revisions.map(\.createdAt) == [secondDate, firstDate])
        #expect(revisions[1].beforeMarkdown == "Original")
        #expect(revisions[1].afterMarkdown == "Agent draft")
        #expect(revisions[1].providerName == "Codex")
    }

    @Test func identicalLatestRevisionIsDeduplicated() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let first = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            before: "Before",
            after: "After",
            in: workspace
        )
        let duplicate = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            before: "Before",
            after: "After",
            in: workspace
        )

        #expect(first != nil)
        #expect(duplicate == nil)
        #expect(try DevotionalAgentRevisionStore.revisions(in: workspace).count == 1)
    }

    @Test func revisionsAreScopedToEachMarkdownDocument() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            before: "Before",
            after: "After",
            in: workspace
        )
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit,
            documentPath: "outline.md",
            before: "Before",
            after: "After",
            in: workspace
        )

        let draftRevisions = try DevotionalAgentRevisionStore.revisions(in: workspace)
        let outlineRevisions = try DevotionalAgentRevisionStore.revisions(
            in: workspace,
            documentPath: "outline.md"
        )
        #expect(draftRevisions.count == 1)
        #expect(draftRevisions.first?.resolvedDocumentPath == "draft.md")
        #expect(outlineRevisions.count == 1)
        #expect(outlineRevisions.first?.kind == .userEdit)
        #expect(outlineRevisions.first?.resolvedDocumentPath == "outline.md")
    }

    @Test func legacyRevisionWithoutDocumentPathBelongsToDraft() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let revisionsDirectory = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisionsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let identifier = UUID()
        let legacyJSON = """
        {
          "afterMarkdown" : "After",
          "beforeMarkdown" : "Before",
          "createdAt" : 100000,
          "id" : "\(identifier.uuidString)",
          "kind" : "agentEdit"
        }
        """
        try Data(legacyJSON.utf8).write(to: revisionsDirectory.appendingPathComponent("legacy.json"))

        let draftRevisions = try DevotionalAgentRevisionStore.revisions(in: workspace)
        #expect(draftRevisions.count == 1)
        #expect(draftRevisions.first?.documentPath == nil)
        #expect(draftRevisions.first?.resolvedDocumentPath == "draft.md")
        #expect(try DevotionalAgentRevisionStore.revisions(
            in: workspace,
            documentPath: "outline.md"
        ).isEmpty)
    }

    @Test func synchronizedDraftRoundTrips() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(try DevotionalAgentRevisionStore.lastSyncedDraft(in: workspace) == nil)
        try DevotionalAgentRevisionStore.markSynced("Current draft", in: workspace)
        #expect(try DevotionalAgentRevisionStore.lastSyncedDraft(in: workspace) == "Current draft")
    }
}

struct AgentRevisionCompactionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let minute: TimeInterval = 60
    private let day: TimeInterval = 86_400

    /// A contiguous chain of edits: each one starts where the previous finished.
    private func chain(
        _ kind: DevotionalAgentRevisionKind = .userEdit,
        startingAt start: Date,
        spacing: TimeInterval,
        count: Int,
        provider: String? = nil,
        firstState: Int = 0
    ) -> [DevotionalAgentRevision] {
        (0..<count).map { index in
            DevotionalAgentRevision(
                createdAt: start.addingTimeInterval(Double(index) * spacing),
                kind: kind,
                providerName: provider,
                beforeMarkdown: "state \(firstState + index)",
                afterMarkdown: "state \(firstState + index + 1)"
            )
        }
    }

    @Test func aTypingSessionBecomesOneRevision() {
        let edits = chain(startingAt: now.addingTimeInterval(-10 * minute), spacing: 5, count: 40)

        let compacted = DevotionalAgentRevisionCompactor.compact(edits, now: now)

        #expect(compacted.count == 1)
        let merged = compacted[0]
        #expect(merged.beforeMarkdown == "state 0")
        #expect(merged.afterMarkdown == "state 40")
        #expect(merged.createdAt == edits.first?.createdAt)
        #expect(merged.effectiveDate == edits.last?.createdAt)
        #expect(merged.coveredRevisionIDs == Set(edits.map(\.id)))
    }

    @Test func aLongPauseEndsARecentSession() {
        let morning = chain(startingAt: now.addingTimeInterval(-60 * minute), spacing: 5, count: 3)
        let afterBreak = chain(
            startingAt: now.addingTimeInterval(-30 * minute),
            spacing: 5,
            count: 3,
            firstState: 3
        )

        let compacted = DevotionalAgentRevisionCompactor.compact(morning + afterBreak, now: now)

        #expect(compacted.count == 2)
        #expect(compacted.map(\.afterMarkdown) == ["state 3", "state 6"])
    }

    @Test func olderHistoryIsMergedMoreCoarsely() {
        // Twenty-minute pauses split recent sessions but sit inside the hour
        // allowed for history from earlier in the month.
        let recent = chain(startingAt: now.addingTimeInterval(-90 * minute), spacing: 20 * minute, count: 3)
        let lastWeek = chain(startingAt: now.addingTimeInterval(-7 * day), spacing: 20 * minute, count: 3)
        let lastYear = chain(startingAt: now.addingTimeInterval(-300 * day), spacing: 12 * 3_600, count: 3)

        #expect(DevotionalAgentRevisionCompactor.compact(recent, now: now).count == 3)
        #expect(DevotionalAgentRevisionCompactor.compact(lastWeek, now: now).count == 1)
        #expect(DevotionalAgentRevisionCompactor.compact(lastYear, now: now).count == 1)
    }

    @Test func changesThatDoNotFollowOnAreNeverMerged() {
        let first = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-60),
            kind: .userEdit,
            beforeMarkdown: "A",
            afterMarkdown: "B"
        )
        // Starts from a state the previous revision didn't finish at, so merging
        // would claim a transition that never happened.
        let unrelated = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-30),
            kind: .userEdit,
            beforeMarkdown: "X",
            afterMarkdown: "Y"
        )

        #expect(DevotionalAgentRevisionCompactor.compact([first, unrelated], now: now).count == 2)
    }

    @Test func kindsStaySeparateAndRestorationsNeverMerge() {
        let typed = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-90), kind: .userEdit,
            beforeMarkdown: "A", afterMarkdown: "B"
        )
        let agent = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-60), kind: .agentEdit,
            beforeMarkdown: "B", afterMarkdown: "C"
        )
        let restoreOne = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-30), kind: .restoration,
            beforeMarkdown: "C", afterMarkdown: "A"
        )
        let restoreTwo = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-10), kind: .restoration,
            beforeMarkdown: "A", afterMarkdown: "C"
        )

        let compacted = DevotionalAgentRevisionCompactor.compact(
            [typed, agent, restoreOne, restoreTwo],
            now: now
        )
        #expect(compacted.count == 4)
    }

    @Test func agentTurnsStayDistinctHoweverOld() {
        // Ten minutes apart, two months ago: user edits like these would merge,
        // but each agent turn remains something a writer may want to undo alone.
        let turns = chain(.agentEdit, startingAt: now.addingTimeInterval(-60 * day), spacing: 10 * minute, count: 3, provider: "Codex")
        #expect(DevotionalAgentRevisionCompactor.compact(turns, now: now).count == 3)

        let oneTurn = chain(.agentEdit, startingAt: now.addingTimeInterval(-60 * day), spacing: 20, count: 3, provider: "Codex")
        #expect(DevotionalAgentRevisionCompactor.compact(oneTurn, now: now).count == 1)
    }

    @Test func agentEditsFromDifferentProvidersStayApart() {
        let codex = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-60), kind: .agentEdit, providerName: "Codex",
            beforeMarkdown: "A", afterMarkdown: "B"
        )
        let claude = DevotionalAgentRevision(
            createdAt: now.addingTimeInterval(-30), kind: .agentEdit, providerName: "Claude",
            beforeMarkdown: "B", afterMarkdown: "C"
        )
        #expect(DevotionalAgentRevisionCompactor.compact([codex, claude], now: now).count == 2)
    }

    @Test func documentsAreCompactedIndependently() {
        let draft = chain(startingAt: now.addingTimeInterval(-60), spacing: 5, count: 3)
        let outline = (0..<3).map { index in
            DevotionalAgentRevision(
                createdAt: now.addingTimeInterval(-58 + Double(index) * 5),
                kind: .userEdit,
                documentPath: "outline.md",
                beforeMarkdown: "outline \(index)",
                afterMarkdown: "outline \(index + 1)"
            )
        }

        let compacted = DevotionalAgentRevisionCompactor.compact(draft + outline, now: now)
        #expect(compacted.count == 2)
        #expect(Set(compacted.map(\.resolvedDocumentPath)) == ["draft.md", "outline.md"])
    }

    @Test func originalsThatComeBackThroughSyncAreRecognised() {
        // Sync merges revision folders by union, so another Mac republishes the
        // originals this one compacted away.
        let originals = chain(startingAt: now.addingTimeInterval(-60), spacing: 5, count: 5)
        let merged = DevotionalAgentRevisionCompactor.compact(originals, now: now)

        let afterSync = DevotionalAgentRevisionCompactor.removingReplaced(merged + originals)
        #expect(afterSync == merged)
    }

    @Test func aLargerMergeReplacesASmallerOne() {
        let originals = chain(startingAt: now.addingTimeInterval(-60), spacing: 5, count: 6)
        let partial = DevotionalAgentRevisionCompactor.compact(Array(originals.prefix(3)), now: now)
        let complete = DevotionalAgentRevisionCompactor.compact(originals, now: now)

        let kept = DevotionalAgentRevisionCompactor.removingReplaced(partial + complete)
        #expect(kept == complete)
    }

    @Test func compactingTheSameHistoryAnywhereGivesTheSameRevisions() {
        // Two Macs compacting identical history must write identical files,
        // or each sync would add the other's copy back.
        let history = chain(startingAt: now.addingTimeInterval(-3 * day), spacing: 30, count: 30)
        let here = DevotionalAgentRevisionCompactor.compact(history, now: now)
        let there = DevotionalAgentRevisionCompactor.compact(history.shuffled(), now: now)
        #expect(here == there)

        // A Mac that compacted first and one that compacts the union afterwards
        // also agree.
        let union = DevotionalAgentRevisionCompactor.compact(here + history, now: now)
        #expect(union == here)
    }
}

struct AgentRevisionStoreCompactionTests {
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func revisionFiles(in workspace: URL) throws -> [URL] {
        let directory = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    @Test func autosavesWhileTypingLeaveOneRevisionOnDisk() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<50 {
            try DevotionalAgentRevisionStore.record(
                kind: .userEdit,
                before: "draft \(index)",
                after: "draft \(index + 1)",
                in: workspace,
                createdAt: start.addingTimeInterval(Double(index) * 5)
            )
        }

        #expect(try revisionFiles(in: workspace).count == 1)
        let revisions = try DevotionalAgentRevisionStore.revisions(in: workspace)
        #expect(revisions.count == 1)
        #expect(revisions.first?.beforeMarkdown == "draft 0")
        #expect(revisions.first?.afterMarkdown == "draft 50")
    }

    @Test func aRepeatedNotificationAfterAMergedRunIsIgnored() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "B", in: workspace, createdAt: start
        )
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "B", after: "C", in: workspace, createdAt: start.addingTimeInterval(5)
        )
        // The merged revision now runs A → C; the same B → C replacement reported
        // a second time is not a new change.
        let duplicate = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "B", after: "C", in: workspace, createdAt: start.addingTimeInterval(6)
        )

        #expect(duplicate == nil)
        #expect(try DevotionalAgentRevisionStore.revisions(in: workspace).count == 1)
    }

    @Test func compactionLeavesUnreadableFilesAlone() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unreadable = directory.appendingPathComponent("from-a-newer-version.json")
        try Data("not a revision".utf8).write(to: unreadable)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<3 {
            try DevotionalAgentRevisionStore.record(
                kind: .userEdit,
                before: "s\(index)",
                after: "s\(index + 1)",
                in: workspace,
                createdAt: start.addingTimeInterval(Double(index) * 5)
            )
        }

        #expect(FileManager.default.fileExists(atPath: unreadable.path))
        #expect(try revisionFiles(in: workspace).count == 2)
    }

    @Test func compactionRemovesOriginalsBroughtBackBySync() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let originals = (0..<4).map { index in
            DevotionalAgentRevision(
                createdAt: start.addingTimeInterval(Double(index) * 5),
                kind: .userEdit,
                documentPath: "draft.md",
                beforeMarkdown: "s\(index)",
                afterMarkdown: "s\(index + 1)"
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        func store(_ revision: DevotionalAgentRevision) throws {
            let name = "\(Int64(revision.createdAt.timeIntervalSince1970 * 1_000))-\(revision.id.uuidString).json"
            try encoder.encode(revision).write(to: directory.appendingPathComponent(name))
        }
        for revision in originals { try store(revision) }

        try DevotionalAgentRevisionStore.compact(in: workspace, now: start.addingTimeInterval(60))
        #expect(try revisionFiles(in: workspace).count == 1)

        // A pull from another Mac restores the originals alongside the merge.
        for revision in originals { try store(revision) }
        #expect(try DevotionalAgentRevisionStore.revisions(in: workspace).count == 1)
        try DevotionalAgentRevisionStore.compact(in: workspace, now: start.addingTimeInterval(60))
        #expect(try revisionFiles(in: workspace).count == 1)
    }

    @Test func aRunThatEndsWhereItBeganIsHiddenButKept() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "Draft", after: "Draft!", in: workspace, createdAt: start
        )
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "Draft!", after: "Draft", in: workspace, createdAt: start.addingTimeInterval(5)
        )

        // Nothing to show — but the file stays, so the originals it replaced
        // are still recognised if another Mac sends them back.
        #expect(try DevotionalAgentRevisionStore.revisions(in: workspace).isEmpty)
        #expect(try revisionFiles(in: workspace).count == 1)
    }
}
