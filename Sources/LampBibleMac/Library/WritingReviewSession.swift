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

    /// The marks as the visual editor takes them, each time they change:
    /// the writing's Markdown with markers, or nil for none. The page keeps
    /// them through the writer's typing itself, so typing sends nothing.
    var onMarksChanged: ((String?) -> Void)?
    /// The marks last sent, for an editor that is ready late.
    private(set) var markedMarkdown: String?

    private var writingID: String?
    private var store: LampWritingReviewStore?
    private var review: LampWritingReview?
    private var text = ""
    private var fileDate: Date?
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
        self.writingID = writingID
        self.text = text
        texts = []
        remember(text)
        review = nil
        fileDate = nil
        needsResend = false
        resentFor = nil
        store = isShown ? LampWritingReviewStore(rootURL: libraryRootURL) : nil
        publish(ranges: [], count: 0, marked: nil, sendsMarks: true)
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

    private func clear(range: NSRange, in text: String) {
        guard writingID != nil else { return }
        remember(text)
        let known = texts
        change { $0.carryingToText(text, from: known).clearing(range, in: text) }
    }

    /// Clears the range the visual page marked in the Markdown it sent.
    ///
    /// Where that is the writing as held here, give or take spelling, the
    /// clear is made in it. Otherwise the page was ahead (typed into within
    /// the settle before its text is reported), and the clear is made in
    /// the text the page sent, the marks carried there first: that text is
    /// then known, so the next draw and save carry the clear on from it.
    /// Never held back for a text that typing may already have passed.
    func clear(markedMarkdown marked: String) {
        if let range = LampWritingReview.markedRange(in: marked, of: text) {
            clear(range: range, in: text)
            return
        }
        let sent = Self.withoutMarkers(marked)
        guard let range = LampWritingReview.markedRange(in: marked, of: sent) else { return }
        clear(range: range, in: sent)
    }

    private static func withoutMarkers(_ marked: String) -> String {
        let markers: Set<Character> = [
            LampWritingReview.markStart, LampWritingReview.markEnd, LampWritingReview.markPoint,
        ]
        return String(marked.filter { !markers.contains($0) })
    }

    func clearAll() {
        change { $0.clearingAll() }
    }

    // MARK: - Internals

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
        guard let read, read.modified != fileDate, self.writingID == writingID, !Task.isCancelled else { return }
        apply(read.modified == nil ? nil : read.review, date: read.modified)
    }

    private func apply(_ review: LampWritingReview?, date: Date?) {
        fileDate = date
        guard review != self.review else { return }
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
            publish(ranges: [], count: 0, marked: nil, sendsMarks: sendsMarks)
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
                return (
                    live.highlightedRanges(in: text),
                    live.located(in: text).count,
                    sendsMarks ? live.markedMarkdown(in: text) : nil
                )
            }.value
            guard let self, self.drawGeneration == generation else { return }
            self.publish(ranges: drawn.0, count: drawn.1, marked: drawn.2, sendsMarks: sendsMarks)
        }
    }

    private func publish(ranges: [NSRange], count: Int, marked: String?, sendsMarks: Bool) {
        if self.ranges != ranges { self.ranges = ranges }
        if self.count != count { self.count = count }
        if sendsMarks {
            markedMarkdown = marked
            onMarksChanged?(marked)
        }
    }
}
