import LampCore
import Testing
@testable import LampBibleMac

/// What the reading card draws, given what core reads.
///
/// The card used to read a writing's blocks itself, and disagreed with the
/// editor the writer types into on 77 of 138 real writings — 1,225
/// paragraphs, 506 bullet lists, 245 ordered lists. It now draws core's
/// reading. This holds the step between the two: core gives a tree, this
/// view draws lines carrying a depth, and the flattening is where that can
/// go wrong without any other test noticing.
struct ReadingCardBlocksTests {
    private func blocks(_ markdown: String, lineBreaks: Bool = false) -> [RenderedProseBlock] {
        var numbering = RunNumbering()
        return RenderedProseBlock.all(
            LampProse.blocks(markdown, options: .init(lineBreaks: lineBreaks)),
            numbering: &numbering
        )
    }

    @Test func aparagraphArrivesWithItsEmphasisAlreadyRead() {
        guard case .paragraph(let item)? = blocks("Jesus draws **two** lessons.").first
        else { return #expect(Bool(false), "no paragraph") }
        #expect(item.plain == "Jesus draws two lessons.")
        let bold = item.attributed?.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold != nil, "the emphasis core read did not reach the card")
    }

    /// A wrapped item is one item, where reading it here cut the list into
    /// one list per item.
    @Test func awrappedItemStaysOneItem() {
        guard case .numberedList(let items)? = blocks(
            "1. first item that wraps\n   onto a second line\n2. second"
        ).first else { return #expect(Bool(false), "no numbered list") }
        #expect(items.count == 2)
        #expect(items.first?.plain == "first item that wraps onto a second line")
    }

    /// Nesting is the tree's own: a four-space level is one step in, where
    /// dividing the indent by two drew it as two.
    @Test func nestingIsOneStepPerLevel() {
        guard case .nestedBulletList(let lines)? = blocks("- outer\n    - inner").first
        else { return #expect(Bool(false), "no nested list") }
        #expect(lines.map(\.depth) == [0, 1])
        #expect(lines.map(\.text.plain) == ["outer", "inner"])
    }

    /// A list that begins at 3 is still a list; its number is the writer's.
    @Test func adeeperTreeKeepsEveryLine() {
        guard case .nestedBulletList(let lines)? = blocks(
            "- one\n    - two\n        - three\n- four"
        ).first else { return #expect(Bool(false), "no nested list") }
        #expect(lines.map(\.depth) == [0, 1, 2, 0])
        #expect(lines.map(\.text.plain) == ["one", "two", "three", "four"])
    }

    /// A quote keeps the breaks the editor keeps between two quoted lines.
    @Test func aquoteKeepsItsLines() {
        guard case .quote(let items)? = blocks("> She gave what she had,\n> and it was everything.").first
        else { return #expect(Bool(false), "no quote") }
        #expect(items.count == 1)
        #expect(items.first?.plain.contains("\n") == true)
    }

    /// A note's typed lines are the writer's, which is the setting the note
    /// editor runs with.
    @Test func anotesLinesAreKept() {
        guard case .paragraph(let item)? = blocks("Grace\nMercy\nPeace", lineBreaks: true).first
        else { return #expect(Bool(false), "no paragraph") }
        #expect(item.plain == "Grace\nMercy\nPeace")
    }

    /// The same text as a writing joins, as the editor joins it.
    @Test func awritingsSoftWrapsJoin() {
        guard case .paragraph(let item)? = blocks("Grace\nMercy\nPeace").first
        else { return #expect(Bool(false), "no paragraph") }
        #expect(item.plain == "Grace Mercy Peace")
    }

    /// A fence is kept as it was written, and opens nothing.
    @Test func afenceIsKeptVerbatim() {
        guard case .codeBlock(let language, let code)? = blocks(
            "```swift\n# not a heading\nlet x = 1\n```"
        ).first else { return #expect(Bool(false), "no code block") }
        #expect(language == "swift")
        #expect(code == "# not a heading\nlet x = 1")
    }

    /// A table's cells arrive read, headers and rows alike.
    @Test func atablesCellsAreRead() {
        guard case .table(let headers, let rows)? = blocks(
            "intro\n\n| Lesson | Where |\n| --- | --- |\n| Not knowing | Matthew 24:36 |"
        ).last else { return #expect(Bool(false), "no table") }
        #expect(headers.map(\.plain) == ["Lesson", "Where"])
        #expect(rows.map { $0.map(\.plain) } == [["Not knowing", "Matthew 24:36"]])
    }

    /// Every run the card draws is numbered once, in reading order: find
    /// uses those numbers to say which run a match is in.
    @Test func everyRunIsNumberedOnceInOrder() {
        var numbering = RunNumbering()
        let rendered = RenderedProseBlock.all(
            LampProse.blocks("# Title\n\nFirst.\n\n- one\n- two\n\n> quoted"),
            numbering: &numbering
        )
        let ids = rendered.flatMap(\.runs).map(\.id)
        #expect(ids == Array(0..<ids.count), "run numbers are \(ids)")
    }

    /// Nothing the writer wrote is dropped on the way through.
    @Test func nothingIsDropped() {
        let rendered = blocks("# Title\n\nProse.\n\n- item\n\n> quote\n\n---\n\n`code`")
        let kinds = rendered.map { block -> String in
            switch block {
            case .heading: "heading"
            case .paragraph: "paragraph"
            case .quote: "quote"
            case .bulletList, .nestedBulletList: "bullet"
            case .numberedList, .nestedNumberedList: "ordered"
            case .table: "table"
            case .codeBlock: "code"
            case .rule: "rule"
            }
        }
        #expect(kinds == ["heading", "paragraph", "bullet", "quote", "rule", "paragraph"])
    }
}
