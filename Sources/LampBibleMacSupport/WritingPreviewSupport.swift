import Foundation

/// Word count and reading time for the status bar, the way Obsidian keeps them
/// permanently visible at the edge of the window. Devotional and sermon writing is
/// written to a length — "about fifteen minutes" — so the estimate is not a
/// novelty, it is the constraint the author is writing against.
/// How a reader will meet the writing: to themselves, or out loud.
///
/// Reading time was one figure at one pace, which answers "how long is this to
/// read" and not "how long will this take me to deliver" — the question a
/// talk's writer is actually asking.
public enum LampReadingMode: String, CaseIterable, Identifiable, Sendable {
    case silent
    case aloud

    public static let defaultsKey = "writing.readingMode"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .silent: "Silent"
        case .aloud: "Aloud"
        }
    }

    /// What the choice means, for the menu that offers it.
    public var explanation: String {
        switch self {
        case .silent: "How long this takes to read to yourself"
        case .aloud: "How long this takes to deliver, read aloud"
        }
    }

    public var systemImage: String {
        switch self {
        case .silent: "clock"
        case .aloud: "microphone"
        }
    }

    /// 200 words a minute silently, the middle of the range for adult silent
    /// reading; 130 aloud, the pace of prepared speech read to a room, which is
    /// slower than the 140–160 of ordinary conversation.
    public var defaultWordsPerMinute: Int {
        switch self {
        case .silent: 200
        case .aloud: 130
        }
    }

    /// Where this pace's rate is kept, so each is set and read on its own.
    public var wordsPerMinuteKey: String { "writing.wordsPerMinute.\(rawValue)" }

    public func description(minutes: Int) -> String {
        switch self {
        case .silent: minutes == 1 ? "1 min read" : "\(minutes) min read"
        case .aloud: minutes == 1 ? "1 min aloud" : "\(minutes) min aloud"
        }
    }

    /// Reads a stored choice, falling back to silent for anything unexpected —
    /// a value from an older version, or from another device.
    public init(storedValue: String?) {
        self = LampReadingMode(rawValue: storedValue ?? "") ?? .silent
    }
}

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
    public static let wordsPerMinute = LampReadingMode.silent.defaultWordsPerMinute

    public func readingMinutes(
        mode: LampReadingMode = .silent,
        wordsPerMinute: Int? = nil
    ) -> Int {
        guard wordCount > 0 else { return 0 }
        let rate = max(wordsPerMinute ?? mode.defaultWordsPerMinute, 1)
        return max(1, Int((Double(wordCount) / Double(rate)).rounded()))
    }

    /// How long this will take, and at which of the two paces.
    ///
    /// A talk is written to be spoken, and a devotional to be read: the same
    /// words take half as long again out loud, so one figure cannot answer
    /// both questions.
    public func readingTimeDescription(
        mode: LampReadingMode = .silent,
        wordsPerMinute: Int? = nil
    ) -> String {
        guard wordCount > 0 else { return "—" }
        return mode.description(minutes: readingMinutes(mode: mode, wordsPerMinute: wordsPerMinute))
    }

    public var readingMinutes: Int { readingMinutes() }

    public var readingTimeDescription: String { readingTimeDescription() }

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
