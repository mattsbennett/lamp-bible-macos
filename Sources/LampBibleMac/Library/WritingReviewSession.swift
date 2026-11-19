import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

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
    /// The text the marks were last read against, which a clear first
    /// carries them from: the writer may have typed into a marked passage
    /// since, before the save that would carry it.
    private var basis = ""
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
        basis = text
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
        let text = self.text, basis = self.basis
        change { $0.carryingWriterEdit(from: basis, to: text).clearing(range, in: text) }
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
    /// takes up what was written.
    private func change(_ edit: @escaping @Sendable (LampWritingReview) -> LampWritingReview) {
        guard let store, let writingID else { return }
        let generation = drawGeneration
        Task { [weak self] in
            let written = await Task.detached(priority: .userInitiated) { () -> (LampWritingReview, Date?)? in
                guard let review = try? store.update(writingID: writingID, edit) else { return nil }
                return (review, Self.modified(store, writingID))
            }.value
            // Not for a writing left since, nor once marks were turned off.
            guard let self, let written, self.drawGeneration >= generation,
                  self.writingID == writingID, self.store != nil else { return }
            self.apply(written.0, date: written.1)
        }
    }

    /// Reads the marks file again if its date has moved since it was last
    /// read. Off the main actor, for the same reason as `change`. The date
    /// is taken before the read, so a write landing between the two is
    /// read on the next check rather than taken for the one just read.
    private func reloadIfMoved() async {
        guard let store, let writingID else { return }
        let known = fileDate
        let read = await Task.detached(priority: .utility) { () -> (LampWritingReview?, Date?)? in
            let date = Self.modified(store, writingID)
            guard date != known else { return nil }
            return (try? store.review(writingID: writingID), date)
        }.value
        guard let read, self.writingID == writingID, !Task.isCancelled else { return }
        apply(read.0, date: read.1)
    }

    private nonisolated static func modified(_ store: LampWritingReviewStore, _ writingID: String) -> Date? {
        guard let url = try? store.url(writingID: writingID) else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func apply(_ review: LampWritingReview?, date: Date?) {
        fileDate = date
        guard review != self.review else { return }
        self.review = review
        basis = text
        draw(sendsMarks: true)
    }

    private func scheduleDraw() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
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
