import Foundation
import LampBibleMacSupport
import Testing

/// The conversation as a record of what happened, rather than two roles of
/// text.
///
/// The transcript kept `user` and `assistant` strings and discarded
/// everything the parser had read — tool calls, activity, failures. So
/// nothing afterwards could say what the agent did, a turn could not be
/// undone or forked from, and a reply had to be drawn as one bubble that
/// grew.
struct AgentChatEventsTests {
    private func event(
        _ turn: UUID, _ seconds: Double, _ kind: String,
        role: AgentChatTranscript.Role? = nil,
        name: String? = nil, text: String? = nil
    ) -> AgentChatTranscript.Event {
        AgentChatTranscript.Event(
            turn: turn, date: Date(timeIntervalSince1970: seconds),
            kind: kind, role: role, name: name, text: text
        )
    }

    @Test func aTurnIsTheQuestionAndEverythingThatFollowedIt() {
        let first = UUID(), second = UUID()
        let transcript = AgentChatTranscript(events: [
            event(first, 10, AgentChatTranscript.Event.said, role: .user, text: "Who wrote Hebrews?"),
            event(first, 11, AgentChatTranscript.Event.tool, name: "search", text: "Hebrews"),
            event(first, 12, AgentChatTranscript.Event.said, role: .assistant, text: "Nobody knows."),
            event(second, 20, AgentChatTranscript.Event.said, role: .user, text: "Why does it matter?"),
            event(second, 21, AgentChatTranscript.Event.said, role: .assistant, text: "It bears on…"),
        ])

        let turns = transcript.turns
        #expect(turns.count == 2)
        #expect(turns[0].question == "Who wrote Hebrews?")
        #expect(turns[0].events.count == 3, "the tool call belongs to its turn")
        #expect(turns[1].question == "Why does it matter?")
    }

    /// What a reader sees is derived, and is what an older Lamp reads.
    @Test func theMessagesAreTheSaidEvents() {
        let turn = UUID()
        let messages = AgentChatTranscript.messages(from: [
            event(turn, 12, AgentChatTranscript.Event.said, role: .assistant, text: "Nobody knows."),
            event(turn, 11, AgentChatTranscript.Event.tool, name: "search", text: "Hebrews"),
            event(turn, 10, AgentChatTranscript.Event.said, role: .user, text: "Who wrote Hebrews?"),
        ])
        #expect(messages.map(\.text) == ["Who wrote Hebrews?", "Nobody knows."], "in order")
        #expect(messages.map(\.role) == [.user, .assistant])
    }

    /// A kind this Lamp has no name for is still something that happened,
    /// still part of its turn, and must survive being read and written.
    @Test func anUnknownKindIsKept() throws {
        let turn = UUID()
        let transcript = AgentChatTranscript(events: [
            event(turn, 10, AgentChatTranscript.Event.said, role: .user, text: "Ask"),
            event(turn, 11, "approval", name: "write", text: "May I?"),
        ])
        let read = try AgentChatTranscriptStore.decode(
            try AgentChatTranscriptStore.encode(transcript)
        )
        #expect(read.events?.count == 2)
        #expect(read.turns.first?.events.map(\.kind) == ["said", "approval"])
    }

    /// A transcript from before events reads as the conversation it is,
    /// rather than as nothing having happened.
    @Test func aTranscriptFromBeforeEventsStillReads() {
        let transcript = AgentChatTranscript(messages: [
            .init(role: .user, text: "Who wrote Hebrews?", date: Date(timeIntervalSince1970: 10)),
            .init(role: .assistant, text: "Nobody knows.", date: Date(timeIntervalSince1970: 11)),
        ])
        #expect(transcript.events == nil)
        #expect(transcript.turns.count == 2, "one per message, which is what it was")
        #expect(transcript.turns.first?.question == "Who wrote Hebrews?")
    }

    /// Two Macs that both carried the conversation on keep both sides'
    /// events — and a side that has none says nothing, rather than saying
    /// there were none.
    @Test func mergingKeepsBothSidesEventsAndRespectsSilence() {
        let conversation = UUID()
        let mine = UUID(), theirs = UUID()
        func transcript(_ turn: UUID, _ at: Double, events: Bool) -> AgentChatTranscript {
            let said = event(turn, at, AgentChatTranscript.Event.said, role: .user, text: "x")
            return AgentChatTranscript(
                conversationID: conversation,
                messages: [.init(id: said.id, role: .user, text: "x", date: said.date)],
                events: events ? [said] : nil
            )
        }
        let merged = AgentChatTranscriptMerge.merge(
            local: transcript(mine, 10, events: true),
            incoming: transcript(theirs, 20, events: true)
        )
        #expect(merged.events?.count == 2)
        #expect(merged.messages.count == 2)

        let withSilence = AgentChatTranscriptMerge.merge(
            local: transcript(mine, 10, events: true),
            incoming: transcript(theirs, 20, events: false)
        )
        #expect(withSilence.events?.count == 1, "silence is not an empty list")
    }

    /// A tangent followed without losing the thread it was followed from.
    @Test func forkingKeepsEverythingUpToTheTurnAndNoSession() throws {
        let first = UUID(), second = UUID(), third = UUID()
        let original = AgentChatTranscript(
            conversationID: UUID(),
            startedAt: Date(timeIntervalSince1970: 5),
            sessionID: "session-1",
            sessionInstallID: "install-1",
            events: [
                event(first, 10, AgentChatTranscript.Event.said, role: .user, text: "Who wrote Hebrews?"),
                event(first, 11, AgentChatTranscript.Event.tool, name: "search", text: "Hebrews"),
                event(first, 12, AgentChatTranscript.Event.said, role: .assistant, text: "Nobody knows."),
                event(second, 20, AgentChatTranscript.Event.said, role: .user, text: "What about Apollos?"),
                event(second, 21, AgentChatTranscript.Event.said, role: .assistant, text: "Luther liked it."),
                event(third, 30, AgentChatTranscript.Event.said, role: .user, text: "And Priscilla?"),
            ]
        )

        let fork = try #require(original.forked(at: second))
        #expect(fork.turns.map(\.question) == ["Who wrote Hebrews?", "What about Apollos?"])
        #expect(fork.events?.count == 5, "the tool call comes with its turn")
        #expect(fork.messages.map(\.text).last == "Luther liked it.")

        // A provider's session is one line of talk in its own store; two
        // conversations pointing at it would each overwrite the other's end.
        #expect(fork.sessionID == nil)
        #expect(fork.sessionInstallID == nil)
        #expect(fork.conversationID != original.conversationID, "its own conversation")

        // And the original is untouched — that is the whole point.
        #expect(original.turns.count == 3)
        #expect(original.sessionID == "session-1")

        #expect(original.forked(at: UUID()) == nil, "a turn it does not have")
    }
}

/// Forking a reader chat on disk.
struct ReaderChatForkTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-fork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aForkIsItsOwnChatAndLeavesTheOriginalAlone() throws {
        let library = try root()
        defer { try? FileManager.default.removeItem(at: library) }
        let original = UUID()
        let workspace = ReaderChatWorkspaceStore.workspaceURL(
            libraryRootURL: library, chatID: original
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let first = UUID(), second = UUID()
        func said(_ turn: UUID, _ at: Double, _ role: AgentChatTranscript.Role, _ text: String)
            -> AgentChatTranscript.Event
        {
            AgentChatTranscript.Event(
                turn: turn, date: Date(timeIntervalSince1970: at),
                kind: AgentChatTranscript.Event.said, role: role, text: text
            )
        }
        let transcript = AgentChatTranscript(
            conversationID: UUID(), sessionID: "session-1", sessionInstallID: "install-1",
            events: [
                said(first, 10, .user, "Who wrote Hebrews?"),
                said(first, 11, .assistant, "Nobody knows."),
                said(second, 20, .user, "And Priscilla?"),
            ]
        )
        try AgentChatTranscriptStore.save(transcript, providerID: "claude", in: workspace)

        let forkID = try #require(try ReaderChatWorkspaceStore.fork(
            chat: original, at: first, providerID: "claude", libraryRootURL: library
        ))
        let forked = AgentChatTranscriptStore.load(
            providerID: "claude",
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: library, chatID: forkID)
        )
        #expect(forked.turns.map(\.question) == ["Who wrote Hebrews?"])
        #expect(forked.sessionID == nil, "a provider session cannot be in two conversations")

        let untouched = AgentChatTranscriptStore.load(providerID: "claude", in: workspace)
        #expect(untouched.turns.count == 2)
        #expect(untouched.sessionID == "session-1")

        // And it is a chat the reader can see and take up, not a loose file.
        #expect(
            ReaderChatWorkspaceStore.chats(libraryRootURL: library).map(\.id).contains(forkID)
        )

        #expect(
            try ReaderChatWorkspaceStore.fork(
                chat: original, at: UUID(), providerID: "claude", libraryRootURL: library
            ) == nil,
            "a turn the conversation does not have"
        )
    }
}

/// Messages written while a reply was still arriving.
///
/// A thought arrives mid-answer, usually *because* of the answer. With
/// nowhere to put it the reader either interrupts the run or holds it until
/// the reply lands, and the second is how a question gets lost.
struct AgentChatQueueTests {
    @Test func aMessageWaitsItsTurnAndIsTakenWhenItGoes() {
        var queue = AgentChatQueue()
        queue.add("Check Romans 8:1")
        queue.add("   ")
        queue.add("And the Greek for 'condemnation'")
        #expect(queue.messages.count == 2, "whitespace is not a message")

        #expect(queue.takeNext() == "Check Romans 8:1")
        #expect(queue.messages.count == 1, "taken, not read: otherwise it is sent twice")
        #expect(queue.takeNext() == "And the Greek for 'condemnation'")
        #expect(queue.takeNext() == nil)
    }

    @Test func aWaitingMessageCanBeRewordedOrTakenBack() throws {
        var queue = AgentChatQueue()
        queue.add("Waht about Apollos")
        let id = try #require(queue.messages.first?.id)

        queue.update(id, text: "What about Apollos?")
        #expect(queue.messages.first?.text == "What about Apollos?")

        // Clearing the words is how a person takes one back.
        queue.update(id, text: "   ")
        #expect(queue.messages.isEmpty)
    }

    @Test func oneCanBeSentSooner() throws {
        var queue = AgentChatQueue()
        queue.add("first")
        queue.add("second")
        let second = try #require(queue.messages.last?.id)

        queue.sendSooner(second)
        #expect(queue.messages.map(\.text) == ["second", "first"])
        queue.sendSooner(second)
        #expect(queue.messages.map(\.text) == ["second", "first"], "already first, and stays")
    }

    /// A queued message is something the person wrote and expects to be
    /// sent, so it outlives the app rather than the pane.
    @Test func whatIsWaitingSurvivesTheApp() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var queue = AgentChatQueue()
        queue.add("Check Romans 8:1")
        try AgentChatQueueStore.save(queue, providerID: "claude", in: workspace)
        #expect(
            AgentChatQueueStore.load(providerID: "claude", in: workspace).messages.map(\.text)
                == ["Check Romans 8:1"]
        )

        // Worked through, it leaves no file — so a queue that has been
        // emptied does not read as one that was never written.
        _ = queue.takeNext()
        try AgentChatQueueStore.save(queue, providerID: "claude", in: workspace)
        #expect(!FileManager.default.fileExists(
            atPath: AgentChatQueueStore.url(providerID: "claude", in: workspace).path
        ))
        #expect(AgentChatQueueStore.load(providerID: "claude", in: workspace).messages.isEmpty)
    }
}
