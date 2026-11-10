import Foundation
import Testing
@testable import LampBibleMacSupport

/// What the ⌘K palette ranks first for what was typed, and the links it uses.
struct CommandPaletteSupportTests {
    @Test func aTitleThatStartsWithTheQueryRanksFirst() throws {
        let start = try #require(CommandPaletteMatch.score("new", title: "New Writing"))
        let word = try #require(CommandPaletteMatch.score("writ", title: "New Writing"))
        let inside = try #require(CommandPaletteMatch.score("riti", title: "New Writing"))
        let letters = try #require(CommandPaletteMatch.score("nwr", title: "New Writing"))
        #expect(start > word)
        #expect(word > inside)
        #expect(inside > letters)
    }

    @Test func caseAndAccentsAreFolded() {
        #expect(CommandPaletteMatch.score("genese", title: "Genèse") != nil)
        #expect(CommandPaletteMatch.score("BOOKS", title: "Books") == 1)
    }

    @Test func keywordsCountForLessThanTheTitle() throws {
        let keyword = try #require(CommandPaletteMatch.score(
            "line spacing", title: "Reader", keywords: ["Text Size", "Line Spacing"]
        ))
        let title = try #require(CommandPaletteMatch.score("line spacing", title: "Line Spacing"))
        #expect(keyword < title)
    }

    @Test func somethingUnrelatedIsNotOffered() {
        #expect(CommandPaletteMatch.score("zzz", title: "New Writing") == nil)
        #expect(CommandPaletteMatch.score("", title: "New Writing") == nil)
        #expect(CommandPaletteMatch.score("x", title: "Books") == nil)
    }

    @Test func macLinksRoundTrip() {
        let links: [LampMacLink] = [
            .writing("personal-devotionals:abc 1"), .plan("p1"), .quiz("q"), .deck("d"), .analysis("G26"),
        ]
        for link in links {
            #expect(LampMacLink(url: link.url) == link)
        }
    }

    @Test func otherLinksAreLeftToCore() {
        #expect(LampMacLink(url: URL(string: "lampbible://verse/43003016")!) == nil)
        #expect(LampMacLink(url: URL(string: "lampbible://writing")!) == nil)
        #expect(LampMacLink(url: URL(string: "https://writing/abc")!) == nil)
    }
}

@Suite struct CommandPaletteSnippetTests {
    @Test func aShortSnippetIsLeftAlone() {
        #expect(CommandPaletteSnippet.clipped("by <mark>grace</mark> you", maxVisible: 90) == "by <mark>grace</mark> you")
    }

    @Test func aLongSnippetIsCutAtASpaceOutsideAMarkWithAPlainEllipsis() {
        let marked = "But if it is by <mark>grace</mark>, it is no longer on the basis of works. Otherwise <mark>grace</mark> would no longer be <mark>grace</mark>."
        let clipped = CommandPaletteSnippet.clipped(marked, maxVisible: 60)
        #expect(clipped.hasSuffix("…"))
        #expect(!clipped.hasSuffix("</mark>…"))
        #expect(clipped.hasPrefix("But if it is by <mark>grace</mark>"))
        let visible = clipped.replacingOccurrences(of: "<mark>", with: "").replacingOccurrences(of: "</mark>", with: "")
        #expect(visible.count <= 61)
        // Tags stay paired.
        #expect(clipped.components(separatedBy: "<mark>").count == clipped.components(separatedBy: "</mark>").count)
    }

    @Test func aSnippetThatRepeatsTheTitleLosesIt() {
        let marked = "Saul the Pharisee Becomes the Apostle of <mark>Grace</mark> The apostles continued"
        #expect(CommandPaletteSnippet.clipped(marked, droppingLeading: "Saul the Pharisee Becomes the Apostle of Grace")
                == "The apostles continued")
        #expect(CommandPaletteSnippet.clipped("By <mark>grace</mark> alone", droppingLeading: "Romans 11:6")
                == "By <mark>grace</mark> alone")
    }

    @Test func aFoundWordPastTheCutIsBroughtIntoView() {
        let marked = String(repeating: "word ", count: 40) + "the <mark>apostle</mark> of grace"
        let clipped = CommandPaletteSnippet.clipped(marked, maxVisible: 60)
        #expect(clipped.hasPrefix("…"))
        #expect(clipped.contains("<mark>apostle</mark>"))
    }
}
