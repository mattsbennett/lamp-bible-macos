import Foundation
import Testing
@testable import LampBibleMacSupport

struct WritingStatisticsTests {
    @Test func countsPlainProse() {
        let statistics = WritingStatistics.measuring(markdown: "The Lord is my shepherd")

        #expect(statistics.wordCount == 5)
    }

    @Test func emphasisDoesNotChangeTheWordCount() {
        let plain = WritingStatistics.measuring(markdown: "grace and peace to you")
        let emphasised = WritingStatistics.measuring(markdown: "**grace** and _peace_ to you")

        #expect(emphasised.wordCount == plain.wordCount)
    }

    @Test func headingAndQuoteMarkersAreNotWords() {
        let statistics = WritingStatistics.measuring(markdown: """
        ## A Call to Endurance

        > Consider it pure joy
        """)

        #expect(statistics.wordCount == 8)
    }

    @Test func listBulletsAreNotWords() {
        let statistics = WritingStatistics.measuring(markdown: """
        - first point
        - second point
        """)

        #expect(statistics.wordCount == 4)
    }

    @Test func linkLabelsCountButTheirTargetsDoNot() {
        let statistics = WritingStatistics.measuring(
            markdown: "See [Romans 15:4](lampbible://read?reference=45015004) today"
        )

        // "See", "Romans", "15:4", "today"
        #expect(statistics.wordCount == 4)
    }

    @Test func imagesContributeNoWords() {
        let statistics = WritingStatistics.measuring(
            markdown: "![a photograph of the hills](lamp-media://abc/hills.png)"
        )

        #expect(statistics.wordCount == 0)
    }

    @Test func horizontalRulesContributeNoWords() {
        let statistics = WritingStatistics.measuring(markdown: """
        one

        ---

        two
        """)

        #expect(statistics.wordCount == 2)
    }

    @Test func anEmptyDraftReportsNothingToRead() {
        let statistics = WritingStatistics.measuring(markdown: "   \n\n  ")

        #expect(statistics.wordCount == 0)
        #expect(statistics.readingMinutes == 0)
        #expect(statistics.readingTimeDescription == "—")
    }

    @Test func shortWritingStillRoundsUpToAMinute() {
        let statistics = WritingStatistics(wordCount: 12, characterCount: 60)

        #expect(statistics.readingMinutes == 1)
        #expect(statistics.readingTimeDescription == "1 min read")
    }

    @Test func readingTimeFollowsTheWordCount() {
        let statistics = WritingStatistics(wordCount: 2_000, characterCount: 10_000)

        #expect(statistics.readingMinutes == 10)
        #expect(statistics.readingTimeDescription == "10 min read")
    }

    /// A talk is written to be spoken: the same words take half as long again
    /// out loud, so one figure cannot answer both questions.
    @Test func readingAloudTakesLongerThanReadingSilently() {
        let statistics = WritingStatistics(wordCount: 2_000, characterCount: 10_000)

        #expect(statistics.readingMinutes(mode: .silent) == 10)
        #expect(statistics.readingTimeDescription(mode: .silent) == "10 min read")
        #expect(statistics.readingMinutes(mode: .aloud) == 15)
        #expect(statistics.readingTimeDescription(mode: .aloud) == "15 min aloud")
    }

    @Test func followsTheRateSetForThatPace() {
        let statistics = WritingStatistics(wordCount: 1_200, characterCount: 6_000)

        #expect(statistics.readingTimeDescription(mode: .aloud, wordsPerMinute: 120) == "10 min aloud")
        #expect(statistics.readingTimeDescription(mode: .aloud, wordsPerMinute: 60) == "20 min aloud")
        // A rate from an older version or another device must not divide by
        // zero or turn the estimate negative.
        #expect(statistics.readingTimeDescription(mode: .silent, wordsPerMinute: 0) == "1200 min read")
    }

    @Test func eachPaceKeepsItsOwnRateAndFallsBackToSilent() {
        #expect(LampReadingMode.silent.wordsPerMinuteKey == "writing.wordsPerMinute.silent")
        #expect(LampReadingMode.aloud.wordsPerMinuteKey == "writing.wordsPerMinute.aloud")
        #expect(LampReadingMode.silent.wordsPerMinuteKey != LampReadingMode.aloud.wordsPerMinuteKey)

        #expect(LampReadingMode(storedValue: "aloud") == .aloud)
        #expect(LampReadingMode(storedValue: nil) == .silent)
        #expect(LampReadingMode(storedValue: "shouted") == .silent)
    }

    @Test func anEmptyDraftReportsNothingAtEitherPace() {
        let statistics = WritingStatistics(wordCount: 0, characterCount: 0)

        #expect(statistics.readingTimeDescription(mode: .aloud) == "—")
        #expect(statistics.readingMinutes(mode: .aloud) == 0)
    }

    @Test func snippetsStripMarkdownSyntax() {
        let snippet = WritingStatistics.snippet(from: """
        ## The Weight of Small Obedience

        Faithfulness is rarely **dramatic**.
        """)

        #expect(snippet == "The Weight of Small Obedience Faithfulness is rarely dramatic.")
    }

    @Test func snippetsCollapseBlankLinesRatherThanShowingGaps() {
        let snippet = WritingStatistics.snippet(from: "one\n\n\ntwo")

        #expect(snippet == "one two")
    }

    @Test func snippetsClipOnAWordBoundary() {
        let snippet = WritingStatistics.snippet(
            from: "alpha bravo charlie delta echo",
            limit: 14
        )

        // 14 characters lands mid-"charlie"; the break moves back to the space.
        #expect(snippet == "alpha bravo…")
    }

    @Test func shortSnippetsAreNotClipped() {
        let snippet = WritingStatistics.snippet(from: "a short line", limit: 160)

        #expect(snippet == "a short line")
        #expect(!snippet.hasSuffix("…"))
    }

    @Test func anEmptyDraftHasNoSnippet() {
        #expect(WritingStatistics.snippet(from: "   \n\n").isEmpty)
    }

    @Test func plainTextDropsLinkTargetsButKeepsLabels() {
        let text = WritingStatistics.plainText(
            from: "See [Romans 15](lampbible://read?reference=45015001) now"
        )

        #expect(text == "See Romans 15 now")
    }

    @Test func wordCountDescriptionIsSingularForOneWord() {
        #expect(WritingStatistics(wordCount: 1, characterCount: 4).wordCountDescription == "1 word")
        #expect(WritingStatistics(wordCount: 2, characterCount: 8).wordCountDescription == "2 words")
    }
}
