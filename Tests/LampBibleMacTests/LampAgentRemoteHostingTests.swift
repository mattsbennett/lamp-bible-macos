import Foundation
import LampBibleMacSupport
import LampCore
import Testing

/// What a paired phone is told about this Mac's reader chats.
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
