import AppKit
import Foundation
import LampCore
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

    @Test func scriptureAnnotationLinksPreserveTheirRange() throws {
        let link = try #require(ScriptureAnnotationLink(
            startReference: 1_001_003,
            endReference: 1_001_005
        ))
        #expect(ScriptureAnnotationLink(url: try #require(link.url)) == link)
        #expect(ScriptureAnnotationLink(startReference: 0) == nil)
        #expect(ScriptureAnnotationLink(startReference: 1_001_005, endReference: 1_001_003) == nil)
        #expect(ScriptureAnnotationLink(url: try #require(URL(string: "https://example.com"))) == nil)
    }

    @Test func readerLinkActivationCoalescesNativeAndFallbackCallbacks() throws {
        let first = try #require(URL(string: "lamp-lexicon://lookup?key=H1254&reference=1001001"))
        let second = try #require(URL(string: "lamp-lexicon://lookup?key=H776&reference=1001001"))
        var gate = ReaderLinkActivationGate()

        let firstActivation = gate.shouldActivate(first, at: 10)
        let nativeDuplicate = gate.shouldActivate(first, at: 10.1)
        let differentLink = gate.shouldActivate(second, at: 10.2)
        let returnToFirstLink = gate.shouldActivate(first, at: 10.3)
        let laterActivation = gate.shouldActivate(first, at: 10.8)

        #expect(firstActivation)
        #expect(!nativeDuplicate)
        #expect(differentLink)
        #expect(returnToFirstLink)
        #expect(laterActivation)
    }

    @Test func readerScrollTailExposesTheFinalAnchorWithoutDelayingCompletion() {
        #expect(ReaderScrollTail.height(for: 600) == 599)
        #expect(ReaderScrollTail.height(for: 0) == 0)

        let totalHeight: CGFloat = 1_599
        #expect(!ReaderScrollTail.hasReachedContentBottom(
            visibleMaxY: 991,
            totalContentHeight: totalHeight,
            viewportHeight: 600
        ))
        #expect(ReaderScrollTail.hasReachedContentBottom(
            visibleMaxY: 992,
            totalContentHeight: totalHeight,
            viewportHeight: 600
        ))
    }

    @Test func scripturePreviewContextIncludesAndMarksNeighboringVerses() {
        let chapter = (1...10).map { 43_001_000 + $0 }

        #expect(ScripturePreviewContextResolver.references(
            in: chapter,
            from: 43_001_005,
            to: 43_001_006,
            contextAmount: .oneVerse
        ) == [
            ScripturePreviewReference(reference: 43_001_004, isContext: true),
            ScripturePreviewReference(reference: 43_001_005, isContext: false),
            ScripturePreviewReference(reference: 43_001_006, isContext: false),
            ScripturePreviewReference(reference: 43_001_007, isContext: true),
        ])

        #expect(ScripturePreviewContextResolver.references(
            in: chapter,
            from: 43_001_002,
            to: 43_001_002,
            contextAmount: .threeVerses
        ).map(\.reference) == Array(chapter[0...4]))
    }

    @Test func scripturePreviewChapterContextKeepsPrimaryVersesDistinct() {
        let chapter = (1...5).map { 43_001_000 + $0 }
        let preview = ScripturePreviewContextResolver.references(
            in: chapter,
            from: 43_001_003,
            to: 43_001_003,
            contextAmount: .chapter
        )

        #expect(preview.map(\.reference) == chapter)
        #expect(preview.filter { !$0.isContext }.map(\.reference) == [43_001_003])
        #expect(ScripturePreviewContextResolver.references(
            in: chapter,
            from: 43_002_001,
            to: 43_002_001,
            contextAmount: .oneVerse
        ).isEmpty)
    }

    @Test @MainActor func appKitTextLinksCanBeHitTested() throws {
        let url = try #require(URL(string: "lamp-lexicon://lookup?key=H1254&reference=1001001"))
        let attributedString = NSMutableAttributedString(
            string: "created the heavens",
            attributes: [.font: NSFont.systemFont(ofSize: 20)]
        )
        attributedString.addAttribute(
            .languageIdentifier,
            value: url.absoluteString,
            range: NSRange(location: 0, length: "created".count)
        )

        let textField = NSTextField(labelWithAttributedString: attributedString)
        textField.frame = NSRect(
            x: 0,
            y: 0,
            width: 300,
            height: textField.intrinsicContentSize.height
        )
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1

        let linkedPoint = NSPoint(x: 4, y: textField.bounds.midY)
        let unlinkedWordPoint = NSPoint(x: 130, y: textField.bounds.midY)
        let unlinkedPoint = NSPoint(x: textField.bounds.maxX - 4, y: textField.bounds.midY)
        #expect(textField.attributedStringValue.attribute(.link, at: 0, effectiveRange: nil) == nil)
        #expect(ReaderTextLinkHitTester.link(at: linkedPoint, in: textField) == url)
        #expect(ReaderTextLinkHitTester.link(at: unlinkedPoint, in: textField) == nil)
        #expect(ReaderTextLinkHitTester.hit(at: linkedPoint, in: textField)?.word == "created")
        let unlinkedWordHit = try #require(
            ReaderTextLinkHitTester.hit(at: unlinkedWordPoint, in: textField)
        )
        #expect(unlinkedWordHit.link == nil)
        #expect(unlinkedWordHit.word == "heavens")
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

    /// A tab is named for where it is until someone names it themselves, and
    /// then it keeps that name wherever it is read on to — which is the point
    /// of naming one.
    @Test func anamedTabKeepsItsNameAsItIsReadOn() {
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        var tabs = ReaderTabCollection(initialLocation: genesis)
        let id = tabs.selectedID

        tabs.rename(id, to: "Sunday Class")
        #expect(tabs.selectedTab?.name == "Sunday Class")

        tabs.updateSelected(location: ReaderLocation(
            translationID: "WEB", bookNumber: 43, chapterNumber: 3
        ))
        #expect(tabs.selectedTab?.name == "Sunday Class", "reading on does not rename it")
    }

    /// Blank is not a name: a tab given one by accident goes back to being
    /// named after its chapter, which is also how the menu clears a name.
    @Test func ablankNameTakesTheNameAway() {
        var tabs = ReaderTabCollection(
            initialLocation: ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        )
        let id = tabs.selectedID
        tabs.rename(id, to: "  Sunday Class  ")
        #expect(tabs.selectedTab?.name == "Sunday Class", "and the spaces around it are not part of it")

        tabs.rename(id, to: "   ")
        #expect(tabs.selectedTab?.name == nil)
        tabs.rename(id, to: "Named again")
        tabs.rename(id, to: nil)
        #expect(tabs.selectedTab?.name == nil)
    }

    /// The copy goes beside the tab it came from, not at the end: "duplicate
    /// this one" means the one pointed at, and a copy that turns up elsewhere
    /// has to be found again.
    @Test func aduplicatedTabOpensBesideItsOriginal() throws {
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        let john = ReaderLocation(translationID: "WEB", bookNumber: 43, chapterNumber: 3)
        var tabs = ReaderTabCollection(initialLocation: genesis)
        let genesisID = tabs.selectedID
        let johnID = tabs.add(location: john)
        tabs.rename(genesisID, to: "Sunday Class")

        let copied = tabs.duplicate(genesisID)

        #expect(copied == genesis)
        #expect(tabs.tabs.count == 3)
        #expect(tabs.tabs.map(\.id).firstIndex(of: johnID) == 2, "the copy went in between")
        let copy = try #require(tabs.tabs.first { $0.id != genesisID && $0.id != johnID })
        #expect(tabs.tabs[1].id == copy.id)
        #expect(copy.location == genesis)
        #expect(copy.name == "Sunday Class", "a copy of a named tab is named too")
        #expect(tabs.selectedID == copy.id, "and it is the one you are now in")
    }

    @Test func duplicatingATabThatIsNotThereChangesNothing() {
        var tabs = ReaderTabCollection(
            initialLocation: ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        )
        let before = tabs

        #expect(tabs.duplicate(UUID()) == nil)
        #expect(tabs == before)
    }

    @Test func readerTabsRoundTripOrderSelectionAndVerseLocations() throws {
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 2, verseReference: 1_002_003)
        let john = ReaderLocation(translationID: "KJV", bookNumber: 43, chapterNumber: 3, verseReference: 43_003_016)
        var tabs = ReaderTabCollection(initialLocation: genesis)
        let firstID = tabs.selectedID
        tabs.add(location: john)
        tabs.select(firstID)

        let restored = try JSONDecoder().decode(ReaderTabCollection.self, from: JSONEncoder().encode(tabs))
        #expect(restored == tabs)
        #expect(restored.tabs.map(\.location) == [genesis, john])
        #expect(restored.selectedID == firstID)
    }

    /// A name is part of the tab, so it comes back with it.
    @Test func anameSurvivesBeingWrittenDownAndReadBack() throws {
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 2)
        var tabs = ReaderTabCollection(initialLocation: genesis)
        tabs.rename(tabs.selectedID, to: "Sunday Class")
        tabs.add(location: ReaderLocation(translationID: "WEB", bookNumber: 43, chapterNumber: 3))

        let restored = try JSONDecoder().decode(
            ReaderTabCollection.self, from: JSONEncoder().encode(tabs)
        )

        #expect(restored.tabs.map(\.name) == ["Sunday Class", nil])
    }

    /// Tabs written by a Lamp that had no names decode as tabs with none,
    /// rather than failing and taking the whole session with them.
    @Test func tabsWrittenBeforeNamesExistedStillOpen() throws {
        let json = Data(#"""
            {"tabs":[{"id":"6B1E4B2E-0A5E-4F3E-9E62-9B1B2C3D4E5F",
            "location":{"translationID":"WEB","bookNumber":1,"chapterNumber":1}}],
            "selectedID":"6B1E4B2E-0A5E-4F3E-9E62-9B1B2C3D4E5F"}
            """#.utf8)

        let restored = try JSONDecoder().decode(ReaderTabCollection.self, from: json)

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs[0].name == nil)
        #expect(restored.tabs[0].location?.bookNumber == 1)
    }

    @Test func readerTabSessionSurvivesRelaunchAndSavesClosedTabs() throws {
        let suite = "reader-tabs-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        let john = ReaderLocation(translationID: "KJV", bookNumber: 43, chapterNumber: 3)
        var tabs = ReaderTabCollection(initialLocation: genesis)
        let firstID = tabs.selectedID
        tabs.add(location: john)
        tabs.close(firstID)
        let session = UUID()
        ReaderTabSessionStore.save(tabs, session: session, defaults: defaults)

        let relaunchedDefaults = try #require(UserDefaults(suiteName: suite))
        let restored = ReaderTabSessionStore.load(
            session: session, resumingLastSession: true, defaults: relaunchedDefaults,
            translationIDs: ["WEB", "KJV"], fallbackLocation: genesis
        )
        #expect(restored == tabs)
        #expect(restored.tabs.count == 1)
        #expect(restored.selectedTab?.location == john)
    }

    @Test func twoWindowsKeepTheirOwnTabsAcrossARelaunch() throws {
        let suite = "reader-tabs-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        let john = ReaderLocation(translationID: "WEB", bookNumber: 43, chapterNumber: 3)
        let window = UUID()
        let otherWindow = UUID()
        let windowTabs = ReaderTabCollection(initialLocation: genesis)
        let otherWindowTabs = ReaderTabCollection(initialLocation: john)
        ReaderTabSessionStore.save(windowTabs, session: window, defaults: defaults)
        // Saved second, so the shared snapshot is this one. Before, that is
        // all either window had to open on, and both opened on John.
        ReaderTabSessionStore.save(otherWindowTabs, session: otherWindow, defaults: defaults)

        #expect(ReaderTabSessionStore.load(
            session: window, resumingLastSession: true, defaults: defaults,
            translationIDs: ["WEB"], fallbackLocation: nil
        ) == windowTabs)
        #expect(ReaderTabSessionStore.load(
            session: otherWindow, resumingLastSession: true, defaults: defaults,
            translationIDs: ["WEB"], fallbackLocation: nil
        ) == otherWindowTabs)
    }

    @Test func aWindowOpenedBesideAnotherStartsAtWhatIsBeingReadAndNotOnItsTabs() throws {
        let suite = "reader-tabs-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        let john = ReaderLocation(translationID: "WEB", bookNumber: 43, chapterNumber: 3)
        var open = ReaderTabCollection(initialLocation: genesis)
        open.add(location: john)
        ReaderTabSessionStore.save(open, session: UUID(), defaults: defaults)

        let second = ReaderTabSessionStore.load(
            session: UUID(), resumingLastSession: false, defaults: defaults,
            translationIDs: ["WEB"], fallbackLocation: genesis
        )
        #expect(second.tabs.count == 1)
        #expect(second.selectedTab?.location == genesis)

        // The first window after a launch does take them up, which is how the
        // tabs saved before this app kept them per window are not lost.
        let first = ReaderTabSessionStore.load(
            session: UUID(), resumingLastSession: true, defaults: defaults,
            translationIDs: ["WEB"], fallbackLocation: genesis
        )
        #expect(first == open)
    }

    @Test func oldSessionsTabsAreForgottenRatherThanKeptForEver() throws {
        let suite = "reader-tabs-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let genesis = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        let oldest = UUID()
        ReaderTabSessionStore.save(
            ReaderTabCollection(initialLocation: genesis), session: oldest, defaults: defaults
        )
        let newest = (0..<ReaderTabSessionStore.keptSessions).map { _ in UUID() }
        for session in newest {
            ReaderTabSessionStore.save(
                ReaderTabCollection(initialLocation: genesis), session: session, defaults: defaults
            )
        }
        #expect(defaults.data(forKey: ReaderTabSessionStore.key(for: oldest)) == nil)
        #expect(defaults.data(forKey: ReaderTabSessionStore.key(for: try #require(newest.first))) != nil)
        #expect(defaults.data(forKey: ReaderTabSessionStore.key(for: try #require(newest.last))) != nil)

        // Saving again moves a session back to the front, so the one in daily
        // use is not forgotten because others were opened around it.
        ReaderTabSessionStore.save(
            ReaderTabCollection(initialLocation: genesis),
            session: try #require(newest.first), defaults: defaults
        )
        ReaderTabSessionStore.save(
            ReaderTabCollection(initialLocation: genesis), session: UUID(), defaults: defaults
        )
        #expect(defaults.data(forKey: ReaderTabSessionStore.key(for: try #require(newest.first))) != nil)
    }

    @Test func removedTranslationsFallBackToAnAvailableTab() {
        let available = ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1)
        let removed = ReaderLocation(translationID: "removed", bookNumber: 43, chapterNumber: 3)
        var tabs = ReaderTabCollection(initialLocation: available)
        let firstID = tabs.selectedID
        tabs.add(location: removed)
        tabs.restoreAvailableLocations(translationIDs: ["WEB"], fallbackLocation: available)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.selectedID == firstID)
        #expect(tabs.selectedTab?.location == available)

        tabs.restoreAvailableLocations(translationIDs: [], fallbackLocation: nil)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.selectedTab != nil)
        #expect(tabs.selectedTab?.location == nil)
    }

    @Test func savedTabDecodingRepairsEmptyDuplicateAndMissingSelections() throws {
        let empty = try JSONDecoder().decode(ReaderTabCollection.self, from: Data(#"{"tabs":[]}"#.utf8))
        #expect(empty.tabs.count == 1)
        #expect(empty.selectedTab != nil)

        let tab = ReaderTab(location: ReaderLocation(translationID: "WEB", bookNumber: 1, chapterNumber: 1))
        let duplicateData = try JSONSerialization.data(withJSONObject: [
            "tabs": try JSONSerialization.jsonObject(with: JSONEncoder().encode([tab, tab])),
            "selectedID": UUID().uuidString,
        ])
        let repaired = try JSONDecoder().decode(ReaderTabCollection.self, from: duplicateData)
        #expect(repaired.tabs == [tab])
        #expect(repaired.selectedID == tab.id)
    }

    @Test func unreadableTabSessionFallsBackToThePreviousReadingLocation() throws {
        let suite = "reader-tabs-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousLocation = ReaderLocation(translationID: "WEB", bookNumber: 19, chapterNumber: 23)
        let session = UUID()
        defaults.set(Data("not JSON".utf8), forKey: ReaderTabSessionStore.key(for: session))
        let restored = ReaderTabSessionStore.load(
            session: session, resumingLastSession: true, defaults: defaults,
            translationIDs: ["WEB"], fallbackLocation: previousLocation
        )
        #expect(restored.tabs.count == 1)
        #expect(restored.selectedTab?.location == previousLocation)
    }

    @Test func normalizesReminderTime() {

        let reminder = ReadingReminderConfiguration(isEnabled: true, hour: 26, minute: -2)
        #expect(reminder.hour == 23)
        #expect(reminder.minute == 0)
        #expect(reminder.dateComponents.hour == 23)
    }

    @Test func parsesDeepLinksAndOpenableDocuments() throws {
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://read?reference=43003016&translation=KJV")))
            == .reader(reference: 43_003_016, translationID: "KJV"))
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://plans"))) == .section(.plans))
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://books"))) == .section(.books))
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://books?module=TEST_BOOK&section=chapter-one")))
            == .book(moduleID: "TEST_BOOK", sectionID: "chapter-one"))
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://reference/john3:16-18")))
            == .reader(reference: 43_003_016, translationID: nil))
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://reading/43003016/43003018?external=1")))
            == .reading(reference: 43_003_016, endReference: 43_003_018,
                        openExternal: true))
        #expect(LampDeepLink(url: try #require(URL(string: "lampbible://strongs/G1234")))
            == .strongs("G1234"))
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
        #expect(DevotionalMarkdownParser.parse("[Prayer](media/audio-id)") == [
            .audio(label: "Prayer", url: try #require(URL(string: "media/audio-id"))),
        ])
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


    @Test func buildsExternalBibleLinks() {
        let start = 43_003_016
        let end = 43_003_018

        // USFM, which is how YouVersion names a book. The others take OSIS.
        #expect(ExternalBibleApplication.youVersion.url(
            startReference: start,
            endReference: end
        )?.absoluteString == "youversion://bible?reference=JHN.3.16-18")
        #expect(ExternalBibleApplication.logos.url(
            startReference: start
        )?.absoluteString == "https://ref.ly/john3:16")
        #expect(ExternalBibleApplication.accordance.url(
            startReference: start,
            endReference: end
        )?.absoluteString == "accord://read/John_3:16-John_3:18")
    }

    // MARK: - Margin marks

    /// Verses 9 and 10 begin on one line, both with notes of their own: the
    /// line shows each kind once, for the first verse with a note of that
    /// kind, so the reader's own goes to verse 10 and the module's to verse 9.
    /// Verse 12, on a later line, keeps its own icon.
    @Test func showsEachKindOfNoteOnceALine() {
        let icons = ReaderMarginMarks.icons(for: [
            (line: 3, note: .init(location: 40, reference: 43014009, kinds: [.module])),
            (line: 3, note: .init(location: 92, reference: 43014010, kinds: [.personal, .module])),
            (line: 5, note: .init(location: 160, reference: 43014012, kinds: [.personal])),
        ])

        #expect(icons == [
            .init(line: 3, kind: .personal, reference: 43014010),
            .init(line: 3, kind: .module, reference: 43014009),
            .init(line: 5, kind: .personal, reference: 43014012),
        ])
    }

    @Test func marksNothingWhenNoVerseIsSelectedOrNoted() {
        #expect(ReaderMarginMarks.none.isEmpty)
        #expect(!ReaderMarginMarks(selectedRange: NSRange(location: 0, length: 4)).isEmpty)
        #expect(ReaderMarginMarks.icons(for: []).isEmpty)
    }

    // MARK: - Side by side

    private func verse(_ number: Int, _ text: String = "text") -> LampVerse {
        LampVerse(id: 40_018_000 + number, number: number, text: text, beginsParagraph: false)
    }

    /// Matthew 18 as the BSB and the WEB have it: the BSB leaves verse 11 out,
    /// so its side of that row is empty and every row after it stays level.
    @Test func pairsVersesByNumberAndKeepsAGapForALeftOutVerse() {
        let rows = ReaderParallelRows.rows(
            main: [verse(10), verse(12), verse(13)],
            companion: [verse(10), verse(11), verse(12), verse(13)]
        )

        #expect(rows.map(\.number) == [10, 11, 12, 13])
        #expect(rows[1].main == nil)
        #expect(rows[1].companion?.number == 11)
        #expect(rows[1].reference == 40_018_011)
        #expect(rows.allSatisfy { $0.number == 11 || $0.main != nil })
    }

    /// The companion can be the one without a verse, or not loaded yet: the
    /// main translation's rows stand on their own.
    @Test func keepsTheMainTranslationsRowsWithoutACompanion() {
        let rows = ReaderParallelRows.rows(main: [verse(1), verse(2)], companion: [])
        #expect(rows.map(\.number) == [1, 2])
        #expect(rows.allSatisfy { $0.companion == nil })

        let extra = ReaderParallelRows.rows(main: [verse(1)], companion: [verse(1), verse(2)])
        #expect(extra.last?.main == nil)
        #expect(extra.last?.companion?.number == 2)
    }

    /// A highlight made in one translation, drawn on another's text, would
    /// colour whatever words its offsets land on there.
    @Test func keepsEachColumnToItsOwnTranslationsHighlights() {
        func highlight(_ id: Int64, _ translation: String, _ reference: Int) -> LampVerseHighlight {
            LampVerseHighlight(
                id: id, setID: "personal-highlights:\(translation)", translationID: translation,
                reference: reference, startOffset: 0, endOffset: 12
            )
        }
        let byVerse = ReaderParallelRows.highlights(
            [highlight(1, "BSBs", 40_018_012), highlight(2, "WEBs", 40_018_012), highlight(3, "WEBs", 40_018_013)],
            of: "WEBs"
        )

        #expect(byVerse[40_018_012]?.map(\.id) == [2])
        #expect(byVerse[40_018_013]?.map(\.id) == [3])
        #expect(byVerse.values.joined().allSatisfy { $0.translationID == "WEBs" })
    }

    /// The WEB ends Romans 14 with the doxology the KJV numbers 16:25-27.
    /// Reading the WEB's Romans 14 beside the KJV, its last three verses sit
    /// beside the KJV's 16:25-27; reading the KJV's Romans 16 beside the WEB,
    /// those verses sit beside the WEB's 14:24-26.
    @Test func pairsAVerseOneTranslationPlacesInAnotherChapter() {
        func romans(_ chapter: Int, _ verse: Int) -> LampVerse {
            LampVerse(id: 45_000_000 + chapter * 1_000 + verse, number: verse, text: "", beginsParagraph: false)
        }
        let webToKJV: (Int) -> Int? = { ref in
            (45_014_024...45_014_026).contains(ref) ? ref - 45_014_024 + 45_016_025 : ref
        }
        let kjvToWEB: (Int) -> Int? = { ref in
            (45_016_025...45_016_027).contains(ref) ? ref - 45_016_025 + 45_014_024 : ref
        }

        let webRomans14 = ReaderParallelRows.rows(
            main: (1...26).map { romans(14, $0) },
            companion: (1...23).map { romans(14, $0) } + (25...27).map { romans(16, $0) },
            mainToCompanion: webToKJV,
            companionToMain: kjvToWEB
        )
        #expect(webRomans14.count == 26)
        #expect(webRomans14.last?.companion?.id == 45_016_027)

        let kjvRomans16 = ReaderParallelRows.rows(
            main: (1...27).map { romans(16, $0) },
            companion: (1...24).map { romans(16, $0) } + (24...26).map { romans(14, $0) },
            mainToCompanion: kjvToWEB,
            companionToMain: webToKJV
        )
        #expect(kjvRomans16.count == 27)
        #expect(kjvRomans16[24].companion?.id == 45_014_024)
        #expect(kjvRomans16.allSatisfy { $0.main != nil })
    }

    /// A psalm whose title the Hebrew numbers as verse 1: read in the Hebrew
    /// numbering beside an English one, the title has no English verse beside
    /// it, and every verse after it pairs with the English verse one lower.
    @Test func pairsAPsalmAcrossTheTitleOneTranslationNumbers() {
        func psalm3(_ verse: Int) -> LampVerse {
            LampVerse(id: 19_003_000 + verse, number: verse, text: "", beginsParagraph: false)
        }
        let rows = ReaderParallelRows.rows(
            main: (1...9).map(psalm3),
            companion: (1...8).map(psalm3),
            mainToCompanion: { $0 == 19_003_001 ? nil : $0 - 1 },
            companionToMain: { $0 + 1 }
        )
        #expect(rows.count == 9)
        #expect(rows[0].companion == nil)
        #expect(rows[1].companion?.number == 1)
        #expect(rows[8].companion?.number == 8)
    }

    /// The bundled Septuagint, read beside an English translation. `LXX` and
    /// `Brenton` declare the `lxx` scheme, which numbers the Psalms one lower
    /// from Psalm 10 to 147 and counts a psalm's title as verse 1: the English
    /// Psalm 22:1 is their 21:2. The verses below are those modules' own text at
    /// those numbers, so this holds the scheme, the conversion and the pairing
    /// to the data that ships.
    @Test func pairsAnEnglishPsalmWithTheSeptuagintsOwnNumbering() {
        let rows = ReaderParallelRows.rows(
            main: [
                psalmVerse(22, 1, "My God, my God, why hast thou forsaken me?"),
                psalmVerse(22, 2, "O my God, I cry in the daytime, but thou hearest not;"),
            ],
            companion: [
                psalmVerse(21, 1, "For the end, concerning the morning aid, a Psalm of David."),
                psalmVerse(21, 2, "O God, my God, attend to me: why hast thou forsaken me?"),
                psalmVerse(21, 3, "O my God, I will cry to thee by day, but thou wilt not hear:"),
            ],
            mainToCompanion: { englishToSeptuagint($0) },
            companionToMain: { septuagintToEnglish($0) }
        )

        #expect(rows.map(\.number) == [0, 1, 2])
        // The title the Septuagint numbers has no English verse beside it.
        #expect(rows[0].main == nil)
        #expect(rows[0].companion?.text.hasPrefix("For the end") == true)
        #expect(rows[1].main?.text.hasPrefix("My God, my God") == true)
        #expect(rows[1].companion?.text.hasPrefix("O God, my God") == true)
        #expect(rows[2].companion?.number == 3)
    }

    /// Neither Septuagint module has a Nehemiah: the Septuagint numbers it
    /// inside Ezra, as chapters 11-23, and the `lxx` scheme maps those chapters
    /// back to Nehemiah. So the English Nehemiah 1 pairs with their Ezra 11,
    /// which is also the chapter the study column must fetch for it.
    @Test func pairsNehemiahWithTheSeptuagintsEzra() {
        func verse(_ book: Int, _ chapter: Int, _ number: Int, _ text: String) -> LampVerse {
            LampVerse(
                id: book * 1_000_000 + chapter * 1_000 + number,
                number: number,
                text: text,
                beginsParagraph: false
            )
        }
        let rows = ReaderParallelRows.rows(
            main: [
                verse(16, 1, 1, "The words of Nehemiah the son of Hachaliah."),
                verse(16, 1, 2, "That Hanani, one of my brethren, came, he and certain men of Judah;"),
            ],
            companion: [
                verse(15, 11, 1, "The words of Neemias the son of Chelcia."),
                verse(15, 11, 2, "And Anani, one of my brethren, came, he and some men of Juda;"),
            ],
            mainToCompanion: { englishToSeptuagint($0) },
            companionToMain: { septuagintToEnglish($0) }
        )

        #expect(rows.map(\.number) == [1, 2])
        #expect(rows[0].companion?.text.hasPrefix("The words of Neemias") == true)
        #expect(rows.allSatisfy { $0.main != nil && $0.companion != nil })
    }

    private func psalmVerse(_ chapter: Int, _ number: Int, _ text: String) -> LampVerse {
        LampVerse(
            id: 19_000_000 + chapter * 1_000 + number,
            number: number,
            text: text,
            beginsParagraph: false
        )
    }

    private func englishToSeptuagint(_ reference: Int) -> Int? {
        LampVersification.standard(.english).convert(
            reference, to: LampVersification.standard(.septuagint)
        )
    }

    private func septuagintToEnglish(_ reference: Int) -> Int? {
        LampVersification.standard(.septuagint).convert(
            reference, to: LampVersification.standard(.english)
        )
    }

    /// Three translations beside the one being read: each column pairs on its
    /// own, and a verse the reading leaves out that two of them have shares
    /// one row.
    @Test func pairsEachOfSeveralCompanionsOnItsOwn() {
        let identity = ReaderParallelCompanion(
            verses: [verse(10), verse(11), verse(12)], fromMain: { $0 }, toMain: { $0 }
        )
        let alsoHasEleven = ReaderParallelCompanion(
            verses: [verse(10), verse(11), verse(12)], fromMain: { $0 }, toMain: { $0 }
        )
        let leavesItOut = ReaderParallelCompanion(
            verses: [verse(10), verse(12)], fromMain: { $0 }, toMain: { $0 }
        )
        let rows = ReaderParallelRows.rows(
            main: [verse(10), verse(12)],
            companions: [identity, alsoHasEleven, leavesItOut]
        )

        #expect(rows.map(\.number) == [10, 11, 12])
        #expect(rows[1].main == nil)
        #expect(rows[1].companions.map { $0?.number } == [11, 11, nil])
        #expect(rows[2].companions.map { $0?.number } == [12, 12, 12])
        #expect(rows.allSatisfy { $0.companions.count == 3 })
    }
}

/// Where a reference typed into the passage picker opens.
///
/// The picker parses what is typed with the search's own parser, which packs
/// a chapter named without verses as running from verse 1 to verse 999. That
/// 999 is the only thing telling "John 3" from "John 3:1".
struct TypedReaderLocationTests {
    private func location(_ typed: String) -> ReaderLocation? {
        guard let reference = LampSearchQuery(typed).reference else { return nil }
        return ReaderLocation.typed(
            reference: reference.startReference,
            through: reference.endReference,
            in: "bsb"
        )
    }

    /// A chapter opens at the top: nothing in it is singled out.
    @Test func aChapterOpensWithNoVerseInMind() {
        let john3 = location("John 3")
        #expect(john3?.bookNumber == 43)
        #expect(john3?.chapterNumber == 3)
        #expect(john3?.verseReference == nil)
    }

    /// A verse is carried, so the reader lands on it rather than at the top
    /// of a chapter the reader has to then look through.
    @Test func aVerseIsCarriedToTheReader() {
        #expect(location("John 3:16")?.verseReference == 43_003_016)
        #expect(location("John 3:16")?.chapterNumber == 3)
    }

    /// A range lands on where it starts.
    @Test func aRangeLandsOnItsFirstVerse() {
        #expect(location("Ps 23:1-4")?.verseReference == 19_023_001)
    }

    /// A range of whole chapters still has no verse in mind: its end is the
    /// 999 a chapter is parsed as running to.
    @Test func aRangeOfChaptersOpensAtTheStartOfTheFirst() {
        let johnThreeToFour = location("John 3-4")
        #expect(johnThreeToFour?.chapterNumber == 3)
        #expect(johnThreeToFour?.verseReference == nil)
    }

    @Test func theTranslationIsTheOneTheFieldWasSetTo() {
        #expect(location("John 3")?.translationID == "bsb")
    }
}

struct ReaderTextMarksTests {
    /// Verses as the reader draws them: each verse's number marked as not
    /// scripture, its words tagged with its verse, and a plain space between.
    private func paragraph(_ verses: [(reference: Int, number: String, words: String)], translation: String? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, verse) in verses.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " ")) }
            var tagged: [NSAttributedString.Key: Any] = [ReaderTextMarks.verse: NSNumber(value: verse.reference)]
            if let translation { tagged[ReaderTextMarks.translation] = translation }
            var number = tagged
            number[ReaderTextMarks.apparatus] = true
            text.append(NSAttributedString(string: verse.number, attributes: number))
            text.append(NSAttributedString(string: " " + verse.words, attributes: tagged))
        }
        return text
    }

    @Test func aSelectionAcrossVersesIsTheirWordsAndTheirReference() throws {
        let text = paragraph([
            (43_003_016, "16", "For God so loved the world."),
            (43_003_017, "17", "For God did not send his Son."),
        ])
        let start = (text.string as NSString).range(of: "loved").location
        let end = NSMaxRange((text.string as NSString).range(of: "send"))
        let passage = try #require(ReaderTextMarks.passage(in: text, range: NSRange(location: start, length: end - start)))
        #expect(passage.text == "loved the world. For God did not send")
        #expect(passage.reference == "John 3:16–17")
        #expect(passage.translationID == nil)
    }

    @Test func noteLettersAreLeftOut() throws {
        let text = NSMutableAttributedString(attributedString: paragraph([(43_003_016, "16", "For God so loved")]))
        let at = (text.string as NSString).range(of: "loved").location
        text.insert(NSAttributedString(string: "a", attributes: [
            ReaderTextMarks.verse: NSNumber(value: 43_003_016), ReaderTextMarks.apparatus: true,
        ]), at: at - 1)
        let passage = try #require(ReaderTextMarks.passage(in: text, range: NSRange(location: 0, length: text.length)))
        #expect(passage.text == "For God so loved")
        #expect(passage.reference == "John 3:16")
    }

    @Test func aCompanionSaysWhichTranslationItIs() throws {
        let text = paragraph([(43_003_016, "16", "Car Dieu a tant aimé le monde")], translation: "LSG")
        let passage = try #require(ReaderTextMarks.passage(in: text, range: NSRange(location: 0, length: text.length)))
        #expect(passage.translationID == "LSG")
    }

    @Test func aSelectionOfNoScriptureIsNone() {
        let text = NSMutableAttributedString(string: "LSG  ")
        text.append(paragraph([(43_003_016, "16", "Car Dieu")]))
        #expect(ReaderTextMarks.passage(in: text, range: NSRange(location: 0, length: 3)) == nil)
        #expect(ReaderTextMarks.passage(in: text, range: NSRange(location: 5, length: 2)) == nil)
        #expect(ReaderTextMarks.passage(in: text, range: NSRange(location: 2, length: 0)) == nil)
    }
}

/// The word study showed each sense's opening twice: a preview cut off with
/// an ellipsis, then the full definition beginning with the same words.
struct DictionarySenseTextTests {
    @Test func previewOfTheDefinitionIsNotShownBesideIt() {
        #expect(!LampDictionarySenseText.showsShortDefinition(
            "Generally, love as in 1 Cor. 4:21, “Shall I come unto you with a rod, or in love,” means full of...",
            beside: "Generally, love as in 1 Cor. 4:21, “Shall I come unto you with a rod, or in love,” means full of love, all love."
        ))
        #expect(!LampDictionarySenseText.showsShortDefinition(
            "Hē agápē toú Theoú, specifically “the love of God.” Here the…",
            beside: "Hē agápē toú Theoú, specifically “the love of God.” Here the gen. is sometimes subj."
        ))
    }

    @Test func identicalTextIsShownOnce() {
        #expect(!LampDictionarySenseText.showsShortDefinition("love", beside: "love"))
        #expect(!LampDictionarySenseText.showsShortDefinition("love,  affection", beside: "love, affection"))
    }

    @Test func aSummaryThatSaysSomethingElseStays() {
        #expect(LampDictionarySenseText.showsShortDefinition("love, goodwill", beside: "From agapáō; affection or benevolence."))
        #expect(LampDictionarySenseText.showsShortDefinition("love", beside: nil))
    }

    @Test func nothingToShowIsNotShown() {
        #expect(!LampDictionarySenseText.showsShortDefinition(nil, beside: "love"))
        #expect(!LampDictionarySenseText.showsShortDefinition("  ", beside: "love"))
        #expect(!LampDictionarySenseText.showsShortDefinition("…", beside: "love"))
    }
}
