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

    /// One thing that happened in the conversation.
    ///
    /// The transcript used to keep two roles of text and throw the rest away:
    /// the parser read tool calls, activity and failures out of the
    /// provider's stream, and `AgentChatRunSummary` folded them into one
    /// string. So nothing afterwards could say what the agent had done,
    /// a turn could not be undone, and a reply had to be drawn as one bubble
    /// that grew — which is what scrolled the chat past its end.
    ///
    /// Flat rather than an enum with associated values, and **unknown kinds
    /// are kept**: a newer Lamp will write kinds this one has no name for,
    /// and an event it cannot draw is still an event that happened, still
    /// part of its turn, and must survive being read and written here.
    public struct Event: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        /// The user message this turn began with, so a turn can be found
        /// whole — to undo it, to fork from it, or to show what it did.
        public let turn: UUID
        public let date: Date
        /// `said`, `tool`, `activity`, `failed`, or something a later Lamp
        /// knows about.
        public let kind: String
        public let role: Role?
        public let name: String?
        public let text: String?

        public init(
            id: UUID = UUID(),
            turn: UUID,
            date: Date,
            kind: String,
            role: Role? = nil,
            name: String? = nil,
            text: String? = nil
        ) {
            self.id = id
            self.turn = turn
            self.date = date
            self.kind = kind
            self.role = role
            self.name = name
            self.text = text
        }

        public static let said = "said"
        public static let tool = "tool"
        public static let activity = "activity"
        public static let failed = "failed"
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
    /// What a reader sees, and what a Lamp from before events reads. Kept
    /// written beside `events` rather than derived on load: an older Mac
    /// opens this file too, and one that rewrites it drops the events it
    /// has no name for — at which point this is the whole conversation
    /// again, which is exactly where we were, rather than nothing.
    public var messages: [Message]
    /// Everything that happened, in order. Absent on a transcript written
    /// before events, which is not the same as a conversation in which
    /// nothing happened.
    public var events: [Event]?

    public init(
        conversationID: UUID? = nil,
        startedAt: Date? = nil,
        sessionID: String? = nil,
        sessionInstallID: String? = nil,
        messages: [Message] = [],
        events: [Event]? = nil
    ) {
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.sessionID = sessionID
        self.sessionInstallID = sessionInstallID
        self.messages = messages
        self.events = events
    }

    /// The most recent thing that happened in this conversation, including it
    /// being cleared.
    public var lastActivity: Date {
        max(startedAt ?? .distantPast, messages.map(\.date).max() ?? .distantPast)
    }

    /// The conversation as turns: each user message with everything that
    /// followed it, in order.
    ///
    /// A transcript from before events has none, so it reads as one turn per
    /// message — which is what it was.
    public var turns: [Turn] {
        // **Every message is in a turn, with or without events.** Events
        // cover what this app recorded; `messages` is the floor, and a
        // message outside the events is not a message that did not happen.
        // It is one from before events, or from a Mac that rewrote the file
        // without them, or from a merge that kept both sides' messages and
        // only one side's events. Drawing from the events alone dropped
        // those from the pane — and the next send wrote the thinned list
        // back, which is how reading a record destroys it.
        // Only a **said** event stands for a message. Suppressing on any
        // event's id meant a tool or activity event that happened to carry
        // a message's id would take that message out of the conversation —
        // the record deciding the floor it exists to protect.
        let recorded = Set(
            (events ?? []).filter { $0.kind == Event.said }.map(\.id)
        )
        let loose = messages.filter { !recorded.contains($0.id) }.map { message in
            Event(
                id: message.id, turn: message.id, date: message.date,
                kind: Event.said, role: message.role, text: message.text
            )
        }
        let all = (events ?? []) + loose
        guard !all.isEmpty else { return [] }

        // Ordered by when each turn began, and a loose message is a turn
        // of its own. So a message whose time falls inside a recorded
        // turn's span follows that whole turn rather than being dropped
        // into the middle of its tool calls — which is deliberate: a turn
        // is one thing that happened, and splitting it to interleave a
        // message from elsewhere would make both harder to read.
        var order: [UUID] = []
        var grouped: [UUID: [Event]] = [:]
        for event in all.sorted(by: Self.inOrder) {
            if grouped[event.turn] == nil { order.append(event.turn) }
            grouped[event.turn, default: []].append(event)
        }
        return order.compactMap { id in
            guard let events = grouped[id], let first = events.first else { return nil }
            return Turn(id: id, date: first.date, events: events)
        }
    }

    public struct Turn: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let events: [Event]

        /// What the person asked, where this turn records it.
        public var question: String? {
            events.first { $0.kind == Event.said && $0.role == .user }?.text
        }

        /// When this turn ran: its first event to its last.
        ///
        /// What the agent changed while it ran is found by this, rather
        /// than by a mark in the revision history. A revision is a synced
        /// record that other Lamps read and write; the time a turn
        /// occupied is already in both and needs nothing added to either.
        public var span: ClosedRange<Date> {
            let dates = events.map(\.date)
            let first = dates.min() ?? date
            return first...(dates.max() ?? first)
        }

        /// The tools this turn used, named once each and in the order they
        /// were first used.
        ///
        /// A run reports the same tool many times, so a list that said
        /// "Read · Read · Read" would be a record of the reporting rather
        /// than of the work.
        public var toolsUsed: [String] {
            var seen = Set<String>()
            return events.compactMap { event in
                guard event.kind == Event.tool, let name = event.name else { return nil }
                return seen.insert(name).inserted ? name : nil
            }
        }
    }

    /// Two devices order the same events the same way.
    static func inOrder(_ left: Event, _ right: Event) -> Bool {
        (left.date, left.id.uuidString) < (right.date, right.id.uuidString)
    }

    /// What a reader sees, from the events — the projection written into
    /// `messages` so an older Lamp still has the conversation.
    public static func messages(from events: [Event]) -> [Message] {
        events.sorted(by: inOrder).compactMap { event in
            guard event.kind == Event.said, let role = event.role, let text = event.text
            else { return nil }
            return Message(id: event.id, role: role, text: text, date: event.date)
        }
    }

    /// This conversation up to and including one turn, as its own
    /// conversation.
    ///
    /// Study is made of tangents: a word leads somewhere, and following it
    /// should not cost the thread it was followed from. A fork keeps
    /// everything up to the turn it was taken at and leaves the rest where
    /// it was.
    ///
    /// It takes **no session**. A provider's session is a single line of
    /// talk in that provider's own store; there is no splitting it, and
    /// pointing two conversations at one session would have each overwrite
    /// the other's end. So a fork carries on from a recap, which is the
    /// same path a conversation already takes when its session is gone —
    /// `AgentChatContinuation`.
    public func forked(at turn: UUID) -> AgentChatTranscript? {
        let kept = turns
        guard let end = kept.firstIndex(where: { $0.id == turn }) else { return nil }
        let events = kept[...end].flatMap(\.events)
        guard !events.isEmpty else { return nil }
        return AgentChatTranscript(
            conversationID: UUID(),
            startedAt: startedAt ?? events.first?.date,
            sessionID: nil,
            sessionInstallID: nil,
            messages: Self.messages(from: events),
            events: events
        )
    }

    /// This conversation without a turn, and without anything after it.
    ///
    /// For undoing a turn: what followed it followed *from* it, so leaving
    /// those behind would leave answers to a question that is no longer
    /// there.
    ///
    /// Takes **no session**, for the same reason a fork does not: a
    /// provider's session is one line of talk in that provider's own store
    /// and cannot be rewound. The next message carries on from a recap of
    /// what is left.
    public func trimmed(from turn: UUID) -> AgentChatTranscript? {
        let kept = turns
        guard let cut = kept.firstIndex(where: { $0.id == turn }) else { return nil }
        let events = kept[..<cut].flatMap(\.events)
        var trimmed = self
        trimmed.events = events
        trimmed.messages = Self.messages(from: events)
        trimmed.sessionID = nil
        trimmed.sessionInstallID = nil
        return trimmed
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

/// Messages written while a reply was still arriving, waiting their turn.
///
/// A thought arrives mid-answer — a verse to check, a follow-up the reply
/// has just prompted. Without somewhere to put it the reader either
/// interrupts the run or holds the thought until the reply lands, and the
/// second is how a question gets lost.
///
/// Kept beside the transcript rather than in memory, because a queued
/// message is something the person wrote and expects to be sent: losing it
/// when the app quits would be losing their words, not their place.
public struct AgentChatQueue: Codable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var text: String
        public let written: Date

        public init(id: UUID = UUID(), text: String, written: Date = Date()) {
            self.id = id
            self.text = text
            self.written = written
        }
    }

    public var messages: [Message]

    public init(messages: [Message] = []) {
        self.messages = messages
    }

    /// Adds a message, ignoring one that is only whitespace.
    public mutating func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Message(text: trimmed))
    }

    public mutating func remove(_ id: UUID) {
        messages.removeAll { $0.id == id }
    }

    /// Drops anything the conversation already holds.
    ///
    /// A queued message is sent under **its own id**, so the transcript
    /// carrying that id is what says it was taken. Without this, a quit
    /// between the question reaching the transcript and the queue being
    /// written would leave it waiting, and the next launch would send it
    /// again — a second copy of a question, or for a writing agent a second
    /// run of whatever it was asked to do.
    public mutating func removeAlreadySaid(in transcript: AgentChatTranscript) {
        let said = Set(transcript.messages.map(\.id))
        guard !said.isEmpty else { return }
        messages.removeAll { said.contains($0.id) }
    }

    /// Rewrites a waiting message, or drops it where the rewrite empties it:
    /// clearing the words is how a person takes one back.
    public mutating func update(_ id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            messages.remove(at: index)
        } else {
            messages[index].text = trimmed
        }
    }

    /// Moves one message a place earlier.
    ///
    /// A place at a time rather than a drag: what is waiting was written
    /// during one reply, so the queue is short by nature, and a drag target
    /// in a strip this size is harder to hit than a button.
    public mutating func sendSooner(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }), index > 0 else { return }
        messages.swapAt(index, index - 1)
    }

}

public enum AgentChatQueueStore {
    public static let filenamePrefix = "native-chat-queue-"

    public static func url(providerID: String, in workspace: URL) -> URL {
        AgentChatTranscriptStore.directory(in: workspace)
            .appendingPathComponent("\(filenamePrefix)\(providerID).json")
    }

    /// A missing or unreadable queue reads as nothing waiting, so a damaged
    /// file never stops the chat from opening or from sending.
    public static func load(providerID: String, in workspace: URL) -> AgentChatQueue {
        guard let data = try? Data(contentsOf: url(providerID: providerID, in: workspace)),
              let queue = try? JSONDecoder().decode(AgentChatQueue.self, from: data)
        else { return AgentChatQueue() }
        return queue
    }

    public static func save(
        _ queue: AgentChatQueue, providerID: String, in workspace: URL
    ) throws {
        let url = url(providerID: providerID, in: workspace)
        // Nothing waiting leaves no file, so a queue that has been worked
        // through does not look like one that was never read.
        guard !queue.messages.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(queue)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
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

        // Events are reconciled in **every** branch, including the two
        // where one side's messages contain the other's. A copy rewritten
        // by an older app has the same messages and no events, and
        // returning it whole threw away the other side's record of what the
        // agent did — in one direction only, so which Mac synced first
        // decided what survived.
        let events = mergedEvents(local: local, incoming: incoming)
        let localIDs = Set(local.messages.map(\.id))
        let incomingIDs = Set(incoming.messages.map(\.id))
        if incomingIDs.isSubset(of: localIDs) {
            var kept = local
            kept.events = events
            return kept
        }
        if localIDs.isSubset(of: incomingIDs) {
            var kept = incoming
            kept.events = events
            return kept
        }

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
            messages: messages,
            events: events
        )
    }

    /// The same union, for events.
    ///
    /// Absent on one side is silence, not emptiness: a Mac from before
    /// events, or one that rewrote the file without them, says nothing
    /// about what happened — so the side that has them keeps them rather
    /// than having them cleared by a copy that never knew.
    private static func mergedEvents(
        local: AgentChatTranscript, incoming: AgentChatTranscript
    ) -> [AgentChatTranscript.Event]? {
        switch (local.events, incoming.events) {
        case (nil, nil): return nil
        case let (mine?, nil): return mine
        case let (nil, theirs?): return theirs
        case let (mine?, theirs?):
            var seen = Set<UUID>()
            return (mine + theirs)
                .filter { seen.insert($0.id).inserted }
                .sorted(by: AgentChatTranscript.inOrder)
        }
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
                // What the run was doing while it ran. It was shown then; a
                // finished run is read for what it said.
                case .activity: break
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
