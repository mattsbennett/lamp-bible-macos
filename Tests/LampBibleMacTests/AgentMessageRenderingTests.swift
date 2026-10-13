import Foundation
import Testing
@testable import LampBibleMacSupport

/// An agent replies in Markdown. These cover the parsing the chat bubble now
/// does, and in particular that moving agent replies out of a plain-text
/// message kind did not cost the transcript its words.
struct AgentMessageRenderingTests {
    @Test func readsATypicalAgentReply() {
        let reply = """
        Here is what I changed:

        - renamed the helper
        - added a test

        ```swift
        func greet() {
            print("hello")
        }
        ```

        Let me know if that reads right.
        """
        let blocks = DevotionalProseParser.parse(reply)
        #expect(blocks.count == 4)
        guard case .codeBlock(let language, let code) = blocks[2] else {
            Issue.record("expected a fenced block, got \(blocks[2])")
            return
        }
        #expect(language == "swift")
        #expect(code.contains("    print(\"hello\")"), "indentation is the content")
    }

    @Test func keepsADiffsMarkersOutOfTheListParser() {
        // Every line of a diff starts with - or +, which a list parser would
        // claim. The fence has to win.
        let blocks = DevotionalProseParser.parse("""
        ```diff
        - let total = items.count
        + let total = items.filter(\\.isActive).count
        ```
        """)
        #expect(blocks.count == 1)
        guard case .codeBlock(let language, let code) = blocks[0] else {
            Issue.record("expected one fenced block, got \(blocks)")
            return
        }
        #expect(language == "diff")
        #expect(code.hasPrefix("- let total"))
        #expect(code.contains("+ let total"))
    }

    @Test func leavesTextWithNoMarkdownAsOneParagraph() {
        let blocks = DevotionalProseParser.parse("Just a sentence.")
        #expect(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0] else {
            Issue.record("expected a paragraph, got \(blocks)")
            return
        }
        #expect(text == "Just a sentence.")
    }

    /// Prose stays prose. Only a fenced block becomes code, which is the whole
    /// point: an agent's reply is mostly sentences.
    @Test func classifiesAMixedReplyBlockByBlock() {
        let reply = """
        I renamed the helper and added a test.

        ## What changed

        - `greet()` is now `welcome()`
        - the test covers the empty case

        ```swift
        func welcome() { print("hi") }
        ```

        | File | Lines |
        | --- | --- |
        | Greeter.swift | 12 |

        > Worth noting: the old name is still referenced in the README.

        Let me know if that reads right.
        """
        let kinds = DevotionalProseParser.parse(reply).map { block -> String in
            switch block {
            case .heading: "heading"
            case .paragraph: "paragraph"
            case .quote: "quote"
            case .bulletList, .nestedBulletList: "bulletList"
            case .numberedList, .nestedNumberedList: "numberedList"
            case .table: "table"
            case .codeBlock: "codeBlock"
            case .rule: "rule"
            }
        }
        #expect(kinds == [
            "paragraph", "heading", "bulletList", "codeBlock",
            "table", "quote", "paragraph",
        ], "got \(kinds)")
        // One block of seven is code; the rest are drawn as ordinary text.
        #expect(kinds.filter { $0 == "codeBlock" }.count == 1)
    }
}
