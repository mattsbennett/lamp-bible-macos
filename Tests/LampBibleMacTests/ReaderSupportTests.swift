import Foundation
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

struct ReaderSupportTests {
    @Test func lexiconLinksPreserveAllKeysAndTheirVerse() throws {
        let link = try #require(LexiconLookupLink(
            keys: [" h7225 ", "H1254", "h7225"],
            reference: 1_001_001
        ))
        let url = try #require(link.url)

        #expect(link.keys == ["H7225", "H1254"])
        #expect(LexiconLookupLink(url: url) == link)
        #expect(LexiconLookupLink(url: try #require(URL(string: "https://example.com"))) == nil)
        #expect(LexiconLookupLink(keys: [], reference: 1_001_001) == nil)
        #expect(LexiconLookupLink(keys: ["G3056"], reference: 0) == nil)
    }

    @Test func readAloudQueueStartsAtReferenceAndAdvances() {
        let items = [
            ReadAloudItem(reference: 1_001_001, verseNumber: 1, text: "In the beginning"),
            ReadAloudItem(reference: 1_001_002, verseNumber: 2, text: "The earth was formless"),
            ReadAloudItem(reference: 1_001_003, verseNumber: 3, text: "Let there be light"),
        ]
        var queue = ReadAloudQueue(items: items, startingAt: 1_001_002)

        #expect(queue.current == items[1])
        #expect(Array(queue.remainingItems) == Array(items[1...]))
        #expect(queue.advance() == items[2])
        #expect(queue.advance() == nil)
        #expect(queue.current == nil)

        queue = ReadAloudQueue(items: items, startingAt: 99)
        #expect(queue.current == items[0])
        queue.stop()
        #expect(queue.remainingItems.isEmpty)
    }

    @Test func textRangesMapBetweenAppKitAndCharacterOffsets() throws {
        let text = "Grace 🙏🏽 and truth"
        let selected = try #require(text.range(of: "🙏🏽 and"))
        let appKitRange = NSRange(selected, in: text)
        let characterRange = try #require(
            ReaderTextRangeMapper.characterRange(in: text, utf16Range: appKitRange)
        )

        #expect(characterRange.startOffset == 6)
        #expect(characterRange.endOffset == 11)
        #expect(ReaderTextRangeMapper.utf16Range(in: text, characterRange: characterRange) == appKitRange)
    }

    @Test func estimatesReadingTimeAndNormalizesReminderTime() {
        #expect(ReadingTimeEstimator.minutes(wordCount: 451, wordsPerMinute: 225) == 3)
        #expect(ReadingTimeEstimator.description(wordCount: 100, wordsPerMinute: 225) == "1 min")
        #expect(ReadingTimeEstimator.description(wordCount: 0, wordsPerMinute: 225) == "0 min")

        let reminder = ReadingReminderConfiguration(isEnabled: true, hour: 26, minute: -2)
        #expect(reminder.hour == 23)
        #expect(reminder.minute == 0)
        #expect(reminder.dateComponents.hour == 23)
    }

    @Test func parsesDeepLinksAndOpenableDocuments() throws {
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://read?reference=43003016&translation=KJV")))
            == .reader(reference: 43_003_016, translationID: "KJV"))
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://plans"))) == .section(.plans))
        #expect(LampDeepLink(url: URL(fileURLWithPath: "/tmp/test.lamp"))
            == .moduleFile(URL(fileURLWithPath: "/tmp/test.lamp")))
        #expect(LampDeepLink(url: URL(fileURLWithPath: "/tmp/notes.json"))
            == .dataFile(URL(fileURLWithPath: "/tmp/notes.json")))
        #expect(LampDeepLink(url: try #require(URL(string: "https://example.com"))) == nil)
    }

    @Test func parsesDevotionalMarkdownMediaBlocks() throws {
        let markdown = """
        # Morning

        A reflection.

        ![Sunrise](lamp-media://dev-1/sunrise.jpg)
        [▶︎ Prayer](lamp-media://dev-1/prayer.m4a)
        """
        let blocks = DevotionalMarkdownParser.parse(markdown)

        #expect(blocks.count == 3)
        #expect(blocks[0] == .text("# Morning\n\nA reflection."))
        #expect(blocks[1] == .image(
            caption: "Sunrise",
            url: try #require(URL(string: "lamp-media://dev-1/sunrise.jpg"))
        ))
        #expect(blocks[2] == .audio(
            label: "Prayer",
            url: try #require(URL(string: "lamp-media://dev-1/prayer.m4a"))
        ))
    }

    @Test func navigationHistoryMovesBackForwardAndBranches() {
        let first = ReaderLocation(translationID: "A", bookNumber: 1, chapterNumber: 1)
        let second = ReaderLocation(translationID: "A", bookNumber: 1, chapterNumber: 2)
        let third = ReaderLocation(translationID: "B", bookNumber: 43, chapterNumber: 3, verseReference: 43_003_016)
        var history = ReaderNavigationHistory(capacity: 3)

        history.visit(first)
        history.visit(second)
        history.visit(third)
        #expect(history.goBack() == second)
        #expect(history.canGoForward)
        #expect(history.goBack() == first)
        #expect(history.goForward() == second)

        let branch = ReaderLocation(translationID: "A", bookNumber: 19, chapterNumber: 23)
        history.visit(branch)
        #expect(!history.canGoForward)
        #expect(history.current == branch)
    }

    @Test func searchHistoryDeduplicatesAndRoundTrips() throws {
        let old = LampSearchHistoryEntry(
            query: "grace",
            kind: .translation,
            searchedAt: Date(timeIntervalSince1970: 1)
        )
        let updated = LampSearchHistoryEntry(
            query: " grace ",
            kind: .translation,
            searchedAt: Date(timeIntervalSince1970: 2)
        )
        let entries = LampSearchHistoryStore.adding(updated, to: [old])

        #expect(entries.count == 1)
        #expect(entries.first?.query == "grace")
        #expect(entries.first?.searchedAt == Date(timeIntervalSince1970: 2))
        #expect(LampSearchHistoryStore.decode(LampSearchHistoryStore.encode(entries)) == entries)
    }

    @Test func buildsExternalBibleLinks() {
        let start = 43_003_016
        let end = 43_003_018

        #expect(ExternalBibleApplication.youVersion.url(
            startReference: start,
            endReference: end
        )?.absoluteString == "youversion://bible?reference=John.3.16-18")
        #expect(ExternalBibleApplication.logos.url(
            startReference: start
        )?.absoluteString == "https://ref.ly/john3:16")
        #expect(ExternalBibleApplication.accordance.url(
            startReference: start,
            endReference: end
        )?.absoluteString == "accord://read/John_3:16-John_3:18")
    }
}
