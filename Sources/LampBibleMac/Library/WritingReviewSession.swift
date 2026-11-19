import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

/// The versions of each writing this Mac has lately seen: the editor's text
/// as it settles, each body saved, each draft taken in. A mark is anchored
/// in a text, and is carried exactly from that text; a clear made while the
/// editor holds text not yet saved anchors what is left there, and the save
/// that follows carries from the last saved body. Kept here, a carry can
/// take each mark from its own (`LampWritingReview.carryingToText`), which
/// hashes them off the main actor. One that has gone is still found by its
/// words and context, so this only makes carries exact more often.
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

    func reserve() -> Reservation {
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        run {
            for await work in stream {
                await work()
                break
            }
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
        WritingReviewTexts.shared.remember(text, for: writingID)
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
        guard let writingID else { return }
        let text = self.text
        WritingReviewTexts.shared.remember(text, for: writingID)
        let known = WritingReviewTexts.shared.known(for: writingID)
        change { $0.carryingToText(text, from: known).clearing(range, in: text) }
    }

    /// Clears the range the visual page marked in the Markdown it sent:
    /// nothing, where that is not the writing as held here, since its range
    /// would then fall on other words.
    func clear(markedMarkdown marked: String) {
        guard let range = LampWritingReview.markedRange(in: marked, of: text) else { return }
        clear(range: range)
    }

    func clearAll() {
        change { $0.clearingAll() }
    }

    // MARK: - Internals

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
            if let writingID = self.writingID { WritingReviewTexts.shared.remember(self.text, for: writingID) }
            self.draw(sendsMarks: self.needsResend)
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
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                (
                    review.highlightedRanges(in: text),
                    review.located(in: text).count,
                    sendsMarks ? review.markedMarkdown(in: text) : nil
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
