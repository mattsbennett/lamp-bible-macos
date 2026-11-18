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

    /// Whether the phone's copy can no longer be brought up to date by
    /// events: messages it holds are gone (the conversation was cleared, or
    /// turns undone), so it needs a fresh snapshot instead.
    public static func needsSnapshot(from old: ChatState, to new: ChatState) -> Bool {
        let now = Set(new.messages.map(\.id))
        return old.messages.contains { !now.contains($0.id) }
    }

    /// The events that take a phone from one state of a chat to the next, in
    /// the order they happened.
    ///
    /// The state is taken a few changes at a time, so one step can hold a
    /// whole turn, or the end of one and the start of the next: each turn
    /// is still told as its own — begun with its question, its answer, ended
    /// — and every reply is filed under the question it answers. A question
    /// from another pane or Mac while nothing runs here is just a message.
    ///
    /// The reply so far goes whole each time, replacing the last: a frame
    /// lost or a phone that joins mid-reply still ends up with all of it.
    public static func events(chatID: String, from old: ChatState, to new: ChatState) -> [LampAgentRemoteChatEvent] {
        var events: [LampAgentRemoteChatEvent] = []
        func event(_ kind: String, _ turn: UUID?, message: AgentChatTranscript.Message? = nil,
                   text: String? = nil, activity: LampAgentRemoteActivity? = nil) {
            events.append(LampAgentRemoteChatEvent(
                chatID: chatID, kind: kind, turnID: turn, message: message.map(Self.message), text: text, activity: activity
            ))
        }
        let known = Set(old.messages.map(\.id))
        let added = new.messages.filter { !known.contains($0.id) }
        let lastAddedQuestion = added.last { $0.role == .user }?.id
        /// The question each message answers: the one before it.
        func question(before id: UUID) -> UUID? {
            guard let index = new.messages.firstIndex(where: { $0.id == id }) else { return nil }
            return new.messages[..<index].last { $0.role == .user }?.id
        }
        var open: UUID? = old.isRunning ? old.messages.last { $0.role == .user }?.id : nil

        for (index, message) in added.enumerated() {
            if message.role == .user {
                if let ending = open {
                    event(LampAgentRemoteChatEvent.turnEnded, ending)
                    open = nil
                }
                // A turn of its own when it is running now or was answered in
                // the same step; otherwise someone else's message.
                let answered = added[(index + 1)...].contains { $0.role == .assistant }
                if message.id == lastAddedQuestion, new.isRunning || answered {
                    event(LampAgentRemoteChatEvent.turnStarted, message.id, message: message)
                    open = message.id
                } else if answered {
                    event(LampAgentRemoteChatEvent.turnStarted, message.id, message: message)
                    open = message.id
                } else {
                    event(LampAgentRemoteChatEvent.reply, message.id, message: message)
                }
            } else {
                event(LampAgentRemoteChatEvent.reply, question(before: message.id), message: message)
            }
        }
        if new.isRunning, open == nil {
            // Running with no new question: a run picked up where it was.
            open = new.messages.last { $0.role == .user }?.id
            if !old.isRunning { event(LampAgentRemoteChatEvent.turnStarted, open) }
        }
        if new.isRunning, new.arriving != old.arriving, !new.arriving.isEmpty {
            event(LampAgentRemoteChatEvent.fragment, open, text: new.arriving)
        }
        if new.isRunning, new.activity != old.activity {
            event(LampAgentRemoteChatEvent.activity, open, activity: activity(new.activity))
        }
        if let failure = new.failure, failure != old.failure {
            event(LampAgentRemoteChatEvent.failed, open ?? new.messages.last { $0.role == .user }?.id, text: failure)
        }
        if !new.isRunning, let ending = open {
            event(LampAgentRemoteChatEvent.turnEnded, ending)
        }
        return events
    }
}
