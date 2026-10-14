import Foundation
import Testing

/// The agent pane polls its workspace from a `.task(id:)` loop that outlives
/// every redraw. That closure holds the view struct as it was when the pane
/// opened: `@State` read through it stays live, because it goes via SwiftUI's
/// own storage, but a plain `let` keeps whatever it was handed and never
/// changes again.
///
/// `draftMarkdown` is one of those `let`s. Resolving a manuscript-following
/// deck's speaker notes against it meant that editing the writing and then
/// letting a deck import land rewrote the notes from the draft as it stood
/// when the pane opened — undoing the correct notes saved moments earlier.
/// Nothing short of relaunching the app cleared it.
///
/// Anything the loop reaches must therefore take the draft from the workspace
/// or from `@State`, never from the property.
struct WorkspacePollingFreshnessTests {
    private var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LampBibleMac/Library/DevotionalAgentWorkspaceView.swift"
                )
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The body of `private func <name>`, by brace matching.
    private func body(of name: String, in source: String) throws -> String {
        let signature = try #require(
            source.range(of: "private func \(name)("),
            "\(name) is gone — this guard needs updating, not deleting"
        )
        let open = try #require(source.range(of: "{", range: signature.upperBound..<source.endIndex))
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        Issue.record("Could not find the end of \(name)")
        return ""
    }

    /// Everything the 400ms poll calls, directly or one level down.
    private let reachedByThePoll = [
        "refreshWorkspace",
        "refreshWorkspaceMetadata",
        "importPresentationArtifactIfNeeded",
        "resolveManuscriptNotes",
        "collectTerminalTurns",
        "manuscript",
    ]

    @Test func thePollingLoopNeverReadsTheFrozenDraftProperty() throws {
        let source = try source
        for function in reachedByThePoll {
            let body = try body(of: function, in: source)
            // The helper's documentation names the property it exists to avoid.
            let code = body
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(
                !code.contains("draftMarkdown"),
                """
                \(function) is reached by the polling task, where `draftMarkdown` \
                is frozen at whatever it was when the pane opened. Read the draft \
                from the workspace, or from @State, instead.
                """
            )
        }
    }

    /// The draft is taken from the file both sides write, so it is current
    /// whichever of them changed it last.
    @Test func theManuscriptIsReadFromTheWorkspace() throws {
        let body = try body(of: "manuscript", in: try source)
        #expect(body.contains("DevotionalAgentWorkspaceStore.readDraft"))
    }

}
