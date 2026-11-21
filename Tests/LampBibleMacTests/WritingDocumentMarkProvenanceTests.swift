import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMac
@testable import LampBibleMacSupport

/// What may be marked as the assistant's in a document beside a writing.
///
/// The editor's poll sees only that a document changed under it. The
/// assistant writing one and the writer's own edits arriving from their
/// phone look exactly alike there, and a mark is a claim about who wrote
/// the words: marking a sentence the writer wrote on the train is a lie
/// they then have to clear.
///
/// The writing's own prose is not decided this way. The reconciler proves
/// the assistant wrote a draft from the note and marker it left, which is
/// proof; this is the best that can be shown about a file in a folder.
struct WritingDocumentMarkProvenanceTests {
    /// A pass says which bodies it installed, by content. Content rather
    /// than a time, because the pass and the poll are not in step: a slow
    /// pass's write would look like a fast agent's.
    @Test func apassesOwnBodyIsKnownAsItsOwnHoweverLateItIsLookedFor() {
        let taken = WorkspaceDocumentsTakenIn.shared
        let path = "Workspaces/Writing/test-\(UUID().uuidString)/Documents/outline.md"
        let fromThePhone = "An outline the writer typed on their phone."

        #expect(taken.tookIn(fromThePhone, at: path) == false)
        taken.tookIn(Data(fromThePhone.utf8), at: path)
        #expect(taken.tookIn(fromThePhone, at: path))
        // Anything else is not the pass's, however close in time.
        #expect(taken.tookIn("Something the assistant wrote.", at: path) == false)
    }

    /// Several of the pass's bodies are remembered, so a poll that fell
    /// behind two of its writes still knows the older one.
    @Test func apollThatFellBehindStillKnowsTheEarlierBody() {
        let taken = WorkspaceDocumentsTakenIn.shared
        let path = "Workspaces/Writing/test-\(UUID().uuidString)/Documents/outline.md"
        for n in 1...4 { taken.tookIn(Data("body \(n)".utf8), at: path) }
        #expect(taken.tookIn("body 1", at: path))
        #expect(taken.tookIn("body 4", at: path))
    }

    /// One document's bodies are never another's.
    @Test func onedocumentsBodiesAreNeverAnothers() {
        let taken = WorkspaceDocumentsTakenIn.shared
        let folder = "Workspaces/Writing/test-\(UUID().uuidString)/Documents"
        taken.tookIn(Data("shared text".utf8), at: "\(folder)/outline.md")
        #expect(taken.tookIn("shared text", at: "\(folder)/outline.md"))
        #expect(taken.tookIn("shared text", at: "\(folder)/notes.md") == false)
    }

    /// The rule itself, read from the source: a mark is made only where a
    /// turn is open and the body is not one a pass installed.
    ///
    /// Read rather than driven because the decision is inside a SwiftUI
    /// view, which no test can reach. Taking either condition out would
    /// otherwise leave a green build and mark the writer's own words.
    @Test func themarkingRequiresATurnAndAbodyNoPassInstalled() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMac/Library/DevotionalEditorView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "private func markAssistantChange("))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]

        #expect(
            body.contains("let turnID = agentChatTurn"),
            """
            A mark on a document is the assistant's only while a turn is open: \
            nothing else writes these files unasked.
            """
        )
        #expect(
            body.contains("!WorkspaceDocumentsTakenIn.shared.tookIn(text, at: path)"),
            """
            A body a sync pass installed is the writer's own edits arriving from \
            another device, and marking it would call their words the assistant's.
            """
        )
        #expect(
            body.contains("reviewDocumentName(of: document)"),
            "Only the writing's own documents are marked, by the name they sync under."
        )
    }

    /// Every branch of the poll that takes an external change into a
    /// document also offers it for marking. One that did not would leave
    /// the assistant's writing unmarked in that case alone, which is the
    /// kind of gap a green build says nothing about.
    @Test func everyExternalChangeThePollTakesInIsOfferedForMarking() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMac/Library/DevotionalEditorView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "private func refreshWorkspaceDocuments()"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])

        let recorded = body.components(separatedBy: "externalRevisions(for: document, after:").count - 1
        let marked = body.components(separatedBy: "marking.append((document,").count - 1
        #expect(recorded > 0)
        #expect(
            marked == recorded,
            """
            \(recorded) branches record an external change to a document and \
            \(marked) offer it for marking. A change worth a revision is a change \
            the assistant may have made.
            """
        )
    }
}
