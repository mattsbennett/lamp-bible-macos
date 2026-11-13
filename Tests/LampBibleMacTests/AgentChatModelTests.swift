import Foundation
import LampBibleMacSupport
import Testing
@testable import LampBibleMac

/// The chat model, driven rather than read.
///
/// Four rounds of review found faults in this sequence — an undo reversed
/// by the save that followed it, a second check that widened what the undo
/// took, a repair that dropped another Mac's session, a New Chat from
/// elsewhere that sent messages into a conversation they were never
/// written to. Every one of them shipped first, because nothing could run
/// it: the tests linked the support module and the model lives in the app.
/// They can run it now.
@MainActor
struct AgentChatModelTests {
    private let providerID = AIProviderCLI.claude.rawValue

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(
        _ turn: UUID, _ at: Double, role: AgentChatTranscript.Role, _ text: String
    ) -> AgentChatTranscript.Event {
        AgentChatTranscript.Event(
            turn: turn, date: Date(timeIntervalSince1970: at),
            kind: AgentChatTranscript.Event.said, role: role, text: text
        )
    }

    /// A conversation of complete turns, as the file would hold it.
    private func conversation(
        _ id: UUID, _ turns: [(UUID, Double, String)],
        session: String? = nil, install: String? = nil
    ) -> AgentChatTranscript {
        let events = turns.flatMap { turn, at, question in
            [event(turn, at, role: .user, question), event(turn, at + 1, role: .assistant, "Done.")]
        }
        return AgentChatTranscript(
            conversationID: id,
            startedAt: Date(timeIntervalSince1970: 1),
            sessionID: session,
            sessionInstallID: install,
            messages: AgentChatTranscript.messages(from: events),
            events: events
        )
    }

    private func onDisk(in workspace: URL) -> AgentChatTranscript {
        AgentChatTranscriptStore.load(providerID: providerID, in: workspace)
    }

    /// The save that follows an undo used to merge the whole conversation
    /// straight back in, with the provider session it was undone from.
    @Test func anUndoneTurnIsGoneFromTheFileItWasUndoneIn() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = UUID(), second = UUID()
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(first, 10, "One"), (second, 20, "Two")],
                         session: "s1", install: LampInstallIdentity.current()),
            providerID: providerID, in: workspace
        )

        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.canRevert(turn: second))
        let going = model.turnsUndoneBy(second)
        #expect(going == [second])
        #expect(model.revert(turns: going))

        let saved = onDisk(in: workspace)
        #expect(saved.turns.map(\.question) == ["One"])
        #expect(saved.removedTurns?.contains(second) == true)
        #expect(saved.sessionID == nil, "the session still held the undone turn")
        // And it stays gone when the pane writes again.
        model.load()
        #expect(onDisk(in: workspace).turns.map(\.question) == ["One"])
    }

    /// A turn can arrive from another Mac between the host being asked and
    /// the conversation being trimmed. It is not part of what was agreed.
    @Test func onlyTheAgreedTurnsAreTaken() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID(), first = UUID(), second = UUID(), arrived = UUID()
        try AgentChatTranscriptStore.save(
            conversation(id, [(first, 10, "One"), (second, 20, "Two")]),
            providerID: providerID, in: workspace
        )

        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        let going = model.turnsUndoneBy(second)

        // Sync lands while the host is putting the writing back.
        try AgentChatTranscriptStore.save(
            conversation(id, [(first, 10, "One"), (second, 20, "Two"), (arrived, 30, "Three")]),
            providerID: providerID, in: workspace
        )
        #expect(model.revert(turns: going))

        let saved = onDisk(in: workspace)
        #expect(saved.turns.map(\.question) == ["One", "Three"], "nobody put the arriving turn's work back")
    }

    /// A copy written by a Lamp that has no name for the record brings the
    /// turns back. Shown without them is half the answer: the file is put
    /// right too, or the undo lasts only until the app next opens — and
    /// the session that copy carries is not this Mac's to erase.
    @Test func aCopyWithoutTheRecordIsRepairedAndKeepsItsSession() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID(), first = UUID(), second = UUID()
        try AgentChatTranscriptStore.save(
            conversation(id, [(first, 10, "One"), (second, 20, "Two")]),
            providerID: providerID, in: workspace
        )
        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.revert(turns: model.turnsUndoneBy(second)))

        // The other Mac rewrites it, with every turn back and a session of
        // its own — a session that has seen the turn being undone.
        let elsewhere = UUID().uuidString
        try AgentChatTranscriptStore.save(
            conversation(id, [(first, 10, "One"), (second, 20, "Two")],
                         session: "theirs", install: elsewhere),
            providerID: providerID, in: workspace
        )
        model.reloadIfChangedOnDisk()

        let saved = onDisk(in: workspace)
        #expect(saved.turns.map(\.question) == ["One"], "put right on disk, not only on screen")
        #expect(saved.removedTurns?.contains(second) == true)
        #expect(saved.sessionID == nil, "that session still holds the turn that was undone")
    }

    /// The other Mac had already taken the undo, carried the conversation
    /// on in a session of its own, and written the file without the record
    /// it has no name for. Nothing is resurrected — so nothing of theirs
    /// should be thrown away either, least of all a session they are in
    /// the middle of.
    @Test func repairingAFileLeavesASessionThisMacCannotResume() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let id = UUID(), first = UUID(), second = UUID()
        try AgentChatTranscriptStore.save(
            conversation(id, [(first, 10, "One"), (second, 20, "Two")]),
            providerID: providerID, in: workspace
        )
        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.revert(turns: model.turnsUndoneBy(second)))

        let elsewhere = UUID().uuidString
        var theirs = conversation(id, [(first, 10, "One")], session: "theirs", install: elsewhere)
        theirs.removedTurns = nil
        try AgentChatTranscriptStore.save(theirs, providerID: providerID, in: workspace)
        model.reloadIfChangedOnDisk()

        let saved = onDisk(in: workspace)
        #expect(saved.turns.map(\.question) == ["One"])
        #expect(saved.removedTurns?.contains(second) == true, "the record is written back")
        #expect(saved.sessionID == "theirs", "a session this Mac cannot resume is still theirs")
        #expect(saved.sessionInstallID == elsewhere)
    }

    /// A New Chat made here throws away what was waiting. One that arrives
    /// through sync had nothing here to do that, and those messages were
    /// drained into a conversation they were never written to.
    @Test func messagesWaitingForAConversationPutAwayElsewhereAreNotSentOn() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let theirs = UUID(), mine = UUID()
        var queue = AgentChatQueue()
        queue.add("Ask about Hebrews 4", conversation: mine)
        try AgentChatQueueStore.save(queue, providerID: providerID, in: workspace)
        try AgentChatTranscriptStore.save(
            conversation(theirs, [(UUID(), 40, "A fresh start")]),
            providerID: providerID, in: workspace
        )

        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.queued.isEmpty, "written to a conversation that has been put away")
        #expect(AgentChatQueueStore.load(providerID: providerID, in: workspace).messages.isEmpty)
    }

    /// Queued before any of this was recorded, so it belongs to whatever
    /// conversation is open: dropping it would be dropping their words.
    @Test func aMessageQueuedBeforeTheRecordIsKept() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var queue = AgentChatQueue()
        queue.add("Still wanted")
        try AgentChatQueueStore.save(queue, providerID: providerID, in: workspace)
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 40, "Hello")]),
            providerID: providerID, in: workspace
        )

        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.queued.map(\.text) == ["Still wanted"])
    }

    /// Sync can put a cleared conversation on disk while the reader is
    /// looking at the confirmation. The turn they are about to undo is no
    /// longer there to undo, and that has to be found out before the
    /// writing is put back rather than after.
    @Test func aTurnClearedElsewhereCannotBeUndone() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let second = UUID()
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 10, "One"), (second, 20, "Two")]),
            providerID: providerID, in: workspace
        )
        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.canRevert(turn: second))

        // The other Mac starts again, and it syncs before the reader
        // presses Undo.
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 40, "A fresh start")]),
            providerID: providerID, in: workspace
        )
        #expect(model.canRevert(turn: second) == false, "there is nothing left to put back for")
    }

    /// A New Chat here takes the conversation's record with it: what was
    /// undone in the one being put away says nothing about its
    /// replacement, and the messages waiting were written to the one going.
    @Test func startingAgainLeavesNothingOfTheOldConversationBehind() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let second = UUID()
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 10, "One"), (second, 20, "Two")]),
            providerID: providerID, in: workspace
        )
        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.revert(turns: model.turnsUndoneBy(second)))
        model.enqueue("Something for later")
        #expect(model.queued.count == 1)

        model.clearConversation()

        let saved = onDisk(in: workspace)
        #expect(saved.messages.isEmpty)
        #expect(saved.removedTurns == nil, "the record went with the conversation it was a record of")
        #expect(model.queued.isEmpty, "those were written to the conversation being put away")
    }

    /// The date an undo happened has to reach the file. Built in `revert`
    /// and left out of the save, it lasted until the next write — and the
    /// test that checked it drove the transcript directly, so it passed
    /// while the path the reader takes dropped it every time.
    @Test func whenATurnWasUndoneIsWrittenDown() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let second = UUID()
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 10, "One"), (second, 20, "Two")]),
            providerID: providerID, in: workspace
        )
        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        #expect(model.revert(turns: model.turnsUndoneBy(second)))

        let saved = onDisk(in: workspace)
        let removedAt = try #require(saved.removedAt)
        #expect(saved.lastActivity >= removedAt, "the undo is the newest thing in this conversation")
        #expect(
            saved.lastActivity > Date(timeIntervalSince1970: 21),
            "and the conversation did not become older by having a turn taken out"
        )

        // And it survives an ordinary save that changes nothing else.
        model.load()
        #expect(onDisk(in: workspace).removedAt != nil)
    }

    /// A message waiting for a conversation that is put away *while it is
    /// being prepared* must not be taken up by its replacement.
    @Test func aMessageIsNotHandedToAConversationThatReplacedItsOwn() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 10, "One")]),
            providerID: providerID, in: workspace
        )
        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        model.load()
        model.enqueue("Ask about Hebrews 4")
        #expect(model.queued.count == 1)

        // The other Mac starts again, and it syncs before the message goes.
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 40, "A fresh start")]),
            providerID: providerID, in: workspace
        )
        model.reloadIfChangedOnDisk()

        #expect(model.reserveNextQueued() == nil, "not into a conversation it was never written to")
        #expect(model.queued.isEmpty)
    }

    /// A chat nobody will ask for again is let go — but not while it is
    /// in use, and the request is remembered rather than dropped.
    ///
    /// Kept chats are held for the life of the process on purpose, so a
    /// run outlives its pane and two panes find one conversation. Nothing
    /// released them, so a long session kept every transcript and every
    /// runner it had opened.
    @Test func aChatIsLetGoOnceNobodyIsUsingIt() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = KeptAgentChats.model(provider: .claude, workspace: workspace, mode: .writing)

        // A pane is showing it: each registers an observer on appearing.
        model.observeTurn(for: "pane") { _ in }
        KeptAgentChats.release(provider: .claude, workspace: workspace)
        #expect(
            KeptAgentChats.existing(provider: .claude, workspace: workspace) === model,
            "refused while a pane is still showing it"
        )

        // The pane goes, which is what it was waiting for.
        model.stopObservingTurn(for: "pane")
        #expect(
            KeptAgentChats.existing(provider: .claude, workspace: workspace) == nil,
            "and let go without being asked twice"
        )

        // Asked for again, it is a new chat reading the same files.
        let reopened = KeptAgentChats.model(provider: .claude, workspace: workspace, mode: .writing)
        #expect(reopened !== model)
    }

    /// Releasing a chat with no pane showing it happens at once.
    @Test func aChatWithNoPaneGoesImmediately() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = KeptAgentChats.model(provider: .claude, workspace: workspace, mode: .writing)
        KeptAgentChats.release(provider: .claude, workspace: workspace)
        #expect(KeptAgentChats.existing(provider: .claude, workspace: workspace) == nil)
    }

    /// Releasing one leaves the others alone — they are keyed per
    /// workspace, and a reader tab's chat is its own.
    @Test func lettingOneGoLeavesTheRest() throws {
        let first = try workspace(), second = try workspace()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let kept = KeptAgentChats.model(provider: .claude, workspace: second, mode: .writing)
        _ = KeptAgentChats.model(provider: .claude, workspace: first, mode: .writing)
        KeptAgentChats.release(provider: .claude, workspace: first)
        #expect(KeptAgentChats.existing(provider: .claude, workspace: first) == nil)
        #expect(KeptAgentChats.existing(provider: .claude, workspace: second) === kept)
    }

    /// Every pane is told the queue has been read, and one going away
    /// takes only its own listening with it.
    ///
    /// A single callback with an owner token stopped a pane clearing
    /// another pane's, but could not hand the job back: with two open,
    /// the second to appear owned it, and when that one went the first
    /// was left listening to nothing while still on screen.
    @Test func everyPaneHearsThatTheQueueWasRead() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentChatTranscriptStore.save(
            conversation(UUID(), [(UUID(), 10, "One")]), providerID: providerID, in: workspace
        )
        var queue = AgentChatQueue()
        queue.add("Waiting")
        try AgentChatQueueStore.save(queue, providerID: providerID, in: workspace)

        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)
        var heard: [String] = []
        model.observeQueueReady(for: "first") { heard.append("first") }
        model.observeQueueReady(for: "second") { heard.append("second") }

        // The second pane closes; the first is still showing the chat.
        model.stopObservingQueueReady(for: "second")
        model.load()

        #expect(heard == ["first"], "the pane still on screen is told")
    }

    /// A turn that ends can still be asked for once.
    ///
    /// SwiftUI delivers two state changes in one update cycle as their
    /// net change, so a pane that opens as a turn ends is told the turn
    /// and then nil, and hears neither — measured in a hosted-view probe,
    /// not assumed. The run's last write lands exactly then, so the host
    /// asks rather than waiting to be told.
    @Test func aTurnThatHasJustEndedCanStillBeAccountedFor() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = NativeAgentChatModel(provider: .claude, workspace: workspace, mode: .writing)

        #expect(model.takeTurnForAttribution() == nil, "nothing has run")

        let turn = UUID()
        model.setCurrentTurnForTesting(turn)
        #expect(model.takeTurnForAttribution() == turn, "while it runs")
        #expect(model.takeTurnForAttribution() == turn, "and it is still running")

        model.setCurrentTurnForTesting(nil)
        #expect(model.takeTurnForAttribution() == turn, "its last write is still its own")
        #expect(model.takeTurnForAttribution() == nil, "taken once; what follows belongs to nobody")

        // A new turn starting clears what the old one left.
        let next = UUID()
        model.setCurrentTurnForTesting(next)
        model.setCurrentTurnForTesting(nil)
        #expect(model.takeTurnForAttribution() == next)
    }

    /// Every pane on a workspace is one chat, and every pane is told which
    /// turn is running — including one that opened while it already was.
    @Test func everyPaneSharesTheChatAndIsToldWhereItStands() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = KeptAgentChats.model(provider: .claude, workspace: workspace, mode: .writing)
        #expect(
            KeptAgentChats.model(provider: .claude, workspace: workspace, mode: .writing) === model,
            "two panes, one conversation"
        )

        var first: [UUID?] = [], second: [UUID?] = []
        model.observeTurn(for: "first") { first.append($0) }
        #expect(first == [nil], "told where things stand, not only about the next change")

        // A pane that opens once a turn is already running.
        model.observeTurn(for: "second") { second.append($0) }
        #expect(second == [nil])

        model.stopObservingTurn(for: "first")
        model.stopObservingTurn(for: "second")
    }
}
