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

    @Test func achatIsListedByItsOpeningUnderTheProviderSpokenToLast() throws {
        let id = UUID()
        let summary = try #require(LampAgentRemoteHosting.summary(
            chatID: id,
            transcripts: [
                .init(provider: codex, transcript: transcript([said("What does agape mean?", .user, 0), said("Love…", .assistant, 1)])),
                .init(provider: claude, transcript: transcript([said("And phileo?", .user, 5), said("Affection…", .assistant, 6)])),
            ],
            appProvider: codex,
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
        #expect(LampAgentRemoteHosting.summary(chatID: UUID(), transcripts: [], appProvider: codex, isRunning: false) == nil)
        #expect(LampAgentRemoteHosting.summary(
            chatID: UUID(), transcripts: [.init(provider: codex, transcript: transcript([]))], appProvider: codex, isRunning: false
        ) == nil)
    }

    @Test func areplyArrivesAsTheTurnTheReplySoFarWholeAndTheFinishedMessage() {
        let question = said("Who wrote Hebrews?", .user, 0)
        let answer = said("Nobody knows for certain.", .assistant, 1)
        let idle = LampAgentRemoteHosting.ChatState()
        let started = LampAgentRemoteHosting.ChatState(messages: [question], isRunning: true)
        let thinking = LampAgentRemoteHosting.ChatState(messages: [question], activity: .thinking(estimatedTokens: 40), isRunning: true)
        let writing = LampAgentRemoteHosting.ChatState(messages: [question], arriving: "Nobody", activity: .writing, isRunning: true)
        let more = LampAgentRemoteHosting.ChatState(messages: [question], arriving: "Nobody knows", activity: .writing, isRunning: true)
        let done = LampAgentRemoteHosting.ChatState(messages: [question, answer])
        let id = "chat"
        let kinds = [idle, started, thinking, writing, more, done].indices.dropFirst().flatMap { i in
            LampAgentRemoteHosting.events(chatID: id, from: [idle, started, thinking, writing, more, done][i - 1],
                                          to: [idle, started, thinking, writing, more, done][i])
        }
        #expect(kinds.map(\.kind) == ["turn-started", "activity", "fragment", "activity", "fragment", "reply", "turn-ended"])
        #expect(kinds[0].message?.id == question.id && kinds[0].turnID == question.id)
        // Whole each time, not what was added.
        #expect(kinds[4].text == "Nobody knows")
        #expect(kinds[5].message?.id == answer.id)
        #expect(kinds.allSatisfy { $0.turnID == question.id })
    }

    @Test func afailureIsToldOnceAndAMessageFromElsewhereStillArrives() {
        let question = said("Hello", .user, 0)
        let failed = LampAgentRemoteHosting.ChatState(messages: [question], failure: "Not signed in")
        let events = LampAgentRemoteHosting.events(
            chatID: "c", from: .init(messages: [question], isRunning: true), to: failed
        )
        #expect(events.map(\.kind) == ["failed", "turn-ended"])
        #expect(LampAgentRemoteHosting.events(chatID: "c", from: failed, to: failed).isEmpty)

        let elsewhere = said("Asked on the Mac", .user, 2)
        let arrived = LampAgentRemoteHosting.events(
            chatID: "c", from: .init(messages: [question]), to: .init(messages: [question, elsewhere])
        )
        #expect(arrived.map(\.kind) == ["reply"] && arrived[0].message?.id == elsewhere.id)
    }

    @Test func asnapshotCarriesTheReplySoFarOnlyWhileRunning() {
        let summary = LampAgentRemoteChatSummary(id: "c", title: "t", kind: "reader", provider: "codex", providerName: "Codex", acceptsMessages: true)
        let running = LampAgentRemoteHosting.snapshot(
            summary: summary, state: .init(messages: [said("Q", .user, 0)], arriving: "So far", activity: .writing, isRunning: true)
        )
        #expect(running.partialReply == "So far" && running.activity?.kind == "writing")
        let stopped = LampAgentRemoteHosting.snapshot(summary: summary, state: .init(arriving: "stale", activity: .writing))
        #expect(stopped.partialReply == nil && stopped.activity == nil)
    }
}
