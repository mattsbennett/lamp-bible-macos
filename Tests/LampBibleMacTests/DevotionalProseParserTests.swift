import Foundation
import Testing
@testable import LampBibleMacSupport

struct DevotionalProseParserTests {
    @Test func nestedListsRetainTheirDepth() {
        let blocks = DevotionalProseParser.parse("""
        - Parent
          - Child
            - Grandchild
        - Sibling
        """)
        #expect(blocks == [.nestedBulletList([
            DevotionalListLine(depth: 0, text: "Parent"),
            DevotionalListLine(depth: 1, text: "Child"),
            DevotionalListLine(depth: 2, text: "Grandchild"),
            DevotionalListLine(depth: 0, text: "Sibling"),
        ])])
    }

    @Test func richDevotionalTablesKeepRowsAndAdjacentProse() {
        let blocks = DevotionalProseParser.parse("""
        Before.

        | Name | Verse |
        | :--- | ---: |
        | Mary | Luke 1:38 |
        | Paul | Acts 9:15 |

        After.
        """)

        #expect(blocks == [
            .paragraph("Before."),
            .table(headers: ["Name", "Verse"], rows: [
                ["Mary", "Luke 1:38"], ["Paul", "Acts 9:15"],
            ]),
            .paragraph("After."),
        ])
    }

    @Test func blankLinesSeparateParagraphs() {
        let blocks = DevotionalProseParser.parse("""
        First paragraph.

        Second paragraph.
        """)

        #expect(blocks == [
            .paragraph("First paragraph."),
            .paragraph("Second paragraph."),
        ])
    }

    @Test func wrappedLinesStayInOneParagraph() {
        // A soft-wrapped source line is not a new paragraph, and joining with a
        // space is what stops "watching,and" appearing in the preview.
        let blocks = DevotionalProseParser.parse("""
        made when nobody
        is watching
        """)

        #expect(blocks == [.paragraph("made when nobody is watching")])
    }

    @Test func headingsCarryTheirLevel() {
        let blocks = DevotionalProseParser.parse("""
        # One
        ## Two
        ###### Six
        """)

        #expect(blocks == [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 6, text: "Six"),
        ])
    }

    @Test func headingsEndTheParagraphBeforeThem() {
        let blocks = DevotionalProseParser.parse("""
        Closing thought.
        ## A New Section
        """)

        #expect(blocks == [
            .paragraph("Closing thought."),
            .heading(level: 2, text: "A New Section"),
        ])
    }

    @Test func hashesWithoutASpaceAreNotHeadings() {
        let blocks = DevotionalProseParser.parse("#faithfulness is a tag")

        #expect(blocks == [.paragraph("#faithfulness is a tag")])
    }

    @Test func sevenHashesAreNotAHeading() {
        let blocks = DevotionalProseParser.parse("####### too deep")

        #expect(blocks == [.paragraph("####### too deep")])
    }

    @Test func quotesCollectTheirLines() {
        let blocks = DevotionalProseParser.parse("""
        > She gave what she had,
        > and it was everything.
        """)

        #expect(blocks == [.quote(["She gave what she had, and it was everything."])])
    }

    @Test func aBlankQuoteLineStartsANewQuoteParagraph() {
        let blocks = DevotionalProseParser.parse("""
        > First line.
        >
        > Second line.
        """)

        #expect(blocks == [.quote(["First line.", "Second line."])])
    }

    @Test func bulletListsGroupTheirItems() {
        let blocks = DevotionalProseParser.parse("""
        - first
        * second
        + third
        """)

        #expect(blocks == [.bulletList(["first", "second", "third"])])
    }

    @Test func numberedListsGroupTheirItems() {
        let blocks = DevotionalProseParser.parse("""
        1. first
        2. second
        3) third
        """)

        #expect(blocks == [.numberedList(["first", "second", "third"])])
    }

    @Test func aListEndsThePrecedingParagraph() {
        let blocks = DevotionalProseParser.parse("""
        Three ordinary places:
        - the conversation
        - the debt
        """)

        #expect(blocks == [
            .paragraph("Three ordinary places:"),
            .bulletList(["the conversation", "the debt"]),
        ])
    }

    @Test func aParagraphAfterAListIsItsOwnBlock() {
        let blocks = DevotionalProseParser.parse("""
        - the conversation
        - the debt

        None of these will be remembered.
        """)

        #expect(blocks == [
            .bulletList(["the conversation", "the debt"]),
            .paragraph("None of these will be remembered."),
        ])
    }

    @Test func bulletAndNumberedListsDoNotMerge() {
        let blocks = DevotionalProseParser.parse("""
        - bulleted
        1. numbered
        """)

        #expect(blocks == [
            .bulletList(["bulleted"]),
            .numberedList(["numbered"]),
        ])
    }

    @Test func horizontalRulesBecomeRules() {
        let blocks = DevotionalProseParser.parse("""
        above

        ---

        below
        """)

        #expect(blocks == [
            .paragraph("above"),
            .rule,
            .paragraph("below"),
        ])
    }

    @Test func emphasisIsLeftForTheInlineRenderer() {
        // Block parsing must not eat inline syntax; AttributedString still needs it.
        let blocks = DevotionalProseParser.parse("the accumulation of **ordinary choices**")

        #expect(blocks == [.paragraph("the accumulation of **ordinary choices**")])
    }

    @Test func aBareDashIsNotAListItem() {
        let blocks = DevotionalProseParser.parse("-")

        #expect(blocks == [.paragraph("-")])
    }

    @Test func emptyProseProducesNoBlocks() {
        #expect(DevotionalProseParser.parse("").isEmpty)
        #expect(DevotionalProseParser.parse("\n\n   \n").isEmpty)
    }

    @Test func aHeadingRestatingTheTitleIsRecognised() {
        #expect(DevotionalHeadingMatch.restatesTitle(
            "The Weight of Small Obedience",
            title: "The Weight of Small Obedience"
        ))
    }

    @Test func caseAndSpacingDoNotMakeTitlesDifferent() {
        #expect(DevotionalHeadingMatch.restatesTitle(
            "  the WEIGHT   of small obedience ",
            title: "The Weight of Small Obedience"
        ))
    }

    @Test func edgePunctuationDoesNotMakeTitlesDifferent() {
        #expect(DevotionalHeadingMatch.restatesTitle(
            "The Weight of Small Obedience:",
            title: "The Weight of Small Obedience"
        ))
    }

    @Test func aDifferentHeadingIsKept() {
        #expect(!DevotionalHeadingMatch.restatesTitle(
            "Three Ordinary Places",
            title: "The Weight of Small Obedience"
        ))
    }

    @Test func aHeadingThatMerelyStartsWithTheTitleIsKept() {
        // Truncating would silently drop the rest of the author's heading.
        #expect(!DevotionalHeadingMatch.restatesTitle(
            "The Weight of Small Obedience in Daily Life",
            title: "The Weight of Small Obedience"
        ))
    }

    @Test func anEmptyHeadingNeverMatches() {
        #expect(!DevotionalHeadingMatch.restatesTitle("", title: ""))
        #expect(!DevotionalHeadingMatch.restatesTitle("   ", title: "Untitled"))
    }

    @Test func aFullDraftKeepsEveryBlockDistinct() {
        // The regression this all exists for: the whole document used to arrive as
        // one run-on paragraph.
        let blocks = DevotionalProseParser.parse("""
        ## The Weight of Small Obedience

        Faithfulness is rarely dramatic.

        > She gave what she had.

        ### Three ordinary places

        - the conversation
        - the debt

        The substance is what is finally weighed.
        """)

        #expect(blocks == [
            .heading(level: 2, text: "The Weight of Small Obedience"),
            .paragraph("Faithfulness is rarely dramatic."),
            .quote(["She gave what she had."]),
            .heading(level: 3, text: "Three ordinary places"),
            .bulletList(["the conversation", "the debt"]),
            .paragraph("The substance is what is finally weighed."),
        ])
    }
}
