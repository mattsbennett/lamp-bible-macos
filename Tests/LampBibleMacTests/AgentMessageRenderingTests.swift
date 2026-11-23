import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// An agent replies in Markdown. These cover what the chat bubble makes of a
/// whole reply — where it cuts a code panel out of the prose, and that the
/// prose on either side keeps the shape the agent wrote.
///
/// The reading itself is core's, and core's suite holds it to the editor.
/// What is this app's own is the cut: these ask about `Segment`, not about
/// Markdown.
struct AgentMessageRenderingTests {
    @Test func keepsADiffsMarkersOutOfTheList() {
        // Every line of a diff starts with - or +, which a list would claim.
        // The fence has to win, and the whole diff has to stay in the panel.
        let segments = AgentProseText.segments(of: """
        ```diff
        - let total = items.count
        + let total = items.filter(\\.isActive).count
        ```
        """)
        #expect(segments.count == 1)
        guard case .code(let language, let code) = segments[0] else {
            Issue.record("expected one code segment, got \(segments)")
            return
        }
        #expect(language == "diff")
        #expect(code.hasPrefix("- let total"))
        #expect(code.contains("+ let total"))
    }

    @Test func leavesTextWithNoMarkdownAsOneParagraph() {
        let segments = AgentProseText.segments(of: "Just a sentence.")
        guard case .prose(let blocks) = segments.first, segments.count == 1,
              blocks.count == 1, case .paragraph(let text) = blocks[0] else {
            Issue.record("expected one paragraph, got \(segments)")
            return
        }
        #expect(text.plain == "Just a sentence.")
    }

    /// Prose stays prose. Only a fenced block leaves the run, which is the
    /// whole point: an agent's reply is mostly sentences.
    @Test func cutsOnlyTheCodeOutOfAMixedReply() {
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
        let kinds = AgentProseText.segments(of: reply).map { segment -> [String] in
            switch segment {
            case .code: ["code"]
            case .prose(let blocks): blocks.map(kind(of:))
            }
        }
        #expect(kinds == [
            ["paragraph", "heading", "bulletList"],
            ["code"],
            ["table", "quote", "paragraph"],
        ], "got \(kinds)")
    }

    private func kind(of block: LampProseBlock) -> String {
        switch block {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .quote: "quote"
        case .list(let ordered, _, _): ordered ? "numberedList" : "bulletList"
        case .code: "code"
        case .table: "table"
        case .html: "html"
        case .footnote: "footnote"
        case .audio: "audio"
        case .picture: "picture"
        case .rule: "rule"
        }
    }
}
