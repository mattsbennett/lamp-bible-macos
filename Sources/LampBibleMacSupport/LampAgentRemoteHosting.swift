import Foundation
import LampCore

/// How this Mac's reader chats are shown to a paired phone: as summaries in
/// a list, as a snapshot when one is opened, and as the events of a reply
/// while it arrives. Worked out here from plain values, where it is tested;
/// the host only reads the chats and their models and sends what this says.
public enum LampAgentRemoteHosting {
    /// A provider, as a chat summary names it.
    public struct Provider: Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One provider's transcript in a chat.
    public struct ProviderTranscript: Sendable {
        public let provider: Provider
        public let transcript: AgentChatTranscript
        public init(provider: Provider, transcript: AgentChatTranscript) {
            self.provider = provider
            self.transcript = transcript
        }
    }

    /// The transcript a chat continues in: the one spoken in last. A chat is
    /// one conversation to the reader, whichever provider carried it on.
    public static func current(_ transcripts: [ProviderTranscript]) -> ProviderTranscript? {
        transcripts
            .filter { !$0.transcript.messages.isEmpty }
            .max { ($0.transcript.messages.last?.date ?? .distantPast) < ($1.transcript.messages.last?.date ?? .distantPast) }
    }

    /// A reader chat as the phone lists it. Nil for a chat nothing was said
    /// in, which is a workspace a pane was opened over, not a conversation.
    public static func summary(
        chatID: UUID,
        transcripts: [ProviderTranscript],
        appProvider: Provider,
        isRunning: Bool
    ) -> LampAgentRemoteChatSummary? {
        let current = current(transcripts)
        guard current != nil || isRunning else { return nil }
        let messages = current?.transcript.messages ?? []
        let opening = messages.first { $0.role == .user }?.text
        let provider = current?.provider ?? appProvider
        return LampAgentRemoteChatSummary(
            id: chatID.uuidString,
            title: opening.map { ReaderChatWorkspaceStore.label($0) } ?? "New Chat",
            kind: LampAgentRemoteChatSummary.reader,
            provider: provider.id,
            providerName: provider.name,
            updatedAt: messages.last?.date,
            preview: messages.last.map { ReaderChatWorkspaceStore.label($0.text, limit: 140) },
            isRunning: isRunning,
            acceptsMessages: true
        )
    }

    public static func message(_ message: AgentChatTranscript.Message) -> LampAgentRemoteChatMessage {
        LampAgentRemoteChatMessage(
            id: message.id,
            role: message.role == .user ? LampAgentRemoteChatMessage.user : LampAgentRemoteChatMessage.assistant,
            text: message.text,
            date: message.date
        )
    }

    public static func activity(_ activity: AgentChatActivity?) -> LampAgentRemoteActivity? {
        switch activity {
        case nil: nil
        case .thinking(let tokens):
            LampAgentRemoteActivity(kind: LampAgentRemoteActivity.thinking, estimatedTokens: tokens)
        case .toolStarted(let name):
            LampAgentRemoteActivity(kind: LampAgentRemoteActivity.toolStarted, name: AgentChatToolDescription.label(for: name))
        case .tool(let name, let summary):
            LampAgentRemoteActivity(kind: LampAgentRemoteActivity.tool, name: AgentChatToolDescription.label(for: name), summary: summary)
        case .toolFinished:
            LampAgentRemoteActivity(kind: LampAgentRemoteActivity.toolFinished)
        case .writing:
            LampAgentRemoteActivity(kind: LampAgentRemoteActivity.writing)
        }
    }

    /// What an open chat's model shows at a moment: its finished messages,
    /// the reply so far, what the run is doing, and what went wrong.
    public struct ChatState: Equatable, Sendable {
        public var messages: [AgentChatTranscript.Message]
        public var arriving: String
        public var activity: AgentChatActivity?
        public var isRunning: Bool
        public var failure: String?

        public init(
            messages: [AgentChatTranscript.Message] = [],
            arriving: String = "",
            activity: AgentChatActivity? = nil,
            isRunning: Bool = false,
            failure: String? = nil
        ) {
            self.messages = messages
            self.arriving = arriving
            self.activity = activity
            self.isRunning = isRunning
            self.failure = failure
        }
    }

    public static func snapshot(summary: LampAgentRemoteChatSummary, state: ChatState) -> LampAgentRemoteChatSnapshot {
        LampAgentRemoteChatSnapshot(
            summary: summary,
            messages: state.messages.map(message),
            partialReply: state.isRunning && !state.arriving.isEmpty ? state.arriving : nil,
            activity: state.isRunning ? activity(state.activity) : nil,
            notice: state.failure
        )
    }

    /// The events that take a phone from one state of a chat to the next, in
    /// the order they happened: a turn begun, the reply so far, what the run
    /// is doing, finished messages, a failure, the turn over.
    ///
    /// The reply so far goes whole each time, replacing the last: a frame
    /// lost or a phone that joins mid-reply still ends up with all of it.
    public static func events(chatID: String, from old: ChatState, to new: ChatState) -> [LampAgentRemoteChatEvent] {
        var events: [LampAgentRemoteChatEvent] = []
        let known = Set(old.messages.map(\.id))
        let added = new.messages.filter { !known.contains($0.id) }
        let turn = (added.last { $0.role == .user } ?? new.messages.last { $0.role == .user })?.id
        if new.isRunning, !old.isRunning {
            events.append(LampAgentRemoteChatEvent(
                chatID: chatID, kind: LampAgentRemoteChatEvent.turnStarted, turnID: turn,
                message: added.last { $0.role == .user }.map(message)
            ))
        } else {
            // A message from another pane or Mac while nothing ran here.
            for user in added where user.role == .user {
                events.append(LampAgentRemoteChatEvent(
                    chatID: chatID, kind: LampAgentRemoteChatEvent.reply, turnID: user.id, message: message(user)
                ))
            }
        }
        if new.isRunning, new.arriving != old.arriving, !new.arriving.isEmpty {
            events.append(LampAgentRemoteChatEvent(
                chatID: chatID, kind: LampAgentRemoteChatEvent.fragment, turnID: turn, text: new.arriving
            ))
        }
        if new.isRunning, new.activity != old.activity {
            events.append(LampAgentRemoteChatEvent(
                chatID: chatID, kind: LampAgentRemoteChatEvent.activity, turnID: turn, activity: activity(new.activity)
            ))
        }
        for reply in added where reply.role == .assistant {
            events.append(LampAgentRemoteChatEvent(
                chatID: chatID, kind: LampAgentRemoteChatEvent.reply, turnID: turn, message: message(reply)
            ))
        }
        if let failure = new.failure, failure != old.failure {
            events.append(LampAgentRemoteChatEvent(
                chatID: chatID, kind: LampAgentRemoteChatEvent.failed, turnID: turn, text: failure
            ))
        }
        if old.isRunning, !new.isRunning {
            events.append(LampAgentRemoteChatEvent(chatID: chatID, kind: LampAgentRemoteChatEvent.turnEnded, turnID: turn))
        }
        return events
    }
}
