import Foundation

public struct BookReaderAnnotationData: Codable, Equatable, Hashable, Sendable {
    public let startReference: Int?
    public let endReference: Int?
    public let references: [BookReaderVerseRange]
    public let strongs: String?
    public let url: String?
    public let style: String?
    public let source: String?
    public let footnoteID: String?
    public let pageNumber: String?
    public let mediaID: String?
    public let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case startReference = "sv"
        case endReference = "ev"
        case references = "refs"
        case strongs, url, style, source
        case footnoteID = "footnoteId"
        case pageNumber = "pageNum"
        case mediaID = "mediaId"
        case mediaType
    }

    public init(
        startReference: Int? = nil,
        endReference: Int? = nil,
        references: [BookReaderVerseRange] = [],
        strongs: String? = nil,
        url: String? = nil,
        style: String? = nil,
        source: String? = nil,
        footnoteID: String? = nil,
        pageNumber: String? = nil,
        mediaID: String? = nil,
        mediaType: String? = nil
    ) {
        self.startReference = startReference
        self.endReference = endReference
        self.references = references
        self.strongs = strongs
        self.url = url
        self.style = style
        self.source = source
        self.footnoteID = footnoteID
        self.pageNumber = pageNumber
        self.mediaID = mediaID
        self.mediaType = mediaType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startReference = try container.decodeIfPresent(Int.self, forKey: .startReference)
        endReference = try container.decodeIfPresent(Int.self, forKey: .endReference)
        references = try container.decodeIfPresent([BookReaderVerseRange].self, forKey: .references) ?? []
        strongs = try container.decodeIfPresent(String.self, forKey: .strongs)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        style = try container.decodeIfPresent(String.self, forKey: .style)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        footnoteID = try container.decodeIfPresent(String.self, forKey: .footnoteID)
        if let string = try? container.decodeIfPresent(String.self, forKey: .pageNumber) {
            pageNumber = string
        } else if let number = try? container.decode(Int.self, forKey: .pageNumber) {
            pageNumber = String(number)
        } else {
            pageNumber = nil
        }
        mediaID = try container.decodeIfPresent(String.self, forKey: .mediaID)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
    }
}

public struct BookReaderVerseRange: Codable, Equatable, Hashable, Sendable {
    public let startReference: Int
    public let endReference: Int?
    public let label: String?

    enum CodingKeys: String, CodingKey {
        case startReference = "sv"
        case endReference = "ev"
        case label
    }

    public init(startReference: Int, endReference: Int? = nil, label: String? = nil) {
        self.startReference = startReference
        self.endReference = endReference
        self.label = label
    }
}

public struct BookReaderAnnotation: Codable, Equatable, Hashable, Sendable {
    public let type: String
    public let start: Int
    public let end: Int
    public let text: String?
    public let data: BookReaderAnnotationData?

    public init(
        type: String,
        start: Int,
        end: Int,
        text: String? = nil,
        data: BookReaderAnnotationData? = nil
    ) {
        self.type = type
        self.start = start
        self.end = end
        self.text = text
        self.data = data
    }
}

public struct BookReaderFootnoteReference: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let offset: Int

    public init(id: String, offset: Int) {
        self.id = id
        self.offset = offset
    }
}

public struct BookReaderAnnotatedText: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let annotations: [BookReaderAnnotation]
    public let footnoteReferences: [BookReaderFootnoteReference]

    enum CodingKeys: String, CodingKey {
        case text, annotations
        case footnoteReferences = "footnote_refs"
    }

    public init(
        text: String,
        annotations: [BookReaderAnnotation] = [],
        footnoteReferences: [BookReaderFootnoteReference] = []
    ) {
        self.text = text
        self.annotations = annotations
        self.footnoteReferences = footnoteReferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        annotations = try container.decodeIfPresent([BookReaderAnnotation].self, forKey: .annotations) ?? []
        footnoteReferences = try container.decodeIfPresent(
            [BookReaderFootnoteReference].self,
            forKey: .footnoteReferences
        ) ?? []
    }
}

public enum BookReaderTextValue: Codable, Equatable, Sendable {
    case plain(String)
    case annotated(BookReaderAnnotatedText)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
        } else {
            self = .annotated(try container.decode(BookReaderAnnotatedText.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let value): try container.encode(value)
        case .annotated(let value): try container.encode(value)
        }
    }

    public var annotatedText: BookReaderAnnotatedText {
        switch self {
        case .plain(let value): BookReaderAnnotatedText(text: value)
        case .annotated(let value): value
        }
    }
}

public struct BookReaderListItem: Codable, Equatable, Sendable {
    public let content: BookReaderAnnotatedText
    public let children: [BookReaderListItem]

    public init(content: BookReaderAnnotatedText, children: [BookReaderListItem] = []) {
        self.content = content
        self.children = children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(BookReaderAnnotatedText.self, forKey: .content)
        children = try container.decodeIfPresent([BookReaderListItem].self, forKey: .children) ?? []
    }

    private enum CodingKeys: String, CodingKey { case content, children }
}

public struct BookReaderTableCell: Codable, Equatable, Sendable {
    public let content: BookReaderAnnotatedText
    public let column: Int
    public let columnSpan: Int
    public let rowSpan: Int
    public let isHeader: Bool

    public init(
        content: BookReaderAnnotatedText,
        column: Int,
        columnSpan: Int = 1,
        rowSpan: Int = 1,
        isHeader: Bool = false
    ) {
        self.content = content
        self.column = column
        self.columnSpan = max(columnSpan, 1)
        self.rowSpan = max(rowSpan, 1)
        self.isHeader = isHeader
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(
            BookReaderAnnotatedText.self,
            forKey: .content
        ) ?? BookReaderAnnotatedText(text: "")
        column = try container.decodeIfPresent(Int.self, forKey: .column) ?? 0
        columnSpan = max(
            try container.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1,
            1
        )
        rowSpan = max(
            try container.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1,
            1
        )
        isHeader = try container.decodeIfPresent(Bool.self, forKey: .isHeader) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case content, column
        case columnSpan = "colSpan"
        case rowSpan
        case isHeader = "header"
    }
}

public struct BookReaderTableRow: Codable, Equatable, Sendable {
    public let cells: [BookReaderTableCell]

    public init(cells: [BookReaderTableCell]) {
        self.cells = cells
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cells = try container.decodeIfPresent(
            [BookReaderTableCell].self,
            forKey: .cells
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey { case cells }
}

public struct BookReaderContentBlock: Codable, Equatable, Sendable {
    public let type: String
    public let content: BookReaderAnnotatedText?
    public let level: Int?
    public let listType: String?
    public let items: [BookReaderListItem]
    public let mediaID: String?
    public let caption: BookReaderTextValue?
    public let alignment: String?
    public let showWaveform: Bool
    public let autoplay: Bool
    public let columnCount: Int?
    public let rows: [BookReaderTableRow]

    enum CodingKeys: String, CodingKey {
        case type, content, level, listType, items
        case mediaID = "mediaId"
        case caption, alignment, showWaveform, autoplay, columnCount, rows
    }

    public init(
        type: String,
        content: BookReaderAnnotatedText? = nil,
        level: Int? = nil,
        listType: String? = nil,
        items: [BookReaderListItem] = [],
        mediaID: String? = nil,
        caption: BookReaderTextValue? = nil,
        alignment: String? = nil,
        showWaveform: Bool = false,
        autoplay: Bool = false,
        columnCount: Int? = nil,
        rows: [BookReaderTableRow] = []
    ) {
        self.type = type
        self.content = content
        self.level = level
        self.listType = listType
        self.items = items
        self.mediaID = mediaID
        self.caption = caption
        self.alignment = alignment
        self.showWaveform = showWaveform
        self.autoplay = autoplay
        self.columnCount = columnCount
        self.rows = rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        content = try container.decodeIfPresent(BookReaderAnnotatedText.self, forKey: .content)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        listType = try container.decodeIfPresent(String.self, forKey: .listType)
        items = try container.decodeIfPresent([BookReaderListItem].self, forKey: .items) ?? []
        mediaID = try container.decodeIfPresent(String.self, forKey: .mediaID)
        caption = try container.decodeIfPresent(BookReaderTextValue.self, forKey: .caption)
        alignment = try container.decodeIfPresent(String.self, forKey: .alignment)
        showWaveform = try container.decodeIfPresent(Bool.self, forKey: .showWaveform) ?? false
        autoplay = try container.decodeIfPresent(Bool.self, forKey: .autoplay) ?? false
        columnCount = try container.decodeIfPresent(Int.self, forKey: .columnCount)
        rows = try container.decodeIfPresent([BookReaderTableRow].self, forKey: .rows) ?? []
    }
}

public struct BookReaderFootnote: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let content: BookReaderTextValue

    public init(id: String, content: BookReaderTextValue) {
        self.id = id
        self.content = content
    }
}

public struct BookReaderMedia: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let filename: String
    public let mimeType: String
    public let size: Int?
    public let width: Int?
    public let height: Int?
    public let duration: Double?
    public let waveform: [Double]
    public let transcription: String?
    public let alt: String?
    public let created: Int?

    public init(
        id: String,
        type: String,
        filename: String,
        mimeType: String,
        size: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        waveform: [Double] = [],
        transcription: String? = nil,
        alt: String? = nil,
        created: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.waveform = waveform
        self.transcription = transcription
        self.alt = alt
        self.created = created
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        filename = try container.decode(String.self, forKey: .filename)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        waveform = try container.decodeIfPresent([Double].self, forKey: .waveform) ?? []
        transcription = try container.decodeIfPresent(String.self, forKey: .transcription)
        alt = try container.decodeIfPresent(String.self, forKey: .alt)
        created = try container.decodeIfPresent(Int.self, forKey: .created)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, filename, mimeType, size, width, height, duration
        case waveform, transcription, alt, created
    }
}

public struct BookReaderDecodedBlocks: Equatable, Sendable {
    public let blocks: [BookReaderContentBlock]
    public let discardedBlockCount: Int

    public init(blocks: [BookReaderContentBlock], discardedBlockCount: Int) {
        self.blocks = blocks
        self.discardedBlockCount = discardedBlockCount
    }
}

public enum BookReaderJSON {
    /// Decodes blocks independently. One forward-version or malformed block must
    /// not turn a whole chapter into an empty document.
    public static func decodeBlocks(_ json: String) -> BookReaderDecodedBlocks {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return BookReaderDecodedBlocks(blocks: [], discardedBlockCount: 1) }

        var blocks: [BookReaderContentBlock] = []
        var failures = 0
        let decoder = JSONDecoder()
        for value in values {
            guard JSONSerialization.isValidJSONObject(value),
                  let blockData = try? JSONSerialization.data(withJSONObject: value),
                  let block = try? decoder.decode(BookReaderContentBlock.self, from: blockData)
            else {
                failures += 1
                continue
            }
            blocks.append(block)
        }
        return BookReaderDecodedBlocks(blocks: blocks, discardedBlockCount: failures)
    }

    public static func decodeFootnotes(_ json: String?) -> [BookReaderFootnote] {
        decodeLossyArray(json, as: BookReaderFootnote.self)
    }

    public static func decodeMedia(_ json: String?) -> [BookReaderMedia] {
        decodeLossyArray(json, as: BookReaderMedia.self)
    }

    private static func decodeLossyArray<Value: Decodable>(
        _ json: String?,
        as type: Value.Type
    ) -> [Value] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        let decoder = JSONDecoder()
        return values.compactMap { value in
            guard JSONSerialization.isValidJSONObject(value),
                  let itemData = try? JSONSerialization.data(withJSONObject: value)
            else { return nil }
            return try? decoder.decode(Value.self, from: itemData)
        }
    }
}

public enum BookReaderFootnoteReferences {
    /// Returns only the footnotes linked from a section's rendered content,
    /// including media captions and nested list items.
    public static func ids(in blocks: [BookReaderContentBlock]) -> Set<String> {
        var result = Set<String>()
        for block in blocks {
            if let content = block.content { collect(content, into: &result) }
            if let caption = block.caption?.annotatedText { collect(caption, into: &result) }
            for item in block.items { collect(item, into: &result) }
            for row in block.rows {
                for cell in row.cells {
                    collect(cell.content, into: &result)
                }
            }
        }
        return result
    }

    private static func collect(
        _ item: BookReaderListItem,
        into result: inout Set<String>
    ) {
        collect(item.content, into: &result)
        for child in item.children { collect(child, into: &result) }
    }

    private static func collect(
        _ content: BookReaderAnnotatedText,
        into result: inout Set<String>
    ) {
        result.formUnion(content.footnoteReferences.map(\.id))
        result.formUnion(content.annotations.compactMap(\.data?.footnoteID))
    }
}

public enum BookReaderMediaResolver {
    public static func url(
        for filename: String,
        moduleID: String,
        libraryRootURL: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        if let remote = URL(string: filename),
           let scheme = remote.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            return remote
        }

        let decoded = filename.removingPercentEncoding ?? filename
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !decoded.hasPrefix("/"), !components.isEmpty,
              !components.contains(".."), !components.contains(".") else { return nil }
        let relative = components.map(String.init).joined(separator: "/")
        let roots = [
            libraryRootURL.appendingPathComponent("Media/Modules/\(moduleID)", isDirectory: true),
            libraryRootURL.appendingPathComponent("Media/Books/\(moduleID)", isDirectory: true),
            libraryRootURL.appendingPathComponent("Media/\(moduleID)", isDirectory: true),
            libraryRootURL.appendingPathComponent("Modules/\(moduleID)/media", isDirectory: true),
        ]
        return roots
            .map { $0.appendingPathComponent(relative) }
            .first { fileExists($0.path) }
    }
}

public struct BookReadingPosition: Codable, Equatable, Sendable {
    public let sectionID: String
    public let blockIndex: Int
    public let updatedAt: Date

    public init(sectionID: String, blockIndex: Int = -1, updatedAt: Date = Date()) {
        self.sectionID = sectionID
        self.blockIndex = max(blockIndex, -1)
        self.updatedAt = updatedAt
    }
}

/// Keeps high-frequency scroll visibility changes in memory until the reader
/// reaches an idle phase. This prevents every scroll tick from becoming a
/// UserDefaults read, JSON encode, and disk-backed write.
public struct BookReadingPositionBuffer: Equatable, Sendable {
    public private(set) var blockIndex: Int
    private var persistedBlockIndex: Int

    public init(blockIndex: Int = -1) {
        let normalizedIndex = max(blockIndex, -1)
        self.blockIndex = normalizedIndex
        persistedBlockIndex = normalizedIndex
    }

    public mutating func observe(visibleBlockIndices: [Int]) {
        guard let firstVisibleIndex = visibleBlockIndices.min() else { return }
        blockIndex = max(firstVisibleIndex, -1)
    }

    /// Returns a value only when the in-memory position has changed since the
    /// previous flush.
    public mutating func takeChangedBlockIndex() -> Int? {
        guard blockIndex != persistedBlockIndex else { return nil }
        persistedBlockIndex = blockIndex
        return blockIndex
    }
}

private struct StoredBookReaderState: Codable {
    var positions: [String: BookReadingPosition] = [:]
    var bookmarks: [String: Set<String>] = [:]
}

public struct BookReadingStateStore {
    public static let defaultsKey = "books.readerState"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func position(for moduleID: String) -> BookReadingPosition? {
        load().positions[moduleID]
    }

    public func save(position: BookReadingPosition, for moduleID: String) {
        var state = load()
        state.positions[moduleID] = position
        save(state)
    }

    public func bookmarkIDs(for moduleID: String) -> Set<String> {
        load().bookmarks[moduleID] ?? []
    }

    @discardableResult
    public func toggleBookmark(sectionID: String, for moduleID: String) -> Bool {
        var state = load()
        var bookmarks = state.bookmarks[moduleID] ?? []
        let isBookmarked: Bool
        if bookmarks.remove(sectionID) != nil {
            isBookmarked = false
        } else {
            bookmarks.insert(sectionID)
            isBookmarked = true
        }
        state.bookmarks[moduleID] = bookmarks
        save(state)
        return isBookmarked
    }

    private func load() -> StoredBookReaderState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(StoredBookReaderState.self, from: data)
        else { return StoredBookReaderState() }
        return state
    }

    private func save(_ state: StoredBookReaderState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum BookReaderNavigation {
    public static func previousID(in orderedIDs: [String], currentID: String) -> String? {
        guard let index = orderedIDs.firstIndex(of: currentID), index > orderedIDs.startIndex else {
            return nil
        }
        return orderedIDs[orderedIDs.index(before: index)]
    }

    public static func nextID(in orderedIDs: [String], currentID: String) -> String? {
        guard let index = orderedIDs.firstIndex(of: currentID) else { return nil }
        let next = orderedIDs.index(after: index)
        return next < orderedIDs.endIndex ? orderedIDs[next] : nil
    }
}
