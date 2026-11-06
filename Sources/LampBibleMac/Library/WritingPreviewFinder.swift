#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// Finds text in a writing preview.
///
/// The preview is read-only, so this is a `WritingFindTarget` and not a
/// `WritingReplaceTarget`: the bar above it offers Find and no Replace, and
/// nothing has to ask for that.
///
/// It holds the preview's text as runs — a heading, a paragraph, a table cell
/// — because the preview is drawn as separate `Text` views rather than one
/// string. A view reads `result` to draw the matches it holds, and `scrollTo`
/// to bring the current one into view.
@MainActor
@Observable
final class WritingPreviewFinder: WritingFindTarget {
    /// Where the matches are, for the views drawing them.
    private(set) var result: WritingPreviewFindResult = .none
    /// The run holding the current match, bumped each time it moves so that
    /// stepping to another match in the same run still scrolls.
    private(set) var scrollTo: ScrollRequest?

    @ObservationIgnored var onFindStatusChanged: ((WritingFindStatus) -> Void)?

    @ObservationIgnored private var runs: [WritingPreviewRun] = []
    /// Which block of the preview each run sits in. A block is what carries a
    /// scroll anchor: a run inside a table cell or a list line has no identity
    /// of its own to be taken to.
    @ObservationIgnored private var blocks: [Int: Int] = [:]
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var options = WritingFindOptions()
    @ObservationIgnored private var isSearching = false
    @ObservationIgnored private var scrollCount = 0

    /// A block to scroll to. Identity changes on every request, so stepping to
    /// another match in the same block still scrolls.
    struct ScrollRequest: Equatable {
        var block: Int
        var number: Int
    }

    /// The preview's text, in reading order, and the block each run sits in.
    /// Called whenever the writing is rendered again; a search already set is
    /// run against the new text and keeps its place.
    func setRuns(_ newRuns: [WritingPreviewRun], blocks newBlocks: [Int: Int]) {
        guard newRuns != runs else { return }
        runs = newRuns
        blocks = newBlocks
        guard isSearching, !query.isEmpty else { return }
        result = WritingPreviewFind.result(
            of: query, in: runs, options: options, keepingPositionOf: result
        )
        onFindStatusChanged?(result.status)
    }

    func setSearch(
        _ query: String,
        options: WritingFindOptions,
        completion: @escaping (WritingFindStatus) -> Void
    ) {
        self.query = query
        self.options = options
        isSearching = true
        result = WritingPreviewFind.result(of: query, in: runs, options: options)
        requestScroll()
        completion(result.status)
    }

    func findNext(completion: @escaping (WritingFindStatus) -> Void) {
        result = WritingPreviewFind.next(result)
        requestScroll()
        completion(result.status)
    }

    func findPrevious(completion: @escaping (WritingFindStatus) -> Void) {
        result = WritingPreviewFind.previous(result)
        requestScroll()
        completion(result.status)
    }

    /// There is no caret in a preview and nothing is selected, so closing the
    /// bar simply takes the matches off the text. `selectingCurrent` is what
    /// an editor does with the match it was on; here there is nothing to do
    /// with it, and leaving the highlight behind would be a mark the reader
    /// could not get rid of.
    func endSearch(selectingCurrent: Bool) {
        isSearching = false
        query = ""
        result = .none
        scrollTo = nil
    }

    private func requestScroll() {
        guard let runID = result.currentRunID, let block = blocks[runID] else { return }
        scrollCount += 1
        scrollTo = ScrollRequest(block: block, number: scrollCount)
    }
}

/// Where a writing preview's find highlights are, handed down the view tree so
/// a run can draw its own without being passed through every block.
struct WritingPreviewHighlight: Equatable {
    var result: WritingPreviewFindResult = .none

    static let none = WritingPreviewHighlight()

    func ranges(inRun id: Int) -> [NSRange] { result.ranges(inRun: id) }
    func currentRange(inRun id: Int) -> NSRange? { result.currentRange(inRun: id) }
}

private struct WritingPreviewHighlightKey: EnvironmentKey {
    static let defaultValue = WritingPreviewHighlight.none
}

extension EnvironmentValues {
    var writingPreviewHighlight: WritingPreviewHighlight {
        get { self[WritingPreviewHighlightKey.self] }
        set { self[WritingPreviewHighlightKey.self] = newValue }
    }
}
