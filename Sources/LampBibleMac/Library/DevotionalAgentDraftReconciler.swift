import Foundation
import LampCore
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
/// Nothing here touches the main actor: the marks it would have made are
/// returned as `ReviewChange`s for the caller to make, which is what lets a
/// pass be one uninterrupted run.
struct DevotionalAgentDraftReconciler {
    let workspace: URL
    let writingID: String
    /// Where a write from outside Lamp leaves its note. Nil in a test, or
    /// where there is no Application Support to read, which reads as "no
    /// note" — the rule a draft without one has always followed.
    let applicationSupportURL: URL?
    init(
        workspace: URL, writingID: String, applicationSupportURL: URL?
    ) {
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
        /// Take this text, and record nothing: somebody else — another
        /// window on the same writing — has already accounted for it.
        ///
        /// Without this, a second pane advanced its mark to the
        /// workspace's and left its editor holding the older text, which
        /// the next save then wrote back over the newer one.
        case adopt(String)
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

    /// A change to the writing's marks for the caller to make.
    ///
    /// Returned rather than made here. Marking goes through
    /// `WritingReviewWork` and `WritingReviewTexts`, both on the main
    /// actor, and *when* it is enqueued is what keeps a save's carry from
    /// retiring it: `WritingReviewWork` carries each save's marks into
    /// that save's body in order, so a carry of pre-draft text that runs
    /// after a turn's marks were made takes those marks back to the
    /// pre-draft text and retires them. The marks therefore have to be
    /// enqueued in the same synchronous main-actor stretch that makes the
    /// editor's content the draft — then every save reserved before them
    /// saved pre-draft text and ran first, and every save reserved after
    /// them saved post-draft text. A pass cannot do that itself: it would
    /// have to suspend mid-pass, which is what makes a pass atomic, or
    /// hop to the main actor and lose the order.
    enum ReviewChange: Sendable {
        /// The assistant's words reaching the writing.
        case assistantWrote(from: String, to: String, turnID: UUID?)
        /// Turns leaving the conversation, and what their work went back to.
        case turnsUndone(Set<UUID>, from: String, to: String)
    }

    /// What a pass did, and what it left behind.
    ///
    /// `draftLeft` and `markerLeft` are nil where the pass wrote neither,
    /// so a caller never takes a value this pass did not establish — which
    /// is the whole point of returning them rather than letting the caller
    /// read the files again afterwards. Between a pass and a second read,
    /// another window can write, and its text then arrives as this pass's
    /// outcome.
    struct Pass<Outcome: Sendable>: Sendable {
        let outcome: Outcome
        let draftLeft: String?
        let markerLeft: String?
        /// In the order the caller must make them.
        let reviewChanges: [ReviewChange]

        init(
            outcome: Outcome, draftLeft: String? = nil, markerLeft: String? = nil,
            reviewChanges: [ReviewChange] = []
        ) {
            self.outcome = outcome
            self.draftLeft = draftLeft
            self.markerLeft = markerLeft
            self.reviewChanges = reviewChanges
        }
    }

    /// The text in the workspace now.
    ///
    /// Read rather than remembered, for the same reason as the marker: an
    /// outside app can write `draft.md` between two passes, and a run
    /// outlives the pane that started it.
    @WritingWorkspaceFiles
    func draftOnDisk() throws -> String {
        try DevotionalAgentWorkspaceStore.readDraft(from: workspace)
    }

    /// Where this workspace and the writing last agreed, as the workspace
    /// records it — not as any one pane remembers it.
    @WritingWorkspaceFiles
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
    @WritingWorkspaceFiles
    /// `lastKnownMarker` is where **this** caller last saw the workspace and
    /// the writing agree, and it is what tells the two sides apart when the
    /// draft and its mark agree but the writing does not. Either another
    /// window wrote and moved the mark — then this caller's own mark is
    /// older, and the draft is the newer side to take up — or nobody has
    /// written since this caller last agreed, and the difference is its own
    /// writer typing ahead of a synchronise that has not run yet. Those look
    /// identical from the files alone, and taking the draft in the second
    /// case puts the writer's keystrokes back.
    ///
    /// Nil asks for the older rule, where the draft is always the newer
    /// side: that is right for a caller with nothing of its own yet.
    func reconcile(
        writing: String,
        lastKnownMarker: String? = nil,
        provider: String? = nil,
        turnID: UUID? = nil
    ) throws -> Pass<Outcome> {
        clearFinishedRestore(given: writing)
        let diskDraft = try draftOnDisk()
        let persisted = marker()
        guard let persisted, diskDraft != persisted else {
            // Accounted for already. By this pane on an earlier pass, or
            // by another window on the same writing — and in the second
            // case this one is still holding the older text.
            //
            // The marker is reported even though nothing was written: it
            // was read here, under the owner, so it is as much this pass's
            // own fact as anything it wrote. A caller left without it kept
            // its old marker after adopting another window's text, and its
            // next keystroke then filed that text as a fresh edit of its
            // own.
            let movedSinceThisCallerAgreed = lastKnownMarker.map { $0 != persisted } ?? true
            let outcome: Outcome
            if diskDraft == writing {
                outcome = .unchanged
            } else if movedSinceThisCallerAgreed {
                outcome = .adopt(diskDraft)
            } else {
                // The caller is ahead, not behind: its own writer has typed
                // since the two last agreed, and the synchronise carrying
                // that text has not run yet. Nothing to take.
                outcome = .unchanged
            }
            return Pass(outcome: outcome, markerLeft: persisted)
        }
        return try takeOrKeep(
            diskDraft: diskDraft, writing: writing, previous: persisted,
            provider: provider, turnID: turnID,
            // Both sides moved: the draft has left the mark, and the caller's
            // own writing has left where it last agreed. Without this the
            // arriving draft always won here, so an agent's write that landed
            // while a keystroke was still on its way replaced what had just
            // been typed, with nothing recording it. `prepare` has always
            // asked this question; the poll could not, until it was told
            // where its caller last agreed.
            writingMovedSince: lastKnownMarker.map { $0 != writing } ?? false
        )
    }

    /// The same pass for a turn no window is watching (a paired phone's).
    ///
    /// A window reads "the draft and its mark agree, the writing does not"
    /// as another window's work and adopts it; its own edits move the mark,
    /// so that is the only way it can arise there. With no window, the
    /// writing also moves by sync — an edit made on the phone — under a
    /// draft nobody touched, and adopting the draft would put the edit back.
    /// So nothing is taken then, and the next turn's `prepare` levels the
    /// draft. Where the agent wrote as well, both moved: the writer's words
    /// stay and the draft goes to the history.
    @WritingWorkspaceFiles
    func reconcileUnwatched(
        writing: String, provider: String? = nil, turnID: UUID? = nil
    ) throws -> Pass<Outcome> {
        guard let marker = marker(), marker != writing else {
            return try reconcile(writing: writing, provider: provider, turnID: turnID)
        }
        let diskDraft = try draftOnDisk()
        guard diskDraft != marker else { return Pass(outcome: .unchanged) }
        return try takeOrKeep(
            diskDraft: diskDraft, writing: writing, previous: marker,
            provider: provider, turnID: turnID, writingMovedSince: true
        )
    }

    /// Opening the pane, where the two may have moved apart while it was
    /// closed — including by a run that outlived it.
    @WritingWorkspaceFiles
    func prepare(
        writing: String, provider: String? = nil, turnID: UUID? = nil
    ) throws -> Pass<Outcome> {
        clearFinishedRestore(given: writing)
        let diskDraft = try draftOnDisk()
        let persisted = marker()
        if diskDraft == writing {
            try markSynced(writing)
            return Pass(outcome: .unchanged, draftLeft: writing, markerLeft: writing)
        }
        if persisted == diskDraft {
            // A restore that never reached the writing looks exactly like
            // this: the draft and the mark agree on the restored text
            // while Lamp still holds what was undone. Taking the writing
            // as the newer side put the undone work back — and the undo
            // had already taken its turn out of the conversation, so
            // nothing was left to say it had happened.
            //
            // Only an outstanding receipt says so. The history cannot: it
            // records what happened, not what is still in progress, and
            // reading a finished restoration as an unfinished one threw
            // away the text of somebody who had deliberately typed the
            // old version back.
            if outstandingRestore(matching: diskDraft) {
                try markSynced(diskDraft)
                finishRestore()
                return Pass(
                    outcome: .take(diskDraft), draftLeft: diskDraft, markerLeft: diskDraft
                )
            }
            // The writing changed while the pane was closed, so its
            // current text is the newer side of the live workspace.
            try DevotionalAgentWorkspaceStore.writeDraftContent(writing, to: workspace)
            try markSynced(writing)
            return Pass(outcome: .unchanged, draftLeft: writing, markerLeft: writing)
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
            // The run can still be going: a pane closing does not stop it,
            // and reopening is exactly when its work is found. Recorded
            // with no turn, that work belonged to nothing, and undoing the
            // turn that asked for it left it in the writing.
            turnID: turnID,
            writingMovedSince: persisted.map { $0 != writing } ?? false
        )
    }

    /// The writer's own change, on its way to the workspace.
    /// `lastKnownMarker` is where **this** caller last saw the workspace
    /// and the writing agree. Where the workspace has moved on from it,
    /// another window on the same writing put that text there — and it is
    /// about to be written over by this one, so it is filed first. The
    /// person typing in that window had not reached an autosave yet, and
    /// without this their sentence was in no file and no history.
    @WritingWorkspaceFiles
    func synchronize(
        writing: String,
        lastKnownMarker: String? = nil,
        provider: String? = nil,
        turnID: UUID? = nil
    ) throws -> Pass<Void> {
        clearFinishedRestore(given: writing)
        let marker = marker()
        guard writing != marker else {
            // The two already agree. The draft is not read here, so this
            // says nothing about it.
            return Pass(outcome: (), markerLeft: marker)
        }
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
        } else if let marker, let lastKnownMarker,
                  marker != lastKnownMarker, marker != writing {
            // Another window's typing, accounted for by that window and
            // not yet saved by it. Filed as the person's own, which is
            // what it is, before this window's text replaces it.
            _ = try DevotionalAgentRevisionStore.record(
                kind: .userEdit,
                before: lastKnownMarker,
                after: marker,
                in: workspace
            )
        }
        try DevotionalAgentWorkspaceStore.writeDraftContent(writing, to: workspace)
        try markSynced(writing)
        return Pass(outcome: (), draftLeft: writing, markerLeft: writing)
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
    @WritingWorkspaceFiles
    func takeOrKeep(
        diskDraft: String,
        writing: String,
        previous: String?,
        provider: String?,
        turnID: UUID?,
        writingMovedSince: Bool = false
    ) throws -> Pass<Outcome> {
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
            return Pass(
                outcome: .keep(note: """
                    A draft written outside the editor was not applied: you had edited \
                    this writing since. Your text is unchanged, and the draft is in the \
                    history below.
                    """),
                draftLeft: writing, markerLeft: writing
            )

        case .takeDraft, .takeDraftUnrecorded:
            try record(
                before: previous ?? writing, after: diskDraft,
                provider: provider, turnID: turnID
            )
            try markSynced(diskDraft)
            return Pass(
                outcome: .take(diskDraft),
                draftLeft: diskDraft, markerLeft: diskDraft,
                // Named here and nowhere else: the one place the
                // assistant's words reach the writing. A draft only filed
                // in the history, above, changed nothing the writer has to
                // read. The caller makes the mark — see `ReviewChange`.
                reviewChanges: [.assistantWrote(from: writing, to: diskDraft, turnID: turnID)]
            )
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
    @WritingWorkspaceFiles
    func undo(
        turns: [UUID],
        writing: String,
        provider: String? = nil
    ) throws -> Pass<UndoOutcome> {
        guard !turns.isEmpty else { return Pass(outcome: .nothingToPutBack) }
        // Anything the agent wrote and the poll has not picked up yet is
        // collected first, so it is in the history as its own change
        // rather than being overwritten by what follows with no record of
        // it having existed.
        let (writing, adopting) = try adopted(writing, provider: provider)
        let before = try DevotionalAgentRevisionStore.stateBefore(turns: turns, in: workspace)
        let primary = DevotionalAgentRevisionStore.primaryDocumentPath
        let others = before.keys.filter { $0 != primary }.sorted()
        guard others.isEmpty else {
            return Pass(
                outcome: .refused(
                    "Those turns also changed \(others.joined(separator: ", ")), which this cannot put back yet, so nothing was changed."
                ),
                draftLeft: adopting.draftLeft, markerLeft: adopting.markerLeft,
                reviewChanges: adopting.reviewChanges
            )
        }
        guard let markdown = before[primary] else {
            return Pass(
                outcome: .nothingToPutBack,
                draftLeft: adopting.draftLeft, markerLeft: adopting.markerLeft,
                reviewChanges: adopting.reviewChanges
            )
        }
        let restoring = try restore(markdown, writing: writing, provider: provider)
        return Pass(
            outcome: .restored(restoring.outcome),
            draftLeft: restoring.draftLeft, markerLeft: restoring.markerLeft,
            // In order: what the adopting pass brought in, then what this
            // undo took away. The turns' work is gone, and so is what
            // marked it; what the undo put back was read before.
            reviewChanges: adopting.reviewChanges + restoring.reviewChanges
                + [.turnsUndone(Set(turns), from: writing, to: restoring.outcome)]
        )
    }

    /// Puts a version back, recording what it replaces.
    ///
    /// What it replaces is **read from the file**, not taken from the
    /// caller: an outside app can write `draft.md` between two passes, and
    /// a run outlives its pane. Recording anything else files a version
    /// nobody ever had and loses the one they did.
    @WritingWorkspaceFiles
    func restore(
        _ markdown: String,
        writing: String,
        provider: String? = nil
    ) throws -> Pass<String> {
        let (_, adopting) = try adopted(writing, provider: provider)
        let replaced = (try? draftOnDisk()) ?? marker() ?? writing
        guard markdown != replaced else {
            return Pass(
                outcome: markdown,
                draftLeft: adopting.draftLeft, markerLeft: adopting.markerLeft,
                reviewChanges: adopting.reviewChanges
            )
        }
        _ = try DevotionalAgentRevisionStore.record(
            kind: .restoration,
            providerName: provider,
            before: replaced,
            after: markdown,
            in: workspace
        )
        // Before the draft, so that an interruption anywhere after this
        // leaves something saying what was being done. Torn up on the
        // first pass that sees the writing holding it.
        if let applicationSupportURL {
            try? LampWritingWrite.Restore.begin(
                restored: markdown,
                applicationSupportURL: applicationSupportURL,
                writingID: writingID
            )
        }
        try DevotionalAgentWorkspaceStore.writeDraftContent(markdown, to: workspace)
        try markSynced(markdown)
        return Pass(
            outcome: markdown, draftLeft: markdown, markerLeft: markdown,
            reviewChanges: adopting.reviewChanges
        )
    }

    /// Whether a restore this Mac began is still outstanding, and this is
    /// the text it was putting back.
    @WritingWorkspaceFiles
    private func outstandingRestore(matching draft: String) -> Bool {
        guard let applicationSupportURL,
              let receipt = LampWritingWrite.Restore.outstanding(
                  applicationSupportURL: applicationSupportURL, writingID: writingID
              )
        else { return false }
        return LampWritingWrite.Restore.matches(receipt, draft)
    }

    @WritingWorkspaceFiles

    private func finishRestore() {
        guard let applicationSupportURL else { return }
        LampWritingWrite.Restore.finish(
            applicationSupportURL: applicationSupportURL, writingID: writingID
        )
    }

    /// The writing holds what was being restored, so the restore is done.
    @WritingWorkspaceFiles
    private func clearFinishedRestore(given writing: String) {
        guard outstandingRestore(matching: writing) else { return }
        finishRestore()
    }

    // MARK: - Pieces

    /// Takes up whatever the workspace has not shown this caller yet, and
    /// says what the writing holds afterwards.
    @WritingWorkspaceFiles
    private func adopted(
        _ writing: String, provider: String?
    ) throws -> (writing: String, pass: Pass<Outcome>) {
        let pass = try reconcile(writing: writing, provider: provider)
        switch pass.outcome {
        case .take(let draft), .adopt(let draft): return (draft, pass)
        case .unchanged, .keep: return (writing, pass)
        }
    }

    @WritingWorkspaceFiles

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

    @WritingWorkspaceFiles

    private func markSynced(_ draft: String) throws {
        try DevotionalAgentRevisionStore.markSynced(draft, in: workspace)
    }
}
