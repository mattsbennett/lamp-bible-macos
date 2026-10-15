import AppKit
import Foundation
import Testing
@testable import LampBibleMacSupport

struct AgentProseTextTests {
    private let reply = """
    ## Gideon's call

    He is threshing **wheat** in a *winepress*, hiding from Midian.

    - The angel greets him
    - Gideon asks for a sign

    > Surely I will be with thee.

    | Verse | Theme |
    | --- | --- |
    | 6:12 | Greeting |
    | 6:16 | Presence |

    ```swift
    print("code")
    ```

    After the code.
    """

    @Test func codeBlocksSplitTheReplyIntoProseRuns() {
        let segments = AgentProseText.segments(of: reply)
        #expect(segments.count == 3)
        guard case .prose = segments[0], case .code(let language, let code) = segments[1], case .prose = segments[2] else {
            Issue.record("unexpected segments: \(segments)"); return
        }
        #expect(language == "swift")
        #expect(code.contains("print"))
    }

    @Test func everyWordIsKeptInOrderAsOneSelectableText() throws {
        guard case .prose(let blocks) = AgentProseText.segments(of: reply).first else {
            Issue.record("no prose"); return
        }
        let text = AgentProseText.attributedString(for: blocks).string
        let expected = ["Gideon's call", "threshing wheat in a winepress", "•\tThe angel greets him",
                        "•\tGideon asks for a sign", "Surely I will be with thee.", "Verse", "Theme",
                        "6:12", "Greeting", "6:16", "Presence"]
        var cursor = text.startIndex
        for piece in expected {
            let found = try #require(text.range(of: piece, range: cursor..<text.endIndex), "missing or out of order: \(piece)")
            cursor = found.upperBound
        }
        // The Markdown markers themselves are not shown.
        #expect(!text.contains("**") && !text.contains("##") && !text.contains("|"))
        #expect(!text.hasSuffix("\n"))
    }

    @Test func emphasisLinksAndCodeKeepTheirStyle() throws {
        let line = AgentProseText.inline(
            "Read **this**, *that*, `code` and [the reader](lamp://read/43003016).",
            font: .systemFont(ofSize: 13),
            color: .labelColor
        )
        let text = line.string as NSString
        func font(at word: String) -> NSFont? {
            line.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as? NSFont
        }
        #expect(font(at: "this")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(at: "that")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(font(at: "code")?.isFixedPitch == true)
        let link = line.attribute(.link, at: text.range(of: "the reader").location, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "lamp://read/43003016")
    }

    @Test func tablesAreRealTableCells() throws {
        let text = AgentProseText.attributedString(for: [.table(headers: ["A", "B"], rows: [["1", "2"]])])
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try #require(style.textBlocks.first as? NSTextTableBlock)
        #expect(cell.table.numberOfColumns == 2)
    }
}

extension AgentProseTextTests {
    private func prose(_ markdown: String) throws -> NSAttributedString {
        guard case .prose(let blocks) = AgentProseText.segments(of: markdown).first else {
            throw CancellationError()
        }
        return AgentProseText.attributedString(for: blocks)
    }

    @Test func copiedTablesAreTabSeparatedRows() throws {
        let text = try prose("> Quoted.\n\n| Verse | Theme |\n| --- | --- |\n| 6:12 | |\n| 6:16 | Presence |\n\nAfter.")
        let all = AgentProseText.plainText(of: text, in: NSRange(location: 0, length: text.length))
        // The spacing line between the quote and the table isn't copied.
        #expect(all == "Quoted.\nVerse\tTheme\n6:12\t\n6:16\tPresence\nAfter.")
    }

    @Test func copiedListMarkersAreFollowedByASpace() throws {
        let text = try prose("- One\n- Two\n  - Under two")
        let all = AgentProseText.plainText(of: text, in: NSRange(location: 0, length: text.length))
        #expect(all == "• One\n• Two\n  • Under two")
    }

    @Test func aPartialSelectionCopiesOnlyWhatIsSelected() throws {
        let text = try prose("First paragraph.\n\nSecond paragraph.")
        let string = text.string as NSString
        let start = string.range(of: "paragraph.").location
        let end = NSMaxRange(string.range(of: "Second"))
        let copied = AgentProseText.plainText(of: text, in: NSRange(location: start, length: end - start))
        #expect(copied == "paragraph.\nSecond")
    }
}

extension AgentProseTextTests {
    @Test func quoteBarsFollowLightAndDarkMode() throws {
        let text = try prose("> Quoted.")
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let bar = try #require(style.textBlocks.first?.borderColor(for: .minX))
        func brightness(in name: NSAppearance.Name) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                value = bar.usingColorSpace(.deviceRGB)!.brightnessComponent
            }
            return value
        }
        #expect(brightness(in: .aqua) < 0.5)
        #expect(brightness(in: .darkAqua) > 0.5)
    }
}
