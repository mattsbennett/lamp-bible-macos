import Foundation
import Testing
@testable import LampBibleMacSupport

struct WritingPreviewPlacementTests {
    @Test func togglingSwapsBetweenWritingAndReading() {
        #expect(WritingPreviewPlacement.hidden.toggled() == .split)
        #expect(WritingPreviewPlacement.split.toggled() == .hidden)
        #expect(WritingPreviewPlacement.full.toggled() == .hidden)
    }

    @Test func cyclingMovesBetweenTheTwoVisiblePlacements() {
        #expect(WritingPreviewPlacement.split.cycledPlacement() == .full)
        #expect(WritingPreviewPlacement.full.cycledPlacement() == .split)
    }

    @Test func cyclingFromHiddenOpensTheFullPreview() {
        // Asking for the other placement while nothing is shown should show
        // something, rather than being a no-op the user cannot see.
        #expect(WritingPreviewPlacement.hidden.cycledPlacement() == .full)
    }

    @Test func onlyHiddenIsInvisible() {
        #expect(!WritingPreviewPlacement.hidden.isVisible)
        #expect(WritingPreviewPlacement.split.isVisible)
        #expect(WritingPreviewPlacement.full.isVisible)
    }

    @Test func anEmptyDraftNeverOpensIntoAFullWidthPreview() {
        // Otherwise a remembered full-width placement greets a new devotional with
        // a window full of nothing and no visible place to type.
        #expect(WritingPreviewPlacement.full.opening(hasContent: false) == .split)
    }

    @Test func aDraftWithContentOpensWhereItWasLeft() {
        #expect(WritingPreviewPlacement.full.opening(hasContent: true) == .full)
    }

    @Test func theOtherPlacementsOpenUnchangedWhateverTheContent() {
        for hasContent in [true, false] {
            #expect(WritingPreviewPlacement.hidden.opening(hasContent: hasContent) == .hidden)
            #expect(WritingPreviewPlacement.split.opening(hasContent: hasContent) == .split)
        }
    }

    @Test func placementsRoundTripThroughTheirStoredValue() {
        for placement in WritingPreviewPlacement.allCases {
            #expect(WritingPreviewPlacement(rawValue: placement.rawValue) == placement)
        }
    }
}

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

struct ProportionalScrollSyncTests {
    @Test func fractionMeasuresTravelThroughTheScrollableRange() {
        let fraction = ProportionalScrollSync.fraction(
            offset: 250,
            contentHeight: 1_000,
            viewportHeight: 500
        )

        #expect(fraction == 0.5)
    }

    @Test func aPaneWithNothingToScrollSitsAtTheTop() {
        let fraction = ProportionalScrollSync.fraction(
            offset: 0,
            contentHeight: 400,
            viewportHeight: 500
        )

        #expect(fraction == 0)
    }

    @Test func fractionsStayInsideTheirBounds() {
        let overscrolled = ProportionalScrollSync.fraction(
            offset: 900,
            contentHeight: 1_000,
            viewportHeight: 500
        )
        let rubberBanded = ProportionalScrollSync.fraction(
            offset: -40,
            contentHeight: 1_000,
            viewportHeight: 500
        )

        #expect(overscrolled == 1)
        #expect(rubberBanded == 0)
    }

    @Test func offsetMirrorsAFractionIntoADifferentlySizedPane() {
        // The rendered pane is twice as tall as the source it mirrors; half way
        // through one is half way through the other.
        let offset = ProportionalScrollSync.offset(
            fraction: 0.5,
            contentHeight: 3_000,
            viewportHeight: 500
        )

        #expect(offset == 1_250)
    }

    @Test func mirroringIntoAPaneWithNothingToScrollStaysAtTheTop() {
        let offset = ProportionalScrollSync.offset(
            fraction: 0.8,
            contentHeight: 300,
            viewportHeight: 500
        )

        #expect(offset == 0)
    }

    @Test func fractionAndOffsetAreInverses() {
        let fraction = ProportionalScrollSync.fraction(
            offset: 320,
            contentHeight: 1_800,
            viewportHeight: 600
        )
        let restored = ProportionalScrollSync.offset(
            fraction: fraction,
            contentHeight: 1_800,
            viewportHeight: 600
        )

        #expect(abs(restored - 320) < 0.000_1)
    }

    @Test func theFirstReportedPositionIsAlwaysActedOn() {
        #expect(ProportionalScrollSync.isSignificantChange(
            from: nil,
            to: 0,
            scrollableHeight: 2_000
        ))
    }

    @Test func subPixelDriftIsIgnored() {
        // 0.0001 of a 2000pt range is a fifth of a point — invisible, and enough
        // to make the two panes chase each other if acted on.
        #expect(!ProportionalScrollSync.isSignificantChange(
            from: 0.5,
            to: 0.500_1,
            scrollableHeight: 2_000
        ))
    }

    @Test func visibleTravelIsActedOn() {
        #expect(ProportionalScrollSync.isSignificantChange(
            from: 0.5,
            to: 0.52,
            scrollableHeight: 2_000
        ))
    }

    @Test func nothingIsSignificantInAPaneThatCannotScroll() {
        #expect(!ProportionalScrollSync.isSignificantChange(
            from: 0.2,
            to: 0.9,
            scrollableHeight: 0
        ))
    }
}
