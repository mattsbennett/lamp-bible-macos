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

    /// The transcript spoken in last.
    public static func newest(_ transcripts: [ProviderTranscript]) -> ProviderTranscript? {
        transcripts
            .filter { !$0.transcript.messages.isEmpty }
            .max { ($0.transcript.messages.last?.date ?? .distantPast) < ($1.transcript.messages.last?.date ?? .distantPast) }
    }

    /// The provider a chat goes on with: its own choice, else the app's —
    /// what the reader chat pane on this Mac would open it on, so a turn
    /// from the phone lands in the conversation a window shows.
    public static func continuingProviderID(in workspace: URL, appProviderID: String) -> String {
        AgentChatChoicesStore.load(in: workspace).value(for: AgentChatChoices.providerKey, orAppDefault: appProviderID)
            ?? appProviderID
    }

    /// A reader chat as the phone lists it, under the provider it goes on
    /// with. Nil for a chat nothing was said in, which is a workspace a pane
    /// was opened over, not a conversation.
    public static func summary(
        chatID: UUID,
        transcripts: [ProviderTranscript],
        continuing: Provider,
        isRunning: Bool
    ) -> LampAgentRemoteChatSummary? {
        // The conversation it goes on with; for its title, the one spoken in
        // last if that is still empty.
        let own = transcripts.first { $0.provider == continuing && !$0.transcript.messages.isEmpty }
        guard let shown = own ?? newest(transcripts) else {
            return isRunning ? untitled(chatID, continuing, isRunning: true) : nil
        }
        let messages = shown.transcript.messages
        let opening = messages.first { $0.role == .user }?.text
        return LampAgentRemoteChatSummary(
            id: chatID.uuidString,
            title: opening.map { ReaderChatWorkspaceStore.label($0) } ?? "New Chat",
            kind: LampAgentRemoteChatSummary.reader,
            provider: continuing.id,
            providerName: continuing.name,
            updatedAt: messages.last?.date,
            preview: messages.last.map { ReaderChatWorkspaceStore.label($0.text, limit: 140) },
            isRunning: isRunning,
            acceptsMessages: true
        )
    }

    /// A chat with nothing in it yet: one a phone has just started.
    public static func untitled(_ chatID: UUID, _ provider: Provider, title: String = "New Chat", isRunning: Bool) -> LampAgentRemoteChatSummary {
        LampAgentRemoteChatSummary(
            id: chatID.uuidString,
            title: title,
            kind: LampAgentRemoteChatSummary.reader,
            provider: provider.id,
            providerName: provider.name,
            isRunning: isRunning,
            acceptsMessages: true
        )
    }

    /// Every reader chat on disk as the phone lists it, newest first. Reads
    /// every transcript, so off the main thread; whether a reply is running
    /// is the caller's to add, from the live models.
    public static func readSummaries(
        libraryRootURL: URL,
        providers: [Provider],
        appProviderID: String
    ) -> [(workspace: URL, summary: LampAgentRemoteChatSummary)] {
        ReaderChatWorkspaceStore.chats(libraryRootURL: libraryRootURL).compactMap { chat in
            let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: libraryRootURL, chatID: chat.id)
            let transcripts = providers.map {
                ProviderTranscript(provider: $0, transcript: AgentChatTranscriptStore.load(providerID: $0.id, in: workspace))
            }
            let continuingID = continuingProviderID(in: workspace, appProviderID: appProviderID)
            let continuing = providers.first { $0.id == continuingID } ?? providers.first { $0.id == appProviderID }
            guard let continuing,
                  let summary = summary(chatID: chat.id, transcripts: transcripts, continuing: continuing, isRunning: false)
            else { return nil }
            return (workspace, summary)
        }
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

    /// The Mac's chat model as the protocol states it: its finished messages,
    /// the reply so far, what the run is doing, what went wrong. What is sent
    /// from it is decided in core (`LampAgentRemoteChatUpdates`).
    public static func state(
        messages: [AgentChatTranscript.Message],
        arriving: String,
        activity: AgentChatActivity?,
        isRunning: Bool,
        failure: String?
    ) -> LampAgentRemoteChatState {
        LampAgentRemoteChatState(
            messages: messages.map(message),
            arriving: arriving,
            activity: Self.activity(activity),
            isRunning: isRunning,
            failure: failure
        )
    }
}
