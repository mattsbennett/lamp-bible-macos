import Foundation

public struct LexiconLookupLink: Equatable, Sendable {
    public let keys: [String]
    public let reference: Int

    public init?(keys: [String], reference: Int) {
        var seen: Set<String> = []
        let normalizedKeys = keys.compactMap { rawKey -> String? in
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
        guard !normalizedKeys.isEmpty, reference > 0 else { return nil }
        self.keys = normalizedKeys
        self.reference = reference
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
        self.init(keys: keys, reference: reference)
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "lamp-lexicon"
        components.host = "lookup"
        components.queryItems = keys.map { URLQueryItem(name: "key", value: $0) }
            + [URLQueryItem(name: "reference", value: String(reference))]
        return components.url
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
