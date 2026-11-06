import Foundation
import SwiftUI

/// One run of a preview's text: a heading, a paragraph, a list line, a table
/// cell. A preview is drawn as separate `Text` views rather than one string,
/// so a match belongs to a run and is drawn inside it.
///
/// The id is the run's place in reading order. It is stable while the writing
/// is, which is what lets a match stay current across a redraw.
public struct WritingPreviewRun: Equatable, Sendable, Identifiable {
    public var id: Int
    public var text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// Where one match is: the run it falls in, and its range in that run's text
/// as UTF-16, which is how a `Text` counts.
public struct WritingPreviewMatch: Equatable, Sendable {
    public var runID: Int
    public var range: NSRange

    public init(runID: Int, range: NSRange) {
        self.runID = runID
        self.range = range
    }
}

/// Every match in a preview, in reading order, and which one is current.
public struct WritingPreviewFindResult: Equatable, Sendable {
    public var matches: [WritingPreviewMatch]
    /// Index into `matches`. Nil when there is nothing found.
    public var current: Int?

    public init(matches: [WritingPreviewMatch] = [], current: Int? = nil) {
        self.matches = matches
        self.current = current
    }

    public static let none = WritingPreviewFindResult()

    /// What the find bar shows: how many, and which of them, counted from 1.
    public var status: WritingFindStatus {
        WritingFindStatus(count: matches.count, current: current.map { $0 + 1 } ?? 0)
    }

    /// The run holding the current match, for scrolling it into view.
    public var currentRunID: Int? {
        guard let current, matches.indices.contains(current) else { return nil }
        return matches[current].runID
    }

    /// The ranges to draw in one run.
    public func ranges(inRun id: Int) -> [NSRange] {
        matches.filter { $0.runID == id }.map(\.range)
    }

    /// The range in this run that is the current match, drawn stronger than
    /// the rest. Nil when the current match is in another run.
    public func currentRange(inRun id: Int) -> NSRange? {
        guard let current, matches.indices.contains(current) else { return nil }
        let match = matches[current]
        return match.runID == id ? match.range : nil
    }
}

/// Finding text across the runs of a writing preview.
///
/// The preview is read-only, so this only ever reports where the matches are.
/// Matching itself is `WritingFind`'s, so the preview and the editor
/// agree on what counts as a match — case, whole words, and accents alike.
public enum WritingPreviewFind {
    /// Every match of `query`, in reading order.
    public static func matches(
        of query: String,
        in runs: [WritingPreviewRun],
        options: WritingFindOptions = .init()
    ) -> [WritingPreviewMatch] {
        guard !query.isEmpty else { return [] }
        return runs.flatMap { run in
            WritingFind.matches(of: query, in: run.text, options: options)
                .map { WritingPreviewMatch(runID: run.id, range: $0) }
        }
    }

    /// The result of a fresh search, with the first match made current.
    public static func result(
        of query: String,
        in runs: [WritingPreviewRun],
        options: WritingFindOptions = .init()
    ) -> WritingPreviewFindResult {
        let found = matches(of: query, in: runs, options: options)
        return WritingPreviewFindResult(matches: found, current: found.isEmpty ? nil : 0)
    }

    /// The result of searching again after the writing, or the options,
    /// changed, keeping the reader as near as it can to the match they were
    /// on: the match at the same place in reading order, or the last one when
    /// there are now fewer.
    ///
    /// Nothing here can move the caret, because a preview has none. Holding
    /// the position is the whole of what carries over.
    public static func result(
        of query: String,
        in runs: [WritingPreviewRun],
        options: WritingFindOptions = .init(),
        keepingPositionOf previous: WritingPreviewFindResult
    ) -> WritingPreviewFindResult {
        let found = matches(of: query, in: runs, options: options)
        guard !found.isEmpty else { return .none }
        guard let was = previous.current else {
            return WritingPreviewFindResult(matches: found, current: 0)
        }
        return WritingPreviewFindResult(matches: found, current: min(was, found.count - 1))
    }

    /// The next match after the current one, wrapping round the end as a Mac
    /// find bar does.
    public static func next(_ result: WritingPreviewFindResult) -> WritingPreviewFindResult {
        stepped(result, by: 1)
    }

    /// The match before the current one, wrapping round the start.
    public static func previous(_ result: WritingPreviewFindResult) -> WritingPreviewFindResult {
        stepped(result, by: -1)
    }

    private static func stepped(
        _ result: WritingPreviewFindResult,
        by offset: Int
    ) -> WritingPreviewFindResult {
        guard !result.matches.isEmpty else { return .none }
        let count = result.matches.count
        guard let current = result.current else {
            return WritingPreviewFindResult(matches: result.matches, current: offset > 0 ? 0 : count - 1)
        }
        let stepped = (current + offset % count + count) % count
        return WritingPreviewFindResult(matches: result.matches, current: stepped)
    }
}

public extension AttributedString {
    /// Marks the found text, the current match more strongly than the rest, as
    /// a find bar marks what it has found.
    ///
    /// The ranges are UTF-16 over the string's visible characters, which is
    /// what the matching counts in and what a `Text` draws.
    func markingFindMatches(_ ranges: [NSRange], current: NSRange?) -> AttributedString {
        guard !ranges.isEmpty else { return self }
        var marked = self
        let text = String(characters)
        for range in ranges {
            guard let stringRange = Range(range, in: text) else { continue }
            let start = text.distance(from: text.startIndex, to: stringRange.lowerBound)
            let length = text.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
            let characters = marked.characters
            guard let lower = characters.index(
                characters.startIndex, offsetBy: start, limitedBy: characters.endIndex
            ), let upper = characters.index(
                lower, offsetBy: length, limitedBy: characters.endIndex
            ) else { continue }
            let isCurrent = range == current
            marked[lower..<upper].backgroundColor = isCurrent
                ? Color.accentColor
                : Color.accentColor.opacity(0.28)
            if isCurrent {
                marked[lower..<upper].foregroundColor = .white
            }
        }
        return marked
    }
}
