import Foundation
import LampBibleMacSupport
import LampCore
import Testing

/// What a paired phone is told about this Mac's reader and writing chats.
struct LampAgentRemoteHostingTests {
    private let codex = LampAgentRemoteHosting.Provider(id: "codex", name: "OpenAI Codex")
    private let claude = LampAgentRemoteHosting.Provider(id: "claude", name: "Claude Code")
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60) }
    private func said(_ text: String, _ role: AgentChatTranscript.Role, _ minutes: Double) -> AgentChatTranscript.Message {
        AgentChatTranscript.Message(role: role, text: text, date: at(minutes))
    }
    private func transcript(_ messages: [AgentChatTranscript.Message]) -> AgentChatTranscript {
        AgentChatTranscript(messages: messages)
    }

    @Test func achatIsListedByItsOpeningUnderTheProviderItGoesOnWith() throws {
        let id = UUID()
        let summary = try #require(LampAgentRemoteHosting.summary(
            chatID: id,
            transcripts: [
                .init(provider: codex, transcript: transcript([said("What does agape mean?", .user, 0), said("Love…", .assistant, 1)])),
                .init(provider: claude, transcript: transcript([said("And phileo?", .user, 5), said("Affection…", .assistant, 6)])),
            ],
            continuing: claude,
            isRunning: false
        ))
        #expect(summary.id == id.uuidString)
        #expect(summary.provider == "claude" && summary.providerName == "Claude Code")
        #expect(summary.title == "And phileo?")
        #expect(summary.preview == "Affection…")
        #expect(summary.updatedAt == at(6))
        #expect(summary.kind == LampAgentRemoteChatSummary.reader && summary.acceptsMessages)
    }

    @Test func achatNothingWasSaidInIsNotListed() {
        #expect(LampAgentRemoteHosting.summary(chatID: UUID(), transcripts: [], continuing: codex, isRunning: false) == nil)
        #expect(LampAgentRemoteHosting.summary(
            chatID: UUID(), transcripts: [.init(provider: codex, transcript: transcript([]))], continuing: codex, isRunning: false
        ) == nil)
    }

    /// A writing's chat is titled by its opening, as a reader chat is, with
    /// the writing named under it; one that came in a module can be read but
    /// not sent to.
    @Test func awritingChatIsListedWithItsWriting() throws {
        let writing = LampAgentRemoteHosting.Writing(id: "studies/grace", title: "On Grace", isEditable: true)
        let summary = try #require(LampAgentRemoteHosting.summary(
            writing: writing,
            transcripts: [.init(provider: claude, transcript: transcript([said("Tighten the opening", .user, 0), said("Done.", .assistant, 1)]))],
            continuing: claude,
            isRunning: false
        ))
        #expect(summary.id == "writing:studies/grace")
        #expect(summary.kind == LampAgentRemoteChatSummary.writing && summary.writingID == "studies/grace")
        #expect(summary.title == "Tighten the opening" && summary.subtitle == "On Grace")
        #expect(summary.acceptsMessages)

        let bundled = LampAgentRemoteHosting.Writing(id: "m/1", title: "", isEditable: false)
        let started = LampAgentRemoteHosting.untitled(.writing(bundled.id), claude, writing: bundled, isRunning: true)
        #expect(!started.acceptsMessages && started.subtitle == "Untitled")
        #expect(LampAgentRemoteHosting.summary(writing: bundled, transcripts: [], continuing: claude, isRunning: false) == nil)
    }

    /// A summary's id names one chat and reads back as it.
    @Test func achatIdNamesItsKind() {
        let reader = UUID()
        #expect(LampAgentRemoteHosting.Chat(id: reader.uuidString) == .reader(reader))
        #expect(LampAgentRemoteHosting.Chat(id: "writing:a/b:c") == .writing("a/b:c"))
        #expect(LampAgentRemoteHosting.Chat(id: LampAgentRemoteHosting.Chat.writing("x").id) == .writing("x"))
        #expect(LampAgentRemoteHosting.Chat(id: "writing:") == nil)
        #expect(LampAgentRemoteHosting.Chat(id: "nonsense") == nil)
    }

    /// The Mac's model as the protocol states it; what is sent from that is
    /// core's to decide, and tested there (`LampAgentRemoteChatTests`).
    @Test func theModelIsStatedAsTheProtocolNamesIt() {
        let question = said("Who wrote Hebrews?", .user, 0)
        let state = LampAgentRemoteHosting.state(
            messages: [question], arriving: "Nobody", activity: .tool(name: "mcp__lamp__read_passage", summary: "Hebrews 1"),
            isRunning: true, failure: nil
        )
        #expect(state.messages.map(\.id) == [question.id])
        #expect(state.messages[0].role == LampAgentRemoteChatMessage.user)
        #expect(state.activity == LampAgentRemoteActivity(kind: LampAgentRemoteActivity.tool, name: "read_passage", summary: "Hebrews 1"))
        #expect(state.arriving == "Nobody" && state.isRunning)
    }
}
