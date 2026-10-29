import Foundation
import LampCore
import LampModuleKit

/// Narrowing a Strong's analysis to the occurrences behind one of its figures.
///
/// Every case is answerable from an occurrence on its own. That is the point:
/// the analysis already carries every occurrence in range, so choosing a
/// rendering or a chapter filters the list in place rather than asking the
/// library a second question. A search would not do — it stops at a page of
/// hits, and a common key has far more occurrences than a page holds.
public enum LampStrongsFilter: Hashable, Sendable {
    /// Carries the rendering's text as well as its id, because the chip has to
    /// name what was chosen and an id is not a thing to show anyone.
    case rendering(id: String, text: String)
    case form(String)
    case grammar(feature: LampGrammarFeature, value: String)
    case book(number: Int)
    case chapter(book: Int, number: Int)

    /// What the removable chip says.
    public var label: String {
        switch self {
        case .rendering(_, let text):
            "“\(text)”"
        case .form(let text):
            text
        case .grammar(let feature, let value):
            "\(feature.title): \(value)"
        case .book(let number):
            LampBibleReferenceFormatter.bookName(number)
        case .chapter(let book, let number):
            "\(LampBibleReferenceFormatter.bookName(book)) \(number)"
        }
    }

    public func matches(_ occurrence: LampStrongsAnalysis.Occurrence) -> Bool {
        switch self {
        case .rendering(let id, _):
            occurrence.renderingID == id
        case .form(let text):
            occurrence.form == text
        case .grammar(let feature, let value):
            // Read through core's own parser rather than taking the code
            // apart here. The grammar counts this filter narrows were built
            // by that parser, so anything else would answer a different
            // question from the number the reader clicked.
            occurrence.morphology.map {
                LampGreekMorphology.features(of: $0)
                    .contains { $0.feature == feature && $0.value == value }
            } ?? false
        case .book(let number):
            LampBibleReferenceFormatter.components(of: occurrence.reference).book == number
        case .chapter(let book, let number):
            {
                let parts = LampBibleReferenceFormatter.components(of: occurrence.reference)
                return parts.book == book && parts.chapter == number
            }()
        }
    }
}

extension LampStrongsAnalysis {
    /// The occurrences one filter leaves, or all of them when nothing is
    /// chosen.
    public func occurrences(matching filter: LampStrongsFilter?) -> [Occurrence] {
        guard let filter else { return occurrences }
        return occurrences.filter(filter.matches)
    }
}

/// Which translation's analysis the pane shows first.
public enum LampStrongsAnalysisOrder {
    /// The analyses with the translation being read at the front.
    ///
    /// The pane shows the active translation before the others have been
    /// worked out, so the order it finally settles into has to start with that
    /// same one. Otherwise the row a reader was looking at slides down the
    /// list as the rest arrive.
    public static func ordered(
        _ analyses: [LampStrongsAnalysis],
        activeTranslationID: String?
    ) -> [LampStrongsAnalysis] {
        guard
            let activeTranslationID,
            let index = analyses.firstIndex(where: { $0.translationID == activeTranslationID })
        else { return analyses }
        var ordered = analyses
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}

public enum LampStrongsSpreadMeasure: String, CaseIterable, Identifiable, Sendable {
    case occurrences
    case perThousandWords

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .occurrences: "Occurrences"
        case .perThousandWords: "Per 1,000 Words"
        }
    }
}

/// One bar of the spread chart.
public struct LampStrongsSpreadBar: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let value: Double
    /// How long to draw the bar, as a fraction of the longest one.
    public let share: Double
    public let expectation: LampStrongsAnalysis.Expectation
    public let occurrenceCount: Int
    public let wordCount: Int

    public init(
        id: Int,
        name: String,
        value: Double,
        share: Double,
        expectation: LampStrongsAnalysis.Expectation,
        occurrenceCount: Int,
        wordCount: Int
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.share = share
        self.expectation = expectation
        self.occurrenceCount = occurrenceCount
        self.wordCount = wordCount
    }
}

public enum LampStrongsSpread {
    /// Bars for a run of divisions, scaled against the longest of them.
    ///
    /// Scaled here rather than in the view because the zero case has to be
    /// decided once: a key that occurs nowhere in range gives every division a
    /// value of nothing, and dividing by the largest of those is a crash in
    /// one place and a chart of full-width bars in another.
    public static func bars(
        _ divisions: [LampStrongsAnalysis.Division],
        measure: LampStrongsSpreadMeasure
    ) -> [LampStrongsSpreadBar] {
        let values = divisions.map { division in
            switch measure {
            case .occurrences: Double(division.occurrenceCount)
            case .perThousandWords: division.ratePerThousandWords
            }
        }
        let longest = values.max() ?? 0
        return zip(divisions, values).map { division, value in
            LampStrongsSpreadBar(
                id: division.id,
                name: division.name,
                value: value,
                share: longest > 0 ? value / longest : 0,
                expectation: division.expectation,
                occurrenceCount: division.occurrenceCount,
                wordCount: division.wordCount
            )
        }
    }
}

extension LampPresentationBlockKind {
    /// The roles Slide Studio can add by hand.
    ///
    /// Every one of them. A chart was held back while Studio could draw one
    /// but not build one — adding it then made a block that was invalid the
    /// moment it appeared — and it came back when the editor did, which adds
    /// a chart with its translation already chosen.
    public static var authorableHere: [LampPresentationBlockKind] {
        allCases
    }

    /// The same list, with `kind` in it whether or not it is authorable.
    ///
    /// Kept for a picker bound to an existing block: a selection with no
    /// matching tag draws blank and can be reset to the first entry, silently
    /// turning one kind of block into another. Nothing is held back today, so
    /// this is the same list — and it is the guard that has to stay if
    /// anything is held back again.
    public static func authorableHere(
        including kind: LampPresentationBlockKind
    ) -> [LampPresentationBlockKind] {
        authorableHere.contains(kind) ? authorableHere : authorableHere + [kind]
    }
}

/// A verse around the word that carries the key.
///
/// Only the translation being read is asked for its verses — the others cost
/// about a megabyte each for a common key and nothing reads them — so a
/// snippet is drawn from `LampStrongsAnalysis.verseTexts`, which is empty
/// unless it was asked for.
public enum LampStrongsContext {
    public struct Snippet: Equatable, Sendable {
        public var before: String
        /// The words the tag covers, which the row draws emphasised.
        public var word: String
        public var after: String
        /// Text was dropped from that end to keep the row short.
        public var isTrimmedAtStart: Bool
        public var isTrimmedAtEnd: Bool

        public init(
            before: String,
            word: String,
            after: String,
            isTrimmedAtStart: Bool = false,
            isTrimmedAtEnd: Bool = false
        ) {
            self.before = before
            self.word = word
            self.after = after
            self.isTrimmedAtStart = isTrimmedAtStart
            self.isTrimmedAtEnd = isTrimmedAtEnd
        }
    }

    /// The verse split around `startOffset..<endOffset`, trimmed to `window`
    /// characters either side.
    ///
    /// Offsets count `Character`s, as every annotation offset in Lamp does.
    /// Slicing `Array(verse)` rather than the scalars is the whole point: a
    /// verse with a decomposed accent earlier in it has more scalars than
    /// characters, and cutting by scalars moves the highlight off the word.
    ///
    /// Out-of-range offsets are clamped rather than trusted. They have been
    /// wrong before — the book readers indexed characters while the converters
    /// counted scalars — and a verse is the one place where being wrong by a
    /// little means slicing a sentence mid-word instead of crashing, which is
    /// harder to notice.
    public static func snippet(
        of verse: String,
        from startOffset: Int,
        to endOffset: Int,
        window: Int = 72
    ) -> Snippet {
        let characters = Array(verse)
        let start = min(max(0, startOffset), characters.count)
        let end = min(max(start, endOffset), characters.count)

        var before = String(characters[..<start])
        var after = String(characters[end...])
        let word = String(characters[start..<end])

        var trimmedStart = false
        if before.count > window {
            before = String(before.suffix(window))
            // Not mid-word: start at the next space, so a row never opens on
            // half of a word.
            if let space = before.firstIndex(of: " ") {
                before = String(before[before.index(after: space)...])
            }
            trimmedStart = true
        }
        var trimmedEnd = false
        if after.count > window {
            after = String(after.prefix(window))
            if let space = after.lastIndex(of: " ") {
                after = String(after[..<space])
            }
            trimmedEnd = true
        }

        return Snippet(
            before: before,
            word: word,
            after: after,
            isTrimmedAtStart: trimmedStart,
            isTrimmedAtEnd: trimmedEnd
        )
    }
}

/// Recognising a Strong's key someone has typed into a search box.
///
/// The analysis has its own field in the toolbar, which only appears once the
/// content picker is on Scripture — so someone who types a key into the search
/// box gets a text search and no sign that the analysis exists. Reading the
/// box lets the obvious thing happen instead.
public enum LampStrongsQuery {
    /// The key this text names, or nil when it is words.
    ///
    /// Deliberately strict. "Genesis" and "Hebrews 1" both begin with a letter
    /// this would accept, so a key is only a key when digits follow the
    /// prefix immediately — and a disambiguating suffix is one letter at most,
    /// as in G1234a.
    public static func key(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        let prefix: String
        if upper.hasPrefix("TH") {
            prefix = "TH"
        } else if upper.hasPrefix("H") || upper.hasPrefix("G") {
            prefix = String(upper.prefix(1))
        } else {
            return nil
        }
        let rest = upper.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let suffix = rest.dropFirst(digits.count)
        guard suffix.count <= 1, suffix.allSatisfy(\.isLetter) else { return nil }
        return LampStrongsKey.normalized(trimmed)
    }
}

/// How the spread is drawn.
///
/// One set of numbers, four readings of it. Bars rank, a histogram shows
/// shape, a grid shows where inside a book, and share shows proportion.
public enum LampStrongsChartStyle: String, CaseIterable, Identifiable, Sendable {
    case bars
    case columns
    case grid
    case share

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bars: "Bars"
        case .columns: "Spread"
        case .grid: "Chapters"
        case .share: "Share"
        }
    }

    /// Whether the measure picker means anything here. A grid counts
    /// occurrences per chapter and a share is a proportion of a whole, so
    /// neither has a rate to offer.
    public var usesMeasure: Bool {
        self == .bars || self == .columns
    }

    /// Only books carry chapters, so the grid has nothing to draw for
    /// sections.
    public var needsBooks: Bool { self == .grid }
}

/// Each division's proportion of the whole.
public enum LampStrongsShare {
    public struct Slice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let value: Int
        /// 0...1 of the total.
        public let fraction: Double
        /// True for the slice that gathers everything past the limit.
        public let isOther: Bool

        public init(id: String, name: String, value: Int, fraction: Double, isOther: Bool = false) {
            self.id = id
            self.name = name
            self.value = value
            self.fraction = fraction
            self.isOther = isOther
        }
    }

    /// The largest divisions by count, with the rest gathered into "Other".
    ///
    /// Gathered rather than drawn, because a ring of twenty-seven slivers
    /// answers no question anyone has. Divisions holding nothing are left out
    /// entirely: a slice of zero is invisible but still takes a label.
    public static func slices(
        from divisions: [LampStrongsAnalysis.Division],
        limit: Int = 6
    ) -> [Slice] {
        let total = divisions.reduce(0) { $0 + $1.occurrenceCount }
        guard total > 0 else { return [] }
        let ranked = divisions
            .filter { $0.occurrenceCount > 0 }
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
        let kept = ranked.prefix(limit)
        var slices = kept.map {
            Slice(
                id: String($0.id),
                name: $0.name,
                value: $0.occurrenceCount,
                fraction: Double($0.occurrenceCount) / Double(total)
            )
        }
        let rest = ranked.dropFirst(kept.count).reduce(0) { $0 + $1.occurrenceCount }
        if rest > 0 {
            slices.append(
                Slice(
                    id: "other",
                    name: "Other",
                    value: rest,
                    fraction: Double(rest) / Double(total),
                    isOther: true
                )
            )
        }
        return slices
    }
}

/// Every chapter of every book, shaded by how often the key occurs.
public enum LampStrongsGrid {
    public struct Cell: Identifiable, Equatable, Sendable {
        public var id: Int { number }
        public let number: Int
        public let occurrenceCount: Int
        /// 0...1 against the busiest chapter anywhere in the grid.
        public let intensity: Double

        public init(number: Int, occurrenceCount: Int, intensity: Double) {
            self.number = number
            self.occurrenceCount = occurrenceCount
            self.intensity = intensity
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let cells: [Cell]
        public let occurrenceCount: Int

        public init(id: Int, name: String, cells: [Cell], occurrenceCount: Int) {
            self.id = id
            self.name = name
            self.cells = cells
            self.occurrenceCount = occurrenceCount
        }
    }

    /// Rows for the books that hold the key.
    ///
    /// Shaded against the busiest chapter in the whole grid rather than the
    /// busiest in each row: per-row shading would paint a book with one
    /// occurrence as darkly as 1 John 4, which is the opposite of what the
    /// picture is for.
    public static func rows(
        from books: [LampStrongsAnalysis.Division],
        includingEmptyBooks: Bool = false
    ) -> [Row] {
        let busiest = books.flatMap(\.chapters).map(\.occurrenceCount).max() ?? 0
        return books.compactMap { book in
            guard includingEmptyBooks || book.occurrenceCount > 0 else { return nil }
            guard !book.chapters.isEmpty else { return nil }
            return Row(
                id: book.id,
                name: book.name,
                cells: book.chapters.map { chapter in
                    Cell(
                        number: chapter.number,
                        occurrenceCount: chapter.occurrenceCount,
                        intensity: busiest > 0
                            ? Double(chapter.occurrenceCount) / Double(busiest)
                            : 0
                    )
                },
                occurrenceCount: book.occurrenceCount
            )
        }
    }
}
