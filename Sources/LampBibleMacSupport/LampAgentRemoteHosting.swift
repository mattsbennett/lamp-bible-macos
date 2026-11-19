import Foundation
import LampCore

/// How this Mac's reader and writing chats are shown to a paired phone: as
/// summaries in a list, as a snapshot when one is opened, and as the events
/// of a reply while it arrives. Worked out here from plain values, where it
/// is tested; the host only reads the chats and their models and sends what
/// this says.
public enum LampAgentRemoteHosting {
    /// Which chat a summary's id names: a reader chat, by its own id, or a
    /// writing's one chat, by the writing's.
    public enum Chat: Hashable, Sendable {
        case reader(UUID)
        case writing(String)

        private static let writingPrefix = "writing:"

        public init?(id: String) {
            if id.hasPrefix(Self.writingPrefix) {
                let writingID = String(id.dropFirst(Self.writingPrefix.count))
                guard !writingID.isEmpty else { return nil }
                self = .writing(writingID)
            } else if let uuid = UUID(uuidString: id) {
                self = .reader(uuid)
            } else {
                return nil
            }
        }

        public var id: String {
            switch self {
            case .reader(let id): id.uuidString
            case .writing(let id): Self.writingPrefix + id
            }
        }
    }

    /// A writing, as much of it as its chat's summary shows.
    public struct Writing: Equatable, Sendable {
        public let id: String
        public let title: String
        /// False for a writing that came in a module: an assistant may not
        /// change it, so a device may read its chat but not send to it.
        public let isEditable: Bool
        public init(id: String, title: String, isEditable: Bool) {
            self.id = id
            self.title = title
            self.isEditable = isEditable
        }

        var name: String { title.isEmpty ? "Untitled" : title }
    }

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
        summary(.reader(chatID), writing: nil, transcripts: transcripts, continuing: continuing, isRunning: isRunning)
    }

    /// A writing's chat as the phone lists it: titled by its opening, as a
    /// reader chat is, with the writing's name under it. Nil while nothing
    /// was said in it.
    public static func summary(
        writing: Writing,
        transcripts: [ProviderTranscript],
        continuing: Provider,
        isRunning: Bool
    ) -> LampAgentRemoteChatSummary? {
        summary(.writing(writing.id), writing: writing, transcripts: transcripts, continuing: continuing, isRunning: isRunning)
    }

    private static func summary(
        _ chat: Chat,
        writing: Writing?,
        transcripts: [ProviderTranscript],
        continuing: Provider,
        isRunning: Bool
    ) -> LampAgentRemoteChatSummary? {
        // The conversation it goes on with; for its title, the one spoken in
        // last if that is still empty.
        let own = transcripts.first { $0.provider == continuing && !$0.transcript.messages.isEmpty }
        guard let shown = own ?? newest(transcripts) else {
            return isRunning ? untitled(chat, continuing, writing: writing, isRunning: true) : nil
        }
        let messages = shown.transcript.messages
        let opening = messages.first { $0.role == .user }?.text
        var summary = untitled(
            chat, continuing, title: opening.map { ReaderChatWorkspaceStore.label($0) } ?? "New Chat",
            writing: writing, isRunning: isRunning
        )
        summary.updatedAt = messages.last?.date
        summary.preview = messages.last.map { ReaderChatWorkspaceStore.label($0.text, limit: 140) }
        return summary
    }

    /// A chat with nothing in it yet: one a phone has just started.
    public static func untitled(
        _ chat: Chat, _ provider: Provider, title: String = "New Chat", writing: Writing? = nil, isRunning: Bool
    ) -> LampAgentRemoteChatSummary {
        LampAgentRemoteChatSummary(
            id: chat.id,
            title: title,
            subtitle: writing?.name,
            kind: writing == nil ? LampAgentRemoteChatSummary.reader : LampAgentRemoteChatSummary.writing,
            writingID: writing?.id,
            provider: provider.id,
            providerName: provider.name,
            isRunning: isRunning,
            acceptsMessages: writing?.isEditable ?? true
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

    /// Every writing's chat on disk as the phone lists it: a writing whose
    /// workspace was never made, or that nothing was said in, has none. Off
    /// the main thread, as `readSummaries` is.
    public static func readWritingSummaries(
        libraryRootURL: URL,
        writings: [Writing],
        providers: [Provider],
        appProviderID: String
    ) -> [(workspace: URL, summary: LampAgentRemoteChatSummary)] {
        writings.compactMap { writing in
            let workspace = LampWritingWorkspace.url(libraryRootURL: libraryRootURL, writingID: writing.id)
            guard FileManager.default.fileExists(atPath: workspace.path) else { return nil }
            let transcripts = providers.map {
                ProviderTranscript(provider: $0, transcript: AgentChatTranscriptStore.load(providerID: $0.id, in: workspace))
            }
            let continuingID = continuingProviderID(in: workspace, appProviderID: appProviderID)
            let continuing = providers.first { $0.id == continuingID } ?? providers.first { $0.id == appProviderID }
            guard let continuing,
                  let summary = summary(writing: writing, transcripts: transcripts, continuing: continuing, isRunning: false)
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
        failure: String?,
        askedBy: [UUID: UUID] = [:]
    ) -> LampAgentRemoteChatState {
        LampAgentRemoteChatState(
            messages: messages.map(message),
            arriving: arriving,
            activity: Self.activity(activity),
            isRunning: isRunning,
            failure: failure,
            askedBy: askedBy
        )
    }
}
