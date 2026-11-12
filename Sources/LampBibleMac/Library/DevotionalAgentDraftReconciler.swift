import Foundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

/// Who the draft belongs to at each moment, and what to do when two
/// answers disagree.
///
/// The writing has three copies: the one Lamp holds, the `draft.md` an
/// agent writes, and the revision history that records the way between
/// them. Deciding between them is the part of this feature that has gone
/// wrong most often — a stale copy captured in a long-lived closure, two
/// panes each believing they were the only one watching, a restore
/// recording a version nobody had, a crash between two writes — and every
/// one of those was found by reading, after it shipped, because the
/// deciding lived in methods on a SwiftUI view struct and nothing could
/// run it.
///
/// So it lives here, where a test can. The rules are unchanged; what
/// changed is that they are reachable.
///
/// **It keeps no copy of the draft.** The workspace's own synced marker is
/// what it compares against, read each time. A pane holding its own was
/// how one window came to record the person's typing in another window as
/// the agent's work, under whatever turn was running — which an undo of
/// that turn then took away.
@MainActor
struct DevotionalAgentDraftReconciler {
    let workspace: URL
    let writingID: String
    /// Where a write from outside Lamp leaves its note. Nil in a test, or
    /// where there is no Application Support to read, which reads as "no
    /// note" — the rule a draft without one has always followed.
    let applicationSupportURL: URL?

    init(workspace: URL, writingID: String, applicationSupportURL: URL?) {
        self.workspace = workspace
        self.writingID = writingID
        self.applicationSupportURL = applicationSupportURL
    }

    /// What the caller should do about the writing it holds.
    enum Outcome: Equatable, Sendable {
        /// Nothing moved.
        case unchanged
        /// Take this text into the writing: an agent wrote it, and the
        /// writing had not moved under it.
        case take(String)
        /// Keep the writing as it is. The draft that arrived is in the
        /// history instead, and this says so.
        case keep(note: String)
    }

    /// What an undo did, or why it did nothing.
    enum UndoOutcome: Equatable, Sendable {
        /// The draft is back to this; take it into the writing.
        case restored(String)
        /// Those turns changed nothing this can put back, so only the
        /// conversation is affected.
        case nothingToPutBack
        /// They also changed something this cannot put back whole, so
        /// nothing was changed at all.
        case refused(String)
    }

    /// The text in the workspace now.
    ///
    /// Read rather than remembered, for the same reason as the marker: an
    /// outside app can write `draft.md` between two passes, and a run
    /// outlives the pane that started it.
    func draftOnDisk() throws -> String {
        try DevotionalAgentWorkspaceStore.readDraft(from: workspace)
    }

    /// Where this workspace and the writing last agreed, as the workspace
    /// records it — not as any one pane remembers it.
    func marker() -> String? {
        try? DevotionalAgentRevisionStore.lastSyncedDraft(in: workspace)
    }

    // MARK: - The passes

    /// The poll: takes up anything written to the workspace since it and
    /// the writing last agreed.
    ///
    /// `writing` is the writing as Lamp holds it **now**, passed in rather
    /// than captured, because the caller is a view whose stored properties
    /// stop changing the moment a long-lived closure captures it.
    func reconcile(
        writing: String,
        provider: String? = nil,
        turnID: UUID? = nil
    ) throws -> Outcome {
        let diskDraft = try draftOnDisk()
        guard let marker = marker(), diskDraft != marker else { return .unchanged }
        return try takeOrKeep(
            diskDraft: diskDraft, writing: writing, previous: marker,
            provider: provider, turnID: turnID
        )
    }

    /// Opening the pane, where the two may have moved apart while it was
    /// closed — including by a run that outlived it.
    func prepare(writing: String, provider: String? = nil) throws -> Outcome {
        let diskDraft = try draftOnDisk()
        let persisted = marker()
        if diskDraft == writing {
            try markSynced(writing)
            return .unchanged
        }
        if persisted == diskDraft {
            // The writing changed while the pane was closed, so its
            // current text is the newer side of the live workspace.
            try DevotionalAgentWorkspaceStore.writeDraftContent(writing, to: workspace)
            try markSynced(writing)
            return .unchanged
        }
        // Both sides may have moved: a run outlives its pane, so the agent
        // can write to the workspace while the writer carries on in the
        // editor, with nothing mounted to reconcile the two as they go.
        // That is the one case where the arriving draft must not simply be
        // taken, and the marker is the base that says so.
        return try takeOrKeep(
            diskDraft: diskDraft,
            writing: writing,
            previous: persisted,
            provider: provider,
            turnID: nil,
            writingMovedSince: persisted.map { $0 != writing } ?? false
        )
    }

    /// The writer's own change, on its way to the workspace.
    func synchronize(
        writing: String,
        provider: String? = nil,
        turnID: UUID? = nil
    ) throws {
        let marker = marker()
        guard writing != marker else { return }
        // If the writer and the agent changed during the same interval,
        // keep the writer's live edit and retain the agent's version in
        // history.
        let diskDraft = try draftOnDisk()
        if let marker, diskDraft != marker, diskDraft != writing {
            try record(before: marker, after: diskDraft, provider: provider, turnID: turnID)
        } else if marker == nil, diskDraft != writing {
            // Nothing has synced yet — the moment just after the pane
            // opens. The branch above cannot run, so the draft on disk
            // used to be overwritten with no record of it. Rare while only
            // this workspace's own agent could have written it; an outside
            // app can write at any moment, including this one.
            try record(before: diskDraft, after: diskDraft, provider: provider, turnID: turnID)
        }
        try DevotionalAgentWorkspaceStore.writeDraftContent(writing, to: workspace)
        try markSynced(writing)
    }

    /// Takes a draft written in the workspace, or keeps the writer's text
    /// and files the draft in history instead.
    ///
    /// Until the writing could be written from outside, the arriving draft
    /// always won, which was right while only an agent working in this
    /// workspace could have written it. Now the question "has the writing
    /// moved since that draft was based on it?" has to be asked, and
    /// `LampWritingWrite.Note` is what answers it. No times are compared;
    /// a clock says which write was later, which is not the question.
    ///
    /// Without a note the old rule applies, so a draft from this
    /// workspace's own agent, or from a Lamp that predates the note,
    /// behaves as before — unless the caller already knows both sides have
    /// moved, which is the same answer a note would have given.
    func takeOrKeep(
        diskDraft: String,
        writing: String,
        previous: String?,
        provider: String?,
        turnID: UUID?,
        writingMovedSince: Bool = false
    ) throws -> Outcome {
        let note = applicationSupportURL.flatMap {
            LampWritingWrite.note(applicationSupportURL: $0, writingID: writingID)
        }
        let resolution = LampWritingWrite.resolve(
            note: note,
            draftOnDisk: diskDraft,
            // The caller holds Lamp's own full copy, so this fingerprints
            // that rather than asking the library — same rule, no round
            // trip.
            libraryRevision: LampWritingWrite.fingerprint(writing)
        )
        // Spent either way: it describes this draft, and this is the
        // decision it was left for.
        if let applicationSupportURL, note != nil {
            LampWritingWrite.forgetNote(
                applicationSupportURL: applicationSupportURL, writingID: writingID
            )
        }

        switch resolution {
        case .takeDraftUnrecorded where writingMovedSince:
            // No note, but the caller has the answer the note would have
            // given: the writer's text and this draft both moved from the
            // same base. Their words stay, and the draft goes to history —
            // the same resolution, reached without one.
            fallthrough

        case .keepWritingAndRecordDraft:
            try record(before: writing, after: diskDraft, provider: provider, turnID: turnID)
            try DevotionalAgentWorkspaceStore.writeDraftContent(writing, to: workspace)
            try markSynced(writing)
            return .keep(note: """
                A draft written outside the editor was not applied: you had edited \
                this writing since. Your text is unchanged, and the draft is in the \
                history below.
                """)

        case .takeDraft, .takeDraftUnrecorded:
            try record(
                before: previous ?? writing, after: diskDraft,
                provider: provider, turnID: turnID
            )
            try markSynced(diskDraft)
            return .take(diskDraft)
        }
    }

    // MARK: - Putting a version back

    /// Puts the draft back as it was before these turns, and says what the
    /// writing should now hold.
    ///
    /// `turns` is all of them — the turn the reader named and everything
    /// that followed it, in the conversation's order, since all of that is
    /// leaving the conversation. Asked about the named turn alone, this
    /// put the draft back to before it and left the later turns' work in
    /// the writing, having just removed the questions that accounted for
    /// it.
    ///
    /// The draft alone. A turn that changed another document is refused
    /// rather than half restored — and the refusal is only as good as the
    /// history, which is why every document the editor manages records
    /// one.
    func undo(
        turns: [UUID],
        writing: String,
        provider: String? = nil
    ) throws -> UndoOutcome {
        guard !turns.isEmpty else { return .nothingToPutBack }
        // Anything the agent wrote and the poll has not picked up yet is
        // collected first, so it is in the history as its own change
        // rather than being overwritten by what follows with no record of
        // it having existed.
        let writing = try adopted(writing, provider: provider)
        let before = try DevotionalAgentRevisionStore.stateBefore(turns: turns, in: workspace)
        let primary = DevotionalAgentRevisionStore.primaryDocumentPath
        let others = before.keys.filter { $0 != primary }.sorted()
        guard others.isEmpty else {
            return .refused(
                "Those turns also changed \(others.joined(separator: ", ")), which this cannot put back yet, so nothing was changed."
            )
        }
        guard let markdown = before[primary] else { return .nothingToPutBack }
        return .restored(try restore(markdown, writing: writing, provider: provider))
    }

    /// Puts a version back, recording what it replaces.
    ///
    /// What it replaces is **read from the file**, not taken from the
    /// caller: an outside app can write `draft.md` between two passes, and
    /// a run outlives its pane. Recording anything else files a version
    /// nobody ever had and loses the one they did.
    func restore(
        _ markdown: String,
        writing: String,
        provider: String? = nil
    ) throws -> String {
        _ = try adopted(writing, provider: provider)
        let replaced = (try? draftOnDisk()) ?? marker() ?? writing
        guard markdown != replaced else { return markdown }
        _ = try DevotionalAgentRevisionStore.record(
            kind: .restoration,
            providerName: provider,
            before: replaced,
            after: markdown,
            in: workspace
        )
        try DevotionalAgentWorkspaceStore.writeDraftContent(markdown, to: workspace)
        try markSynced(markdown)
        return markdown
    }

    // MARK: - Pieces

    /// Takes up whatever the workspace has not shown this caller yet, and
    /// says what the writing holds afterwards.
    private func adopted(_ writing: String, provider: String?) throws -> String {
        switch try reconcile(writing: writing, provider: provider) {
        case .take(let draft): return draft
        case .unchanged, .keep: return writing
        }
    }

    private func record(
        before: String, after: String, provider: String?, turnID: UUID?
    ) throws {
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            providerName: provider,
            // Marked with the turn that asked for it, which is what lets
            // that turn be undone later. Agent edits minutes apart are
            // merged into one record, so the times alone cannot say which
            // turn a change belonged to once the history is tidied.
            turnID: turnID,
            before: before,
            after: after,
            in: workspace
        )
    }

    private func markSynced(_ draft: String) throws {
        try DevotionalAgentRevisionStore.markSynced(draft, in: workspace)
    }
}
