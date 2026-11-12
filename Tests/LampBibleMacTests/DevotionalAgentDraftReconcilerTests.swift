import Foundation
import LampBibleMacSupport
import Testing
@testable import LampBibleMac

/// Deciding who the draft belongs to.
///
/// This is where this feature has gone wrong most often, and every fault
/// was found by reading rather than by running: the deciding lived in
/// methods on a SwiftUI view struct. These drive it against a real
/// workspace and read the files afterwards.
@MainActor
struct DevotionalAgentDraftReconcilerTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reconciler(_ workspace: URL) -> DevotionalAgentDraftReconciler {
        // No Application Support: a draft with no note, which is the rule
        // this workspace's own agent has always followed.
        DevotionalAgentDraftReconciler(
            workspace: workspace, writingID: "writing-1", applicationSupportURL: nil
        )
    }

    private func writeDraft(_ text: String, to workspace: URL) throws {
        try DevotionalAgentWorkspaceStore.writeDraftContent(text, to: workspace)
    }

    private func draft(in workspace: URL) throws -> String {
        try DevotionalAgentWorkspaceStore.readDraft(from: workspace)
    }

    private func history(in workspace: URL) throws -> [DevotionalAgentRevision] {
        try DevotionalAgentRevisionStore.revisions(in: workspace)
    }

    // MARK: - The ordinary passes

    @Test func anAgentsWriteIsTakenUpAndRecorded() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Mine", to: workspace)
        try reconciler(workspace).synchronize(writing: "Mine")

        try writeDraft("The agent's", to: workspace)
        let turn = UUID()
        let outcome = try reconciler(workspace).reconcile(writing: "Mine", turnID: turn)

        #expect(outcome == .take("The agent's"))
        let recorded = try history(in: workspace)
        #expect(recorded.first?.beforeMarkdown == "Mine")
        #expect(recorded.first?.afterMarkdown == "The agent's")
        #expect(recorded.first?.turnID == turn, "the turn that asked for it")
    }

    @Test func nothingHappensWhenNothingMoved() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Mine", to: workspace)
        try reconciler(workspace).synchronize(writing: "Mine")

        #expect(try reconciler(workspace).reconcile(writing: "Mine") == .unchanged)
        #expect(try history(in: workspace).isEmpty)
    }

    /// A run outlives the pane that started it. Close the pane, carry on
    /// writing, and the agent's copy — based on the text as it was —
    /// arrives to a workspace with nobody reconciling the two.
    @Test func whenBothSidesMovedTheWritersWordsStay() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Base", to: workspace)
        try reconciler(workspace).synchronize(writing: "Base")

        // The pane closes. The person writes on; the run writes its own.
        try writeDraft("The agent's, from the base", to: workspace)
        let outcome = try reconciler(workspace).prepare(writing: "Mine, written since")

        guard case .keep = outcome else {
            Issue.record("expected the writing to be kept, got \(outcome)")
            return
        }
        #expect(try draft(in: workspace) == "Mine, written since", "the workspace is put back to what Lamp holds")
        #expect(
            try history(in: workspace).contains { $0.afterMarkdown == "The agent's, from the base" },
            "and theirs is in the history to read"
        )
    }

    /// The same, but the writing has not moved: then the draft is the
    /// newer text and is taken.
    @Test func whenOnlyTheDraftMovedItIsTaken() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Base", to: workspace)
        try reconciler(workspace).synchronize(writing: "Base")
        try writeDraft("The agent's", to: workspace)

        #expect(try reconciler(workspace).prepare(writing: "Base") == .take("The agent's"))
    }

    /// Two windows on one writing. The marker is the workspace's, not each
    /// pane's — a pane holding its own read the person's typing in the
    /// other window as an agent edit, under whatever turn was running, and
    /// undoing that turn took their words away.
    @Test func typingInOneWindowIsNotTheAgentsWorkInAnother() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let one = reconciler(workspace), two = reconciler(workspace)
        try writeDraft("Base", to: workspace)
        try one.synchronize(writing: "Base")
        try two.synchronize(writing: "Base")

        // The person types in the first window.
        try one.synchronize(writing: "Base, and a new sentence")

        // The second window polls, with a turn running — and holding the
        // text as it was before the first window's keystroke. That is the
        // real shape of it: the pane that did not receive the typing is
        // the one that misreads it, and it is behind by exactly that
        // sentence.
        let turn = UUID()
        let outcome = try two.reconcile(writing: "Base", turnID: turn)
        #expect(outcome == .unchanged)
        #expect(
            try history(in: workspace).isEmpty,
            "the typing is the person's, and belongs to no agent turn"
        )

        // And when the agent really does write, that *is* recorded, so the
        // check above is not passing because nothing is ever recorded.
        try writeDraft("The agent's", to: workspace)
        #expect(try two.reconcile(writing: "Base", turnID: turn) == .take("The agent's"))
        #expect(try history(in: workspace).contains { $0.turnID == turn })
    }

    // MARK: - Putting a version back

    @Test func anUndoPutsTheDraftBackToBeforeTheTurn() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Mine", to: workspace)
        try reconciler(workspace).synchronize(writing: "Mine")
        let turn = UUID()
        try writeDraft("The agent's", to: workspace)
        _ = try reconciler(workspace).reconcile(writing: "Mine", turnID: turn)

        let outcome = try reconciler(workspace).undo(turns: [turn], writing: "The agent's")
        #expect(outcome == .restored("Mine"))
        #expect(try draft(in: workspace) == "Mine")
        #expect(
            try history(in: workspace).contains { $0.kind == .restoration && $0.beforeMarkdown == "The agent's" },
            "the restore is itself recorded, so it can be undone"
        )
    }

    /// Undoing a turn takes everything after it, so what it puts back has
    /// to account for all of them — and refuse where it cannot.
    @Test func aTurnThatChangedAnotherDocumentIsRefused() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Mine", to: workspace)
        try reconciler(workspace).synchronize(writing: "Mine")
        let first = UUID(), second = UUID()
        try writeDraft("The agent's", to: workspace)
        _ = try reconciler(workspace).reconcile(writing: "Mine", turnID: first)
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, turnID: second, documentPath: "notes.md",
            before: "", after: "A note", in: workspace
        )

        let outcome = try reconciler(workspace).undo(
            turns: [first, second], writing: "The agent's"
        )
        guard case .refused(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("notes.md"))
        #expect(try draft(in: workspace) == "The agent's", "nothing was changed at all")
    }

    /// A version written to the file since this pane last looked is taken
    /// up before it is written over, so it is in the history rather than
    /// nowhere.
    @Test func aRestoreRecordsTheVersionItActuallyReplaces() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Mine", to: workspace)
        try reconciler(workspace).synchronize(writing: "Mine")

        // A run that outlived the pane writes, and nobody has polled.
        try writeDraft("Written while nobody watched", to: workspace)

        let restored = try reconciler(workspace).restore("An older version", writing: "Mine")
        #expect(restored == "An older version")
        #expect(try draft(in: workspace) == "An older version")
        // The restoration's own `before` is the text that was in the file,
        // not the caller's copy. Asserting only that the unseen version is
        // somewhere in the history passes either way: the pass this makes
        // first records it too.
        let restoration = try #require(
            try history(in: workspace).first { $0.kind == .restoration }
        )
        #expect(
            restoration.beforeMarkdown == "Written while nobody watched",
            "a restore records the version it actually replaced"
        )
    }

    /// Restoring the same version twice, with typing in between, used to
    /// read as a repeat and record nothing while overwriting the typing.
    @Test func restoringTwiceKeepsWhatWasWrittenBetween() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Mine", to: workspace)
        try reconciler(workspace).synchronize(writing: "Mine")
        try writeDraft("The agent's", to: workspace)
        _ = try reconciler(workspace).reconcile(writing: "Mine", turnID: UUID())

        _ = try reconciler(workspace).restore("Mine", writing: "The agent's")
        try reconciler(workspace).synchronize(writing: "Mine, with a new paragraph")
        _ = try reconciler(workspace).restore("Mine", writing: "Mine, with a new paragraph")

        #expect(
            try history(in: workspace).contains { $0.beforeMarkdown == "Mine, with a new paragraph" },
            "the paragraph written between the two restores is recoverable"
        )
    }

    /// The marker is read from the workspace every time, so a reconciler
    /// built fresh — as the view's is, on every pass — knows where things
    /// stand without being told.
    @Test func theWorkspaceRemembersWhereThingsStand() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try writeDraft("Mine", to: workspace)
        try reconciler(workspace).synchronize(writing: "Mine")
        #expect(reconciler(workspace).marker() == "Mine")
    }
}
