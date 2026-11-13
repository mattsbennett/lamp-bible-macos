import AppKit
import LampBibleMacSupport
import LampCore
import Testing
@testable import LampBibleMac

/// The commentary pane's text, as one string for a chapter. The scroll link
/// finds each passage by where its heading begins, so those places have to
/// be exact, and the links and order have to match what the pane drew when
/// it was a stack of views.
struct CommentaryDocumentTests {
    private let style = CommentaryTextStyle(fontSize: 15, lineSpacing: 4, typeface: .serif)

    private func unit(
        _ id: String,
        start: Int,
        end: Int? = nil,
        order: Int,
        title: String? = nil,
        commentary: String? = nil,
        footnotes: String? = nil,
        links: [LampScriptureLink] = []
    ) -> LampCommentaryUnit {
        LampCommentaryUnit(
            unitID: id, moduleID: "NIC", moduleName: "NIC", bookNumber: 45, chapterNumber: 8,
            startReference: start, endReference: end, unitType: "block", level: 2,
            title: title, commentary: commentary, footnotes: footnotes,
            scriptureLinks: links, orderIndex: order
        )
    }

    @Test func eachPassageIsFoundWhereItsHeadingBegins() {
        let units = [
            unit("c", start: 45_008_005, order: 3, commentary: "Flesh and Spirit."),
            unit("a", start: 45_008_001, end: 45_008_004, order: 1, title: "Opening discussion"),
            unit("b", start: 45_008_001, end: 45_008_004, order: 2, commentary: "No condemnation."),
        ]
        let document = CommentaryDocument.build(title: "Romans 8", units: units, style: style)
        let string = document.text.string as NSString

        #expect(document.anchors.map(\.reference) == [45_008_001, 45_008_005])
        #expect(document.anchors.first?.endReference == 45_008_004)
        let headings = document.anchorLocations.map {
            string.substring(with: string.paragraphRange(for: NSRange(location: $0, length: 0)))
                .trimmingCharacters(in: .newlines)
        }
        #expect(headings == ["ROMANS 8:1–4", "ROMANS 8:5"])
        // Units in their order, a heading with nothing under it as the outline.
        #expect(string.range(of: "Opening discussion").location < string.range(of: "No condemnation.").location)
        #expect(string.range(of: "No condemnation.").location < string.range(of: "Flesh and Spirit.").location)
        #expect(document.text.attribute(.lampCommentaryIcon, at: string.range(of: "Opening discussion").location, effectiveRange: nil) is CommentaryIcon)

        // The top of the pane, inside a passage's comment, is that passage.
        #expect(document.anchorIndex(containing: 0) == 0)
        #expect(document.anchorIndex(containing: string.range(of: "No condemnation.").location) == 0)
        #expect(document.anchorIndex(containing: string.range(of: "Flesh and Spirit.").location) == 1)
    }

    /// A reference is linked where its words appear and not where they are
    /// already a link; one whose words appear nowhere is set after the unit.
    @Test func referencesAreLinkedInTheTextOrAfterIt() throws {
        let inText = LampScriptureLink(text: "Rom 8:3", startReference: 45_008_003, endReference: nil)
        let again = LampScriptureLink(text: "gal 5:17", startReference: 48_005_017, endReference: nil)
        let nowhere = LampScriptureLink(text: "Gen 1:1", startReference: 1_001_001, endReference: nil)
        let document = CommentaryDocument.build(title: "Romans 8", units: [
            unit("a", start: 45_008_001, order: 1,
                 commentary: "See Rom 8:3, and Gal 5:17.", links: [inText, again, nowhere]),
        ], style: style)
        let string = document.text.string as NSString

        let first = string.range(of: "Rom 8:3")
        let link = try #require(document.text.attribute(.link, at: first.location, effectiveRange: nil) as? URL)
        #expect(LampScriptureLink(previewURL: link)?.startReference == 45_008_003)
        // Found again in any case, as the pane always matched.
        let second = string.range(of: "Gal 5:17")
        #expect(document.text.attribute(.link, at: second.location, effectiveRange: nil) != nil)
        // Not found in the text, so kept as a trailing link.
        let trailing = string.range(of: "(Gen 1:1)")
        #expect(trailing.location != NSNotFound)
        #expect(document.text.attribute(.link, at: trailing.location + 1, effectiveRange: nil) != nil)
    }

    /// Commentary quoting Hebrew at a paragraph's start would otherwise take
    /// a right-to-left base direction and turn its references round.
    @Test func everyParagraphIsLeftToRight() {
        let document = CommentaryDocument.build(title: "Psalms 22", units: [
            unit("a", start: 19_022_001, order: 1, commentary: "אֵלִי (Ps 22:1)\nMy God."),
        ], style: style)
        var directions = Set<NSWritingDirection>()
        document.text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.text.length)) { value, _, _ in
            if let paragraph = value as? NSParagraphStyle { directions.insert(paragraph.baseWritingDirection) }
        }
        #expect(directions == [.leftToRight])
    }
}
