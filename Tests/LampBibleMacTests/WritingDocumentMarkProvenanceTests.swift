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
            body.contains("said || agentChatTurn != nil"),
            """
            A mark on a document needs the assistant's own word for it, or a \
            turn open: nothing else writes these files unasked.
            """
        )
        #expect(
            body.contains("declared.contains("),
            """
            The assistant says what it wrote through its own tool hook. Without \
            that, a write whose turn closed before the next poll is never marked, \
            and no rule about what was running can know it happened.
            """
        )
        #expect(
            body.contains("said || !WorkspaceDocumentsTakenIn.shared.tookIn(text, at: path)"),
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

/// What the agent is told of the marks in the documents beside a writing.
///
/// Told of the prose's alone, an agent reads the rest as cleared and
/// rewrites passages the writer has not looked at yet. Told of them
/// without a name, it takes them for the writing's own and looks for
/// those words in a draft that does not hold them.
struct WritingDocumentAgentNoteTests {
    private func review(from old: String, to new: String) -> LampWritingReview {
        LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
    }

    @Test func thenoteNamesTheDocumentEachMarkedPassageIsIn() throws {
        let outline = "One. The flood came suddenly, without warning."
        let notes = "A note the assistant rewrote completely here."
        let note = try #require(WritingChatTurns.documentReviewNotes([
            (
                name: "outline.md",
                review: review(from: "One. The flood came.", to: outline),
                text: outline, known: []
            ),
            (
                name: "notes.md",
                review: review(from: "A note.", to: notes),
                text: notes, known: []
            ),
        ]))
        #expect(note.contains("In outline.md, these are still marked as not yet read:"))
        #expect(note.contains("In notes.md, these are still marked as not yet read:"))
        #expect(note.contains("suddenly, without warning"))
        // By name, so one turn's note reads in the same order as the next.
        let outlineAt = try #require(note.range(of: "In outline.md"))
        let notesAt = try #require(note.range(of: "In notes.md"))
        #expect(notesAt.lowerBound < outlineAt.lowerBound)
    }

    /// Nothing is said of a writing whose documents are all clear, rather
    /// than a line saying so for each: the prose's note already tells the
    /// agent what the marks mean.
    @Test func adocumentWithNothingMarkedIsNotMentioned() {
        let text = "Nothing here was changed by anyone."
        #expect(WritingChatTurns.documentReviewNotes([
            (name: "outline.md", review: LampWritingReview(writingID: "w"), text: text, known: [])
        ]) == nil)
    }

    /// A mark whose words the writer has since rewritten is carried before
    /// it is said, as the prose's are, so the agent is never given a
    /// passage it cannot find.
    @Test func amarkIsCarriedIntoTheTextBeforeItIsSaid() throws {
        let marked = "One. The flood came suddenly, without warning."
        let typed = "One. The flood came suddenly, without any warning at all."
        let note = try #require(WritingChatTurns.documentReviewNotes([
            (
                name: "outline.md",
                review: review(from: "One. The flood came.", to: marked),
                text: typed, known: [marked]
            )
        ]))
        let quoted = note.components(separatedBy: "\"")
        for passage in quoted.enumerated().filter({ $0.offset % 2 == 1 }).map(\.element) {
            #expect(typed.contains(passage), "The agent is given \"\(passage)\", which is not in the file")
        }
    }
}

/// The assistant saying which files it wrote, through its own tool hook.
struct AgentDeclaredWritesTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("declared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func leave(_ payload: [String: Any], in workspace: URL) throws {
        let directory = AgentTerminalLaunchPlanner.wroteDirectory(in: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload).write(
            to: directory.appendingPathComponent("wrote.\(UUID().uuidString).json")
        )
    }

    @Test func apathTheAssistantWroteIsReadBackOnce() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("outline.md")
        try leave(["tool_name": "Write", "tool_input": ["file_path": file.path]], in: root)

        #expect(AgentDeclaredWrites.take(in: root) == [file.standardizedFileURL.path])
        // Taken away as it is read: one write is answered once, or every
        // later poll would mark the file again.
        #expect(AgentDeclaredWrites.take(in: root).isEmpty)
    }

    /// A payload that is not what was expected is passed over rather than
    /// taken for a write: the fallback marks less, never wrongly.
    @Test func apayloadWithNoPathSaysNothing() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try leave(["tool_name": "Bash", "tool_input": ["command": "ls"]], in: root)
        #expect(AgentDeclaredWrites.take(in: root).isEmpty)
    }

    @Test func aworkspaceTheAssistantNeverWroteInSaysNothing() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentDeclaredWrites.take(in: root).isEmpty)
    }

    /// The hook is installed for the CLI that documents it, on the tools
    /// that write files, and never stops a turn.
    @Test func thehookIsInstalledForTheToolsThatWriteFiles() throws {
        let settings = try JSONSerialization.jsonObject(
            with: AgentTerminalLaunchPlanner.claudeSettings()
        ) as? [String: Any]
        let hooks = try #require(settings?["hooks"] as? [String: Any])
        let wrote = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(wrote.first?["matcher"] as? String == "Write|Edit|NotebookEdit")
        let command = try #require(
            (wrote.first?["hooks"] as? [[String: String]])?.first?["command"]
        )
        #expect(command.hasSuffix("exit 0"), "A hook that fails must not be what stops a turn")
        #expect(command.contains("LAMP_CAPTURE_DIR"))
    }
}
