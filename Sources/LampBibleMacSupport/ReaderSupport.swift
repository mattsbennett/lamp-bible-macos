import Foundation

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

public enum StrongsKey {
    /// Strong's keys are written `H7225`, `h07225` or bare `7225` depending on who
    /// compiled the dictionary, and some carry a disambiguating letter (`G3588a`).
    /// Normalizing puts case and zero-padding aside so two spellings of the same
    /// key compare equal.
    public static func normalized(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return "" }
        let prefix = trimmed.first.map { $0 == "H" || $0 == "G" ? String($0) : "" } ?? ""
        let rest = trimmed.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return trimmed }
        let suffix = rest.dropFirst(digits.count)
        let unpadded = String(digits.drop { $0 == "0" })
        return prefix + (unpadded.isEmpty ? "0" : unpadded) + suffix
    }

    /// Whether two keys name the same lexicon entry. A dictionary that stores bare
    /// numbers still matches a prefixed key, since the alternative is showing the
    /// reader nothing at all.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftPrefixed = left.first == "H" || left.first == "G"
        let rightPrefixed = right.first == "H" || right.first == "G"
        guard leftPrefixed != rightPrefixed else { return false }
        return left.drop { $0 == "H" || $0 == "G" } == right.drop { $0 == "H" || $0 == "G" }
    }
}

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

public enum ReadingTimeEstimator {
    public static func minutes(wordCount: Int, wordsPerMinute: Int) -> Int {
        guard wordCount > 0 else { return 0 }
        return max(Int(ceil(Double(wordCount) / Double(max(wordsPerMinute, 1)))), 1)
    }

    public static func description(wordCount: Int, wordsPerMinute: Int) -> String {
        let minutes = minutes(wordCount: wordCount, wordsPerMinute: wordsPerMinute)
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}

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

public enum LampDeepLinkSection: String, Codable, Equatable, Sendable {
    case today
    case reader
    case plans
    case devotionals
    case quizzes
    case search
    case modules
}

public enum LampDeepLink: Equatable, Sendable {
    case reader(reference: Int, translationID: String?)
    case section(LampDeepLinkSection)
    case moduleFile(URL)
    case dataFile(URL)

    public init?(url: URL) {
        if url.isFileURL {
            switch url.pathExtension.lowercased() {
            case "lamp": self = .moduleFile(url)
            case "json": self = .dataFile(url)
            default: return nil
            }
            return
        }
        guard url.scheme?.lowercased() == "lampbible" else { return nil }
        let route = (url.host?.isEmpty == false ? url.host : url.pathComponents.dropFirst().first)?
            .lowercased()
        guard let route else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if route == "read" || route == "reader" {
            guard let rawReference = components?.queryItems?.first(where: { $0.name == "reference" })?.value,
                  let reference = Int(rawReference), reference > 0 else {
                self = .section(.reader)
                return
            }
            let translation = components?.queryItems?.first(where: { $0.name == "translation" })?.value
            self = .reader(reference: reference, translationID: translation)
        } else if let section = LampDeepLinkSection(rawValue: route) {
            self = .section(section)
        } else {
            return nil
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

        for line in markdown.components(separatedBy: .newlines) {
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
                textLines.append(line)
            }
        }
        flushText()
        return result
    }

    private static func isAudioURL(_ url: URL) -> Bool {
        ["mp3", "m4a", "wav", "aac", "aiff", "caf"].contains(url.pathExtension.lowercased())
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
}

public struct ReaderTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var location: ReaderLocation?

    public init(id: UUID = UUID(), location: ReaderLocation? = nil) {
        self.id = id
        self.location = location
    }
}

/// Lightweight tab state independent from the loaded chapter. The active reader
/// model can load one location at a time while each tab retains its own place.
public struct ReaderTabCollection: Equatable, Sendable {
    public private(set) var tabs: [ReaderTab]
    public private(set) var selectedID: UUID

    public init(initialLocation: ReaderLocation? = nil) {
        let tab = ReaderTab(location: initialLocation)
        tabs = [tab]
        selectedID = tab.id
    }

    public var selectedTab: ReaderTab? {
        tabs.first { $0.id == selectedID }
    }

    public mutating func updateSelected(location: ReaderLocation?) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[index].location = location
    }

    @discardableResult
    public mutating func add(location: ReaderLocation?) -> UUID {
        let tab = ReaderTab(location: location)
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

public struct ReaderNavigationHistory: Codable, Equatable, Sendable {
    public private(set) var backStack: [ReaderLocation]
    public private(set) var current: ReaderLocation?
    public private(set) var forwardStack: [ReaderLocation]
    public let capacity: Int

    public init(
        backStack: [ReaderLocation] = [],
        current: ReaderLocation? = nil,
        forwardStack: [ReaderLocation] = [],
        capacity: Int = 100
    ) {
        self.backStack = backStack
        self.current = current
        self.forwardStack = forwardStack
        self.capacity = max(capacity, 1)
        trimToCapacity()
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public mutating func visit(_ location: ReaderLocation) {
        guard current != location else { return }
        if let current { backStack.append(current) }
        current = location
        forwardStack = []
        trimToCapacity()
    }

    @discardableResult
    public mutating func goBack() -> ReaderLocation? {
        guard let destination = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = destination
        trimToCapacity()
        return destination
    }

    @discardableResult
    public mutating func goForward() -> ReaderLocation? {
        guard let destination = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = destination
        trimToCapacity()
        return destination
    }

    public mutating func clear(keeping location: ReaderLocation? = nil) {
        backStack = []
        current = location
        forwardStack = []
    }

    private mutating func trimToCapacity() {
        if backStack.count > capacity {
            backStack.removeFirst(backStack.count - capacity)
        }
        if forwardStack.count > capacity {
            forwardStack.removeFirst(forwardStack.count - capacity)
        }
    }
}

public struct LampSearchHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(query.lowercased())|\(kind?.rawValue ?? "all")|\(moduleID ?? "all")" }

    public let query: String
    public let kind: LampModuleKind?
    public let moduleID: String?
    public let searchedAt: Date

    public init(
        query: String,
        kind: LampModuleKind? = nil,
        moduleID: String? = nil,
        searchedAt: Date = Date()
    ) {
        self.query = query
        self.kind = kind
        self.moduleID = moduleID
        self.searchedAt = searchedAt
    }
}

public enum LampSearchHistoryStore {
    public static func decode(_ data: Data) -> [LampSearchHistoryEntry] {
        (try? JSONDecoder().decode([LampSearchHistoryEntry].self, from: data)) ?? []
    }

    public static func encode(_ entries: [LampSearchHistoryEntry]) -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data()
    }

    public static func adding(
        _ entry: LampSearchHistoryEntry,
        to entries: [LampSearchHistoryEntry],
        limit: Int = 20
    ) -> [LampSearchHistoryEntry] {
        let normalizedQuery = entry.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return entries }
        let normalized = LampSearchHistoryEntry(
            query: normalizedQuery,
            kind: entry.kind,
            moduleID: entry.moduleID,
            searchedAt: entry.searchedAt
        )
        return Array(([normalized] + entries.filter { $0.id != normalized.id }).prefix(max(limit, 1)))
    }
}

public enum ExternalBibleApplication: String, CaseIterable, Codable, Identifiable, Sendable {
    case accordance = "Accordance"
    case eSword = "e-Sword LT"
    case logos = "Logos"
    case oliveTree = "Olive Tree"
    case youVersion = "YouVersion"

    public var id: String { rawValue }

    public func url(startReference: Int, endReference: Int? = nil) -> URL? {
        let start = BibleReferenceParts(startReference)
        let end = BibleReferenceParts(endReference ?? startReference)
        guard Self.bookAbbreviations.indices.contains(start.book - 1),
              Self.bookAbbreviations.indices.contains(end.book - 1) else { return nil }
        let startOSIS = Self.bookAbbreviations[start.book - 1]
        let endOSIS = Self.bookAbbreviations[end.book - 1]
        let startName = Self.bookNames[start.book - 1]
            .lowercased().replacingOccurrences(of: " ", with: "")
        let path: String
        let root: String
        switch self {
        case .accordance:
            root = "accord://read/"
            path = "\(startOSIS)_\(start.chapter):\(start.verse)-\(endOSIS)_\(end.chapter):\(end.verse)"
        case .eSword:
            root = "e-sword://"
            path = "\(startName).\(start.chapter):\(start.verse)"
        case .logos:
            root = "https://ref.ly/"
            path = "\(startName)\(start.chapter):\(start.verse)"
        case .oliveTree:
            root = "olivetree://bible/"
            path = "\(start.book).\(start.chapter).\(start.verse)"
        case .youVersion:
            root = "youversion://bible?reference="
            path = start.book == end.book && start.chapter == end.chapter
                ? "\(startOSIS).\(start.chapter).\(start.verse)-\(end.verse)"
                : "\(startOSIS).\(start.chapter)"
        }
        return URL(string: root + path)
    }

    private struct BibleReferenceParts {
        let book: Int
        let chapter: Int
        let verse: Int

        init(_ reference: Int) {
            book = reference / 1_000_000
            chapter = (reference / 1_000) % 1_000
            verse = reference % 1_000
        }
    }

    private static let bookAbbreviations = [
        "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
        "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
        "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer",
        "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah", "Mic",
        "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt", "Mark", "Luke",
        "John", "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil",
        "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm",
        "Heb", "Jas", "1Pet", "2Pet", "1John", "2John", "3John", "Jude", "Rev",
    ]

    private static let bookNames = [
        "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth",
        "1 Samuel", "2 Samuel", "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra", "Nehemiah",
        "Esther", "Job", "Psalms", "Proverbs", "Ecclesiastes", "Song of Songs", "Isaiah", "Jeremiah",
        "Lamentations", "Ezekiel", "Daniel", "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah",
        "Nahum", "Habakkuk", "Zephaniah", "Haggai", "Zechariah", "Malachi", "Matthew", "Mark", "Luke",
        "John", "Acts", "Romans", "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians", "Philippians",
        "Colossians", "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus", "Philemon",
        "Hebrews", "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John", "Jude", "Revelation",
    ]
}
