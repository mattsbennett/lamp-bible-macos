import Foundation
import Testing
@testable import LampBibleMacSupport

/// Highlighting must never change the code. These hold it to that, and to
/// separating what is said from what is done.
struct CodeHighlightSupportTests {
    private func spans(_ code: String, _ info: String?) -> [LampCodeHighlighter.Span] {
        LampCodeHighlighter.spans(
            in: code,
            language: LampCodeHighlighter.Language(info: info)
        )
    }

    private func rejoined(_ code: String, _ info: String?) -> String {
        spans(code, info).map(\.text).joined()
    }

    @Test(arguments: [
        ("swift", "func greet() { print(\"hi\") } // done"),
        ("python", "def greet():\n    print('hi')  # done"),
        ("json", "{\"a\": 1, \"b\": [true, null]}"),
        ("bash", "echo \"hi\" # done"),
        ("javascript", "const x = `t`; /* c */ let y = 2"),
        (nil, "whatever this is"),
        ("brainfuck", "+++[-]"),
    ])
    func neverChangesACharacter(info: String?, code: String) {
        #expect(rejoined(code, info) == code)
    }

    @Test func separatesWhatIsSaidFromWhatIsDone() {
        let tokens = spans("let x = \"hi\" // note", "swift")
        #expect(tokens.first { $0.text == "let" }?.token == .keyword)
        #expect(tokens.contains { $0.text == "\"hi\"" && $0.token == .string })
        #expect(tokens.contains { $0.text == "// note" && $0.token == .comment })
        // Adjacent runs of one kind are merged, so the identifier is part of a
        // plain span rather than a span of its own.
        #expect(tokens.contains { $0.token == .plain && $0.text.contains("x") })
    }

    @Test func doesNotColourTheTailOfAnIdentifier() {
        // `utf8` is one word, not a word and a number.
        let tokens = spans("String.utf8", "swift")
        #expect(!tokens.contains { $0.token == .number })
    }

    @Test func stopsAnUnterminatedStringAtItsLine() {
        // One stray mark must not colour the rest of the block.
        let tokens = spans("let a = \"oops\nlet b = 2", "swift")
        #expect(tokens.contains { $0.text == "let" && $0.token == .keyword })
        let strings = tokens.filter { $0.token == .string }.map(\.text)
        #expect(strings.allSatisfy { !$0.contains("\n") }, "got \(strings)")
    }

    @Test func leavesAnUnknownLanguageAlone() {
        let tokens = spans("¯\\_(ツ)_/¯ let", "cuneiform")
        #expect(tokens.count == 1)
        #expect(tokens.first?.token == .plain)
    }

    @Test func readsAJsonLiteralButNoComments() {
        let tokens = spans("{\"on\": true} // not a comment in json", "json")
        #expect(tokens.contains { $0.text == "true" && $0.token == .keyword })
        #expect(!tokens.contains { $0.token == .comment })
    }

    // MARK: - Diffs

    @Test func readsAUnifiedDiffLineByLine() {
        let rows = LampDiffHighlighter.rows(in: """
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -1,3 +1,3 @@
         let kept = 1
        -let old = 2
        +let new = 2
        """)
        #expect(rows.map(\.kind) == [
            .meta, .meta, .meta, .meta, .context, .removed, .added,
        ])
    }

    @Test func doesNotMistakeAFileHeaderForAChangedLine() {
        // `---` and `+++` open exactly like a removed and an added line.
        let rows = LampDiffHighlighter.rows(in: "--- a/A.swift\n+++ b/A.swift")
        #expect(rows.allSatisfy { $0.kind == .meta })
    }

    @Test func keepsEveryLineOfTheDiff() {
        let diff = "-one\n+two\n three"
        let rows = LampDiffHighlighter.rows(in: diff)
        #expect(rows.map(\.text).joined(separator: "\n") == diff)
    }
}
