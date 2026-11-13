import Foundation
import LampBibleMacSupport
import Testing

/// A reader chat carried into a new writing: copied once, one way, and
/// written only into the writing's own workspace.
struct ReaderChatWritingCopyTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writing-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func said(
        _ turn: UUID, _ at: Double, _ role: AgentChatTranscript.Role, _ text: String
    ) -> AgentChatTranscript.Event {
        AgentChatTranscript.Event(
            // A question is stored under its turn's own id, as the chat
            // records it.
            id: role == .user ? turn : UUID(),
            turn: turn, date: Date(timeIntervalSince1970: at),
            kind: AgentChatTranscript.Event.said, role: role, text: text
        )
    }

    /// A reader chat with two turns, on Claude, with a session of its own.
    private func chat(in library: URL) throws -> (id: UUID, first: UUID, second: UUID) {
        let id = UUID(), first = UUID(), second = UUID()
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: id)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(
                conversationID: UUID(), sessionID: "session-1", sessionInstallID: "install-1",
                events: [
                    said(first, 10, .user, "Who wrote Hebrews?"),
                    said(first, 11, .assistant, "Nobody knows."),
                    said(second, 20, .user, "And Priscilla?"),
                    said(second, 21, .assistant, "Harnack thought so."),
                ]
            ),
            providerID: "claude", in: workspace
        )
        var choices = AgentChatChoices()
        choices.set("claude", for: AgentChatChoices.providerKey)
        choices.set("opus", for: "model")
        try AgentChatChoicesStore.save(choices, in: workspace)
        return (id, first, second)
    }

    @Test func theWholeConversationGoesIntoTheWritingsOwnWorkspace() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)
        let sourceWorkspace = ReaderChatWorkspaceStore.workspaceURL(
            libraryRootURL: library, chatID: source.id
        )
        let before = try Data(contentsOf: AgentChatTranscriptStore.url(
            providerID: "claude", in: sourceWorkspace
        ))

        let copied = try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: nil, providerID: "claude",
            libraryRootURL: library, writingID: "W-1",
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(copied)

        let writing = LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-1")
        let transcript = AgentChatTranscriptStore.load(providerID: "claude", in: writing)
        #expect(transcript.turns.compactMap(\.question) == ["Who wrote Hebrews?", "And Priscilla?"])
        #expect(transcript.messages.map(\.text) == [
            "Who wrote Hebrews?", "Nobody knows.", "And Priscilla?", "Harnack thought so.",
        ])
        #expect(transcript.sessionID == nil, "a provider session cannot be in two conversations")

        // The mark comes last and names the chat it came from.
        let mark = try #require(transcript.events?.last)
        #expect(mark.kind == ReaderChatWritingCopy.copiedEventKind)
        #expect(mark.name == source.id.uuidString)
        #expect(mark.date == Date(timeIntervalSince1970: 100))
        #expect(transcript.turns.last?.question == nil, "the mark is not a question")

        // The chat's own choices come with it, so the writing's chat opens on
        // the provider the conversation was had with.
        let choices = AgentChatChoicesStore.load(in: writing)
        #expect(choices.value(for: AgentChatChoices.providerKey) == "claude")
        #expect(choices.value(for: "model") == "opus")

        // The reader chat is not touched, byte for byte.
        let after = try Data(contentsOf: AgentChatTranscriptStore.url(
            providerID: "claude", in: sourceWorkspace
        ))
        #expect(before == after)
        #expect(
            AgentChatTranscriptStore.load(providerID: "claude", in: writing).conversationID
                != AgentChatTranscriptStore.load(providerID: "claude", in: sourceWorkspace).conversationID,
            "a conversation of its own"
        )
    }

    @Test func upToATurnLeavesTheRestBehind() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)

        try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: source.first, providerID: "claude",
            libraryRootURL: library, writingID: "W-2"
        )
        let transcript = AgentChatTranscriptStore.load(
            providerID: "claude",
            in: LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-2")
        )
        #expect(transcript.messages.map(\.text) == ["Who wrote Hebrews?", "Nobody knows."])
    }

    /// What the reader undid in the chat stays undone in the copy.
    @Test func anUndoneTurnDoesNotComeAcross() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: source.id)
        let trimmed = AgentChatTranscriptStore.load(providerID: "claude", in: workspace)
            .removing(turns: [source.second], at: Date(timeIntervalSince1970: 30))
        try AgentChatTranscriptStore.save(trimmed, providerID: "claude", in: workspace)

        try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: nil, providerID: "claude",
            libraryRootURL: library, writingID: "W-3"
        )
        let transcript = AgentChatTranscriptStore.load(
            providerID: "claude",
            in: LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-3")
        )
        #expect(transcript.messages.map(\.text) == ["Who wrote Hebrews?", "Nobody knows."])
    }

    /// The mark is drawn where it falls in the conversation's order, so it
    /// must sort after every copied event even when a clock disagrees.
    @Test func theMarkFollowsATurnDatedAfterTheCopy() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)

        try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: nil, providerID: "claude",
            libraryRootURL: library, writingID: "W-4",
            now: Date(timeIntervalSince1970: 5)
        )
        let transcript = AgentChatTranscriptStore.load(
            providerID: "claude",
            in: LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-4")
        )
        #expect(transcript.turns.last?.events.first?.kind == ReaderChatWritingCopy.copiedEventKind)
        #expect(transcript.turns.map(\.id).count == 3)
    }

    @Test func aChatWithNothingSaidCopiesNothing() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let id = UUID()
        try FileManager.default.createDirectory(
            at: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: id),
            withIntermediateDirectories: true
        )

        #expect(try ReaderChatWritingCopy.copy(
            chat: id, upTo: nil, providerID: "claude", libraryRootURL: library, writingID: "W-5"
        ) == false)
        #expect(!FileManager.default.fileExists(
            atPath: LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-5").path
        ))
        let source = try chat(in: library)
        #expect(try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: UUID(), providerID: "claude",
            libraryRootURL: library, writingID: "W-5"
        ) == false, "a turn the conversation does not have")
    }

    /// Only the provider being copied: the chat's other conversation stays.
    @Test func anotherProvidersConversationStaysBehind() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)
        let other = UUID()
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(conversationID: UUID(), events: [said(other, 40, .user, "Codex here")]),
            providerID: "codex",
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: source.id)
        )

        try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: nil, providerID: "claude",
            libraryRootURL: library, writingID: "W-6"
        )
        let writing = LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-6")
        #expect(AgentChatTranscriptStore.load(providerID: "codex", in: writing).messages.isEmpty)
    }

    @Test func aWritingThatAlreadyHasAConversationIsNotCopiedOver() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)
        let writing = LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-7")
        let mine = UUID()
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(conversationID: UUID(), events: [said(mine, 1, .user, "Mine")]),
            providerID: "claude", in: writing
        )

        #expect(throws: ReaderChatWritingCopy.CopyError.writingHasAConversation) {
            try ReaderChatWritingCopy.copy(
                chat: source.id, upTo: nil, providerID: "claude",
                libraryRootURL: library, writingID: "W-7"
            )
        }
        #expect(AgentChatTranscriptStore.load(providerID: "claude", in: writing).turns.compactMap(\.question) == ["Mine"])
    }

    /// A transcript written before events keeps each message as a turn of
    /// its own, so the answer is the turn after its question. The copy must
    /// end after the answer, not at the question.
    @Test func anOlderTranscriptKeepsItsLastAnswer() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let id = UUID()
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: id)
        let question = UUID(), second = UUID()
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(messages: [
                .init(id: question, role: .user, text: "Who wrote Hebrews?", date: Date(timeIntervalSince1970: 10)),
                .init(role: .assistant, text: "Nobody knows.", date: Date(timeIntervalSince1970: 11)),
                .init(id: second, role: .user, text: "And Priscilla?", date: Date(timeIntervalSince1970: 20)),
                .init(role: .assistant, text: "Harnack thought so.", date: Date(timeIntervalSince1970: 21)),
            ]),
            providerID: "claude", in: workspace
        )

        try ReaderChatWritingCopy.copy(
            chat: id, upTo: nil, providerID: "claude", libraryRootURL: library, writingID: "L-1"
        )
        try ReaderChatWritingCopy.copy(
            chat: id, upTo: question, providerID: "claude", libraryRootURL: library, writingID: "L-2"
        )
        func texts(_ writing: String) -> [String] {
            AgentChatTranscriptStore.load(
                providerID: "claude",
                in: LampWritingWorkspace.url(libraryRootURL: library, writingID: writing)
            ).messages.map(\.text)
        }
        #expect(texts("L-1") == ["Who wrote Hebrews?", "Nobody knows.", "And Priscilla?", "Harnack thought so."])
        #expect(texts("L-2") == ["Who wrote Hebrews?", "Nobody knows."], "the answer to the chosen question comes too")
    }

    /// A start interrupted after its copy is finished by the next attempt,
    /// not refused by its own first half.
    @Test func copyingTheSameChatAgainIsTheSameCopy() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)
        let writing = LampWritingWorkspace.url(libraryRootURL: library, writingID: "W-8")

        try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: nil, providerID: "claude", libraryRootURL: library, writingID: "W-8"
        )
        let first = try Data(contentsOf: AgentChatTranscriptStore.url(providerID: "claude", in: writing))
        try FileManager.default.removeItem(at: AgentChatChoicesStore.url(in: writing))

        #expect(try ReaderChatWritingCopy.copy(
            chat: source.id, upTo: nil, providerID: "claude", libraryRootURL: library, writingID: "W-8"
        ))
        #expect(try Data(contentsOf: AgentChatTranscriptStore.url(providerID: "claude", in: writing)) == first)
        #expect(
            AgentChatChoicesStore.load(in: writing).value(for: AgentChatChoices.providerKey) == "claude",
            "and what the first attempt did not finish is finished"
        )

        // A copy of a different chat is still not a copy of this one.
        let other = try chat(in: library)
        #expect(throws: ReaderChatWritingCopy.CopyError.writingHasAConversation) {
            try ReaderChatWritingCopy.copy(
                chat: other.id, upTo: nil, providerID: "claude", libraryRootURL: library, writingID: "W-8"
            )
        }
    }

    /// A writing asked for from inside a reply waits for the reply to be on
    /// disk — the transcript written after the request — and one from an
    /// earlier run of Lamp waits for nothing.
    @Test func aRequestWaitsForTheReplyThatMadeIt() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)
        let written = Date()
        func ready(asked: Date, running: Bool = false, launched: Date = .distantPast) -> Bool {
            ReaderChatWritingCopy.isReady(
                askedAt: asked, chat: source.id, providerID: "claude", libraryRootURL: library,
                isRunning: running, launchedAt: launched
            )
        }
        #expect(ready(asked: written.addingTimeInterval(-60)), "written after it was asked")
        #expect(!ready(asked: written.addingTimeInterval(60)), "nothing written since")
        #expect(!ready(asked: written.addingTimeInterval(-60), running: true), "not while a reply is arriving")
        #expect(
            ready(asked: written.addingTimeInterval(60), launched: written.addingTimeInterval(120)),
            "asked in an earlier run, which nothing will finish"
        )
        #expect(!ReaderChatWritingCopy.isReady(
            askedAt: written.addingTimeInterval(-60), chat: source.id, providerID: "codex",
            libraryRootURL: library, isRunning: false, launchedAt: .distantPast
        ), "a provider with no transcript has not answered")
    }

    /// A request is copied up to the turn that asked, so one taken in late
    /// does not carry what was said after; and not at all from a
    /// conversation cleared since.
    @Test func aRequestIsCopiedUpToTheTurnThatAskedIt() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let source = try chat(in: library)
        func asking(_ seconds: Double) -> (turn: UUID?, replaced: Bool) {
            ReaderChatWritingCopy.requestingTurn(
                askedAt: Date(timeIntervalSince1970: seconds), chat: source.id,
                providerID: "claude", libraryRootURL: library
            )
        }
        #expect(asking(10.5).turn == source.first)
        #expect(asking(20.5).turn == source.second)
        #expect(asking(10.5).replaced == false)

        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: source.id)
        var cleared = AgentChatTranscriptStore.load(providerID: "claude", in: workspace)
        cleared.startedAt = Date(timeIntervalSince1970: 50)
        try AgentChatTranscriptStore.save(cleared, providerID: "claude", in: workspace)
        #expect(asking(20.5).replaced, "the conversation that asked is gone")
        #expect(asking(60).replaced == false)
    }

    @Test func aChatRemembersTheWritingsStartedFromIt() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let id = UUID()
        #expect(ReaderChatWritingCopy.started(chat: id, libraryRootURL: library).isEmpty)

        try ReaderChatWritingCopy.recordStarted(
            .init(writingID: "B", title: "Second", startedAt: Date(timeIntervalSince1970: 20)),
            chat: id, libraryRootURL: library
        )
        try ReaderChatWritingCopy.recordStarted(
            .init(writingID: "A", title: "First", startedAt: Date(timeIntervalSince1970: 10)),
            chat: id, libraryRootURL: library
        )
        try ReaderChatWritingCopy.recordStarted(
            .init(writingID: "B", title: "Second, renamed", startedAt: Date(timeIntervalSince1970: 20)),
            chat: id, libraryRootURL: library
        )
        let started = ReaderChatWritingCopy.started(chat: id, libraryRootURL: library)
        #expect(started.map(\.writingID) == ["A", "B"], "oldest first, once each")
        #expect(started.last?.title == "Second, renamed")

        // Beside the transcript, where sync does not carry it: a reader chat
        // is this Mac's own.
        let record = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: id)
            .appendingPathComponent(".lamp/started-writings.json")
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(!AgentChatTranscriptStore.isTranscriptFilename(record.lastPathComponent))
    }
}

/// Writings an agent asked for, left for Lamp to start.
struct LampWritingStartsTests {
    private func support() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writing-starts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aRequestIsWrittenDownReadBackAndForgotten() throws {
        let root = try support()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = UUID()
        try LampWritingStarts.write(
            .init(id: "later", title: "Later", askedAt: Date(timeIntervalSince1970: 20)),
            inApplicationSupport: root
        )
        try LampWritingStarts.write(
            .init(
                id: "sooner", title: "Sooner", category: "study", draft: "# Sooner",
                readerChatID: chat, askedAt: Date(timeIntervalSince1970: 10)
            ),
            inApplicationSupport: root
        )

        let waiting = LampWritingStarts.pending(inApplicationSupport: root)
        #expect(waiting.map(\.id) == ["sooner", "later"], "in the order asked for")
        #expect(waiting.first?.readerChatID == chat)
        #expect(waiting.first?.draft == "# Sooner")
        #expect(waiting.last?.readerChatID == nil)

        LampWritingStarts.forget(id: "sooner", inApplicationSupport: root)
        #expect(LampWritingStarts.pending(inApplicationSupport: root).map(\.id) == ["later"])

        // Outside the library, so a request never syncs.
        #expect(LampWritingStarts.url(inApplicationSupport: root, id: "later").path
            .hasPrefix(root.appendingPathComponent("Lamp Bible").path))
    }

    /// To the millisecond: readiness compares this with a file's date, and a
    /// second rounded off lets an earlier save pass for a later one.
    @Test func whenItWasAskedSurvivesBeingWrittenDown() throws {
        let root = try support()
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Date(timeIntervalSince1970: 1_800_000_000.875)
        try LampWritingStarts.write(.init(id: "p", title: "P", askedAt: asked), inApplicationSupport: root)
        let read = try #require(LampWritingStarts.pending(inApplicationSupport: root).first)
        #expect(abs(read.askedAt.timeIntervalSince(asked)) < 0.002)
    }

    @Test func anIdentifierThatCouldNameAnotherPathIsRefused() throws {
        let root = try support()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: LampWritingStarts.StartError.unusableIdentifier("../x")) {
            try LampWritingStarts.write(.init(id: "../x", title: "X"), inApplicationSupport: root)
        }
    }

    /// A descriptor from before the switch existed must not read as
    /// permission nobody gave.
    @Test func anOlderDescriptorDoesNotAllowStartingWritings() throws {
        let json = #"{"version":1,"libraryRootPath":"/l","policyPath":"/p","allowsExternalApps":true}"#
        let descriptor = try JSONDecoder().decode(LampAgentDescriptor.self, from: Data(json.utf8))
        #expect(descriptor.allowsWritingStarts == false)
    }

    /// The reader chat's helper is told which chat it answers in, so a
    /// writing started from it can bring the conversation along.
    @Test func aReaderChatsHelperIsToldItsChat() {
        let id = UUID()
        let library = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        let configuration = ReaderChatWorkspaceStore.configuration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/lamp-mcp"),
            libraryRootURL: library,
            bundledModulesArchiveURL: nil,
            policyURL: URL(fileURLWithPath: "/tmp/policy.json"),
            workspace: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: id)
        )
        #expect(configuration.readerChatID == id)
        let arguments = configuration.arguments
        let flag = try? #require(arguments.firstIndex(of: "--reader-chat"))
        #expect(flag.map { arguments[$0 + 1] } == id.uuidString)

        let writing = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/lamp-mcp"),
            libraryRootURL: library,
            policyURL: URL(fileURLWithPath: "/tmp/policy.json")
        )
        #expect(!writing.arguments.contains("--reader-chat"))
    }

    /// Each provider's helper is told it is that provider's, so a writing
    /// takes the conversation that asked for it.
    @Test func eachProvidersHelperSaysWhoseConversationItServes() throws {
        let id = UUID()
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("writing-start-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: id)
        let configuration = ReaderChatWorkspaceStore.configuration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/lamp-mcp"),
            libraryRootURL: library,
            bundledModulesArchiveURL: nil,
            policyURL: URL(fileURLWithPath: "/tmp/policy.json"),
            workspace: workspace
        )
        #expect(!configuration.arguments.contains("--reader-chat-provider"))
        let claude = configuration.answering(provider: "claude").arguments
        let flag = try #require(claude.firstIndex(of: "--reader-chat-provider"))
        #expect(claude[flag + 1] == "claude")

        let launched = AgentChatLaunchArguments.make(
            provider: .claude, prompt: "Hi", sessionID: nil, proposedSessionID: nil,
            mode: .reader(configuration)
        )
        #expect(launched.contains { $0.contains("--reader-chat-provider") && $0.contains("claude") })
        let codex = AgentChatLaunchArguments.make(
            provider: .codex, prompt: "Hi", sessionID: nil, proposedSessionID: nil,
            mode: .reader(configuration)
        )
        #expect(codex.contains { $0.contains("--reader-chat-provider") && $0.contains("codex") })

        // The files in the workspace are each one provider's.
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try configuration.writeProviderConfigurations(to: workspace, readOnly: true)
        let openCode = try String(contentsOf: workspace.appendingPathComponent("opencode.json"), encoding: .utf8)
        #expect(openCode.contains("openCode"))
        let toml = try String(contentsOf: workspace.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(toml.contains("\"codex\""))
    }
}
