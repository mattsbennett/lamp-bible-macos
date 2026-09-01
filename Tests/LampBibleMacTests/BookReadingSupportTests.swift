import Foundation
import Testing
@testable import LampBibleMacSupport

struct BookReadingSupportTests {
    @Test func decodesRichBookSchemaValues() throws {
        let json = #"""
        [
          {
            "type": "paragraph",
            "content": {
              "text": "Read John 3:16 carefully.",
              "annotations": [
                {"type":"scripture","start":5,"end":14,"data":{"sv":43003016,"ev":43003016}},
                {"type":"emphasis","start":15,"end":24,"data":{"style":"italic"}}
              ],
              "footnote_refs": [{"id":"note-1","offset":24}]
            }
          },
          {
            "type":"audio",
            "mediaId":"audio-1",
            "caption":{"text":"A reading","annotations":[]},
            "showWaveform":true,
            "autoplay":false
          }
        ]
        """#

        let result = BookReaderJSON.decodeBlocks(json)

        #expect(result.discardedBlockCount == 0)
        #expect(result.blocks.count == 2)
        #expect(result.blocks[0].content?.annotations.first?.data?.startReference == 43_003_016)
        #expect(result.blocks[0].content?.footnoteReferences == [
            BookReaderFootnoteReference(id: "note-1", offset: 24),
        ])
        #expect(result.blocks[1].mediaID == "audio-1")
        #expect(result.blocks[1].caption?.annotatedText.text == "A reading")
        #expect(result.blocks[1].showWaveform)
    }

    @Test func oneMalformedBlockDoesNotBlankTheChapter() {
        let json = #"""
        [
          {"type":"paragraph","content":{"text":"Before"}},
          {"content":{"text":"Missing a type"}},
          {"type":"paragraph","content":{"text":"After"}}
        ]
        """#

        let result = BookReaderJSON.decodeBlocks(json)

        #expect(result.blocks.map { $0.content?.text } == ["Before", "After"])
        #expect(result.discardedBlockCount == 1)
    }

    @Test func decodesBookTablesWithoutCreatingEmptyScrollTargets() throws {
        let result = BookReaderJSON.decodeBlocks(#"""
        [{
          "type":"table",
          "columnCount":2,
          "rows":[
            {"cells":[
              {"content":{"text":"Name"},"column":0,"header":true},
              {"content":{"text":"Date"},"column":1,"header":true}
            ]},
            {"cells":[
              {
                "content":{
                  "text":"Irenaeus",
                  "footnote_refs":[{"id":"table-note","offset":8}]
                },
                "column":0,
                "rowSpan":4
              },
              {"content":{"text":"185"},"column":1,"colSpan":1}
            ]}
          ]
        }]
        """#)

        let table = try #require(result.blocks.first)
        #expect(result.discardedBlockCount == 0)
        #expect(table.columnCount == 2)
        #expect(table.rows.count == 2)
        #expect(table.rows[0].cells.map(\.isHeader) == [true, true])
        #expect(table.rows[1].cells[0].rowSpan == 4)
        #expect(BookReaderFootnoteReferences.ids(in: result.blocks) == ["table-note"])
    }

    @Test func footnotesMediaAndFlexiblePageNumbersDecodeLossily() {
        let footnotes = BookReaderJSON.decodeFootnotes(#"""
        [{"id":"one","content":"Plain"},{"no":"id"},{"id":"two","content":{"text":"Rich"}}]
        """#)
        let media = BookReaderJSON.decodeMedia(#"""
        [{"id":"cover","type":"image","filename":"cover.jpg","mimeType":"image/jpeg","width":800},42]
        """#)
        let blocks = BookReaderJSON.decodeBlocks(#"""
        [{"type":"paragraph","content":{"text":"Page","annotations":[{"type":"page","start":0,"end":4,"data":{"pageNum":12}}]}}]
        """#)

        #expect(footnotes.map(\.id) == ["one", "two"])
        #expect(media.map(\.id) == ["cover"])
        #expect(blocks.blocks[0].content?.annotations[0].data?.pageNumber == "12")
    }

    @Test func resolvesOnlyFootnotesReferencedByASection() {
        let decoded = BookReaderJSON.decodeBlocks(#"""
        [
          {
            "type":"paragraph",
            "content":{
              "text":"Paragraph",
              "footnote_refs":[{"id":"paragraph-note","offset":9}]
            }
          },
          {
            "type":"audio",
            "caption":{
              "text":"Caption",
              "annotations":[
                {"type":"footnote","start":0,"end":7,"data":{"footnoteId":"caption-note"}}
              ]
            }
          },
          {
            "type":"list",
            "items":[{
              "content":{"text":"Parent"},
              "children":[{
                "content":{
                  "text":"Child",
                  "footnote_refs":[{"id":"nested-note","offset":5}]
                }
              }]
            }]
          }
        ]
        """#)

        #expect(BookReaderFootnoteReferences.ids(in: decoded.blocks) == [
            "paragraph-note",
            "caption-note",
            "nested-note",
        ])
    }

    @Test func mediaResolverFindsSupportedLayoutsAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mediaDirectory = root.appendingPathComponent("Media/Modules/a-book", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let image = mediaDirectory.appendingPathComponent("images/cover.jpg")
        try FileManager.default.createDirectory(
            at: image.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: image)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(BookReaderMediaResolver.url(
            for: "images/cover.jpg",
            moduleID: "a-book",
            libraryRootURL: root
        ) == image)
        #expect(BookReaderMediaResolver.url(
            for: "../secrets.txt",
            moduleID: "a-book",
            libraryRootURL: root
        ) == nil)
        #expect(BookReaderMediaResolver.url(
            for: "https://example.com/image.jpg",
            moduleID: "a-book",
            libraryRootURL: root
        ) == URL(string: "https://example.com/image.jpg"))
    }

    @Test func readingStatePersistsPositionsAndBookmarksPerBook() throws {
        let suiteName = "BookReadingSupportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BookReadingStateStore(defaults: defaults)
        let position = BookReadingPosition(
            sectionID: "book-a:chapter-2",
            blockIndex: 9,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        store.save(position: position, for: "book-a")
        #expect(store.position(for: "book-a") == position)
        #expect(store.position(for: "book-b") == nil)
        #expect(store.toggleBookmark(sectionID: "chapter-2", for: "book-a"))
        #expect(store.bookmarkIDs(for: "book-a") == ["chapter-2"])
        #expect(!store.toggleBookmark(sectionID: "chapter-2", for: "book-a"))
        #expect(store.bookmarkIDs(for: "book-a").isEmpty)
    }

    @Test func scrollPositionBufferDefersAndCoalescesPersistence() {
        var buffer = BookReadingPositionBuffer(blockIndex: 2)

        buffer.observe(visibleBlockIndices: [4, 3, 5])
        buffer.observe(visibleBlockIndices: [7, 6])

        #expect(buffer.blockIndex == 6)
        #expect(buffer.takeChangedBlockIndex() == 6)
        #expect(buffer.takeChangedBlockIndex() == nil)

        buffer.observe(visibleBlockIndices: [])
        #expect(buffer.blockIndex == 6)
        #expect(buffer.takeChangedBlockIndex() == nil)
    }

    @Test func navigationStopsAtDocumentEdges() {
        let ids = ["one", "two", "three"]
        #expect(BookReaderNavigation.previousID(in: ids, currentID: "one") == nil)
        #expect(BookReaderNavigation.previousID(in: ids, currentID: "three") == "two")
        #expect(BookReaderNavigation.nextID(in: ids, currentID: "two") == "three")
        #expect(BookReaderNavigation.nextID(in: ids, currentID: "three") == nil)
        #expect(BookReaderNavigation.nextID(in: ids, currentID: "missing") == nil)
    }
}
