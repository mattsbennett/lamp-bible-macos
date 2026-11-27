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
        askedBy: [UUID: UUID] = [:],
        approvals: [AgentToolApprovalRequest] = [],
        provider: String = ""
    ) -> LampAgentRemoteChatState {
        LampAgentRemoteChatState(
            messages: messages.map(message),
            arriving: arriving,
            activity: Self.activity(activity),
            isRunning: isRunning,
            failure: failure,
            askedBy: askedBy,
            approvals: approvals.map { approval($0, provider: provider) }
        )
    }

    /// A request on the Mac's card, as a paired device shows it
    /// (`decisions/0040`): a command to run, from Codex, Antigravity or
    /// Claude's shell, with where it runs and the agent's reason, which a
    /// device may allow where it can show it whole; any other tool call with
    /// what the Mac's card shows of it, which a device may only deny, since
    /// the card itself shows a file's new text only in part.
    public static func approval(_ request: AgentToolApprovalRequest, provider: String) -> LampAgentRemoteApproval {
        let summary = AgentToolApprovalSummary.of(request)
        let input = request.toolInput
        func string(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        switch request.toolName {
        case AgentCodexRun.commandToolName, AgentACPRun.commandToolName, "Bash":
            let command = string("command")
            return LampAgentRemoteApproval(
                id: request.id, provider: provider, kind: LampAgentRemoteApproval.command, title: summary.title,
                command: command, folder: string("cwd"),
                // Codex gives a reason; Claude's shell, a description of the
                // command. Both are the agent's own words.
                agentReason: string("reason") ?? string("description"),
                note: summary.note,
                canAllow: command.map(LampAgentRemoteApproval.canShowWhole) ?? false
            )
        default:
            return LampAgentRemoteApproval(
                id: request.id, provider: provider, kind: LampAgentRemoteApproval.tool, title: summary.title,
                command: summary.detail, note: summary.note, canAllow: false
            )
        }
    }
}


/// What a phone is told a chat runs with, and how a choice it makes is taken
/// into the chat: the same values, kept in the same place, as the menus over
/// a window's chat (`AgentChatProviderChoice`), so a window and a phone on
/// one chat always say the same thing.
public extension LampAgentRemoteHosting {
    /// A chat's model and effort under a provider, as its menus show them: its
    /// own choice, else what the app remembers, "" for the provider's default.
    /// For a provider whose effort rides on the model, the variant is shown as
    /// the effort and the model without it, as the Mac's two menus show them.
    static func chosen(
        in choices: AgentChatChoices,
        provider: AgentChatWireProvider,
        appDefault: (String) -> String?
    ) -> (model: String, effort: String) {
        let modelKey = AgentChatModelChoice.defaultsKey(provider)
        let effortKey = AgentChatEffortChoice.defaultsKey(provider)
        let model = choices.value(for: modelKey, orAppDefault: appDefault(modelKey)) ?? ""
        guard AgentChatEffortChoice.isCarriedByTheModel(provider) else {
            return (model, choices.value(for: effortKey, orAppDefault: appDefault(effortKey)) ?? "")
        }
        return (
            AgentChatModelChoice.separatingVariant(model).base,
            AgentChatOpenCodeVariants.chosen(in: model) ?? ""
        )
    }

    /// Why a phone's choice could not be taken.
    enum ChoiceRefusal: Error, Equatable {
        /// An effort for a provider that writes it on a model, with no model.
        case effortNeedsModel
        case unknownProvider
        /// A model or effort no provider would name: too long, or holding
        /// what a command line or a config value would read as its own.
        case unusableName
    }

    /// Whether a name typed on a phone can go to a provider's CLI as its
    /// model or effort. A phone is a new source of these, and they end up as
    /// arguments (`--model <name>`) and in a config value
    /// (`model_reasoning_effort="<level>"`), so what a provider would never
    /// name is refused rather than passed on: a control character, a quote
    /// or backslash, a leading dash, or more than 200 characters.
    static func isUsableName(_ name: String) -> Bool {
        guard name.count <= 200, !name.hasPrefix("-") else { return false }
        return !name.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "\"" || scalar == "\\"
        }
    }

    /// A phone's choice taken into a chat's own choices, as the menus take
    /// one: a provider is set and its model and effort pinned from what the
    /// app remembers; a model or effort is set for the chat's provider, on the
    /// model's name where its effort rides there.
    ///
    /// - Returns: the chat's choices, and what the app should now remember,
    ///   by defaults key, so the next new chat opens on it as it would after
    ///   the same pick in a window.
    static func applying(
        _ change: LampAgentRemoteChoices,
        to choices: AgentChatChoices,
        appProviderID: String,
        appProviderKey: String,
        wire: (String) -> AgentChatWireProvider?,
        appDefault: (String) -> String?
    ) throws(ChoiceRefusal) -> (choices: AgentChatChoices, remembered: [String: String]) {
        var updated = choices
        var remembered: [String: String] = [:]
        let currentProviderID = updated.value(for: AgentChatChoices.providerKey, orAppDefault: appProviderID)
            ?? appProviderID
        // A phone names the provider its model or effort was chosen for, so
        // one that has since been moved elsewhere takes it for that provider
        // and goes back to it, rather than handing it to another.
        let providerID = change.provider ?? currentProviderID
        guard let provider = wire(providerID) else { throw .unknownProvider }
        let modelKey = AgentChatModelChoice.defaultsKey(provider)
        let effortKey = AgentChatEffortChoice.defaultsKey(provider)

        if let chosenProvider = change.provider, chosenProvider != currentProviderID || updated.value(for: AgentChatChoices.providerKey) == nil {
            updated.set(chosenProvider, for: AgentChatChoices.providerKey)
            remembered[appProviderKey] = chosenProvider
            updated = AgentChatChoicesPin.pinning(
                updated, providerID: chosenProvider, provider: provider,
                model: appDefault(modelKey) ?? "", effort: appDefault(effortKey) ?? ""
            ).choices
        }
        for name in [change.model, change.effort].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !isUsableName(name) {
            throw .unusableName
        }
        if let model = change.model {
            let written = model.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.set(written, for: modelKey)
            remembered[modelKey] = written
        }
        if let effort = change.effort {
            let level = effort.trimmingCharacters(in: .whitespacesAndNewlines)
            if AgentChatEffortChoice.isCarriedByTheModel(provider) {
                let model = updated.value(for: modelKey, orAppDefault: appDefault(modelKey)) ?? ""
                guard AgentChatEffortChoice.isAvailable(provider: provider, model: model) else {
                    if level.isEmpty { return (updated, remembered) }
                    throw .effortNeedsModel
                }
                let written = AgentChatOpenCodeVariants.applying(variant: level, to: model)
                updated.set(written, for: modelKey)
                remembered[modelKey] = written
            } else {
                updated.set(level, for: effortKey)
                remembered[effortKey] = level
            }
        }
        return (updated, remembered)
    }

    /// A provider as a phone's setup offers it: the names it stands behind,
    /// what to type where it names none, and what a new chat opens on.
    static func setupProvider(
        id: String,
        name: String,
        shortName: String,
        systemImage: String?,
        wire: AgentChatWireProvider,
        connection: LampAgentRemoteSetup.Connection,
        appDefault: (String) -> String?
    ) -> LampAgentRemoteSetup.Provider {
        let defaults = chosen(in: AgentChatChoices(), provider: wire, appDefault: appDefault)
        return LampAgentRemoteSetup.Provider(
            id: id,
            name: name,
            shortName: shortName,
            systemImage: systemImage,
            connection: connection,
            models: AgentChatModelChoice.aliases(wire),
            modelHint: AgentChatModelChoice.hint(wire),
            efforts: AgentChatEffortChoice.levels(wire),
            effortHint: AgentChatEffortChoice.hint(wire),
            effortIsOnTheModel: AgentChatEffortChoice.isCarriedByTheModel(wire),
            defaultModel: defaults.model,
            defaultEffort: defaults.effort
        )
    }
}

/// A chat's choices changed by something other than the pane showing it — a
/// phone, through the host — so a window open on the chat reads them again
/// rather than show, and keep writing back, the ones it loaded.
public extension AgentChatChoicesStore {
    static let changedElsewhere = Notification.Name("AgentChatChoicesStore.changedElsewhere")

    static func announceChange(in workspace: URL) {
        NotificationCenter.default.post(name: changedElsewhere, object: workspace.standardizedFileURL.path)
    }

    static func isChange(_ notification: Notification, in workspace: URL?) -> Bool {
        guard let workspace, let path = notification.object as? String else { return false }
        return path == workspace.standardizedFileURL.path
    }
}

/// This Mac's own addresses on a tailnet, from its network interfaces, for a
/// device that cannot find it with Bonjour; see `LampAgentRemoteAddress`.
public enum LampAgentRemoteTailnet {
    /// IPv4 before IPv6, as the shorter to type, each once.
    public static func addresses(port: UInt16) -> [LampAgentRemoteAddress] {
        ordered(interfaceAddresses().filter(LampAgentRemoteAddress.isTailnet))
            .map { LampAgentRemoteAddress(host: $0, port: port) }
    }

    static func ordered(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        let unique = addresses.filter { seen.insert($0).inserted }
        return unique.filter { !$0.contains(":") } + unique.filter { $0.contains(":") }
    }

    /// Every address on an interface that is up, numeric, any zone left off.
    private static func interfaceAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0, let address = interface.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            addresses.append(text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text)
        }
        return addresses
    }
}
