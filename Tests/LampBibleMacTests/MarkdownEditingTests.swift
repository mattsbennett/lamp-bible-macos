import Foundation
import Testing
@testable import LampBibleMacSupport

struct MarkdownEditingTests {
    @Test func wrappingASelectionKeepsItSelected() {
        let result = MarkdownEditor.toggleWrap(
            "**",
            in: "In the beginning",
            selection: NSRange(location: 7, length: 9)
        )

        #expect(result.text == "In the **beginning**")
        #expect(result.selection == NSRange(location: 7, length: 13))
    }

    @Test func wrappingTwiceUndoesItself() {
        let once = MarkdownEditor.toggleWrap(
            "**",
            in: "In the beginning",
            selection: NSRange(location: 7, length: 9)
        )
        let twice = MarkdownEditor.toggleWrap("**", in: once.text, selection: once.selection)

        #expect(twice.text == "In the beginning")
        #expect(twice.selection == NSRange(location: 7, length: 9))
    }

    @Test func unwrappingWorksFromInsideTheMarkers() {
        // Caret placed around the word itself, with the markers just outside it.
        let result = MarkdownEditor.toggleWrap(
            "**",
            in: "In the **beginning**",
            selection: NSRange(location: 9, length: 9)
        )

        #expect(result.text == "In the beginning")
        #expect(result.selection == NSRange(location: 7, length: 9))
    }

    @Test func wrappingAnEmptySelectionLeavesTheCaretBetweenTheMarkers() {
        let result = MarkdownEditor.toggleWrap(
            "_",
            in: "Write here",
            selection: NSRange(location: 6, length: 0)
        )

        #expect(result.text == "Write __here")
        #expect(result.selection == NSRange(location: 7, length: 0))
    }

    @Test func prefixingAppliesToEveryLineTheSelectionTouches() {
        let text = "First line\nSecond line\nThird line"
        // Selection starts inside line one and ends inside line two.
        let result = MarkdownEditor.togglePrefix(
            "> ",
            in: text,
            selection: NSRange(location: 3, length: 12)
        )

        #expect(result.text == "> First line\n> Second line\nThird line")
    }

    @Test func prefixingTwiceRemovesIt() {
        let text = "First line\nSecond line"
        let once = MarkdownEditor.togglePrefix("- ", in: text, selection: NSRange(location: 0, length: 22))
        let twice = MarkdownEditor.togglePrefix("- ", in: once.text, selection: once.selection)

        #expect(once.text == "- First line\n- Second line")
        #expect(twice.text == text)
    }

    @Test func prefixingSkipsBlankLinesAndStillTogglesOff() {
        let text = "One\n\nTwo"
        let once = MarkdownEditor.togglePrefix("## ", in: text, selection: NSRange(location: 0, length: 8))

        // The blank line stays blank rather than becoming a stray empty heading.
        #expect(once.text == "## One\n\n## Two")

        let twice = MarkdownEditor.togglePrefix("## ", in: once.text, selection: once.selection)
        #expect(twice.text == text)
    }

    @Test func insertingOnItsOwnLineAddsOnlyTheBreaksItNeeds() {
        let midParagraph = MarkdownEditor.insert(
            "![photo](lamp-media://x/y.png)",
            in: "Before after",
            selection: NSRange(location: 6, length: 0),
            onOwnLine: true
        )
        #expect(midParagraph.text == "Before\n![photo](lamp-media://x/y.png)\n after")

        // Already at the start of a line: no leading break is added.
        let atLineStart = MarkdownEditor.insert(
            "![photo](x)",
            in: "Before\nafter",
            selection: NSRange(location: 7, length: 0),
            onOwnLine: true
        )
        #expect(atLineStart.text == "Before\n![photo](x)\nafter")
    }

    @Test func insertingReplacesTheSelectionAndLeavesTheCaretAfterIt() {
        let result = MarkdownEditor.insert(
            "[John 3:16](lampbible://read?reference=43003016)",
            in: "See here for more",
            selection: NSRange(location: 4, length: 4),
            onOwnLine: false
        )

        #expect(result.text == "See [John 3:16](lampbible://read?reference=43003016) for more")
        // Caret lands just past the inserted link, before " for more".
        #expect(result.selection == NSRange(location: 52, length: 0))
    }

    @Test func commandsOnAnOutOfRangeSelectionChangeNothing() {
        let text = "Short"
        let selection = NSRange(location: 40, length: 5)

        #expect(MarkdownEditor.toggleWrap("**", in: text, selection: selection).text == text)
        #expect(MarkdownEditor.togglePrefix("- ", in: text, selection: selection).text == text)
        #expect(MarkdownEditor.insert("x", in: text, selection: selection).text == text)
    }
}
