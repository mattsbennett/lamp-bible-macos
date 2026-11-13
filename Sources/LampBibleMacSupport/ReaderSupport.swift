import AppKit
import Foundation
import LampCore

/// Resolves attributed-string links at a point in supported AppKit selectable
/// text implementations. Callers can use either `NSTextField` or `NSTextView`.
public struct ReaderTextHit: Equatable, Sendable {
    public let link: URL?
    public let word: String?

    public init(link: URL?, word: String?) {
        self.link = link
        self.word = word
    }
}

@MainActor
public enum ReaderTextLinkHitTester {
    public static func link(at point: NSPoint, in textView: NSTextView) -> URL? {
        hit(at: point, in: textView)?.link
    }

    public static func hit(at point: NSPoint, in textView: NSTextView) -> ReaderTextHit? {
        guard let textStorage = textView.textStorage, textStorage.length > 0 else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textView.textContainerOrigin.x,
            y: point.y - textView.textContainerOrigin.y
        )
        // A TextKit 2 view, such as the study pane's commentary: asking it for
        // `layoutManager` would switch it to TextKit 1 for good, so its own
        // layout manager finds the character.
        if let textLayoutManager = textView.textLayoutManager {
            guard let index = characterIndex(at: containerPoint, in: textLayoutManager, string: textStorage.string as NSString),
                  index < textStorage.length else { return nil }
            return hit(atCharacterIndex: index, attributedString: textStorage)
        }
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        return hit(
            at: containerPoint,
            attributedString: textStorage,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
    }

    public static func link(at point: NSPoint, in textField: NSTextField) -> URL? {
        hit(at: point, in: textField)?.link
    }

    public static func hit(at point: NSPoint, in textField: NSTextField) -> ReaderTextHit? {
        let attributedString = textField.attributedStringValue
        guard attributedString.length > 0 else { return nil }

        let drawingRect = textField.cell?.drawingRect(forBounds: textField.bounds)
            ?? textField.bounds
        guard drawingRect.contains(point), drawingRect.width > 0, drawingRect.height > 0 else {
            return nil
        }

        let textStorage = NSTextStorage(attributedString: attributedString)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: drawingRect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = textField.lineBreakMode
        textContainer.maximumNumberOfLines = textField.maximumNumberOfLines
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let containerPoint = NSPoint(
            x: point.x - drawingRect.minX,
            y: point.y - drawingRect.minY
        )
        return hit(
            at: containerPoint,
            attributedString: attributedString,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
    }

    private static func hit(
        at point: NSPoint,
        attributedString: NSAttributedString,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> ReaderTextHit? {
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < attributedString.length else { return nil }
        return hit(atCharacterIndex: characterIndex, attributedString: attributedString)
    }

    /// The character under `point` in a TextKit 2 layout, in the container's
    /// space, or nil when the point is not on a glyph: past a line's end, or
    /// between paragraphs.
    private static func characterIndex(at point: NSPoint, in layoutManager: NSTextLayoutManager, string: NSString) -> Int? {
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: {
            $0.typographicBounds.insetBy(dx: -2, dy: -2).contains(local)
        }) else { return nil }
        let bounds = line.typographicBounds
        let inLine = CGPoint(x: local.x - bounds.minX, y: local.y - bounds.minY)
        let index = line.characterIndex(for: inLine)
        guard index >= line.characterRange.location, index < NSMaxRange(line.characterRange) else { return nil }
        let paragraphStart = layoutManager.offset(
            from: layoutManager.documentRange.location,
            to: fragment.rangeInElement.location
        )
        let documentIndex = paragraphStart + index
        guard documentIndex < string.length else { return nil }
        // On the glyph itself, as the TextKit 1 path checks its glyph's rect:
        // the whole composed character's own segments, which right-to-left
        // text and combining marks make more than two neighbouring edges.
        let composed = string.rangeOfComposedCharacterSequence(at: documentIndex)
        guard let start = layoutManager.location(layoutManager.documentRange.location, offsetBy: composed.location),
              let end = layoutManager.location(start, offsetBy: composed.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var isOnGlyph = false
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            isOnGlyph = segment.insetBy(dx: -2, dy: -2).contains(point)
            return !isOnGlyph
        }
        return isOnGlyph ? documentIndex : nil
    }

    private static func hit(atCharacterIndex characterIndex: Int, attributedString: NSAttributedString) -> ReaderTextHit? {
        var effectiveLinkRange = NSRange(location: NSNotFound, length: 0)
        let value = attributedString.attribute(
            .link,
            at: characterIndex,
            effectiveRange: &effectiveLinkRange
        )
        var link = linkURL(from: value)
        if link == nil {
            var internalRange = NSRange(location: NSNotFound, length: 0)
            let internalValue = attributedString.attribute(
                .languageIdentifier,
                at: characterIndex,
                effectiveRange: &internalRange
            )
            if let url = linkURL(from: internalValue), LexiconLookupLink(url: url) != nil {
                link = url
                effectiveLinkRange = internalRange
            }
        }

        let linkedText: String? = if link != nil,
                                    effectiveLinkRange.location != NSNotFound,
                                    NSMaxRange(effectiveLinkRange) <= attributedString.length {
            attributedString.attributedSubstring(from: effectiveLinkRange).string
        } else {
            nil
        }
        let word = linkedText.flatMap(nonemptyTrimmed(_:))
            ?? word(atUTF16Offset: characterIndex, in: attributedString.string)
        return ReaderTextHit(link: link, word: word)
    }

    private static func linkURL(from value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func nonemptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func word(atUTF16Offset offset: Int, in text: String) -> String? {
        guard !text.isEmpty, offset >= 0, offset < text.utf16.count else { return nil }
        let clickedIndex = String.Index(utf16Offset: offset, in: text)
        var clickedWord: String?
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            guard range.contains(clickedIndex) else { return }
            clickedWord = String(text[range])
            stop = true
        }
        return clickedWord.flatMap(nonemptyTrimmed(_:))
    }
}

public struct LexiconLookupLink: Equatable, Sendable {
    public let keys: [String]
    public let reference: Int
    /// The word as it appears in the verse. Carried along so the dictionary can say
    /// which word it is answering about — a lookup can resolve to several Strong's
    /// keys, and several entries per key, which is unreadable without it.
    public let word: String?

    public init?(keys: [String], reference: Int, word: String? = nil) {
        var seen: Set<String> = []
        let normalizedKeys = keys.compactMap { rawKey -> String? in
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
        guard !normalizedKeys.isEmpty, reference > 0 else { return nil }
        self.keys = normalizedKeys
        self.reference = reference
        let trimmedWord = word?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.word = trimmedWord?.isEmpty == false ? trimmedWord : nil
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "lamp-lexicon",
              url.host?.lowercased() == "lookup",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawReference = components.queryItems?.first(where: { $0.name == "reference" })?.value,
              let reference = Int(rawReference) else { return nil }
        let keys = components.queryItems?
            .filter { $0.name == "key" }
            .compactMap(\.value) ?? []
        let word = components.queryItems?.first { $0.name == "word" }?.value
        self.init(keys: keys, reference: reference, word: word)
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "lamp-lexicon"
        components.host = "lookup"
        components.queryItems = keys.map { URLQueryItem(name: "key", value: $0) }
            + [URLQueryItem(name: "reference", value: String(reference))]
            + (word.map { [URLQueryItem(name: "word", value: $0)] } ?? [])
        return components.url
    }
}

/// An internal link attached to scripture annotations in selectable prose such
/// as quiz questions and answers. Keeping both endpoints lets future previews
/// retain the annotated range even though today's reader opens at its first verse.
public struct ScriptureAnnotationLink: Equatable, Sendable {
    public let startReference: Int
    public let endReference: Int

    public init?(startReference: Int, endReference: Int? = nil) {
        let resolvedEnd = endReference ?? startReference
        guard startReference > 0, resolvedEnd >= startReference else { return nil }
        self.startReference = startReference
        self.endReference = resolvedEnd
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "lamp-scripture",
              url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawStart = components.queryItems?.first(where: { $0.name == "start" })?.value,
              let start = Int(rawStart) else { return nil }
        let end = components.queryItems?
            .first(where: { $0.name == "end" })?
            .value
            .flatMap(Int.init)
        self.init(startReference: start, endReference: end)
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "lamp-scripture"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "start", value: String(startReference)),
            URLQueryItem(name: "end", value: String(endReference)),
        ]
        return components.url
    }
}

/// Coalesces the native AppKit link callback with the reader's click fallback.
/// Both may observe the same click, but opening the inspector twice can replace
/// an in-flight lookup request and make link activation appear intermittent.
public struct ReaderLinkActivationGate: Sendable {
    public let duplicateInterval: TimeInterval
    private var lastURL: URL?
    private var lastActivationTime: TimeInterval?

    public init(duplicateInterval: TimeInterval = 0.4) {
        self.duplicateInterval = duplicateInterval
    }

    public mutating func shouldActivate(_ url: URL, at time: TimeInterval) -> Bool {
        defer {
            lastURL = url
            lastActivationTime = time
        }
        guard lastURL == url, let lastActivationTime else { return true }
        return time - lastActivationTime > duplicateInterval
    }
}

/// Adds enough non-content space after a scroll-linked passage for its final
/// anchor to reach the viewport's top edge. Completion checks subtract this
/// artificial tail so reaching the real passage end keeps its original meaning.
public enum ReaderScrollTail {
    public static func height(for viewportHeight: CGFloat) -> CGFloat {
        max(viewportHeight - 1, 0)
    }

    public static func hasReachedContentBottom(
        visibleMaxY: CGFloat,
        totalContentHeight: CGFloat,
        viewportHeight: CGFloat,
        tolerance: CGFloat = 8
    ) -> Bool {
        visibleMaxY >= totalContentHeight - height(for: viewportHeight) - tolerance
    }
}

/// How much neighboring scripture a reference preview includes. The raw values
/// intentionally match iOS so the choices keep the same meaning across apps.
public enum ScripturePreviewContextAmount: Int, CaseIterable, Hashable, Sendable {
    case oneVerse = 1
    case threeVerses = 3
    case chapter = 0

    fileprivate var neighboringVerseCount: Int? {
        switch self {
        case .oneVerse: 1
        case .threeVerses: 3
        case .chapter: nil
        }
    }
}

public struct ScripturePreviewReference: Equatable, Sendable {
    public let reference: Int
    public let isContext: Bool

    public init(reference: Int, isContext: Bool) {
        self.reference = reference
        self.isContext = isContext
    }
}

public enum ScripturePreviewContextResolver {
    /// Selects the primary range and its neighboring verses from one chapter.
    /// Multi-chapter loading remains the caller's responsibility because context
    /// is deliberately only added around compact, single-chapter references.
    public static func references(
        in chapterReferences: [Int],
        from startReference: Int,
        to endReference: Int,
        contextAmount: ScripturePreviewContextAmount
    ) -> [ScripturePreviewReference] {
        guard startReference > 0, endReference >= startReference,
              let firstPrimaryIndex = chapterReferences.firstIndex(where: {
                  $0 >= startReference && $0 <= endReference
              }),
              let lastPrimaryIndex = chapterReferences.lastIndex(where: {
                  $0 >= startReference && $0 <= endReference
              }) else { return [] }

        let bounds: ClosedRange<Int>
        if let neighboringVerseCount = contextAmount.neighboringVerseCount {
            bounds = (
                max(0, firstPrimaryIndex - neighboringVerseCount)
                    ... min(chapterReferences.count - 1, lastPrimaryIndex + neighboringVerseCount)
            )
        } else {
            bounds = chapterReferences.indices.first!...chapterReferences.indices.last!
        }

        return bounds.map { index in
            let reference = chapterReferences[index]
            return ScripturePreviewReference(
                reference: reference,
                isContext: reference < startReference || reference > endReference
            )
        }
    }
}

public typealias StrongsKey = LampStrongsKey

public struct ReadAloudItem: Codable, Equatable, Identifiable, Sendable {
    public let reference: Int
    public let verseNumber: Int
    public let text: String

    public var id: Int { reference }

    public init(reference: Int, verseNumber: Int, text: String) {
        self.reference = reference
        self.verseNumber = verseNumber
        self.text = text
    }
}

public struct ReadAloudQueue: Codable, Equatable, Sendable {
    public private(set) var items: [ReadAloudItem]
    public private(set) var currentIndex: Int?

    public init(items: [ReadAloudItem] = [], startingAt reference: Int? = nil) {
        self.items = items
        guard !items.isEmpty else {
            currentIndex = nil
            return
        }
        currentIndex = reference.flatMap { reference in
            items.firstIndex { $0.reference == reference }
        } ?? items.startIndex
    }

    public var current: ReadAloudItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public var remainingItems: ArraySlice<ReadAloudItem> {
        guard let currentIndex, items.indices.contains(currentIndex) else { return [] }
        return items[currentIndex...]
    }

    @discardableResult
    public mutating func advance() -> ReadAloudItem? {
        guard let currentIndex else { return nil }
        let nextIndex = items.index(after: currentIndex)
        guard items.indices.contains(nextIndex) else {
            self.currentIndex = nil
            return nil
        }
        self.currentIndex = nextIndex
        return items[nextIndex]
    }

    public mutating func stop() {
        currentIndex = nil
    }
}

public struct ReaderTextRange: Codable, Equatable, Sendable {
    public let startOffset: Int
    public let endOffset: Int

    public init(startOffset: Int, endOffset: Int) {
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

/// What the reader marks in the margin beside a run of verse text: the verse
/// being studied, and the verses that carry notes.
///
/// In the margin rather than in the text, because the text's own marks are
/// taken: three of the four highlight styles are underlines, a translation's
/// variants are underlined too, and a fill would read as another highlight.
public struct ReaderMarginMarks: Equatable, Sendable {
    public struct NoteKinds: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// The reader's own note.
        public static let personal = NoteKinds(rawValue: 1 << 0)
        /// A note from an installed study module.
        public static let module = NoteKinds(rawValue: 1 << 1)
    }

    public struct Note: Equatable, Sendable {
        /// Where the verse's number is in the text, in UTF-16 units.
        public let location: Int
        public let reference: Int
        public let kinds: NoteKinds

        public init(location: Int, reference: Int, kinds: NoteKinds) {
            self.location = location
            self.reference = reference
            self.kinds = kinds
        }
    }

    /// One icon in the margin, beside the line where a verse with a note of
    /// its kind begins.
    public struct Icon: Equatable, Sendable {
        public let line: Int
        public let kind: NoteKinds
        public let reference: Int

        public init(line: Int, kind: NoteKinds, reference: Int) {
            self.line = line
            self.kind = kind
            self.reference = reference
        }
    }

    /// The selected verse's characters in the text, when any of them are here.
    public var selectedRange: NSRange?
    public var notes: [Note]

    public init(selectedRange: NSRange? = nil, notes: [Note] = []) {
        self.selectedRange = selectedRange
        self.notes = notes
    }

    public static let none = ReaderMarginMarks()

    public var isEmpty: Bool { selectedRange == nil && notes.isEmpty }

    /// The icons for notes, given the line each one's verse begins on.
    ///
    /// Two verses can begin on one line, and the line shows each kind once:
    /// a second icon of a kind would repeat the first, and the margin has
    /// room for two. Each icon stands for the first verse on the line with a
    /// note of its kind, so the two beside one line can belong to different
    /// verses. The reader's own note comes first, nearer the text.
    public static func icons(for notes: [(line: Int, note: Note)]) -> [Icon] {
        var shown = Set<[Int]>()
        var icons: [Icon] = []
        for (line, note) in notes {
            for kind in [NoteKinds.personal, .module] where note.kinds.contains(kind) {
                guard shown.insert([line, kind.rawValue]).inserted else { continue }
                icons.append(Icon(line: line, kind: kind, reference: note.reference))
            }
        }
        return icons.sorted { ($0.line, $0.kind.rawValue) < ($1.line, $1.kind.rawValue) }
    }
}

/// One row of the side-by-side reader: a verse, in the translation being read
/// and in each companion beside it, where each has it.
public struct ReaderParallelRow: Identifiable, Equatable, Sendable {
    public let number: Int
    /// The verse every column speaks to: what the row scrolls to, and what
    /// selecting it or opening its notes acts on.
    public let reference: Int
    public let main: LampVerse?
    /// One for each companion, in the order of their columns.
    public let companions: [LampVerse?]

    public var id: Int { reference }
    /// The first companion's verse.
    public var companion: LampVerse? { companions.first ?? nil }
}

/// One companion's verses for a chapter, and how its numbering and the
/// reading's convert into each other: nil where the other has no such verse.
public struct ReaderParallelCompanion {
    public let verses: [LampVerse]
    public let fromMain: (Int) -> Int?
    public let toMain: (Int) -> Int?

    public init(verses: [LampVerse], fromMain: @escaping (Int) -> Int?, toMain: @escaping (Int) -> Int?) {
        self.verses = verses
        self.fromMain = fromMain
        self.toMain = toMain
    }
}

public enum ReaderParallelRows {
    /// Pairs two translations' verses of a chapter by number, in reading
    /// order: for two translations that number their verses alike.
    public static func rows(main: [LampVerse], companion: [LampVerse]) -> [ReaderParallelRow] {
        rows(main: main, companion: companion, mainToCompanion: { $0 }, companionToMain: { $0 })
    }

    /// Pairs a chapter of the translation being read with one companion.
    public static func rows(
        main: [LampVerse],
        companion: [LampVerse],
        mainToCompanion: @escaping (Int) -> Int?,
        companionToMain: @escaping (Int) -> Int?
    ) -> [ReaderParallelRow] {
        rows(main: main, companions: [
            ReaderParallelCompanion(verses: companion, fromMain: mainToCompanion, toMain: companionToMain),
        ])
    }

    /// Pairs a chapter of the translation being read with each companion's
    /// verses that are the same verses, however each translation numbers them:
    /// a psalm whose title one of them counts as verse 1, a doxology one of
    /// them places in another chapter.
    ///
    /// Each verse of the chapter is a row, in its order, beside the verse each
    /// companion's numbering converts it to. A companion verse that converts
    /// into this chapter to a verse it leaves out gets a row of its own, the
    /// reading's side empty, shared with any other companion that has that
    /// verse: closing the gap would pull every row after it out of line, and
    /// the gap is itself a difference between them. Companion verses that
    /// convert to another chapter of the reading belong to that chapter's rows.
    public static func rows(main: [LampVerse], companions: [ReaderParallelCompanion]) -> [ReaderParallelRow] {
        guard let chapter = main.first.map({ $0.id / 1_000 })
            ?? companions.lazy.compactMap({ $0.verses.first }).first.map({ $0.id / 1_000 })
        else { return [] }
        let mainByID = Dictionary(main.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var columns: [Int: [LampVerse?]] = [:]
        for verse in main {
            columns[verse.id] = Array(repeating: nil, count: companions.count)
        }
        for (index, companion) in companions.enumerated() {
            let byID = Dictionary(companion.verses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var paired = Set<Int>()
            for verse in main {
                guard let partner = companion.fromMain(verse.id).flatMap({ byID[$0] }) else { continue }
                columns[verse.id]?[index] = partner
                paired.insert(partner.id)
            }
            for verse in companion.verses where !paired.contains(verse.id) {
                guard let reference = companion.toMain(verse.id),
                      reference / 1_000 == chapter,
                      mainByID[reference] == nil else { continue }
                columns[reference, default: Array(repeating: nil, count: companions.count)][index] = verse
            }
        }
        // Verses in reading order; a row standing for a verse the reading
        // leaves out takes the place its number gives it.
        return columns.keys.sorted().map { reference in
            ReaderParallelRow(
                number: reference % 1_000,
                reference: reference,
                main: mainByID[reference],
                companions: columns[reference] ?? []
            )
        }
    }

    /// One translation's highlights, by verse.
    ///
    /// Filtered rather than trusted: a highlight's offsets count the
    /// characters of the translation it was made in, and drawn on another's
    /// text they colour the wrong words without any error to show it.
    public static func highlights(
        _ highlights: [LampVerseHighlight],
        of translationID: String
    ) -> [Int: [LampVerseHighlight]] {
        Dictionary(
            grouping: highlights.filter { $0.translationID == translationID },
            by: \.reference
        )
    }
}

public struct ReaderParagraphSegment: Equatable, Sendable {
    public let reference: Int
    public let characterCount: Int

    public init(reference: Int, characterCount: Int) {
        self.reference = reference
        self.characterCount = max(characterCount, 1)
    }
}

public enum ReaderParagraphAnchorResolver {
    /// Approximates the verse crossing the viewport edge inside one continuously
    /// rendered paragraph. SwiftUI exposes the paragraph as a single scroll target,
    /// so character-weighted segments preserve verse-level linking without changing
    /// the reader's inline paragraph layout.
    public static func reference(
        at progress: Double,
        in segments: [ReaderParagraphSegment]
    ) -> Int? {
        guard !segments.isEmpty else { return nil }
        let progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        let total = segments.reduce(0) { $0 + $1.characterCount }
        let target = progress * Double(total)
        var cumulative = 0

        for (index, segment) in segments.enumerated() {
            cumulative += segment.characterCount
            if target < Double(cumulative) || index == segments.indices.last {
                return segment.reference
            }
        }
        return segments.last?.reference
    }
}

public enum ReaderTextRangeMapper {
    public static func characterRange(in text: String, utf16Range: NSRange) -> ReaderTextRange? {
        guard utf16Range.location != NSNotFound,
              utf16Range.length > 0,
              let stringRange = Range(utf16Range, in: text) else { return nil }
        return ReaderTextRange(
            startOffset: text.distance(from: text.startIndex, to: stringRange.lowerBound),
            endOffset: text.distance(from: text.startIndex, to: stringRange.upperBound)
        )
    }

    public static func utf16Range(in text: String, characterRange: ReaderTextRange) -> NSRange? {
        guard characterRange.startOffset >= 0,
              characterRange.endOffset > characterRange.startOffset,
              characterRange.endOffset <= text.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: characterRange.startOffset)
        let end = text.index(text.startIndex, offsetBy: characterRange.endOffset)
        return NSRange(start..<end, in: text)
    }
}

public struct ReaderCitationVerse: Equatable, Sendable {
    public let number: Int
    public let text: String
    public let displayPrefix: String

    public init(number: Int, text: String, displayPrefix: String? = nil) {
        self.number = number
        self.text = text
        self.displayPrefix = displayPrefix ?? String(number)
    }
}

public enum ReaderCitationFormatter {
    /// Formats reader text for pasting into notes and documents. If the system can
    /// provide a selection, its position is mapped back to verse text so display-only
    /// verse numbers and note markers never reach the citation.
    public static func citation(
        bookName: String,
        chapterNumber: Int,
        verses: [ReaderCitationVerse],
        translationName: String,
        selectedDisplayText: String? = nil
    ) -> String? {
        guard !verses.isEmpty else { return nil }
        let excerpts = selectedDisplayText
            .flatMap { selectedExcerpts(from: $0, in: verses) }
            ?? verses.compactMap { verse in
                let text = normalizedWhitespace(verse.text)
                return text.isEmpty ? nil : (verse.number, text)
            }
        guard let first = excerpts.first, let last = excerpts.last else { return nil }

        let verseDescription = first.0 == last.0
            ? String(first.0)
            : "\(first.0)-\(last.0)"
        let reference = "\(normalizedWhitespace(bookName)) \(chapterNumber):\(verseDescription)"
        let translation = citationTranslationName(translationName)
        let citationLabel = translation.isEmpty ? reference : "\(reference) \(translation)"
        let passage = excerpts.map(\.1).joined(separator: " ")
        return "(\(citationLabel))\n\"\(passage)\""
    }

    /// Strong's-enabled translation variants conventionally add a lowercase `s`
    /// to an otherwise uppercase abbreviation (`ESVs`, `KJVs`). Citations name the
    /// underlying translation instead of exposing that implementation suffix.
    public static func citationTranslationName(_ name: String) -> String {
        let name = normalizedWhitespace(name)
        guard name.last == "s" else { return name }
        let base = name.dropLast()
        guard !base.isEmpty,
              base.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return name }
        return String(base)
    }

    private struct MappedCharacter {
        let character: Character
        let verseIndex: Int?
    }

    private static func selectedExcerpts(
        from selectedText: String,
        in verses: [ReaderCitationVerse]
    ) -> [(Int, String)]? {
        let selection = Array(normalizedWhitespace(selectedText))
        guard !selection.isEmpty else { return nil }

        var displayed: [MappedCharacter] = []
        for (index, verse) in verses.enumerated() {
            if !displayed.isEmpty {
                displayed.append(MappedCharacter(character: " ", verseIndex: nil))
            }
            displayed += verse.displayPrefix.map {
                MappedCharacter(character: $0, verseIndex: nil)
            }
            displayed.append(MappedCharacter(character: " ", verseIndex: nil))
            displayed += verse.text.map {
                MappedCharacter(character: $0, verseIndex: index)
            }
        }
        displayed = normalizedCharacters(displayed)

        guard selection.count <= displayed.count else { return nil }
        let finalStart = displayed.count - selection.count
        for start in 0...finalStart {
            let range = start..<(start + selection.count)
            guard zip(displayed[range], selection).allSatisfy({ $0.character == $1 }) else {
                continue
            }

            var excerpts: [(verseIndex: Int, text: String)] = []
            for character in displayed[range] {
                guard let verseIndex = character.verseIndex else { continue }
                if excerpts.last?.verseIndex == verseIndex {
                    excerpts[excerpts.count - 1].text.append(character.character)
                } else {
                    excerpts.append((verseIndex, String(character.character)))
                }
            }
            let cleaned = excerpts.compactMap { excerpt -> (Int, String)? in
                let text = normalizedWhitespace(excerpt.text)
                guard !text.isEmpty else { return nil }
                return (verses[excerpt.verseIndex].number, text)
            }
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    private static func normalizedCharacters(_ characters: [MappedCharacter]) -> [MappedCharacter] {
        var result: [MappedCharacter] = []
        for character in characters {
            if character.character.isWhitespace {
                if !result.isEmpty, result.last?.character != " " {
                    result.append(MappedCharacter(character: " ", verseIndex: character.verseIndex))
                }
            } else {
                result.append(character)
            }
        }
        if result.last?.character == " " { result.removeLast() }
        return result
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public struct ReaderBookStructure: Equatable, Sendable {
    public let bookNumber: Int
    public let chapterCount: Int

    public init(bookNumber: Int, chapterCount: Int) {
        self.bookNumber = bookNumber
        self.chapterCount = chapterCount
    }
}

public struct ReaderChapterLocation: Equatable, Hashable, Sendable {
    public let bookNumber: Int
    public let chapterNumber: Int

    public init(bookNumber: Int, chapterNumber: Int) {
        self.bookNumber = bookNumber
        self.chapterNumber = chapterNumber
    }
}

public enum ReaderPassageChapterPlanner {
    /// Expands an encoded scripture range into each chapter it crosses, including
    /// book boundaries. Verse clipping remains the renderer's responsibility.
    public static func locations(
        from startReference: Int,
        to endReference: Int,
        books: [ReaderBookStructure]
    ) -> [ReaderChapterLocation] {
        guard startReference > 0, endReference >= startReference else { return [] }
        let start = components(of: startReference)
        let end = components(of: endReference)
        guard start.book > 0, start.chapter > 0,
              end.book > 0, end.chapter > 0 else { return [] }

        let orderedBooks = books.sorted { $0.bookNumber < $1.bookNumber }
        guard let startBook = orderedBooks.first(where: { $0.bookNumber == start.book }),
              let endBook = orderedBooks.first(where: { $0.bookNumber == end.book }),
              start.chapter <= startBook.chapterCount,
              end.chapter <= endBook.chapterCount else { return [] }

        var result: [ReaderChapterLocation] = []
        for book in orderedBooks where book.bookNumber >= start.book && book.bookNumber <= end.book {
            let firstChapter = book.bookNumber == start.book ? start.chapter : 1
            let lastChapter = book.bookNumber == end.book ? end.chapter : book.chapterCount
            guard firstChapter <= lastChapter else { return [] }
            for chapter in firstChapter...lastChapter {
                result.append(ReaderChapterLocation(
                    bookNumber: book.bookNumber,
                    chapterNumber: chapter
                ))
            }
        }
        return result
    }

    private static func components(of reference: Int) -> (book: Int, chapter: Int) {
        (reference / 1_000_000, (reference / 1_000) % 1_000)
    }
}

public enum ReaderPoetryLayout {
    /// Some source modules can only mark poetry at verse granularity even when a
    /// prose introduction and a quoted poetic line share the same verse. Recover
    /// the quoted range when the punctuation clearly introduces speech so the
    /// reader does not indent the prose along with it.
    public static func partialRange(in text: String, isPoetry: Bool) -> ReaderTextRange? {
        guard isPoetry else { return nil }
        let characters = Array(text)
        guard characters.count > 2 else { return nil }

        let quotePairs: [(opening: Character, closing: Character)] = [
            ("\u{201C}", "\u{201D}"),
            ("\"", "\""),
        ]
        for pair in quotePairs {
            guard let start = characters.firstIndex(of: pair.opening), start > 0 else { continue }
            let prefix = String(characters[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard introducesQuotedPoetry(prefix) else { continue }

            let searchStart = characters.index(after: start)
            let closing = characters[searchStart...].lastIndex(of: pair.closing)
            let end = closing.map { characters.index(after: $0) } ?? characters.endIndex
            guard end > start else { continue }
            return ReaderTextRange(startOffset: start, endOffset: end)
        }
        return nil
    }

    private static func introducesQuotedPoetry(_ prefix: String) -> Bool {
        guard let finalCharacter = prefix.last else { return false }
        if finalCharacter == ":" { return true }

        let normalized = prefix.lowercased()
        let speechVerbs = [
            "answered", "called", "cried", "declared", "proclaimed",
            "replied", "said", "sang", "shouted", "spoke",
        ]
        return speechVerbs.contains { verb in
            normalized.hasSuffix("\(verb),") || normalized.hasSuffix("\(verb):")
        }
    }
}

public typealias ReadingTimeEstimator = LampReadingTimeEstimator

public struct ReadingReminderConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int

    public init(isEnabled: Bool, hour: Int, minute: Int) {
        self.isEnabled = isEnabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var dateComponents: DateComponents {
        DateComponents(hour: hour, minute: minute)
    }
}

public typealias LampDeepLinkSection = LampApplicationSection

public enum LampDeepLink: Equatable, Sendable {
    case reader(reference: Int, translationID: String?)
    case reading(reference: Int, endReference: Int?, openExternal: Bool)
    case strongs(String)
    case book(moduleID: String?, sectionID: String?)
    case section(LampDeepLinkSection)
    case moduleFile(URL)
    case dataFile(URL)

    public init?(url: URL) {
        guard let link = LampApplicationLink(url: url) else { return nil }
        switch link {
        case .verse(let reference, _, let translationID):
            self = .reader(reference: reference, translationID: translationID)
        case .reading(let reference, let endReference, let openExternal):
            self = .reading(
                reference: reference, endReference: endReference,
                openExternal: openExternal
            )
        case .strongs(let key):
            self = .strongs(key)
        case .reader(let reference?, let translationID):
            self = .reader(reference: reference, translationID: translationID)
        case .reader:
            self = .section(.reader)
        case .book(let moduleID, let sectionID):
            self = .book(moduleID: moduleID, sectionID: sectionID)
        case .section(let section):
            self = .section(section)
        case .moduleFile(let url):
            self = .moduleFile(url)
        case .dataFile(let url):
            self = .dataFile(url)
        }
    }
}

public enum DevotionalMarkdownBlock: Equatable, Sendable {
    case text(String)
    case image(caption: String, url: URL)
    case audio(label: String, url: URL)
}

public enum DevotionalMarkdownParser {
    private static let imagePattern = try! NSRegularExpression(pattern: #"^!\[([^]]*)\]\(([^)]+)\)$"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"^\[([^]]+)\]\(([^)]+)\)$"#)

    public static func parse(_ markdown: String) -> [DevotionalMarkdownBlock] {
        var result: [DevotionalMarkdownBlock] = []
        var textLines: [String] = []
        func flushText() {
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.text(text)) }
            textLines.removeAll()
        }

        // A fenced block is the author's literal text, whatever it holds.
        // Without this a `![map](media/M)` written *as an example* inside
        // one became a picture, and the flush that put the picture after
        // its line cut the fence in half as well.
        var fence: DevotionalProseParser.Fence?

        for line in markdown.components(separatedBy: .newlines) {
            if let open = fence {
                textLines.append(line)
                if DevotionalProseParser.isFenceClosing(line, fence: open) { fence = nil }
                continue
            }
            if let open = DevotionalProseParser.fenceOpening(line) {
                fence = open
                textLines.append(line)
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = imagePattern.firstMatch(in: line, range: range),
               let captionRange = Range(match.range(at: 1), in: line),
               let urlRange = Range(match.range(at: 2), in: line),
               let url = URL(string: String(line[urlRange])) {
                flushText()
                result.append(.image(caption: String(line[captionRange]), url: url))
            } else if let match = linkPattern.firstMatch(in: line, range: range),
                      let labelRange = Range(match.range(at: 1), in: line),
                      let urlRange = Range(match.range(at: 2), in: line),
                      let url = URL(string: String(line[urlRange])),
                      isAudioURL(url) || line[labelRange].contains("▶") {
                flushText()
                result.append(.audio(
                    label: String(line[labelRange])
                        .replacingOccurrences(of: "▶︎", with: "")
                        .trimmingCharacters(in: .whitespaces),
                    url: url
                ))
            } else {
                // A picture or a recording inside a sentence, which is how a
                // note carries one: the annotation marks a run of words, so
                // its Markdown is `![those words](media/<id>)` with prose
                // either side of it. Whole-line patterns step straight over
                // that, and the picture was parsed into the paragraph and
                // never drawn — on the Mac only, since the phone already
                // shows it.
                //
                // The words stay in the sentence they were written in and the
                // picture follows the line, which is what the phone does.
                let (prose, media) = splittingInlineMedia(from: line)
                textLines.append(prose)
                if !media.isEmpty {
                    flushText()
                    result.append(contentsOf: media)
                }
            }
        }
        flushText()
        return result
    }

    private static let inlineMediaPattern = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]]*)\]\(([^)\s]+)\)"#
    )

    /// A line with its inline pictures and recordings taken out: what is left
    /// to read, and what to draw after it.
    ///
    /// Only a picture or a recording is taken: an ordinary link is part of the
    /// sentence and stays one. What the annotation marked is left where it was
    /// written, so the sentence still reads, and the picture carries no caption
    /// because those same words are the line above it.
    private static func splittingInlineMedia(
        from line: String
    ) -> (prose: String, media: [DevotionalMarkdownBlock]) {
        guard line.contains("](") else { return (line, []) }
        // A code span is the author's literal text too, in the small.
        let code = codeSpans(in: line)
        let found: [(range: NSRange, label: String, block: DevotionalMarkdownBlock)] =
            inlineMediaPattern.matches(
                in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)
            ).compactMap { match in
                guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { return nil }
                guard let labelRange = Range(match.range(at: 2), in: line),
                      let urlRange = Range(match.range(at: 3), in: line),
                      let url = URL(string: String(line[urlRange])) else { return nil }
                let label = String(line[labelRange])
                if match.range(at: 1).length == 1 {
                    return (match.range, label, .image(caption: "", url: url))
                }
                guard isAudioURL(url) || label.contains("\u{25B6}") else { return nil }
                return (match.range, label, .audio(
                    label: label
                        .replacingOccurrences(of: "\u{25B6}\u{FE0E}", with: "")
                        .trimmingCharacters(in: .whitespaces),
                    url: url
                ))
            }
        guard !found.isEmpty else { return (line, []) }

        // Replaced right to left, so that one replacement cannot move the
        // next; drawn left to right, which is the order they were written in.
        let prose = NSMutableString(string: line)
        for item in found.reversed() {
            prose.replaceCharacters(in: item.range, with: item.label)
        }
        return (prose as String, found.map(\.block))
    }

    /// The parts of a line inside backticks, which are quoted rather than
    /// written: a run of N backticks opens a span that the next run of
    /// exactly N closes, as Markdown has it.
    private static func codeSpans(in line: String) -> [NSRange] {
        guard line.contains("`") else { return [] }
        let characters = Array(line.utf16)
        let tick = UInt16(UInt8(ascii: "`"))
        var spans: [NSRange] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == tick else {
                index += 1
                continue
            }
            var length = 0
            while index + length < characters.count, characters[index + length] == tick {
                length += 1
            }
            let openStart = index
            var search = index + length
            var closed = false
            while search < characters.count {
                guard characters[search] == tick else {
                    search += 1
                    continue
                }
                var run = 0
                while search + run < characters.count, characters[search + run] == tick {
                    run += 1
                }
                if run == length {
                    spans.append(NSRange(location: openStart, length: search + run - openStart))
                    index = search + run
                    closed = true
                    break
                }
                search += run
            }
            // An unmatched run opens nothing; the rest of the line is prose.
            if !closed { index = openStart + length }
        }
        return spans
    }

    private static func isAudioURL(_ url: URL) -> Bool {
        if url.scheme == nil, url.path.hasPrefix("media/") { return true }
        return ["mp3", "m4a", "wav", "aac", "aiff", "caf"]
            .contains(url.pathExtension.lowercased())
    }
}

/// One structural piece of devotional prose.
///
/// `AttributedString(markdown:)` renders inline emphasis faithfully but discards
/// every block boundary, so a whole document handed to it comes back as a single
/// run-on paragraph with its headings, quotes and list items butted together.
/// Splitting the prose first is what lets the preview show the shape the author
/// actually wrote.
public enum DevotionalProseBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// The paragraphs inside a block quote, already stripped of their `>` markers.
    case quote([String])
    case bulletList([String])
    case numberedList([String])
    case nestedBulletList([DevotionalListLine])
    case nestedNumberedList([DevotionalListLine])
    case table(headers: [String], rows: [[String]])
    /// A fenced block, kept exactly as written: its whitespace and line breaks
    /// are the content. `language` is the fence's info string, when it has one.
    case codeBlock(language: String?, code: String)
    case rule
}

public struct DevotionalListLine: Equatable, Sendable {
    public let depth: Int
    public let text: String

    public init(depth: Int, text: String) {
        self.depth = depth
        self.text = text
    }
}

/// Whether a document's opening heading merely restates the title shown above it.
///
/// Writing that is authored as a Markdown file usually carries its own title as
/// the first heading. A reader that also displays the title from metadata then
/// shows it twice, one line apart.
public enum DevotionalHeadingMatch {
    public static func restatesTitle(_ heading: String, title: String) -> Bool {
        let left = normalized(heading)
        let right = normalized(title)
        return !left.isEmpty && left == right
    }

    /// Compares what a reader would see rather than the characters: case, edge
    /// punctuation and runs of whitespace all fail to make two titles different.
    private static func normalized(_ value: String) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
            .trimmingCharacters(in: CharacterSet(charactersIn: ".:;,!?-–— "))
            .lowercased()
    }
}

public enum DevotionalProseParser {
    /// An opening fence: how it was drawn, and what it says the code is.
    fileprivate struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    fileprivate static func fenceOpening(_ line: String) -> Fence? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string cannot itself contain a backtick.
        if marker == "`", info.contains("`") { return nil }
        return Fence(
            marker: marker,
            length: length,
            language: info.isEmpty ? nil : info
        )
    }

    /// A closing fence is the same character, at least as long, and says nothing.
    fileprivate static func isFenceClosing(_ line: String, fence: Fence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy({ $0 == fence.marker }) else { return false }
        return trimmed.count >= fence.length
    }

    public static func parse(_ text: String) -> [DevotionalProseBlock] {
        var blocks: [DevotionalProseBlock] = []
        var paragraphLines: [String] = []
        var bulletItems: [DevotionalListLine] = []
        var numberedItems: [DevotionalListLine] = []
        var quoteLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphLines.removeAll()
        }

        func flushBullets() {
            if !bulletItems.isEmpty {
                blocks.append(bulletItems.allSatisfy { $0.depth == 0 }
                    ? .bulletList(bulletItems.map(\.text))
                    : .nestedBulletList(bulletItems))
            }
            bulletItems.removeAll()
        }

        func flushNumbered() {
            if !numberedItems.isEmpty {
                blocks.append(numberedItems.allSatisfy { $0.depth == 0 }
                    ? .numberedList(numberedItems.map(\.text))
                    : .nestedNumberedList(numberedItems))
            }
            numberedItems.removeAll()
        }

        func flushQuote() {
            // Blank lines inside a quote separate its paragraphs.
            var paragraphs: [String] = []
            var current: [String] = []
            for line in quoteLines {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !current.isEmpty {
                        paragraphs.append(current.joined(separator: " "))
                        current.removeAll()
                    }
                } else {
                    current.append(line)
                }
            }
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            if !paragraphs.isEmpty { blocks.append(.quote(paragraphs)) }
            quoteLines.removeAll()
        }

        /// Everything except the kind of block being started, so a list that
        /// follows a paragraph does not swallow it.
        func flushAll(except kind: PendingKind = .none) {
            if kind != .paragraph { flushParagraph() }
            if kind != .bullet { flushBullets() }
            if kind != .numbered { flushNumbered() }
            if kind != .quote { flushQuote() }
        }

        let lines = text.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]

            // A fence suspends every other rule: inside it a `#` is a comment
            // and a `-` is a minus sign, not a heading or a bullet.
            if let fence = fenceOpening(rawLine) {
                flushAll()
                lineIndex += 1
                var code: [String] = []
                while lineIndex < lines.count, !isFenceClosing(lines[lineIndex], fence: fence) {
                    code.append(lines[lineIndex])
                    lineIndex += 1
                }
                // An unterminated fence runs to the end of the text, which is
                // what a reader sees in every Markdown renderer.
                if lineIndex < lines.count { lineIndex += 1 }
                blocks.append(.codeBlock(
                    language: fence.language,
                    code: code.joined(separator: "\n")
                ))
                continue
            }

            if lineIndex + 1 < lines.count,
               let headers = tableCells(rawLine),
               let separators = tableCells(lines[lineIndex + 1]),
               headers.count == separators.count,
               separators.allSatisfy({ isTableSeparator($0) }) {
                flushAll()
                lineIndex += 2
                var rows: [[String]] = []
                while lineIndex < lines.count,
                      let cells = tableCells(lines[lineIndex]),
                      cells.count == headers.count {
                    rows.append(cells)
                    lineIndex += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
            lineIndex += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                // A blank line ends a paragraph and a list, but is kept inside a
                // quote so the quote can hold more than one paragraph.
                if !quoteLines.isEmpty {
                    quoteLines.append("")
                } else {
                    flushAll()
                }
                continue
            }

            if isRule(line) {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(from: line) {
                flushAll()
                blocks.append(heading)
                continue
            }

            if let quoted = quoteContent(of: line) {
                flushAll(except: .quote)
                quoteLines.append(quoted)
                continue
            }

            if let item = bulletContent(of: line) {
                flushAll(except: .bullet)
                bulletItems.append(DevotionalListLine(
                    depth: rawLine.prefix { $0 == " " }.count / 2, text: item
                ))
                continue
            }

            if let item = numberedContent(of: line) {
                flushAll(except: .numbered)
                numberedItems.append(DevotionalListLine(
                    depth: rawLine.prefix { $0 == " " }.count / 2, text: item
                ))
                continue
            }

            flushAll(except: .paragraph)
            paragraphLines.append(line)
        }

        flushAll()
        return blocks
    }

    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        return trimmed.dropFirst().dropLast().split(
            separator: "|", omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
    }

    private enum PendingKind {
        case none
        case paragraph
        case bullet
        case numbered
        case quote
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" } ||
            compact.allSatisfy { $0 == "*" } ||
            compact.allSatisfy { $0 == "_" }
    }

    private static func heading(from line: String) -> DevotionalProseBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        // `#tagged` is not a heading; ATX headings require a space.
        guard remainder.first == " " else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func quoteContent(of line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        var remainder = Substring(line.dropFirst())
        if remainder.first == " " { remainder = remainder.dropFirst() }
        return String(remainder)
    }

    private static func bulletContent(of line: String) -> String? {
        guard let marker = line.first, marker == "-" || marker == "*" || marker == "+" else {
            return nil
        }
        let remainder = line.dropFirst()
        guard remainder.first == " " else { return nil }
        let item = remainder.trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    private static func numberedContent(of line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        var remainder = line.dropFirst(digits.count)
        guard let separator = remainder.first, separator == "." || separator == ")" else {
            return nil
        }
        remainder = remainder.dropFirst()
        guard remainder.first == " " else { return nil }
        let item = remainder.trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }
}
import LampModuleKit

public struct ReaderLocation: Codable, Equatable, Hashable, Sendable {
    public let translationID: String
    public let bookNumber: Int
    public let chapterNumber: Int
    public let verseReference: Int?

    public init(
        translationID: String,
        bookNumber: Int,
        chapterNumber: Int,
        verseReference: Int? = nil
    ) {
        self.translationID = translationID
        self.bookNumber = bookNumber
        self.chapterNumber = chapterNumber
        self.verseReference = verseReference
    }

    /// Where a typed reference goes.
    ///
    /// One that names a verse — "John 3:16", "Ps 23:1-4" — carries it, so the
    /// reader lands on the verse rather than at the top of the chapter; one
    /// that names a chapter — "John 3", "1 Cor 13" — opens at the top. The two
    /// are told apart by the end of the range: a chapter named without verses
    /// is parsed as running to verse 999, which nobody types.
    public static func typed(
        reference startReference: Int,
        through endReference: Int,
        in translationID: String
    ) -> ReaderLocation {
        let start = LampBibleReferenceFormatter.components(of: startReference)
        let namesAVerse = LampBibleReferenceFormatter.components(of: endReference).verse != 999
        return ReaderLocation(
            translationID: translationID,
            bookNumber: start.book,
            chapterNumber: max(1, start.chapter),
            verseReference: namesAVerse ? startReference : nil
        )
    }
}

/// The column beside a tab's reader: whether it is open, on what, and where
/// the study pane was left.
///
/// Kept with the tab, so one tab can be read plainly while another keeps its
/// commentary open, and moving between them does not drag the column along.
///
/// Every field is read leniently. These are saved with the tabs, and a column
/// that could not be read must cost the column, never the tabs: a pane this
/// build does not know reads as closed, and anything else missing or
/// malformed reads as unset.
public struct ReaderTabSidebar: Codable, Equatable, Sendable {
    public enum Pane: String, Codable, Sendable { case study, chat }

    /// The pane open beside the reader, or nil when the column is closed.
    public var pane: Pane?
    /// The study pane's tool, or nil for whatever a new tab starts on.
    public var studyTool: String?
    /// What was typed into the dictionary's search field.
    public var dictionaryQuery: String
    /// The dictionary entry being read: the Strong's keys it was looked up
    /// by, and the word that led there. Empty when nothing has been looked up.
    public var dictionaryKeys: [String]
    public var dictionaryWord: String?
    /// The Strong's analyses opened over the dictionary entry, the one shown
    /// last: each companion followed from an analysis goes on the end, and
    /// Back takes it off. Empty when the entry itself is showing.
    public var analysisKeys: [String]

    public init(
        pane: Pane? = nil,
        studyTool: String? = nil,
        dictionaryQuery: String = "",
        dictionaryKeys: [String] = [],
        dictionaryWord: String? = nil,
        analysisKeys: [String] = []
    ) {
        self.pane = pane
        self.studyTool = studyTool
        self.dictionaryQuery = dictionaryQuery
        self.dictionaryKeys = dictionaryKeys
        self.dictionaryWord = dictionaryWord
        self.analysisKeys = analysisKeys
    }

    private enum CodingKeys: String, CodingKey {
        case pane, studyTool, dictionaryQuery, dictionaryKeys, dictionaryWord, analysisKeys
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func lenient<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? values.decodeIfPresent(type, forKey: key)) ?? nil
        }
        // By name, so a pane added later is unknown here rather than a
        // failure: a tab saved with it open opens here with the column shut.
        pane = lenient(String.self, .pane).flatMap(Pane.init(rawValue:))
        studyTool = lenient(String.self, .studyTool)
        dictionaryQuery = lenient(String.self, .dictionaryQuery) ?? ""
        dictionaryKeys = lenient([String].self, .dictionaryKeys) ?? []
        dictionaryWord = lenient(String.self, .dictionaryWord)
        analysisKeys = lenient([String].self, .analysisKeys) ?? []
    }
}

public struct ReaderTab: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var location: ReaderLocation?
    /// What the reader called this tab, or nil to be named after wherever it
    /// is. A named tab keeps its name as it is read on through the book,
    /// which is the point of naming one: it is the place you are keeping,
    /// not the chapter you are at.
    public var name: String?
    public var sidebar: ReaderTabSidebar
    /// The chat this tab is on, or nil until one is opened in it.
    ///
    /// Held rather than claimed on sight: a tab nobody chats in should leave
    /// nothing behind in the library, so the chat is taken up the first time
    /// its pane is opened and not when the tab is made. A copy of a tab does
    /// not copy this — a copy is a new tab, and the conversation stays with
    /// the tab it was had in.
    public var chatID: UUID?
    /// A new tab nothing has been chosen in yet: it shows the passage
    /// chooser, not a chapter, until a passage is chosen in it. Kept apart
    /// from having no place, which a tab still opening also has, and which a
    /// tab restored without one is dropped for.
    public var isBlank: Bool

    public init(
        id: UUID = UUID(),
        location: ReaderLocation? = nil,
        name: String? = nil,
        sidebar: ReaderTabSidebar = ReaderTabSidebar(),
        chatID: UUID? = nil,
        isBlank: Bool = false
    ) {
        self.id = id
        self.location = location
        self.name = name
        self.sidebar = sidebar
        self.chatID = chatID
        self.isBlank = isBlank
    }

    private enum CodingKeys: String, CodingKey { case id, location, name, sidebar, chatID, isBlank }

    /// Tabs saved before they kept a column decode with it closed. A column
    /// that cannot be read is closed too, rather than failing the tab, which
    /// would fail the whole session: the store falls back to a fresh one.
    /// A place that cannot be read is no place, for the same reason; the
    /// collection then drops that tab as it does one whose translation went.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        location = (try? values.decodeIfPresent(ReaderLocation.self, forKey: .location)) ?? nil
        name = try values.decodeIfPresent(String.self, forKey: .name)
        sidebar = ((try? values.decodeIfPresent(ReaderTabSidebar.self, forKey: .sidebar)) ?? nil)
            ?? ReaderTabSidebar()
        // A chat that cannot be read is no chat: the tab opens its pane on a
        // new conversation, and the old one is still in the list to go back to.
        chatID = (try? values.decodeIfPresent(UUID.self, forKey: .chatID)) ?? nil
        isBlank = (try? values.decodeIfPresent(Bool.self, forKey: .isBlank)) ?? false
    }

    /// A name worth keeping, or nil. Blank is not a name, and a tab given one
    /// by accident goes back to being named after its chapter.
    public static func trimmedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Lightweight tab state independent from the loaded chapter. The active reader
/// model can load one location at a time while each tab retains its own place.
public struct ReaderTabCollection: Codable, Equatable, Sendable {
    public private(set) var tabs: [ReaderTab]
    public private(set) var selectedID: UUID

    public init(initialLocation: ReaderLocation? = nil) {
        let tab = ReaderTab(location: initialLocation)
        tabs = [tab]
        selectedID = tab.id
    }

    private enum CodingKeys: String, CodingKey { case tabs, selectedID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTabs = try values.decode([ReaderTab].self, forKey: .tabs)
        let decodedSelection = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        var seenIDs = Set<UUID>()
        var restoredTabs = decodedTabs.filter { seenIDs.insert($0.id).inserted }
        if restoredTabs.isEmpty { restoredTabs = [ReaderTab()] }
        tabs = restoredTabs
        selectedID = decodedSelection.flatMap { id in restoredTabs.contains { $0.id == id } ? id : nil }
            ?? restoredTabs[0].id
    }

    /// Module removal must not prevent the remaining tabs from reopening.
    public mutating func restoreAvailableLocations(
        translationIDs: Set<String>,
        fallbackLocation: ReaderLocation?
    ) {
        tabs.removeAll { tab in
            // A new tab has no place and is kept: it reopens as it was left.
            guard let location = tab.location else { return !tab.isBlank }
            return !translationIDs.contains(location.translationID)
                || location.bookNumber < 1 || location.chapterNumber < 1
        }
        if tabs.isEmpty { tabs = [ReaderTab(location: fallbackLocation)] }
        if !tabs.contains(where: { $0.id == selectedID }) { selectedID = tabs[0].id }
    }

    public var selectedTab: ReaderTab? {
        tabs.first { $0.id == selectedID }
    }

    /// Records where the open tab is.
    ///
    /// Nothing is not a place, and does not replace one. The reader has no
    /// place while it is still opening, or between a translation going and
    /// another being chosen, and every caller hands this whatever the reader
    /// has at that moment — so taking nil literally let a tab with a chapter
    /// in it be emptied by a passing moment, and the tab came back on
    /// whatever the app was last reading instead of its own chapter.
    public mutating func updateSelected(location: ReaderLocation?) {
        guard let location, let index = tabs.firstIndex(where: { $0.id == selectedID })
        else { return }
        tabs[index].location = location
        // A passage chosen in a new tab makes it an ordinary one.
        tabs[index].isBlank = false
    }

    /// Puts the open tab on a chat, or on none.
    public mutating func updateSelected(chatID: UUID?) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }),
              tabs[index].chatID != chatID else { return }
        tabs[index].chatID = chatID
    }

    /// Every chat the tabs are on, for a window to hold and to release.
    public var chatIDs: [UUID] { tabs.compactMap(\.chatID) }

    /// Forgets a chat wherever the tabs are on it.
    ///
    /// For the chats a scrub took: the tab stays where it is and opens its
    /// pane on a new conversation rather than on a workspace that has gone.
    public mutating func forgetChats(_ gone: Set<UUID>) {
        guard !gone.isEmpty else { return }
        for index in tabs.indices where tabs[index].chatID.map(gone.contains) == true {
            tabs[index].chatID = nil
        }
    }

    /// Records the open tab's column. Unlike its place, which the reader
    /// holds until it is written back, the column is written as it changes.
    public mutating func updateSelected(sidebar: ReaderTabSidebar) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }),
              tabs[index].sidebar != sidebar else { return }
        tabs[index].sidebar = sidebar
    }

    @discardableResult
    public mutating func add(location: ReaderLocation?) -> UUID {
        let tab = ReaderTab(location: location)
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    /// Opens a new tab with nothing in it yet, at the end, and selects it:
    /// it shows the passage chooser until a passage is chosen in it.
    @discardableResult
    public mutating func addBlank() -> UUID {
        let tab = ReaderTab(isBlank: true)
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    @discardableResult
    public mutating func select(_ id: UUID) -> ReaderLocation? {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return selectedTab?.location
        }
        selectedID = tab.id
        return tab.location
    }

    /// Names a tab, or takes its name away when `name` is blank.
    public mutating func rename(_ id: UUID, to name: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].name = ReaderTab.trimmedName(name)
    }

    /// Opens a copy of `id` beside it, at the same place, under the same name
    /// and with the same column, and selects it.
    ///
    /// The copy goes next to the tab it came from rather than at the end,
    /// since "duplicate this one" means the one you right-clicked, and a copy
    /// that appears somewhere else has to be found again.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> ReaderLocation? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        // Without the chat: a copy is a new tab, and the conversation stays
        // with the tab it was had in.
        let copy = ReaderTab(
            location: tabs[index].location, name: tabs[index].name, sidebar: tabs[index].sidebar,
            isBlank: tabs[index].isBlank
        )
        tabs.insert(copy, at: index + 1)
        selectedID = copy.id
        return copy.location
    }

    /// Moves a tab to `index` among the tabs, as a dragged tab lands where it
    /// is dropped. The open tab stays open: moving one is not choosing it.
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
    }

    /// A reader always keeps one tab. Closing the selected tab chooses the tab to
    /// its right, or the previous tab when the closed tab was last.
    @discardableResult
    public mutating func close(_ id: UUID) -> ReaderLocation? {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == id }) else {
            return selectedTab?.location
        }
        let wasSelected = selectedID == id
        tabs.remove(at: index)
        if wasSelected {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        return selectedTab?.location
    }
}

/// Each reader window's tabs, kept under the session that window took up.
///
/// There was one snapshot for the whole app, written by whichever window
/// changed its tabs last. One window never noticed. Two did: they overwrote
/// each other as they were read in, and at the next launch both opened on the
/// same tabs, because the same snapshot was all there was to open on. Scene
/// storage was meant to keep them apart, and cannot: macOS throws it away on a
/// clean quit, which is the very moment it was there for.
public enum ReaderTabSessionStore {
    private static let lastSessionKey = "reader.tabs.lastSession"
    private static let sessionsKey = "reader.tabs.sessions"
    /// How many windows' tabs are kept, most recently saved first. Far more
    /// than are ever open at once; the cap is only so that sessions cannot
    /// pile up unread for as long as the app is installed.
    static let keptSessions = 24

    static func key(for session: UUID) -> String {
        "reader.tabs.session.\(session.uuidString)"
    }

    /// Where windows' tabs are kept: a store of their own, apart from the
    /// app's settings. Written to those, every tab chosen woke each view in
    /// the window that reads a setting — about a tenth of a switch on the
    /// owner's Mac (2026-11-12). Tabs kept in the settings before are copied
    /// across the first time, so none are lost.
    public static let store: UserDefaults = {
        let suiteName = (Bundle.main.bundleIdentifier ?? "Lamp") + ".reader-tabs"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        adoptEarlierSessions(from: .standard, into: suite)
        return suite
    }()

    /// Copies the tabs kept in `old` into `new` where `new` has none yet.
    static func adoptEarlierSessions(from old: UserDefaults, into new: UserDefaults) {
        guard new.stringArray(forKey: sessionsKey) == nil, new.data(forKey: lastSessionKey) == nil else { return }
        if let last = old.data(forKey: lastSessionKey) { new.set(last, forKey: lastSessionKey) }
        guard let sessions = old.stringArray(forKey: sessionsKey) else { return }
        for session in sessions {
            let key = "reader.tabs.session.\(session)"
            if let data = old.data(forKey: key) { new.set(data, forKey: key) }
        }
        new.set(sessions, forKey: sessionsKey)
    }

    /// The sessions tabs have been saved under, the most recently saved first.
    public static func sessions(defaults: UserDefaults = store) -> [UUID] {
        (defaults.stringArray(forKey: sessionsKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// Which session a window opening now should take up, and nil for none —
    /// which means start one.
    ///
    /// With no other window holding a session, the most recent: a relaunch
    /// should hand a window back the tabs it was interrupted in, and so
    /// should closing a window and opening another. Beside a window that
    /// already holds one, a session of its own, because a second window was
    /// opened to read something else and not to mirror the first.
    ///
    /// The same shape as the rule the chats used to need. Chats no longer
    /// guess — a tab remembers the one it is on, and any other is chosen from
    /// the list — but a window's tabs have nowhere else to be remembered, so
    /// here the guess stands.
    public static func claimingSession(from sessions: [UUID], heldBy held: Set<UUID>) -> UUID? {
        guard held.isEmpty else { return nil }
        return sessions.first { !held.contains($0) }
    }

    /// The tabs for `session`.
    ///
    /// A session with none of its own falls back to the last tabs any window
    /// saved, but only when this window is picking up where the app left off.
    /// A second window opened beside one starts at the chapter being read
    /// instead: it was opened to read something else, and handing it a copy of
    /// the other window's tabs — which it would then save over — is how the
    /// two came to share one set in the first place.
    public static func load(
        session: UUID,
        resumingLastSession: Bool,
        defaults: UserDefaults = store,
        translationIDs: Set<String>,
        fallbackLocation: ReaderLocation?
    ) -> ReaderTabCollection {
        var collection = [
            defaults.data(forKey: key(for: session)),
            resumingLastSession ? defaults.data(forKey: lastSessionKey) : nil,
        ]
            .compactMap { $0 }
            .lazy
            .compactMap { try? JSONDecoder().decode(ReaderTabCollection.self, from: $0) }
            .first ?? ReaderTabCollection(initialLocation: fallbackLocation)
        collection.restoreAvailableLocations(
            translationIDs: translationIDs, fallbackLocation: fallbackLocation
        )
        return collection
    }

    public static func save(
        _ collection: ReaderTabCollection,
        session: UUID,
        defaults: UserDefaults = store
    ) {
        guard let data = try? JSONEncoder().encode(collection) else { return }
        defaults.set(data, forKey: key(for: session))
        // Kept as well, so that a session with no tabs of its own — the first
        // window after this app learned to keep them apart, or after a chat
        // was deleted — still opens on what was last being read.
        defaults.set(data, forKey: lastSessionKey)
        var sessions = [session.uuidString]
            + (defaults.stringArray(forKey: sessionsKey) ?? [])
                .filter { $0 != session.uuidString }
        for forgotten in sessions.dropFirst(keptSessions) {
            defaults.removeObject(forKey: "reader.tabs.session.\(forgotten)")
        }
        sessions = Array(sessions.prefix(keptSessions))
        defaults.set(sessions, forKey: sessionsKey)
    }
}

public typealias ReaderNavigationHistory = LampNavigationStack<ReaderLocation>


public typealias ExternalBibleApplication = LampExternalBibleApplication

public extension LampExternalBibleApplication {
    /// The Bible apps this Mac can actually open.
    ///
    /// Offering one nothing can open gives the reader a link and then an
    /// error naming a URL at them. YouVersion is the case that prompted this:
    /// its Mac listing is the iPhone app running under "Designed for iPad",
    /// and those do not register their URL schemes with macOS, so
    /// `youversion://` has no handler however the app is installed. The same
    /// would greet anyone offered Accordance or Olive Tree without owning
    /// them.
    ///
    /// Asked of the system rather than written down here, so an app installed
    /// later appears, and YouVersion returns of its own accord if it ever
    /// ships a Mac app that registers the scheme.
    ///
    /// Logos stays whatever is installed: its links are ordinary web
    /// addresses, which a browser answers for.
    static var openableOnThisMac: [LampExternalBibleApplication] {
        allCases.filter(\.canOpenOnThisMac)
    }

    /// Whether this Mac can open this app right now.
    var canOpenOnThisMac: Bool {
        guard let url = URL(string: urlRoot) else { return false }
        if url.scheme?.hasPrefix("http") == true { return true }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    /// Whether installing it would help.
    ///
    /// For every app here but one, "no handler" means "not installed", and
    /// saying so is worth doing: it tells the reader which apps Lamp works
    /// with. YouVersion is the exception — its Mac listing is the iPhone app
    /// under "Designed for iPad", which registers no URL scheme — so there is
    /// nothing to install that would make it work, and offering it greyed
    /// would be holding out a hope that cannot be met.
    ///
    /// Read through `canOpenOnThisMac` first, so a YouVersion that one day
    /// ships a real Mac app comes back without anyone editing this.
    var couldBeInstalledOnThisMac: Bool { self != .youVersion }

    /// The apps worth naming in settings: those that work, and those that
    /// would if they were installed.
    static var offeredOnThisMac: [LampExternalBibleApplication] {
        allCases.filter { $0.canOpenOnThisMac || $0.couldBeInstalledOnThisMac }
    }
}

/// Text selected in the reader, traced to the verses it came from.
public struct ReaderSelectedPassage: Equatable, Sendable {
    /// The words selected, without verse numbers or note letters.
    public let text: String
    public let firstReference: Int
    public let lastReference: Int
    /// The companion translation it was selected in, or nil for the one
    /// being read.
    public let translationID: String?

    public init(text: String, firstReference: Int, lastReference: Int, translationID: String?) {
        self.text = text
        self.firstReference = firstReference
        self.lastReference = lastReference
        self.translationID = translationID
    }

    public var reference: String {
        LampBibleReferenceFormatter.describeRange(from: firstReference, to: lastReference)
    }
}

/// What the reader marks in the text it draws, so a selection can be traced
/// back to scripture: which verse each character belongs to, and which
/// characters are the reader's own marks rather than the translation's words.
public enum ReaderTextMarks {
    /// The verse a character belongs to, as an `NSNumber` reference.
    public static let verse = NSAttributedString.Key("LampReaderVerse")
    /// The companion translation a character is from, as a string. Absent
    /// from the translation being read.
    public static let translation = NSAttributedString.Key("LampReaderTranslation")
    /// A verse number or a translator's note letter: drawn among the words,
    /// and not one of them.
    public static let apparatus = NSAttributedString.Key("LampReaderApparatus")

    /// The scripture in `range`, or nil when it holds none: a selection of
    /// only a verse number, or of a companion's name.
    ///
    /// Space drawn between verses carries no verse, and is kept; anything
    /// else that carries none is not scripture, and is left out.
    public static func passage(in text: NSAttributedString, range: NSRange) -> ReaderSelectedPassage? {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return nil }
        let string = text.string as NSString
        var words = ""
        var first: Int?
        var last: Int?
        var translationID: String?
        text.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[apparatus] == nil else { return }
            let piece = string.substring(with: run)
            guard let reference = (attributes[verse] as? NSNumber)?.intValue else {
                if piece.allSatisfy(\.isWhitespace) { words += piece }
                return
            }
            words += piece
            first = min(first ?? reference, reference)
            last = max(last ?? reference, reference)
            if translationID == nil { translationID = attributes[translation] as? String }
        }
        // A verse number left out leaves the space either side of it.
        let collapsed = words
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, let last, !collapsed.isEmpty else { return nil }
        return ReaderSelectedPassage(
            text: collapsed, firstReference: first, lastReference: last, translationID: translationID
        )
    }
}

/// What a dictionary sense shows of its two definitions.
///
/// Many lexicon modules carry a `shortDefinition` that is only the long
/// definition's opening, cut off with an ellipsis, as a preview for lists.
/// Shown over the full definition it printed the same words twice, once
/// trailing off and once in full.
public enum LampDictionarySenseText {
    /// Whether `short` says something `definition` doesn't already open with.
    public static func showsShortDefinition(_ short: String?, beside definition: String?) -> Bool {
        guard let short = short.map(normalized), !short.isEmpty else { return false }
        guard let definition = definition.map(normalized), !definition.isEmpty else { return true }
        if short == definition { return false }
        let opening = trimmingEllipsis(short)
        guard !opening.isEmpty else { return false }
        return !definition.hasPrefix(opening)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func trimmingEllipsis(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last == "…" || last == "." || last == " " {
            result = result.dropLast()
        }
        return String(result)
    }
}

/// A dictionary field's bold, italic and original-language stretches, set on
/// the text drawn for it.
public enum LampDictionaryStyling {
    /// Sets bold and italic on `value`, adding to emphasis already there, and
    /// returns the Greek and Hebrew stretches for the caller to colour.
    /// `prefix` is how many scalars the drawn text puts before the field's
    /// own, as "Derivation: " does; a style that would run past the text is
    /// left off rather than cut.
    @discardableResult
    public static func apply(
        _ styles: [LampDictionaryStyle],
        after prefix: Int = 0,
        to value: inout AttributedString
    ) -> [Range<AttributedString.Index>] {
        var originalLanguage: [Range<AttributedString.Index>] = []
        let length = value.unicodeScalars.count
        for style in styles {
            let start = style.start + prefix
            let end = style.end + prefix
            guard start >= 0, end > start, end <= length else { continue }
            let scalars = value.unicodeScalars
            let range = scalars.index(scalars.startIndex, offsetBy: start)
                ..< scalars.index(scalars.startIndex, offsetBy: end)
            switch style.kind {
            case .bold: add(.stronglyEmphasized, to: range, in: &value)
            case .italic: add(.emphasized, to: range, in: &value)
            case .greek, .hebrew: originalLanguage.append(range)
            }
        }
        return originalLanguage
    }

    /// Holds a paragraph left to right when its first letter is Hebrew or
    /// Arabic. A paragraph takes its direction from its first letter, so a
    /// sense that opens on its Hebrew headword was laid out right to left and
    /// its English came out in the wrong order. A left-to-right mark goes in
    /// front, after any styles and links were placed, so their counts stand.
    public static func holdLeftToRight(_ value: inout AttributedString) {
        guard let first = value.unicodeScalars.first(where: { $0.properties.isAlphabetic }),
              isRightToLeft(first) else { return }
        value.insert(AttributedString("\u{200E}"), at: value.startIndex)
    }

    static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: true
        default: false
        }
    }

    private static func add(
        _ intent: InlinePresentationIntent,
        to range: Range<AttributedString.Index>,
        in value: inout AttributedString
    ) {
        let runs = value[range].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
        for (run, existing) in runs {
            value[run].inlinePresentationIntent = existing.union(intent)
        }
    }
}
