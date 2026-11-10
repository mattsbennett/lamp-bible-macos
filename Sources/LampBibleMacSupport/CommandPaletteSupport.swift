import Foundation

/// How well a typed query names something in the ⌘K palette, for ordering
/// what it shows. Nil where it does not name it at all.
///
/// Folded for case and accents, so "genese" finds "Genèse". A title that
/// starts with the query ranks first, then one with a word that does, then
/// one that holds it anywhere, then one whose letters run through the query
/// in order ("nwr" for "New Writing"). Keywords — the settings in a pane,
/// another name for a command — count a little less than the title.
public enum CommandPaletteMatch {
    public static func score(_ query: String, title: String, keywords: [String] = []) -> Double? {
        let needle = fold(query)
        guard !needle.isEmpty else { return nil }
        if let titleScore = score(needle, in: fold(title)) { return titleScore }
        let best = keywords.compactMap { score(needle, in: fold($0)) }.max()
        return best.map { $0 * 0.85 }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func score(_ needle: String, in haystack: String) -> Double? {
        guard !haystack.isEmpty else { return nil }
        if haystack == needle { return 1 }
        if haystack.hasPrefix(needle) { return 0.95 }
        let words = haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(needle) }) { return 0.85 }
        if haystack.contains(needle) { return 0.7 }
        // Letters in order, each word's first letters counting more:
        // "nw" for New Writing.
        var index = haystack.startIndex
        for character in needle where character != " " {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            index = haystack.index(after: found)
        }
        return needle.count > 1 ? 0.4 : nil
    }
}

/// Links to the things the ⌘K palette and the window open that core's shared
/// links do not name: a writing, a reading plan, a quiz, a deck, a word's
/// analysis. Read on the Mac before core's parser, so the phone's copy of
/// that parser is unchanged.
///
/// `lampbible://writing/<id>`, `plan/<id>`, `quiz/<module id>`,
/// `deck/<id>`, `analysis/<key>`.
public enum LampMacLink: Equatable, Sendable {
    case writing(String)
    case plan(String)
    case quiz(String)
    case deck(String)
    case analysis(String)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "lampbible", let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard let first = path.first?.removingPercentEncoding, !first.isEmpty else { return nil }
        switch host {
        case "writing": self = .writing(first)
        case "plan": self = .plan(first)
        case "quiz": self = .quiz(first)
        case "deck": self = .deck(first)
        case "analysis": self = .analysis(first)
        default: return nil
        }
    }

    public var url: URL {
        let (host, value): (String, String) = switch self {
        case .writing(let id): ("writing", id)
        case .plan(let id): ("plan", id)
        case .quiz(let id): ("quiz", id)
        case .deck(let id): ("deck", id)
        case .analysis(let key): ("analysis", key)
        }
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = host
        components.path = "/" + value
        return components.url!
    }
}
