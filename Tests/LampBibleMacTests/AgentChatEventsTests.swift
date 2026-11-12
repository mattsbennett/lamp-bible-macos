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
}
