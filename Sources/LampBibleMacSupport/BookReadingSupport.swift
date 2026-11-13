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

// Which footnotes a section cites, and where an offset falls in a block, are
// both core's now: `LampBookSectionIndex.footnoteIDs` gives them in the order
// cited rather than as an unordered set, and `LampBookTextResolver` holds the
// scalar-offset contract that the phone's reader needs too.

// Where a book's pictures are found is core's: `LampBookMediaFiles`, with
// this library's folders from `LampBookMediaFiles.libraryFolders`.

// Where each book was left and what is bookmarked in it are core's now, as
// `LampBookReadingPosition`, `LampBookReadingPositionBuffer` and
// `LampBookReadingStateStore`. They moved so that the phone keeps the same
// record under the same `books.readerState` key, and so that a sync pass can
// carry it: the store's ledger is what a pass contributes.

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
