import Foundation

/// A reader chat carried into a new writing: once, one way.
///
/// Study turns into writing. A conversation about a passage is often where a
/// piece of writing starts, and without this the only way to bring it along
/// was to copy it out by hand. Starting a writing from a chat copies the
/// conversation into the new writing's workspace, where its chat carries on
/// from it.
///
/// **It is a copy, and it is made once.** The reader chat stays where it was,
/// on this Mac and under its own retention; the writing's chat is the
/// writing's, and syncs with it. Nothing said afterwards in either reaches
/// the other. That is the whole of the rule, and the reason it is a copy
/// rather than a link: a reader chat is scrubbed on a clock the writing does
/// not share, and a writing's conversation travels to devices that have no
/// reader chats at all.
public enum ReaderChatWritingCopy {
    /// The event that marks where the copied conversation ends and the
    /// writing's own begins. Its `name` is the reader chat's identifier.
    ///
    /// An event rather than a field on the transcript, so that it survives
    /// everything a transcript goes through: events are kept whole by every
    /// save and merge, and kept by a Lamp that has no name for their kind. A
    /// field would be dropped by the first older app to rewrite the file.
    /// Nothing reads its absence as meaning anything — a transcript without
    /// one is a transcript that says nothing about where it came from.
    public static let copiedEventKind = "copiedFromReaderChat"

    public enum CopyError: Error, LocalizedError, Equatable {
        case writingHasAConversation
        case replyArriving

        public var errorDescription: String? {
            switch self {
            case .replyArriving:
                "A reply is still arriving in this chat. Start the writing once it has finished, so the conversation copied holds it."
            case .writingHasAConversation:
                "This writing already has a conversation, so the reader chat was not copied over it."
            }
        }
    }

    /// Copies a reader chat's conversation into a writing's workspace, up to
    /// and including `turn`, or the whole of it where `turn` is nil.
    ///
    /// Only the conversation with `providerID` comes across, as a fork takes
    /// it: a chat may hold conversations with more than one provider, and
    /// those were never one conversation. The chat's own choices — which
    /// provider, which model — come with it, so the writing's chat opens on
    /// the provider the conversation was had with.
    ///
    /// The copy is a fork of the conversation under a new identity, written
    /// into the **writing's** workspace. The reader chat's file is not
    /// touched, so what was undone in it stays undone there, and the copy
    /// holds no turn that was undone: a fork keeps only the turns still in
    /// the conversation.
    ///
    /// Returns false where there was nothing to copy — no conversation, or a
    /// turn that is no longer in it. The writing is still the writing; it
    /// simply starts without a conversation.
    ///
    /// **Made again, it does nothing.** A copy of this chat already in the
    /// writing is the copy, so a start that was interrupted after copying —
    /// the app quit before the writing was saved — finishes on the next
    /// attempt rather than being refused for ever by its own first half.
    @discardableResult
    public static func copy(
        chat id: UUID,
        upTo turn: UUID?,
        providerID: String,
        libraryRootURL: URL,
        writingID: String,
        now: Date = Date()
    ) throws -> Bool {
        let source = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: libraryRootURL, chatID: id)
        let destination = LampWritingWorkspace.url(libraryRootURL: libraryRootURL, writingID: writingID)
        var choices = AgentChatChoicesStore.load(in: source)
        choices.set(providerID, for: AgentChatChoices.providerKey)

        let existing = AgentChatTranscriptStore.load(providerID: providerID, in: destination)
        if holdsCopy(of: id, existing) {
            try AgentChatChoicesStore.save(choices, in: destination)
            return true
        }
        guard existing.messages.isEmpty, (existing.events ?? []).isEmpty else {
            throw CopyError.writingHasAConversation
        }

        let transcript = AgentChatTranscriptStore.load(providerID: providerID, in: source)
        guard let end = lastTurn(of: transcript, upTo: turn),
              var copied = transcript.forked(at: end)
        else { return false }

        // After everything copied, whatever the clocks say: the mark is drawn
        // where it falls in the conversation's order, and a turn dated a
        // moment after `now` would otherwise appear below it.
        let latest = (copied.events ?? []).map(\.date).max() ?? now
        let markedAt = max(now, latest.addingTimeInterval(0.001))
        let mark = UUID()
        copied.events = (copied.events ?? []) + [AgentChatTranscript.Event(
            id: mark, turn: mark, date: markedAt,
            kind: copiedEventKind, name: id.uuidString
        )]
        copied.startedAt = markedAt

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try AgentChatTranscriptStore.save(copied, providerID: providerID, in: destination)
        try AgentChatChoicesStore.save(choices, in: destination)
        return true
    }

    /// Whether this transcript is already a copy of that chat.
    static func holdsCopy(of chat: UUID, _ transcript: AgentChatTranscript) -> Bool {
        (transcript.events ?? []).contains {
            $0.kind == copiedEventKind && $0.name == chat.uuidString
        }
    }

    /// The turn a copy ends with: `turn`, or the conversation's last, and any
    /// answers that follow it.
    ///
    /// A transcript written before events keeps each message as a turn of
    /// its own, so the answer to a question is the turn *after* it. Ending
    /// at the question would leave the answer behind — and for a copy of the
    /// whole conversation, its final answer.
    static func lastTurn(of transcript: AgentChatTranscript, upTo turn: UUID?) -> UUID? {
        let turns = transcript.turns
        guard !turns.isEmpty else { return nil }
        var end = turns.count - 1
        if let turn {
            guard let index = turns.firstIndex(where: { $0.id == turn }) else { return nil }
            end = index
        }
        while end + 1 < turns.count, turns[end + 1].question == nil { end += 1 }
        return turns[end].id
    }

    /// Whether a writing asked for in a reader chat can be started now, with
    /// the whole of the turn that asked for it.
    ///
    /// The request is made from inside a reply, so the reply has to be on
    /// disk before the conversation is copied: copied sooner, it ends with
    /// the question. Finishing a turn is not enough to say so — the save
    /// that ends it can fail — so this asks whether the transcript was
    /// written after the request was made. Its file's date, rather than an
    /// answer in it: a reply stopped before it said anything is saved with
    /// nothing to show for it, and is as finished as one that spoke.
    ///
    /// A request older than this run of Lamp is ready whatever the
    /// transcript says: the reply that made it ended with an earlier run,
    /// finished or not, and nothing is coming to complete it.
    public static func isReady(
        askedAt: Date,
        chat id: UUID,
        providerID: String,
        libraryRootURL: URL,
        isRunning: Bool,
        launchedAt: Date
    ) -> Bool {
        guard !isRunning else { return false }
        if askedAt < launchedAt { return true }
        let url = AgentChatTranscriptStore.url(
            providerID: providerID,
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: libraryRootURL, chatID: id)
        )
        guard let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        else { return false }
        return written >= askedAt
    }

    /// Where a copy asked for at `askedAt` ends: the turn that was under way
    /// when it was asked, which is the turn that asked.
    ///
    /// Bounded by that turn, so a request taken in late — its first attempt
    /// failed, and the conversation went on — copies the conversation as it
    /// was when the reader asked, not what was said after. Nil, with
    /// `replaced` set, where the conversation that asked is no longer the
    /// one in the chat: it was cleared since, and what is there now is a
    /// conversation the request never saw.
    public static func requestingTurn(
        askedAt: Date,
        chat id: UUID,
        providerID: String,
        libraryRootURL: URL
    ) -> (turn: UUID?, replaced: Bool) {
        let transcript = AgentChatTranscriptStore.load(
            providerID: providerID,
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: libraryRootURL, chatID: id)
        )
        if let started = transcript.startedAt, started > askedAt { return (nil, true) }
        let asking = transcript.turns.last { $0.question != nil && $0.date <= askedAt }
        return (asking?.id, false)
    }

    /// A writing started from a reader chat, as that chat remembers it.
    public struct Started: Codable, Equatable, Identifiable, Sendable {
        public let writingID: String
        public let title: String
        public let startedAt: Date

        public var id: String { writingID }

        public init(writingID: String, title: String, startedAt: Date = Date()) {
            self.writingID = writingID
            self.title = title
            self.startedAt = startedAt
        }
    }

    static let startedFilename = "started-writings.json"

    static func startedURL(chat id: UUID, libraryRootURL: URL) -> URL {
        AgentChatTranscriptStore.directory(
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: libraryRootURL, chatID: id)
        ).appendingPathComponent(startedFilename)
    }

    /// The writings started from this chat, oldest first.
    ///
    /// Kept beside the chat's transcript rather than in it: the chat pane
    /// owns its transcript while a reply is arriving, and this is written by
    /// whatever started the writing, which may be that very reply.
    public static func started(chat id: UUID, libraryRootURL: URL) -> [Started] {
        guard let data = try? Data(contentsOf: startedURL(chat: id, libraryRootURL: libraryRootURL)) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([Started].self, from: data)) ?? [])
            .sorted { $0.startedAt < $1.startedAt }
    }

    public static func recordStarted(
        _ started: Started, chat id: UUID, libraryRootURL: URL
    ) throws {
        var all = Self.started(chat: id, libraryRootURL: libraryRootURL)
            .filter { $0.writingID != started.writingID }
        all.append(started)
        let url = startedURL(chat: id, libraryRootURL: libraryRootURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(all).write(to: url, options: .atomic)
    }
}
