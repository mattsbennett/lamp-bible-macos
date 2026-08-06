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

    @Test func lexiconLinksCarryTheClickedWord() throws {
        let link = try #require(LexiconLookupLink(
            keys: ["H7225"],
            reference: 1_001_001,
            word: "  beginning  "
        ))
        let url = try #require(link.url)

        #expect(link.word == "beginning")
        #expect(LexiconLookupLink(url: url) == link)
        // A word is optional, and blank is the same as absent.
        #expect(LexiconLookupLink(keys: ["H7225"], reference: 1_001_001, word: "   ")?.word == nil)
        #expect(LexiconLookupLink(keys: ["H7225"], reference: 1_001_001)?.word == nil)
    }

    @Test func strongsKeysCompareAcrossSpellings() {
        #expect(StrongsKey.normalized(" h07225 ") == "H7225")
        #expect(StrongsKey.normalized("G3588a") == "G3588A")
        #expect(StrongsKey.normalized("0776") == "776")

        #expect(StrongsKey.matches("H7225", "h07225"))
        #expect(StrongsKey.matches("G3056", "G3056"))
        // A dictionary that stores bare numbers still answers a prefixed key.
        #expect(StrongsKey.matches("H776", "0776"))

        #expect(!StrongsKey.matches("H7225", "H7226"))
        // Same number, different language: never the same entry.
        #expect(!StrongsKey.matches("H3056", "G3056"))
        #expect(!StrongsKey.matches("G3588a", "G3588b"))
        #expect(!StrongsKey.matches("", "H7225"))
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

    @Test func continuousParagraphProgressResolvesItsVisibleVerse() {
        let segments = [
            ReaderParagraphSegment(reference: 1_001_001, characterCount: 10),
            ReaderParagraphSegment(reference: 1_001_002, characterCount: 20),
            ReaderParagraphSegment(reference: 1_001_003, characterCount: 10),
        ]

        #expect(ReaderParagraphAnchorResolver.reference(at: 0, in: segments) == 1_001_001)
        #expect(ReaderParagraphAnchorResolver.reference(at: 0.3, in: segments) == 1_001_002)
        #expect(ReaderParagraphAnchorResolver.reference(at: 0.9, in: segments) == 1_001_003)
        #expect(ReaderParagraphAnchorResolver.reference(at: 2, in: segments) == 1_001_003)
        #expect(ReaderParagraphAnchorResolver.reference(at: 0.5, in: []) == nil)
    }

    @Test func formatsCleanReaderCitations() throws {
        let verses = [
            ReaderCitationVerse(number: 1, text: "In the beginning was the Word,", displayPrefix: "1*"),
            ReaderCitationVerse(number: 2, text: "and the Word was with God,", displayPrefix: "2✎"),
            ReaderCitationVerse(number: 3, text: "and the Word was God.", displayPrefix: "3▣"),
        ]

        #expect(ReaderCitationFormatter.citation(
            bookName: "John",
            chapterNumber: 1,
            verses: verses,
            translationName: "ESVs"
        ) == "(John 1:1-3 ESV)\n\"In the beginning was the Word, and the Word was with God, and the Word was God.\"")

        let selected = "beginning was the Word, 2✎ and the Word was with God, 3▣ and the Word"
        #expect(ReaderCitationFormatter.citation(
            bookName: "John",
            chapterNumber: 1,
            verses: verses,
            translationName: "ESVs",
            selectedDisplayText: selected
        ) == "(John 1:1-3 ESV)\n\"beginning was the Word, and the Word was with God, and the Word\"")
    }

    @Test func citationTranslationNamesOnlyDropTheStrongsSuffix() {
        #expect(ReaderCitationFormatter.citationTranslationName("ESVs") == "ESV")
        #expect(ReaderCitationFormatter.citationTranslationName("KJV") == "KJV")
        #expect(ReaderCitationFormatter.citationTranslationName("World English Scriptures") == "World English Scriptures")
    }

    @Test func expandsPassageRangesAcrossEveryCoveredChapter() {
        let books = [
            ReaderBookStructure(bookNumber: 1, chapterCount: 50),
            ReaderBookStructure(bookNumber: 2, chapterCount: 40),
        ]

        #expect(ReaderPassageChapterPlanner.locations(
            from: 1_049_020,
            to: 2_002_003,
            books: books
        ) == [
            ReaderChapterLocation(bookNumber: 1, chapterNumber: 49),
            ReaderChapterLocation(bookNumber: 1, chapterNumber: 50),
            ReaderChapterLocation(bookNumber: 2, chapterNumber: 1),
            ReaderChapterLocation(bookNumber: 2, chapterNumber: 2),
        ])

        #expect(ReaderPassageChapterPlanner.locations(
            from: 1_001_001,
            to: 1_003_010,
            books: books
        ).map(\.chapterNumber) == [1, 2, 3])
        #expect(ReaderPassageChapterPlanner.locations(
            from: 1_003_001,
            to: 1_002_010,
            books: books
        ).isEmpty)
    }

    @Test func isolatesPoetryAfterAProseSpeechIntroduction() throws {
        let text = "Now a worthless man happened to be there, and he shouted: \u{201C}We have no share in David, no inheritance in Jesse's son. Every man to his tent, O Israel!\u{201D}"
        let range = try #require(ReaderPoetryLayout.partialRange(in: text, isPoetry: true))
        let start = text.index(text.startIndex, offsetBy: range.startOffset)
        let end = text.index(text.startIndex, offsetBy: range.endOffset)

        #expect(String(text[start..<end]) == "\u{201C}We have no share in David, no inheritance in Jesse's son. Every man to his tent, O Israel!\u{201D}")
        #expect(ReaderPoetryLayout.partialRange(in: text, isPoetry: false) == nil)
        #expect(ReaderPoetryLayout.partialRange(in: "\u{201C}The whole line is poetry.\u{201D}", isPoetry: true) == nil)
        #expect(ReaderPoetryLayout.partialRange(in: "A poetic line with a \u{201C}quoted word\u{201D} inside it", isPoetry: true) == nil)
    }

    @Test func readerTabsRetainIndependentLocationsAndAlwaysKeepOneTab() throws {
        let genesis = ReaderLocation(
            translationID: "WEB",
            bookNumber: 1,
            chapterNumber: 1,
            verseReference: 1_001_001
        )
        let john = ReaderLocation(
            translationID: "WEB",
            bookNumber: 43,
            chapterNumber: 1,
            verseReference: 43_001_001
        )
        var tabs = ReaderTabCollection(initialLocation: genesis)
        let genesisID = try #require(tabs.selectedTab?.id)

        let johnID = tabs.add(location: john)
        #expect(tabs.tabs.count == 2)
        #expect(tabs.selectedID == johnID)
        #expect(tabs.selectedTab?.location == john)

        #expect(tabs.select(genesisID) == genesis)
        tabs.updateSelected(location: ReaderLocation(
            translationID: "WEB",
            bookNumber: 1,
            chapterNumber: 2
        ))
        #expect(tabs.selectedTab?.location?.chapterNumber == 2)

        #expect(tabs.close(genesisID) == john)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.selectedID == johnID)
        _ = tabs.close(johnID)
        #expect(tabs.tabs.count == 1)
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
