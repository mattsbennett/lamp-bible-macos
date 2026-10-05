import Foundation

/// The conversation a chat pane shows, kept in the workspace so it survives a
/// relaunch and travels with sync.
///
/// Each provider keeps its own, fuller record of the same session — tool calls,
/// intermediate reasoning — but in a private store on the Mac that ran it. This
/// transcript is the part that can go anywhere: enough to read the conversation
/// on another Mac, and to carry it on there from a recap.
public struct AgentChatTranscript: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public struct Message: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let role: Role
        public let text: String
        public let date: Date

        public init(id: UUID = UUID(), role: Role, text: String, date: Date) {
            self.id = id
            self.role = role
            self.text = text
            self.date = date
        }
    }

    /// Replaced whenever the conversation is cleared, so a clear on one Mac can be
    /// told apart from an older copy of the same conversation on another. Missing
    /// on transcripts written before sync, which all count as one conversation.
    public var conversationID: UUID?
    /// When this conversation began: the moment it was cleared, or created.
    public var startedAt: Date?
    public var sessionID: String?
    /// The install whose provider holds `sessionID`. Provider sessions live in
    /// each tool's private store on the Mac that ran them, so an ID recorded
    /// anywhere else names a session that cannot be resumed here.
    public var sessionInstallID: String?
    public var messages: [Message]

    public init(
        conversationID: UUID? = nil,
        startedAt: Date? = nil,
        sessionID: String? = nil,
        sessionInstallID: String? = nil,
        messages: [Message] = []
    ) {
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.sessionID = sessionID
        self.sessionInstallID = sessionInstallID
        self.messages = messages
    }

    /// The most recent thing that happened in this conversation, including it
    /// being cleared.
    public var lastActivity: Date {
        max(startedAt ?? .distantPast, messages.map(\.date).max() ?? .distantPast)
    }

    /// The session ID this install may hand back to its provider, if any.
    ///
    /// A transcript written before ownership was recorded is taken to be local:
    /// until transcripts synced, it could only have been made here.
    public func resumableSessionID(forInstall installID: String) -> String? {
        guard let sessionID else { return nil }
        guard let sessionInstallID else { return sessionID }
        return sessionInstallID == installID ? sessionID : nil
    }

    /// Records the install that owns an unattributed session, so the transcript
    /// says where its session lives before it leaves this Mac.
    public func attributingSession(toInstall installID: String) -> AgentChatTranscript {
        guard sessionID != nil, sessionInstallID == nil else { return self }
        var attributed = self
        attributed.sessionInstallID = installID
        return attributed
    }
}

public enum AgentChatTranscriptStore {
    public static let filenamePrefix = "native-chat-"
    private static let metadataDirectoryName = ".lamp"

    public static func url(providerID: String, in workspace: URL) -> URL {
        directory(in: workspace).appendingPathComponent("\(filenamePrefix)\(providerID).json")
    }

    /// A missing or unreadable transcript reads as an empty conversation, so a
    /// damaged file never stops the chat pane from opening.
    public static func load(providerID: String, in workspace: URL) -> AgentChatTranscript {
        let url = url(providerID: providerID, in: workspace)
        guard let data = try? Data(contentsOf: url),
              let transcript = try? decode(data)
        else { return AgentChatTranscript() }
        return transcript
    }

    public static func save(
        _ transcript: AgentChatTranscript,
        providerID: String,
        in workspace: URL
    ) throws {
        let url = url(providerID: providerID, in: workspace)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode(transcript).write(to: url, options: .atomic)
    }

    /// The folder in a workspace that holds its transcripts.
    public static func directory(in workspace: URL) -> URL {
        workspace.appendingPathComponent(metadataDirectoryName, isDirectory: true)
    }

    /// `native-chat-<provider>.json`, with a provider name of letters, digits,
    /// hyphens and underscores only. Sync uses this to decide which incoming
    /// names to accept, so it admits nothing that could address another path.
    public static func isTranscriptFilename(_ name: String) -> Bool {
        guard name.hasPrefix(filenamePrefix), name.hasSuffix(".json") else { return false }
        let provider = name.dropFirst(filenamePrefix.count).dropLast(".json".count)
        guard !provider.isEmpty else { return false }
        return provider.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                || scalar == "-" || scalar == "_"
        }
    }

    // The coding matches what the chat pane wrote before transcripts synced, so
    // existing conversations keep loading.
    public static func decode(_ data: Data) throws -> AgentChatTranscript {
        try JSONDecoder().decode(AgentChatTranscript.self, from: data)
    }

    public static func encode(_ transcript: AgentChatTranscript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(transcript)
        data.append(0x0A)
        return data
    }
}

/// Reconciles two copies of one provider's transcript after sync.
public enum AgentChatTranscriptMerge {
    /// - If they are different conversations — one side cleared it — the one with
    ///   the more recent activity wins, so a clear spreads unless the other Mac
    ///   carried on chatting after it.
    /// - If one side's messages include all of the other's, that side simply has
    ///   more of the conversation, and its session goes with it.
    /// - If each has messages the other lacks, both Macs carried the conversation
    ///   on. Every message is kept, in time order, and neither session is kept:
    ///   neither provider has seen the other's turns, so the next message
    ///   continues from a recap instead.
    public static func merge(
        local: AgentChatTranscript,
        incoming: AgentChatTranscript
    ) -> AgentChatTranscript {
        if local.conversationID != incoming.conversationID {
            if local.lastActivity != incoming.lastActivity {
                return incoming.lastActivity > local.lastActivity ? incoming : local
            }
            // A dead heat is decided the same way on every Mac.
            let localKey = local.conversationID?.uuidString ?? ""
            let incomingKey = incoming.conversationID?.uuidString ?? ""
            return incomingKey > localKey ? incoming : local
        }

        let localIDs = Set(local.messages.map(\.id))
        let incomingIDs = Set(incoming.messages.map(\.id))
        if incomingIDs.isSubset(of: localIDs) { return local }
        if localIDs.isSubset(of: incomingIDs) { return incoming }

        var seen = Set<UUID>()
        let messages = (local.messages + incoming.messages)
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        let starts = [local.startedAt, incoming.startedAt].compactMap { $0 }
        return AgentChatTranscript(
            conversationID: local.conversationID,
            startedAt: starts.min(),
            sessionID: nil,
            sessionInstallID: nil,
            messages: messages
        )
    }
}

/// Builds the prompt that carries a conversation on in a fresh provider session.
///
/// Used whenever there is earlier conversation but no session to resume: the
/// session lives on another Mac, the provider has pruned it, or two Macs both
/// continued it. The recap is lossy — tool calls and intermediate steps are gone
/// — but for writing, the visible conversation plus the workspace files carry
/// most of what matters, and the agent is told to reread the files.
public enum AgentChatContinuation {
    public static let defaultCharacterBudget = 24_000

    /// A prompt that carries the conversation into a fresh session, for a
    /// provider that can only be given it as part of the user's message.
    public static func prompt(
        continuing earlier: [AgentChatTranscript.Message],
        with newPrompt: String,
        characterBudget: Int = defaultCharacterBudget
    ) -> String {
        guard !earlier.isEmpty else { return newPrompt }
        return """
        \(preamble)

        <earlier_conversation>
        \(recap(of: earlier, characterBudget: characterBudget))
        </earlier_conversation>

        The user's new message follows.

        \(newPrompt)
        """
    }

    /// The same recap as standing instructions for an interactive session, which
    /// receives it before the user has typed anything. Nil when there is nothing
    /// to carry on.
    public static func sessionInstructions(
        continuing earlier: [AgentChatTranscript.Message],
        characterBudget: Int = defaultCharacterBudget
    ) -> String? {
        guard !earlier.isEmpty else { return nil }
        return """
        \(preamble)

        <earlier_conversation>
        \(recap(of: earlier, characterBudget: characterBudget))
        </earlier_conversation>

        The user's next message continues this conversation.
        """
    }

    private static let preamble = """
    You are continuing a conversation that began in an earlier session, which \
    can't be resumed here. The conversation so far is reproduced below for \
    context. The workspace files are current, so reread them rather than \
    relying on any text quoted in it.
    """

    private static func recap(
        of earlier: [AgentChatTranscript.Message],
        characterBudget: Int
    ) -> String {
        // Newest first: when the budget runs out, the oldest turns are the ones
        // left out, since they matter least to what is being asked now.
        var kept: [String] = []
        var used = 0
        var remaining = earlier.count
        while remaining > 0 {
            let message = earlier[remaining - 1]
            let speaker = message.role == .user ? "User" : "Assistant"
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = "\(speaker): \(text)"
            if used + entry.count > characterBudget {
                if kept.isEmpty {
                    // Even the latest message alone overruns. Its end is closest
                    // to the new turn, so that is the part kept.
                    kept.append("\(speaker): […] \(text.suffix(max(characterBudget - 20, 0)))")
                    remaining -= 1
                }
                break
            }
            kept.append(entry)
            used += entry.count + 2
            remaining -= 1
        }

        var transcript = kept.reversed().joined(separator: "\n\n")
        if remaining > 0 {
            let noun = remaining == 1 ? "message" : "messages"
            transcript = "[\(remaining) earlier \(noun) omitted]\n\n" + transcript
        }
        return transcript
    }
}

/// What one provider run produced, read from its JSON event stream.
public struct AgentChatRunSummary: Equatable, Sendable {
    public var sessionID: String?
    public var response: String
    public var failure: String?

    public init(sessionID: String? = nil, response: String = "", failure: String? = nil) {
        self.sessionID = sessionID
        self.response = response
        self.failure = failure
    }

    public static func summarize(
        output: String,
        provider: AgentChatWireProvider
    ) -> AgentChatRunSummary {
        var summary = AgentChatRunSummary()
        var fragments = ""
        var finalText: String?
        for line in output.split(whereSeparator: \.isNewline) {
            for event in AgentChatWireParser.parse(String(line), provider: provider) {
                switch event {
                case .sessionStarted(let value): summary.sessionID = value
                case .textFragment(let value): fragments += value
                case .finalText(let value): finalText = value
                case .failure(let value): summary.failure = value
                }
            }
        }
        summary.response = (finalText ?? fragments).trimmingCharacters(in: .whitespacesAndNewlines)
        return summary
    }
}

public enum AgentChatResumeFailure {
    /// Whether a run that asked to resume a session failed because the provider
    /// has no such session.
    ///
    /// Each CLI says so in its own words, and does so immediately, before any
    /// model call:
    ///
    /// - Claude Code: `No conversation found with session ID: …`
    /// - Codex: `no rollout found for thread id …`
    /// - OpenCode: `Session not found`
    ///
    /// Matching the wording rather than treating every failure as a lost session
    /// matters: an authentication or network failure leaves the session intact,
    /// and starting over from a recap would throw away the provider's fuller
    /// record of it for nothing.
    public static func indicatesMissingSession(in output: String) -> Bool {
        let text = output.lowercased()
        let explicit = [
            "no conversation found with session id",
            "no rollout found",
            "session not found",
            "thread not found",
            "no saved session found",
        ]
        return explicit.contains { text.contains($0) }
    }
}

/// A stable identifier for this installation of Lamp, used to record which Mac
/// holds a provider session. It lives in this Mac's defaults and is never synced.
public enum LampInstallIdentity {
    public static let defaultsKey = "agent.installIdentifier"

    public static func current(in defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: defaultsKey)
        return created
    }
}
