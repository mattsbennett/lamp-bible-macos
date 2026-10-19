import Foundation
import Testing
@testable import LampBibleMacSupport

/// An agent is told `draft.md` changed but not what changed, so to tell the
/// writer's edits from its own it kept private copies of the draft and compared
/// them. Lamp already holds the revisions; these cover handing them over.
struct WritingChangesSupportTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The diff itself

    @Test func showsAChangedLineWithTheLinesAroundIt() {
        let diff = LampUnifiedDiff.diff(
            before: """
            One.
            Two.
            So on capacity there has been no meaningful change.
            Four.
            Five.
            """,
            after: """
            One.
            Two.
            But on this question of capacity, there has been no meaningful change.
            Four.
            Five.
            """,
            beforeLabel: "draft.md before",
            afterLabel: "draft.md after"
        )
        #expect(diff.hasPrefix("--- draft.md before\n+++ draft.md after\n@@ "))
        #expect(diff.contains("-So on capacity there has been no meaningful change."))
        #expect(diff.contains("+But on this question of capacity, there has been no meaningful change."))
        // The lines around it, so the hunk can be placed.
        #expect(diff.contains(" Two."))
        #expect(diff.contains(" Four."))
    }

    @Test func saysNothingAboutAnUnchangedDocument() {
        #expect(LampUnifiedDiff.diff(before: "Same.", after: "Same.").isEmpty)
    }

    @Test func reportsAnAdditionAndARemoval() {
        let added = LampUnifiedDiff.diff(before: "One.\nThree.", after: "One.\nTwo.\nThree.")
        #expect(added.contains("+Two."))
        #expect(!added.contains("-One."))

        let removed = LampUnifiedDiff.diff(before: "One.\nTwo.\nThree.", after: "One.\nThree.")
        #expect(removed.contains("-Two."))
        #expect(!removed.contains("+Three."))
    }

    /// Two edits far apart are two hunks, not one hunk swallowing the
    /// untouched middle of a talk.
    @Test func separatesTwoDistantEditsIntoTwoHunks() {
        let before = (1...40).map { "Line \($0)." }.joined(separator: "\n")
        var lines = (1...40).map { "Line \($0)." }
        lines[2] = "Line 3, reworded."
        lines[36] = "Line 37, reworded."
        let diff = LampUnifiedDiff.diff(before: before, after: lines.joined(separator: "\n"))
        #expect(diff.components(separatedBy: "@@ -").count - 1 == 2)
        #expect(!diff.contains(" Line 20."))
    }

    /// A document replaced wholesale reads as a replacement rather than costing
    /// a table of millions of cells to say so.
    @Test func reportsAWholesaleRewriteWithoutMatchingLineByLine() {
        let before = (1...3_000).map { "Before \($0)." }.joined(separator: "\n")
        let after = (1...3_000).map { "After \($0)." }.joined(separator: "\n")
        let diff = LampUnifiedDiff.diff(before: before, after: after)
        #expect(diff.contains("-Before 1."))
        #expect(diff.contains("+After 1."))
    }

    @Test func doesNotInventATrailingBlankLine() {
        #expect(LampUnifiedDiff.lines(of: "One.\nTwo.\n") == ["One.", "Two."])
        #expect(LampUnifiedDiff.lines(of: "One.\nTwo.") == ["One.", "Two."])
        #expect(LampUnifiedDiff.lines(of: "") == [""])
    }

    // MARK: - Reading the history

    @Test func tellsTheWritersEditsFromTheAgents() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            providerName: "Claude Code",
            before: "The opening.",
            after: "The opening, tightened.",
            in: directory,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit,
            before: "The opening, tightened.",
            after: "The opening, tightened again by hand.",
            in: directory,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        let changes = try LampWritingChanges.changes(in: directory)
        // Oldest first: the order they happened, which is how they read.
        #expect(changes.map(\.source) == [.agent, .editor])
        #expect(changes.first?.providerName == "Claude Code")
        #expect(changes.last?.diff.contains("+The opening, tightened again by hand.") == true)
        #expect(changes.last?.addedLines == 1)
        #expect(changes.last?.removedLines == 1)
        #expect(changes.allSatisfy { $0.documentPath == "draft.md" })
    }

    @Test func returnsOnlyWhatFollowsAChangeAlreadyRead() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "One.", after: "Two.", in: directory,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "Two.", after: "Three.", in: directory,
            createdAt: Date(timeIntervalSince1970: 100_000)
        )

        let all = try LampWritingChanges.changes(in: directory)
        #expect(all.count == 2)
        let first = try #require(all.first)
        let rest = try LampWritingChanges.changes(in: directory, since: .revision(first.id))
        #expect(rest.count == 1)
        #expect(rest.first?.diff.contains("+Three.") == true)

        // And nothing at all once the last one has been read.
        let last = try #require(all.last)
        #expect(try LampWritingChanges.changes(
            in: directory, since: .revision(last.id)
        ).isEmpty)
    }

    @Test func readsASinceValueAsAnIdentifierOrATime() {
        let id = UUID()
        guard case .revision(let parsed) = LampWritingChanges.since(id.uuidString) else {
            Issue.record("a UUID should read as a revision")
            return
        }
        #expect(parsed == id)

        guard case .time(let date) = LampWritingChanges.since("2026-10-19T09:30:00Z") else {
            Issue.record("an ISO 8601 string should read as a time")
            return
        }
        #expect(date == Date(timeIntervalSince1970: 1_792_402_200))

        // Anything else means "whatever is most recent" rather than an error:
        // an agent asking the wrong way should still learn something.
        guard case .latest = LampWritingChanges.since("yesterday") else {
            Issue.record("an unreadable value should read as the latest changes")
            return
        }
        guard case .latest = LampWritingChanges.since(nil) else {
            Issue.record("no value should read as the latest changes")
            return
        }
    }

    @Test func returnsTheMostRecentWhenMoreExistThanAsked() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        for step in 1...4 {
            try DevotionalAgentRevisionStore.record(
                kind: .userEdit,
                before: "Step \(step).",
                after: "Step \(step + 1).",
                in: directory,
                // Far enough apart that the store keeps them as separate
                // revisions rather than merging the run.
                createdAt: Date(timeIntervalSince1970: Double(step) * 100_000)
            )
        }
        let changes = try LampWritingChanges.changes(in: directory, limit: 2)
        #expect(changes.count == 2)
        #expect(changes.last?.diff.contains("+Step 5.") == true)
    }

    @Test func hasNothingToSayAboutAWorkspaceWithNoHistory() throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try LampWritingChanges.changes(in: directory).isEmpty)
    }
}
