import Foundation

/// Where the rendered preview sits relative to the writing surface.
///
/// Preview used to be a third peer of the two editing surfaces, which conflated
/// two unrelated questions — *which* editor am I typing in, and am I writing or
/// reading? Obsidian keeps those apart: Live Preview and Source are editing
/// surfaces, and Reading view is a separate toggle. Placement is that toggle.
public enum WritingPreviewPlacement: String, CaseIterable, Codable, Sendable {
    /// Writing only. The preview is not on screen.
    case hidden
    /// Preview beside the writing surface, so prose can be checked against its
    /// rendered form without losing the caret.
    case split
    /// Preview alone, for reading a finished draft the way a reader will see it.
    case full

    public var isVisible: Bool { self != .hidden }

    /// ⌘E in Obsidian swaps between writing and reading. Toggling off remembers
    /// nothing beyond "was it full?", so a writer who prefers full-width reading
    /// gets it back rather than being dropped into split every time.
    public func toggled() -> WritingPreviewPlacement {
        self == .hidden ? .split : .hidden
    }

    /// ⌘⇧E moves the preview between the two visible placements. From hidden it
    /// opens straight to full, which is what "show me the whole thing" means when
    /// nothing is on screen yet.
    public func cycledPlacement() -> WritingPreviewPlacement {
        switch self {
        case .hidden: .full
        case .split: .full
        case .full: .split
        }
    }

    /// The placement an editor should actually open with.
    ///
    /// Placement is remembered across windows and launches, which is right for a
    /// draft you are coming back to and wrong for an empty one: a full-width
    /// preview of nothing is a window with no content and no visible way to start
    /// typing. An empty document therefore never opens into one.
    public func opening(hasContent: Bool) -> WritingPreviewPlacement {
        self == .full && !hasContent ? .split : self
    }

    public var title: String {
        switch self {
        case .hidden: "Hide Preview"
        case .split: "Split Preview"
        case .full: "Full Preview"
        }
    }

    public var systemImage: String {
        switch self {
        case .hidden: "book.closed"
        case .split: "rectangle.split.2x1"
        case .full: "book"
        }
    }
}

/// Word count and reading time for the status bar, the way Obsidian keeps them
/// permanently visible at the edge of the window. Devotional and sermon writing is
/// written to a length — "about fifteen minutes" — so the estimate is not a
/// novelty, it is the constraint the author is writing against.
public struct WritingStatistics: Equatable, Sendable {
    public let wordCount: Int
    public let characterCount: Int

    public init(wordCount: Int, characterCount: Int) {
        self.wordCount = wordCount
        self.characterCount = characterCount
    }

    /// Counts the prose a reader would hear, not the Markdown that produces it.
    /// Syntax markers are dropped so adding emphasis to a sentence never changes
    /// its word count, and link labels are kept while their URLs are not.
    public static func measuring(markdown: String) -> WritingStatistics {
        let prose = plainProse(from: markdown)
        let words = prose.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { word in word.contains { $0.isLetter || $0.isNumber } }
        return WritingStatistics(
            wordCount: words.count,
            characterCount: prose.count
        )
    }

    /// 200 words per minute, the middle of the range for adult silent reading and
    /// the figure Obsidian and Medium both settle on.
    public static let wordsPerMinute = 200

    public var readingMinutes: Int {
        guard wordCount > 0 else { return 0 }
        return max(1, Int((Double(wordCount) / Double(Self.wordsPerMinute)).rounded()))
    }

    public var readingTimeDescription: String {
        guard wordCount > 0 else { return "—" }
        let minutes = readingMinutes
        return minutes == 1 ? "1 min read" : "\(minutes) min read"
    }

    public var wordCountDescription: String {
        wordCount == 1 ? "1 word" : "\(wordCount.formatted()) words"
    }

    /// The prose a reader would hear, with Markdown syntax removed. A list row
    /// showing raw source — `## The Weight`, `**ordinary**` — is harder to scan
    /// than the sentence it stands for.
    public static func plainText(from markdown: String) -> String {
        plainProse(from: markdown)
    }

    /// A single-line opening for a list row. Collapses the paragraph breaks that
    /// would otherwise make one line of a row render as an empty gap.
    public static func snippet(from markdown: String, limit: Int = 160) -> String {
        let collapsed = plainProse(from: markdown)
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        // Break on a word so the ellipsis never lands mid-word.
        let clipped = collapsed.prefix(limit)
        guard let lastSpace = clipped.lastIndex(of: " ") else {
            return String(clipped) + "…"
        }
        return clipped[clipped.startIndex..<lastSpace] + "…"
    }

    private static func plainProse(from markdown: String) -> String {
        var result = ""
        result.reserveCapacity(markdown.count)

        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = Substring(rawLine)

            // Leading block syntax: heading hashes, quote carets, list bullets.
            while let first = line.first, first == " " || first == "\t" {
                line = line.dropFirst()
            }
            while let first = line.first, first == "#" || first == ">" {
                line = line.dropFirst()
                while let next = line.first, next == " " { line = line.dropFirst() }
            }
            if let first = line.first, first == "-" || first == "*" || first == "+" {
                let afterMarker = line.dropFirst()
                if afterMarker.first == " " { line = afterMarker.dropFirst() }
            }

            // A horizontal rule carries no prose at all.
            let compact = line.filter { !$0.isWhitespace }
            if compact.count >= 3,
               compact.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                result.append("\n")
                continue
            }

            result.append(contentsOf: stripInlineSyntax(String(line)))
            result.append("\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops emphasis markers and link and image targets, keeping the label a
    /// reader actually reads. Image captions are dropped along with their URL:
    /// a picture is not part of the spoken length.
    private static func stripInlineSyntax(_ line: String) -> String {
        var result = ""
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            switch character {
            case "*", "_", "`":
                index += 1
            case "!":
                // `![caption](url)` — skip the whole image.
                if let closing = linkRange(in: characters, startingAt: index + 1) {
                    index = closing + 1
                } else {
                    result.append(character)
                    index += 1
                }
            case "[":
                if let closing = linkRange(in: characters, startingAt: index),
                   let labelEnd = characters[index...closing].firstIndex(of: "]") {
                    result.append(contentsOf: characters[(index + 1)..<labelEnd])
                    index = closing + 1
                } else {
                    result.append(character)
                    index += 1
                }
            default:
                result.append(character)
                index += 1
            }
        }

        return result
    }

    /// The index of the `)` closing a `[label](url)` beginning at `start`, or nil
    /// when the text merely contains a stray bracket.
    private static func linkRange(in characters: [Character], startingAt start: Int) -> Int? {
        guard start < characters.count, characters[start] == "[" else { return nil }
        var index = start + 1
        var foundLabelEnd = false
        while index < characters.count {
            if characters[index] == "]" {
                foundLabelEnd = true
                break
            }
            index += 1
        }
        guard foundLabelEnd, index + 1 < characters.count, characters[index + 1] == "(" else {
            return nil
        }
        index += 2
        var depth = 1
        while index < characters.count {
            if characters[index] == "(" { depth += 1 }
            if characters[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}

/// Maps a scroll position in one pane onto the equivalent position in another.
///
/// Split preview is only useful if the rendered pane stays near the paragraph
/// being written; otherwise the writer scrolls twice for every edit. Markdown
/// source and rendered output have no shared coordinate system — an image is one
/// line of source and 400 points of output — so this mirrors the fraction
/// scrolled rather than pretending the two heights correspond.
public enum ProportionalScrollSync {
    /// How far through its scrollable range a pane sits, from 0 to 1. A pane with
    /// nothing to scroll is at the top, not at the end.
    public static func fraction(offset: Double, contentHeight: Double, viewportHeight: Double) -> Double {
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 0.5 else { return 0 }
        return min(max(offset / scrollable, 0), 1)
    }

    /// The offset that puts another pane at the same fraction.
    public static func offset(fraction: Double, contentHeight: Double, viewportHeight: Double) -> Double {
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 0.5 else { return 0 }
        return min(max(fraction, 0), 1) * scrollable
    }

    /// Whether a newly reported fraction is worth acting on. Scroll notifications
    /// arrive continuously, and re-driving the other pane for a sub-pixel change
    /// makes the two views fight each other instead of following.
    public static func isSignificantChange(
        from previous: Double?,
        to current: Double,
        scrollableHeight: Double
    ) -> Bool {
        guard let previous else { return true }
        guard scrollableHeight > 0.5 else { return false }
        // Half a point of travel in the driven pane is the smallest move that can
        // show up on screen.
        return abs(current - previous) * scrollableHeight > 0.5
    }
}
