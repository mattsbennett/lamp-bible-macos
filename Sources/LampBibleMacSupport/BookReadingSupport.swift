import Foundation
import LampModuleKit

public typealias BookReaderAnnotationData = LampBookAnnotationData
public typealias BookReaderVerseRange = LampBookVerseRange
public typealias BookReaderAnnotation = LampBookAnnotation
public typealias BookReaderFootnoteReference = LampBookFootnoteReference
public typealias BookReaderAnnotatedText = LampBookAnnotatedText
public typealias BookReaderTextValue = LampBookTextValue
public typealias BookReaderListItem = LampBookListItem
public typealias BookReaderTableCell = LampBookTableCell
public typealias BookReaderTableRow = LampBookTableRow
public typealias BookReaderContentBlock = LampBookContentBlock
public typealias BookReaderFootnote = LampBookFootnote
public typealias BookReaderMedia = LampBookMedia

public struct BookReaderDecodedBlocks: Equatable, Sendable {
    public let blocks: [BookReaderContentBlock]
    public let discardedBlockCount: Int

    public init(blocks: [BookReaderContentBlock], discardedBlockCount: Int) {
        self.blocks = blocks
        self.discardedBlockCount = discardedBlockCount
    }
}

public enum BookReaderJSON {
    public static func decodeBlocks(_ json: String) -> BookReaderDecodedBlocks {
        let decoded = LampPortableBookJSON.decodeArray(
            json, as: BookReaderContentBlock.self
        )
        return BookReaderDecodedBlocks(
            blocks: decoded.items, discardedBlockCount: decoded.discardedCount
        )
    }

    public static func decodeFootnotes(_ json: String?) -> [BookReaderFootnote] {
        LampPortableBookJSON.decodeArray(json, as: BookReaderFootnote.self).items
    }

    public static func decodeMedia(_ json: String?) -> [BookReaderMedia] {
        LampPortableBookJSON.decodeArray(json, as: BookReaderMedia.self).items
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

        guard let relative = LampPortableBookJSON.safeRelativeMediaPath(filename) else {
            return nil
        }
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
