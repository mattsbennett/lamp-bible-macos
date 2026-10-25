import Foundation

/// How the writing editor's find bar matches.
public struct WritingFindOptions: Equatable, Sendable {
    /// Whether "Grace" and "grace" are different words. Off, as in every Mac
    /// find bar.
    public var matchesCase: Bool
    /// Whether a match must be whole words, so `law` misses `lawless`.
    public var wholeWords: Bool

    public init(matchesCase: Bool = false, wholeWords: Bool = false) {
        self.matchesCase = matchesCase
        self.wholeWords = wholeWords
    }
}

/// How many matches the find bar has, and which of them is current.
public struct WritingFindStatus: Equatable, Sendable {
    public var count: Int
    /// Counted from 1; 0 when no match is current.
    public var current: Int

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }

    public static let noMatches = WritingFindStatus(count: 0, current: 0)

    /// What the find bar shows beside the query: "3 of 12".
    public var description: String {
        guard count > 0 else { return "No matches" }
        guard current > 0 else { return count == 1 ? "1 match" : "\(count) matches" }
        return "\(current) of \(count)"
    }
}

/// Finding text in a Markdown document as a text view holds it.
///
/// Kept free of AppKit so what is easy to get subtly wrong — a match that
/// splits an accented letter, a whole word next to punctuation — can be
/// tested without a text view.
public enum WritingFind {
    /// Every match of `query` in `text`, left to right and never overlapping,
    /// as UTF-16 ranges, which is how a text view counts.
    ///
    /// The query is literal text. Composed and decomposed accents match each
    /// other, and a match never starts or ends inside a character, so `grace`
    /// does not match the start of `grace\u{301}d`.
    public static func matches(
        of query: String,
        in text: String,
        options: WritingFindOptions = .init()
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = text as NSString
        let compareOptions: NSString.CompareOptions = options.matchesCase ? [] : [.caseInsensitive]
        var found: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.range(
                of: query,
                options: compareOptions,
                range: NSRange(location: location, length: string.length - location)
            )
            guard range.location != NSNotFound, range.length > 0 else { break }
            if isWholeCharacters(range, in: string),
               !options.wholeWords || isWholeWords(range, in: string) {
                found.append(range)
                location = NSMaxRange(range)
            } else {
                location = NSMaxRange(string.rangeOfComposedCharacterSequence(at: range.location))
            }
        }
        return found
    }

    /// The match a search from `location` lands on: the first at or after it,
    /// or else the first in the document. Nil when there are none.
    public static func index(startingAt location: Int, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex { $0.location >= location } ?? 0
    }

    private static func isWholeCharacters(_ range: NSRange, in string: NSString) -> Bool {
        string.rangeOfComposedCharacterSequence(at: range.location).location == range.location
            && (NSMaxRange(range) == string.length
                || string.rangeOfComposedCharacterSequence(at: NSMaxRange(range)).location == NSMaxRange(range))
    }

    /// A letter or digit at an edge of the match may not have another beside
    /// it. Punctuation at an edge needs no boundary, so `Cain` matches in
    /// `Cain's`, and a query that ends in a full stop still matches.
    private static func isWholeWords(_ range: NSRange, in string: NSString) -> Bool {
        let first = character(at: range.location, in: string)
        let last = character(at: NSMaxRange(range) - 1, in: string)
        if range.location > 0, isWordCharacter(first),
           isWordCharacter(character(at: range.location - 1, in: string)) {
            return false
        }
        if NSMaxRange(range) < string.length, isWordCharacter(last),
           isWordCharacter(character(at: NSMaxRange(range), in: string)) {
            return false
        }
        return true
    }

    private static func character(at offset: Int, in string: NSString) -> Character? {
        string.substring(with: string.rangeOfComposedCharacterSequence(at: offset)).first
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }
}
