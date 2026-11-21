import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

/// The versions of each writing this Mac has lately seen, in any window: the
/// editor's text as it settles, each body saved, each draft taken in. A mark
/// is anchored in a text, and is placed exactly from that text
/// (`LampWritingReview.carryingToText`, which hashes them off the main
/// actor). One that has gone is still found by its words and context.
///
/// For drawing only. What is written — a save's carry, a clear — carries
/// from the texts its own window held (`WritingReviewSession.texts`): a
/// draft another window took in, not yet saved, is not this one's to
/// carry, and carried from here its new words would be retired for good.
@MainActor
final class WritingReviewTexts {
    static let shared = WritingReviewTexts()
    /// How many versions of a writing are kept: enough to span a clear and
    /// the saves after it, few enough that a long manuscript costs little.
    static let kept = 24

    private var texts: [String: [String]] = [:]

    func remember(_ text: String, for writingID: String) {
        var kept = texts[writingID, default: []]
        guard kept.last != text else { return }
        kept.append(text)
        texts[writingID] = Array(kept.suffix(Self.kept))
    }

    func known(for writingID: String) -> [String] {
        texts[writingID, default: []]
    }
}

/// Where the marks are changed by a save's carry and by an assistant's draft
/// taken in: one at a time, in the order they were asked for, off the main
/// actor. In order, a carry asked for before a turn's draft was taken in is
/// done before the draft's marks are made, so it can never take the turn's
/// new marks back to the text before it; off the main actor, the whole
/// manuscript compared, and the wait on the marks file's lock, are not the
/// writer's to feel. Each counts as a pending write, so quitting waits.
@MainActor
final class WritingReviewWork {
    static let shared = WritingReviewWork()
    private var last: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async -> Void) {
        let previous = last
        LampPendingWrites.shared.begin()
        last = Task.detached(priority: .utility) {
            await previous?.value
            await work()
            await MainActor.run { LampPendingWrites.shared.end() }
        }
    }

    /// A place in line taken now, for work only known later: a save takes
    /// its place before it waits on the database, so a turn's draft taken in
    /// meanwhile is marked after its carry, never before. Filled with the
    /// work once known, or given up, and either way the line moves on.
    struct Reservation: Sendable {
        fileprivate let continuation: AsyncStream<@Sendable () async -> Void>.Continuation

        func fill(_ work: @escaping @Sendable () async -> Void) {
            continuation.yield(work)
            continuation.finish()
        }

        func giveUp() {
            continuation.finish()
        }
    }

    /// How long a place in line waits to be filled before the line moves
    /// on without it: far past any save, and short of a queue stopped for
    /// good by a place nobody fills. Work filled in after that is dropped,
    /// not run late: behind what was queued after it, it would be the stale
    /// writer the line exists to prevent. (The stream is finished as the
    /// place gives up, and a finished stream discards what it is given.)
    var reservationPatience: Duration = .seconds(120)

    func reserve() -> Reservation {
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        let patience = reservationPatience
        run {
            let work = await withTaskGroup(of: (@Sendable () async -> Void)?.self) { group in
                group.addTask {
                    for await work in stream { return work }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: patience)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                continuation.finish()
                return first
            }
            await work?()
        }
        return Reservation(continuation: continuation)
    }

    /// Returns once everything asked for so far is done.
    func drained() async {
        await last?.value
    }
}

/// The review marks of the writing an editor has open (`LampWritingReview`):
/// what is drawn, how many passages are still to read, and the writer's
/// clears. One per editor, held apart from the editor's view so that none of
/// this is worked out in its body, which is on the typing path.
///
/// The marks file is read again when its date moves — an assistant's turn
/// marked something, or another device's clears arrived by sync — checked
/// about once a second while the writing is open. What to draw is worked out
/// off the main actor, once the text has settled.
@MainActor
final class WritingReviewSession: ObservableObject {
    /// What is still marked, in the writing's Markdown, for the Markdown
    /// editor to draw.
    @Published private(set) var ranges: [NSRange] = []
    /// How many passages are still to read, places words were taken out
    /// among them.
    @Published private(set) var count = 0
    /// What of those can be put back as the assistant found it, in the
    /// order they stand. Worked out with what is drawn, off the main actor,
    /// so the editor can offer a restore without asking for it: short of
    /// the marks, since a passage the writer has typed into is not offered.
    @Published private(set) var restorable: [LampWritingReview.Restorable] = []
    /// What the writing's agent is told is still marked
    /// (`WritingChatTurns.reviewNote`), for `.lamp/editor.md`: nil only
    /// while marks are off, `unreadReviewNote` until the marks file is first
    /// read. Changes only as the marks are drawn, once the text settles, so
    /// typing writes nothing.
    @Published private(set) var agentNote: String?

    /// The marks as the visual editor takes them, each time they change:
    /// the writing's Markdown with markers, or nil for none, and what a
    /// restore of each marked passage would come to. The page keeps them
    /// through the writer's typing itself, so typing sends nothing.
    var onMarksChanged: ((String?, [WritingReviewChange?]) -> Void)?
    /// The marks last sent, for an editor that is ready late.
    private(set) var markedMarkdown: String?
    /// What was sent with them, one to each marked passage, in the order
    /// they stand — which is the order the page finds its markers in.
    private(set) var markedChanges: [WritingReviewChange?] = []

    private var writingID: String?
    private var store: LampWritingReviewStore?
    private var review: LampWritingReview?
    private var text = ""
    private var fileDate: Date?
    /// Whether the marks file has been read since the writing was followed:
    /// the first read is drawn even when it finds nothing, so the agent is
    /// told that nothing is marked.
    private var hasRead = false
    private var settleTask: Task<Void, Never>?
    private var drawGeneration = 0
    /// The page refused the last marks sent (its text was a moment ahead of
    /// this one's), so the next draw sends them again.
    private var needsResend = false
    /// The text a refused set of marks was last sent again for. Refused
    /// again for the same text, they wait for the text to change rather
    /// than going round every few hundred milliseconds.
    private var resentFor: String?
    /// The texts this editor has held, newest last: what its clears and its
    /// saves' carries take marks from.
    private(set) var texts: [String] = []

    static let checkInterval: Duration = .seconds(1)
    static let settleDelay: Duration = .milliseconds(300)

    /// Keeps the writing's marks current until the task is cancelled: the
    /// editor's `.task(id:)`, keyed on the writing and on whether marks are
    /// shown at all. Shown off, everything is cleared and nothing is read.
    func follow(writingID: String, text: String, libraryRootURL: URL, isShown: Bool) async {
        // Nothing drawn for the writing before may land now.
        settleTask?.cancel()
        drawGeneration += 1
        // The texts held are kept while the writing stays the same (marks
        // turned off and on again): an edit made meanwhile is carried from
        // them back to the marks.
        if self.writingID != writingID { texts = [] }
        self.writingID = writingID
        self.text = text
        remember(text)
        review = nil
        fileDate = nil
        hasRead = false
        needsResend = false
        resentFor = nil
        store = isShown ? LampWritingReviewStore(rootURL: libraryRootURL) : nil
        publish(
            ranges: [], count: 0, restorable: [], marked: nil, changes: [],
            note: isShown ? WritingChatTurns.unreadReviewNote : nil, sendsMarks: true
        )
        guard isShown else { return }
        while !Task.isCancelled {
            await reloadIfMoved()
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    /// The writing's text moved: what to draw is worked out again once it
    /// settles. The visual page is not sent the marks again for it, unless
    /// it refused the last ones.
    func textChanged(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        guard review != nil else { return }
        scheduleDraw()
    }

    /// The page could not place the marks it was sent: its text was not
    /// this one. They go again once the text settles.
    func marksRejected() {
        needsResend = true
        guard resentFor != text else { return }
        resentFor = text
        scheduleDraw()
    }

    // MARK: - Clearing

    /// Clears what of the marks `range` of the writing covers. A caret with
    /// nothing selected clears the mark it stands in.
    ///
    /// The marks are carried to the text as it is now first: typed into
    /// since they were read, a marked passage would otherwise not be found
    /// and the clear would do nothing.
    func clear(range: NSRange) {
        clear(range: range, in: text)
    }

    /// Made in `text` with the marks carried there, changing only the marks
    /// it touches: `text` can be a moment behind the latest marks (the
    /// page's, pressed before a turn's draft reached it), and carried whole
    /// into it, a mark with no words there would be retired by a clear of
    /// some other passage.
    private func clear(range: NSRange, in text: String) {
        guard writingID != nil else { return }
        remember(text)
        let known = texts
        change { $0.clearing(range, in: text, carryingFrom: known) }
    }

    /// Clears the range the visual page marked in the Markdown it sent.
    ///
    /// Where that is the writing as held here, give or take spelling, the
    /// clear is made in it. Otherwise the page was ahead or behind (typed
    /// into within the settle before its text is reported, or pressed
    /// before a turn's draft reached it), and the clear is made in the
    /// page's own text, `pageText`, which it sends unmarked beside the
    /// marked: that text is then known, so the next draw and save carry the
    /// clear on from it. Never held back for a text typing may already have
    /// passed.
    ///
    /// Never made in the marked Markdown with its markers taken out: a
    /// marker can change how the page writes what is round it (inside an
    /// autolink, `<url>` becomes `[url](url)`), so that is text the page
    /// never held. A page that sends no text of its own clears only where
    /// it matches the writing here.
    func clear(markedMarkdown marked: String, pageText: String? = nil) {
        if let range = LampWritingReview.markedRange(in: marked, of: text) {
            clear(range: range, in: text)
        } else if let pageText, let range = LampWritingReview.markedRange(in: marked, of: pageText) {
            clear(range: range, in: pageText)
        }
    }

    func clearAll() {
        change { $0.clearingAll() }
    }

    // MARK: - Putting a wording back

    /// The restore `range` of the writing asks for, or nil where it cannot
    /// be made exactly: every marked passage it touches whole, and nothing
    /// unless all of them can be put back.
    ///
    /// Worked out here rather than taken from `restorable` so that the
    /// refusal is the record's own: a selection holding one passage the
    /// writer has typed into is refused, and that is not a thing the drawn
    /// list can say, holding only what can be put back.
    func restoring(_ range: NSRange, in text: String? = nil) -> LampWritingReview.RestoreOutcome {
        let text = text ?? self.text
        return live(in: text)?.restoring(range, in: text) ?? .nothingTouched
    }

    /// The marks carried into `text`, as drawing carries them.
    ///
    /// A restore planned against the stored record rather than this one
    /// can put words back in the wrong place: a mark whose own words the
    /// writer has typed into is not found where it stands, and the same
    /// words standing somewhere else — an untouched sentence that happens
    /// to repeat them — are found instead, where they pass the digest and
    /// are replaced. The carry is what ties a mark to its own place.
    private func live(in text: String) -> LampWritingReview? {
        guard let review else { return nil }
        return review.carryingToText(text, from: texts)
    }

    /// Records a restore the editor's own surface has just made, the text
    /// going from what it held to `restored`.
    ///
    /// The surface makes the edits, not this: in the visual page they are a
    /// transaction of its own, so the writer's ⌘Z takes them back, and in
    /// the Markdown view they are the text view's edit for the same reason.
    func restored(_ plan: LampWritingReview.RestorePlan, in from: String, to restored: String) {
        guard writingID != nil else { return }
        remember(from)
        remember(restored)
        text = restored
        let known = texts
        change { $0.restoringWording(plan, from: from, to: restored, carryingFrom: known) }
    }

    /// A restore the visual page has asked for: the Markdown it sent with
    /// markers at the edges of the passage, and its own text beside it.
    ///
    /// Worked out and handed back rather than recorded, because the page
    /// makes the edit — as one transaction of its own, so the writer's ⌘Z
    /// takes it back — and it may refuse. Recorded by `recordRestore` once
    /// the page says what it now holds.
    ///
    /// The page's own text is tried first: it is the text the press was
    /// made in. A page that sends none is answered against the writing as
    /// held here.
    ///
    /// By id rather than by a range of text: the page widens a range to a
    /// whole link when it writes its markers, so two changes inside one
    /// link label came back under the first one's button.
    func pageRestore(ids: String, pageText: String?) -> PageRestore? {
        guard let review else { return nil }
        let wanted = Set(ids.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        guard !wanted.isEmpty else { return nil }
        _ = review
        for base in [pageText, text].compactMap({ $0 }) {
            guard let live = live(in: base),
                  case .plan(let plan) = live.restoring(marks: wanted, in: base) else { continue }
            return PageRestore(base: base, restored: Self.applying(plan, to: base), plan: plan)
        }
        return nil
    }

    /// A restore the page has made, recorded against the text it now holds.
    ///
    /// `held` is the page's own Markdown afterwards, not what the plan
    /// worked out: the page writes its own spelling, and a word of it may
    /// come back another way. Only the marks put back change either way.
    func recordRestore(_ restore: PageRestore, held: String) {
        guard writingID != nil else { return }
        remember(restore.base)
        remember(held)
        text = held
        let known = texts
        change { $0.restoringWording(restore.plan, from: restore.base, to: held, carryingFrom: known) }
    }

    /// A restore worked out for the page, before the page has made it.
    struct PageRestore {
        let base: String
        let restored: String
        let plan: LampWritingReview.RestorePlan
    }

    /// What a restore of each drawn passage would come to, for the page to
    /// draw its offer and say what it would do.
    ///
    /// One to each drawn range, in the order they stand, which is the order
    /// the page finds its markers in. A range can cover more than one mark
    /// — touching marks are drawn as one — so this asks about the range
    /// rather than the mark, and a range holding one passage that cannot be
    /// put back offers nothing for the pair rather than half of it.
    ///
    /// `nil` is nothing to offer and nothing to say: the wording was never
    /// kept, which is not the writer's doing and not theirs to fix.
    nonisolated static func changes(
        of review: LampWritingReview, in text: String, ranges: [NSRange]
    ) -> [WritingReviewChange?] {
        let source = text as NSString
        // Asked about every range at once: one at a time finds every mark
        // again for each, which is quadratic in the marks.
        return review.restoring(ranges, in: text).enumerated().map { index, answer in
            let range = ranges[index]
            switch answer.outcome {
            case .plan(let plan):
                let ordered = plan.edits.sorted { $0.range.location < $1.range.location }
                guard let first = ordered.first, let last = ordered.last else { return nil }
                let span = NSRange(
                    location: first.range.location,
                    length: NSMaxRange(last.range) - first.range.location
                )
                var before = ""
                var at = span.location
                for edit in ordered {
                    before += source.substring(
                        with: NSRange(location: at, length: edit.range.location - at)
                    )
                    before += edit.replacement
                    at = NSMaxRange(edit.range)
                }
                before += source.substring(
                    with: NSRange(location: at, length: NSMaxRange(span) - at)
                )
                return WritingReviewChange(
                    id: WritingReviewChange.id(of: answer.marks),
                    now: source.substring(with: span), before: before, reason: nil
                )
            case .notExact:
                return WritingReviewChange(
                    id: WritingReviewChange.id(of: answer.marks),
                    now: source.substring(with: range), before: nil, reason: "edited"
                )
            case .notKept, .nothingTouched:
                return nil
            }
        }
    }

    /// A plan's edits put in place. They come last first, so each range
    /// still means in the text what it meant when the plan was made.
    static func applying(_ plan: LampWritingReview.RestorePlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    // MARK: - Internals

    /// A text the editor is about to hold, an assistant's draft it takes
    /// in: remembered at once rather than as the text settles, since the
    /// writer may type into it first.
    func holds(_ text: String) {
        remember(text)
    }

    /// Remembers a text this editor holds, here and among every window's.
    private func remember(_ text: String) {
        guard let writingID else { return }
        WritingReviewTexts.shared.remember(text, for: writingID)
        guard texts.last != text else { return }
        texts.append(text)
        texts = Array(texts.suffix(WritingReviewTexts.kept))
    }

    /// Changes the marks file off the main actor — another writer can hold
    /// its lock for as long as a long manuscript takes to compare — and
    /// takes up what was written, with the file's date read under the same
    /// lock. Counted as a pending write, so quitting waits for a clear.
    private func change(_ edit: @escaping @Sendable (LampWritingReview) -> LampWritingReview) {
        guard let store, let writingID else { return }
        LampPendingWrites.shared.begin()
        Task { [weak self] in
            let written = await Task.detached(priority: .userInitiated) {
                try? store.updating(writingID: writingID, edit)
            }.value
            LampPendingWrites.shared.end()
            // Not for a writing left since, nor once marks were turned off.
            guard let self, let written, self.writingID == writingID, self.store != nil else { return }
            self.apply(written.review, date: written.modified)
        }
    }

    /// Reads the marks file again if its date has moved since it was last
    /// read: the record and its date together, under the file's lock, so a
    /// write can never be taken for the one before it. Off the main actor,
    /// for the same reason as `change`.
    private func reloadIfMoved() async {
        guard let store, let writingID else { return }
        let read = await Task.detached(priority: .utility) {
            try? store.snapshot(writingID: writingID)
        }.value
        guard self.writingID == writingID, !Task.isCancelled else { return }
        guard let read else {
            // Unreadable now, though it was read before: the agent is told
            // so rather than what was read then, until a read succeeds.
            hasRead = false
            if agentNote != nil, agentNote != WritingChatTurns.unreadReviewNote {
                agentNote = WritingChatTurns.unreadReviewNote
            }
            return
        }
        guard read.modified != fileDate || !hasRead else { return }
        apply(read.modified == nil ? nil : read.review, date: read.modified)
    }

    private func apply(_ review: LampWritingReview?, date: Date?) {
        fileDate = date
        let isFirstRead = !hasRead
        hasRead = true
        guard review != self.review || isFirstRead else { return }
        self.review = review
        draw(sendsMarks: true)
    }

    private func scheduleDraw() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.remember(self.text)
            // Sent too while none are shown but some stand: marks that placed
            // nowhere in the text before (a newer body arrived) may place in
            // this one.
            let unplaced = self.markedMarkdown == nil && !(self.review?.isEmpty ?? true)
            self.draw(sendsMarks: self.needsResend || unplaced)
        }
    }

    private func draw(sendsMarks: Bool) {
        drawGeneration += 1
        let generation = drawGeneration
        if sendsMarks { needsResend = false }
        guard let review, !review.isEmpty else {
            publish(
                ranges: [], count: 0, restorable: [], marked: nil, changes: [],
                note: noteForAgent(ranges: []), sendsMarks: sendsMarks
            )
            return
        }
        let text = self.text
        // Drawn from the marks carried into the text as it is now, each from
        // the text it is anchored in: typed into since they were saved, a
        // marked passage would otherwise be found nowhere, and not counted,
        // until the next save carries it.
        let known = writingID.map { WritingReviewTexts.shared.known(for: $0) } ?? []
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                let live = review.carryingToText(text, from: known)
                let ranges = live.highlightedRanges(in: text)
                return (
                    ranges,
                    live.located(in: text).count,
                    sendsMarks ? live.markedMarkdown(in: text) : nil,
                    live.restorable(in: text),
                    sendsMarks ? Self.changes(of: live, in: text, ranges: ranges) : []
                )
            }.value
            guard let self, self.drawGeneration == generation else { return }
            self.publish(
                ranges: drawn.0, count: drawn.1, restorable: drawn.3, marked: drawn.2,
                changes: drawn.4, note: self.noteForAgent(ranges: drawn.0, in: text),
                sendsMarks: sendsMarks
            )
        }
    }

    /// The note for what is drawn, as the session stands: nothing once marks
    /// are off, though a draw asked for before (a rejection the page sends
    /// late) still lands; unread until the file has been read.
    private func noteForAgent(ranges: [NSRange], in text: String? = nil) -> String? {
        guard store != nil else { return nil }
        guard hasRead else { return WritingChatTurns.unreadReviewNote }
        return WritingChatTurns.reviewNote(
            ranges: ranges, in: text ?? self.text, restorations: review?.restorations ?? []
        )
    }

    private func publish(
        ranges: [NSRange], count: Int, restorable: [LampWritingReview.Restorable],
        marked: String?, changes: [WritingReviewChange?], note: String?, sendsMarks: Bool
    ) {
        if self.ranges != ranges { self.ranges = ranges }
        if self.count != count { self.count = count }
        if self.restorable != restorable { self.restorable = restorable }
        if agentNote != note { agentNote = note }
        if sendsMarks {
            markedMarkdown = marked
            markedChanges = changes
            onMarksChanged?(marked, changes)
        }
    }
}

/// What a restore of one drawn passage would come to, as the visual page
/// is told it: the words that stand there now, the words that would stand
/// there instead, and — where there is nothing to offer but something to
/// say — why not.
struct WritingReviewChange: Equatable, Encodable, Sendable {
    /// The marks this passage stands in, as the page names them when it
    /// presses: their ids sorted and joined, since what the page can hand
    /// back is this label, not a range of the writing's Markdown.
    let id: String
    let now: String
    /// Nil where there is nothing to put back here.
    let before: String?
    /// `edited` where the passage can no longer be put back exactly because
    /// the writer has been at it. Never said of a passage whose wording was
    /// simply never kept: they did nothing to that one.
    let reason: String?

    static func id(of marks: [UUID]) -> String {
        marks.map(\.uuidString).sorted().joined(separator: ",")
    }
}

/// Makes the marks a reconciler pass asked for, in the order it asked.
///
/// Synchronous and on the main actor by design. `WritingReviewWork` carries
/// each save's marks into that save's body in order, so a carry of pre-draft
/// text that runs after a turn's marks were made takes those marks back to
/// the pre-draft text and retires them. The caller therefore makes these in
/// the same uninterrupted stretch that makes the editor's content the draft:
/// then every save reserved before them saved pre-draft text and runs first,
/// and every save reserved after them saved post-draft text. Put an `await`
/// between the two and that ordering is gone.
///
/// See `DevotionalAgentDraftReconciler.ReviewChange`, which is why a pass
/// names its marks rather than making them.
@MainActor
struct WritingReviewChanges {
    let writingID: String
    let store: LampWritingReviewStore?

    func make(_ changes: [DevotionalAgentDraftReconciler.ReviewChange]) {
        for change in changes {
            switch change {
            case .assistantWrote(let from, let to, let turnID):
                update { $0.markingAssistantChange(from: from, to: to, turnID: turnID) }
                WritingReviewTexts.shared.remember(to, for: writingID)
            case .turnsUndone(let turns, let from, let to):
                update { $0.undoingTurns(turns, from: from, to: to) }
            }
        }
    }

    private func update(
        _ change: @escaping @Sendable (LampWritingReview) -> LampWritingReview
    ) {
        guard let store else { return }
        let writingID = writingID
        // In line with the saves' carries, off the main actor
        // (`WritingReviewWork`).
        WritingReviewWork.shared.run { _ = try? store.update(writingID: writingID, change) }
    }
}
