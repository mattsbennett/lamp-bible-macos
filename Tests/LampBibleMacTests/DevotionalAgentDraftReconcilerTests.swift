import Foundation
import LampBibleMacSupport
import LampCore
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

    /// No note is left anywhere, which is the rule this workspace's own
    /// agent has always followed. `support` is where a restore's receipt
    /// goes — a folder of this test's own, so one test cannot finish
    /// another's restore.
    private func reconciler(
        _ workspace: URL, support: URL? = nil
    ) -> DevotionalAgentDraftReconciler {
        DevotionalAgentDraftReconciler(
            workspace: workspace, writingID: "writing-1", applicationSupportURL: support
        )
    }

    private func writeDraft(_ text: String, to workspace: URL) async throws {
        try await DevotionalAgentWorkspaceStore.writeDraftContent(text, to: workspace)
    }

    private func draft(in workspace: URL) async throws -> String {
        try await DevotionalAgentWorkspaceStore.readDraft(from: workspace)
    }

    private func history(in workspace: URL) throws -> [DevotionalAgentRevision] {
        try DevotionalAgentRevisionStore.revisions(in: workspace)
    }

    // MARK: - The ordinary passes

    @Test func anAgentsWriteIsTakenUpAndRecorded() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")

        try await writeDraft("The agent's", to: workspace)
        let turn = UUID()
        let outcome = try await reconciler(workspace).reconcile(writing: "Mine", turnID: turn).outcome

        #expect(outcome == .take("The agent's"))
        let recorded = try history(in: workspace)
        #expect(recorded.first?.beforeMarkdown == "Mine")
        #expect(recorded.first?.afterMarkdown == "The agent's")
        #expect(recorded.first?.turnID == turn, "the turn that asked for it")
    }

    @Test func nothingHappensWhenNothingMoved() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")

        #expect(try await reconciler(workspace).reconcile(writing: "Mine").outcome == .unchanged)
        #expect(try history(in: workspace).isEmpty)
    }

    /// A run outlives the pane that started it. Close the pane, carry on
    /// writing, and the agent's copy — based on the text as it was —
    /// arrives to a workspace with nobody reconciling the two.
    @Test func whenBothSidesMovedTheWritersWordsStay() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Base", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Base")

        // The pane closes. The person writes on; the run writes its own.
        try await writeDraft("The agent's, from the base", to: workspace)
        let outcome = try await reconciler(workspace).prepare(writing: "Mine, written since").outcome

        guard case .keep = outcome else {
            Issue.record("expected the writing to be kept, got \(outcome)")
            return
        }
        #expect(try await draft(in: workspace) == "Mine, written since", "the workspace is put back to what Lamp holds")
        #expect(
            try history(in: workspace).contains { $0.afterMarkdown == "The agent's, from the base" },
            "and theirs is in the history to read"
        )
    }

    /// The same, but the writing has not moved: then the draft is the
    /// newer text and is taken.
    @Test func whenOnlyTheDraftMovedItIsTaken() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Base", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Base")
        try await writeDraft("The agent's", to: workspace)

        #expect(try await reconciler(workspace).prepare(writing: "Base").outcome == .take("The agent's"))
    }

    /// Two windows on one writing. The marker is the workspace's, not each
    /// pane's — a pane holding its own read the person's typing in the
    /// other window as an agent edit, under whatever turn was running, and
    /// undoing that turn took their words away.
    @Test func typingInOneWindowIsNotTheAgentsWorkInAnother() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let one = reconciler(workspace), two = reconciler(workspace)
        try await writeDraft("Base", to: workspace)
        try await one.synchronize(writing: "Base")
        try await two.synchronize(writing: "Base")

        // The person types in the first window.
        try await one.synchronize(writing: "Base, and a new sentence")

        // The second window polls, with a turn running — and holding the
        // text as it was before the first window's keystroke. That is the
        // real shape of it: the pane that did not receive the typing is
        // the one that misreads it, and it is behind by exactly that
        // sentence.
        let turn = UUID()
        let outcome = try await two.reconcile(writing: "Base", turnID: turn).outcome
        // Taken up, since this window is behind — but recorded by nobody,
        // which is the point: it is the person's typing, not a turn's.
        #expect(outcome == .adopt("Base, and a new sentence"))
        #expect(
            try history(in: workspace).isEmpty,
            "the typing is the person's, and belongs to no agent turn"
        )

        // And when the agent really does write, that *is* recorded, so the
        // check above is not passing because nothing is ever recorded.
        try await writeDraft("The agent's", to: workspace)
        #expect(try await two.reconcile(writing: "Base", turnID: turn).outcome == .take("The agent's"))
        #expect(try history(in: workspace).contains { $0.turnID == turn })
    }

    // MARK: - Putting a version back

    @Test func anUndoPutsTheDraftBackToBeforeTheTurn() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")
        let turn = UUID()
        try await writeDraft("The agent's", to: workspace)
        _ = try await reconciler(workspace).reconcile(writing: "Mine", turnID: turn).outcome

        let outcome = try await reconciler(workspace).undo(turns: [turn], writing: "The agent's").outcome
        #expect(outcome == .restored("Mine"))
        #expect(try await draft(in: workspace) == "Mine")
        #expect(
            try history(in: workspace).contains { $0.kind == .restoration && $0.beforeMarkdown == "The agent's" },
            "the restore is itself recorded, so it can be undone"
        )
    }

    /// Undoing a turn takes everything after it, so what it puts back has
    /// to account for all of them — and refuse where it cannot.
    @Test func aTurnThatChangedAnotherDocumentIsRefused() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")
        let first = UUID(), second = UUID()
        try await writeDraft("The agent's", to: workspace)
        _ = try await reconciler(workspace).reconcile(writing: "Mine", turnID: first).outcome
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, turnID: second, documentPath: "notes.md",
            before: "", after: "A note", in: workspace
        )

        let outcome = try await reconciler(workspace).undo(
            turns: [first, second], writing: "The agent's"
        ).outcome
        guard case .refused(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("notes.md"))
        #expect(try await draft(in: workspace) == "The agent's", "nothing was changed at all")
    }

    /// A version written to the file since this pane last looked is taken
    /// up before it is written over, so it is in the history rather than
    /// nowhere.
    @Test func aRestoreRecordsTheVersionItActuallyReplaces() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")

        // A run that outlived the pane writes, and nobody has polled.
        try await writeDraft("Written while nobody watched", to: workspace)

        let restored = try await reconciler(workspace).restore("An older version", writing: "Mine").outcome
        #expect(restored == "An older version")
        #expect(try await draft(in: workspace) == "An older version")
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
    @Test func restoringTwiceKeepsWhatWasWrittenBetween() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")
        try await writeDraft("The agent's", to: workspace)
        _ = try await reconciler(workspace).reconcile(writing: "Mine", turnID: UUID()).outcome

        _ = try await reconciler(workspace).restore("Mine", writing: "The agent's").outcome
        try await reconciler(workspace).synchronize(writing: "Mine, with a new paragraph")
        _ = try await reconciler(workspace).restore("Mine", writing: "Mine, with a new paragraph").outcome

        #expect(
            try history(in: workspace).contains { $0.beforeMarkdown == "Mine, with a new paragraph" },
            "the paragraph written between the two restores is recoverable"
        )
    }

    /// A second window has to take up what the first accounted for. It
    /// records nothing — that is the first window's to record — but it
    /// cannot go on holding the older text, or its own next save writes
    /// that back over the newer one.
    @Test func theOtherWindowTakesUpWhatThisOneAccountedFor() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let one = reconciler(workspace), two = reconciler(workspace)
        try await writeDraft("Base", to: workspace)
        try await one.synchronize(writing: "Base")

        try await one.synchronize(writing: "Base, and a new sentence")
        let outcome = try await two.reconcile(writing: "Base").outcome
        #expect(outcome == .adopt("Base, and a new sentence"))
        #expect(try history(in: workspace).isEmpty, "and records nothing of its own")
    }

    /// A run outlives its pane, so reopening is when its work is found —
    /// and that work belongs to the turn that asked for it.
    @Test func workFoundOnReopeningKeepsItsTurn() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Base", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Base")

        // The pane closes mid-run; the run writes; the pane reopens.
        try await writeDraft("What the run wrote", to: workspace)
        let turn = UUID()
        let outcome = try await reconciler(workspace).prepare(writing: "Base", turnID: turn).outcome

        #expect(outcome == .take("What the run wrote"))
        #expect(
            try history(in: workspace).contains { $0.turnID == turn },
            "found late is not found unowned"
        )
    }

    /// A restore writes the history, then the draft, then the writing. A
    /// crash in the last step used to look exactly like the writer having
    /// edited while the pane was closed — so the undone work was put back,
    /// with its turn already gone from the conversation.
    @Test func anInterruptedRestoreIsFinishedRatherThanReversed() async throws {
        let support = try workspace()
        let workspace = try workspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: support)
        }
        try await writeDraft("The agent's", to: workspace)
        try await reconciler(workspace, support: support).synchronize(writing: "The agent's")
        _ = try await reconciler(workspace, support: support).restore("Mine", writing: "The agent's").outcome
        // The draft and the mark are "Mine"; Lamp never got it.
        #expect(try await draft(in: workspace) == "Mine")

        let outcome = try await reconciler(workspace, support: support).prepare(writing: "The agent's").outcome
        #expect(outcome == .take("Mine"), "the receipt says the restore was still outstanding")
        #expect(try await draft(in: workspace) == "Mine")
    }

    /// The same shape, from a restore that **finished**: the person
    /// undoes, then deliberately types the old version back while the
    /// pane is closed. Read as an interrupted restore, their typing was
    /// thrown away.
    @Test func typingTheOldVersionBackIsNotAnInterruptedRestore() async throws {
        let support = try workspace()
        let workspace = try workspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: support)
        }
        try await writeDraft("The agent's", to: workspace)
        try await reconciler(workspace, support: support).synchronize(writing: "The agent's")
        _ = try await reconciler(workspace, support: support).restore("Mine", writing: "The agent's").outcome
        // The restore reached the writing: the next pass sees Lamp
        // holding it, and the receipt is torn up.
        #expect(try await reconciler(workspace, support: support).reconcile(writing: "Mine").outcome == .unchanged)

        // Now they type the agent's version back in, with the pane closed.
        let outcome = try await reconciler(workspace, support: support).prepare(writing: "The agent's").outcome
        #expect(outcome == .unchanged, "their text is the newer side and stays")
        #expect(try await draft(in: workspace) == "The agent's")
    }

    /// Two windows, both typing. The second overwrites what the first put
    /// in the workspace before the first had saved it — so the first
    /// window's sentence is filed before it goes.
    @Test func theOtherWindowsUnsavedTextIsFiledBeforeItIsReplaced() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("A", to: workspace)
        try await reconciler(workspace).synchronize(writing: "A", lastKnownMarker: nil)

        // Window one types, and has not autosaved yet.
        try await reconciler(workspace).synchronize(writing: "A and B", lastKnownMarker: "A")
        // Window two types, still believing the two agreed at "A".
        try await reconciler(workspace).synchronize(writing: "A and C", lastKnownMarker: "A")

        #expect(try await draft(in: workspace) == "A and C")
        #expect(
            try history(in: workspace).contains { $0.afterMarkdown == "A and B" },
            "the first window's sentence is recoverable"
        )
    }

    /// The marker is read from the workspace every time, so a reconciler
    /// built fresh — as the view's is, on every pass — knows where things
    /// stand without being told.
    // MARK: - Marking what the assistant changed

    private func marking(_ workspace: URL) -> DevotionalAgentDraftReconciler {
        DevotionalAgentDraftReconciler(
            workspace: workspace, writingID: "writing-1", applicationSupportURL: nil
        )
    }

    /// Makes the marks a pass asked for, as the editor and the phone's host
    /// both do: a pass names them, its caller makes them.
    @MainActor
    private func make(
        _ changes: [DevotionalAgentDraftReconciler.ReviewChange], in store: LampWritingReviewStore
    ) {
        WritingReviewChanges(writingID: "writing-1", store: store).make(changes)
    }

    private func marked(_ store: LampWritingReviewStore, in text: String) throws -> [String] {
        try store.review(writingID: "writing-1").highlightedRanges(in: text).map { (text as NSString).substring(with: $0) }
    }

    @Test func aDraftTakenInIsMarkedUnderItsTurnAndUndoingTheTurnTakesTheMark() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LampWritingReviewStore(rootURL: workspace.appendingPathComponent("library", isDirectory: true))
        try await writeDraft("One two three.", to: workspace)
        _ = try await marking(workspace).synchronize(writing: "One two three.")

        let turn = UUID()
        try await writeDraft("One deux three.", to: workspace)
        let taking = try await marking(workspace).reconcile(writing: "One two three.", turnID: turn)
        #expect(taking.outcome == .take("One deux three."))
        await make(taking.reviewChanges, in: store)
        await WritingReviewWork.shared.drained()
        #expect(try marked(store, in: "One deux three.") == ["deux"])
        #expect(try store.review(writingID: "writing-1").marks.first?.turnID == turn)

        let undoing = try await marking(workspace).undo(turns: [turn], writing: "One deux three.")
        await make(undoing.reviewChanges, in: store)
        await WritingReviewWork.shared.drained()
        #expect(try store.review(writingID: "writing-1").isEmpty)
    }

    @Test func aDraftOnlyFiledInTheHistoryIsNotMarked() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LampWritingReviewStore(rootURL: workspace.appendingPathComponent("library", isDirectory: true))
        try await writeDraft("Base", to: workspace)
        _ = try await marking(workspace).synchronize(writing: "Base")
        try await writeDraft("The agent's, from the base", to: workspace)
        let keeping = try await marking(workspace).prepare(writing: "Mine, written since")
        guard case .keep = keeping.outcome else {
            Issue.record("expected the writing to be kept")
            return
        }
        // Whatever it asked for is made, so "nothing is marked" is a fact
        // about the pass rather than about the caller skipping it.
        await make(keeping.reviewChanges, in: store)
        await WritingReviewWork.shared.drained()
        #expect(try store.review(writingID: "writing-1").isEmpty)
    }

    /// Adopting another window's text must move this one's mark with it.
    ///
    /// The pass writes nothing on that branch, but it read the marker under
    /// the owner, so it reports it. Left without it, the adopting window kept
    /// its old mark and its next keystroke filed the text it had just taken
    /// in as a fresh edit of its own.
    @Test func adoptingAnotherWindowsTextDoesNotFileItAgain() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let a = reconciler(workspace), b = reconciler(workspace)
        try await writeDraft("Base", to: workspace)
        _ = try await a.synchronize(writing: "Base")
        var marker = try await b.synchronize(writing: "Base").markerLeft

        // The first window types; the second has not seen it yet.
        _ = try await a.synchronize(writing: "Base, and more")
        let adopting = try await b.reconcile(writing: "Base")
        #expect(adopting.outcome == .adopt("Base, and more"))
        marker = adopting.markerLeft
        #expect(marker == "Base, and more", "the adopting pass reports the mark it read")

        // The second window, now holding that text, types on.
        let before = try history(in: workspace).count
        _ = try await b.synchronize(writing: "Base, and more, and mine", lastKnownMarker: marker)
        #expect(
            try history(in: workspace).count == before,
            "the adopted text must not be filed again as this window's own edit"
        )
    }

    // MARK: - A turn no window is watching

    @Test func unwatchedAnAgentsWriteIsTaken() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")
        try await writeDraft("The agent's", to: workspace)
        #expect(try await reconciler(workspace).reconcileUnwatched(writing: "Mine").outcome == .take("The agent's"))
    }

    @Test func unwatchedAnEditSyncedInUnderAnUntouchedDraftIsNotUndone() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Before", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Before")
        // Edited on the phone and synced here; the draft has not moved.
        #expect(try await reconciler(workspace).reconcileUnwatched(writing: "Edited on the phone").outcome == .unchanged)
        #expect(try await draft(in: workspace) == "Before", "left for the next turn to level")
        // And the next turn's prepare levels it.
        _ = try await reconciler(workspace).prepare(writing: "Edited on the phone").outcome
        #expect(try await draft(in: workspace) == "Edited on the phone")
    }

    @Test func unwatchedBothMovingKeepsTheWritersWords() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Base", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Base")
        try await writeDraft("The agent's, from the base", to: workspace)
        guard case .keep = try await reconciler(workspace).reconcileUnwatched(writing: "Mine, synced in since").outcome else {
            Issue.record("expected the writing to be kept")
            return
        }
        #expect(try history(in: workspace).contains { $0.afterMarkdown == "The agent's, from the base" })
    }

    @Test func theWorkspaceRemembersWhereThingsStand() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await writeDraft("Mine", to: workspace)
        try await reconciler(workspace).synchronize(writing: "Mine")
        #expect(await reconciler(workspace).marker() == "Mine")
    }
}
