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
    private var fileDate: Date?
    private var settleTask: Task<Void, Never>?
    private var drawGeneration = 0

    static let checkInterval: Duration = .seconds(1)
    static let settleDelay: Duration = .milliseconds(300)

    /// Keeps the writing's marks current until the task is cancelled: the
    /// editor's `.task(id:)`, keyed on the writing and on whether marks are
    /// shown at all. Shown off, everything is cleared and nothing is read.
    func follow(writingID: String, text: String, libraryRootURL: URL, isShown: Bool) async {
        self.writingID = writingID
        self.text = text
        review = nil
        fileDate = nil
        store = isShown ? LampWritingReviewStore(rootURL: libraryRootURL) : nil
        publish(ranges: [], count: 0, marked: nil, sendsMarks: true)
        guard isShown else { return }
        while !Task.isCancelled {
            reloadIfMoved()
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    /// The writing's text moved: what to draw is worked out again once it
    /// settles. The visual page is not sent the marks again for it.
    func textChanged(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        guard review != nil else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.draw(sendsMarks: false)
        }
    }

    // MARK: - Clearing

    /// Clears what of the marks `range` of the writing covers. A caret with
    /// nothing selected clears the mark it stands in.
    func clear(range: NSRange) {
        guard let store, let writingID else { return }
        let text = self.text
        apply((try? store.update(writingID: writingID) { $0.clearing(range, in: text) }))
    }

    /// Clears the range the visual page marked in the Markdown it sent:
    /// nothing, where that is not the writing as held here, since its range
    /// would then fall on other words.
    func clear(markedMarkdown marked: String) {
        guard let range = LampWritingReview.markedRange(in: marked, of: text) else { return }
        clear(range: range)
    }

    func clearAll() {
        guard let store, let writingID else { return }
        apply((try? store.update(writingID: writingID) { $0.clearingAll() }))
    }

    // MARK: - Internals

    private func reloadIfMoved() {
        guard let store, let writingID, let url = try? store.url(writingID: writingID) else { return }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard date != fileDate else { return }
        fileDate = date
        apply(try? store.review(writingID: writingID))
    }

    private func apply(_ review: LampWritingReview?) {
        guard review != self.review else { return }
        self.review = review
        if let store, let writingID, let url = try? store.url(writingID: writingID) {
            fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        draw(sendsMarks: true)
    }

    private func draw(sendsMarks: Bool) {
        drawGeneration += 1
        let generation = drawGeneration
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
