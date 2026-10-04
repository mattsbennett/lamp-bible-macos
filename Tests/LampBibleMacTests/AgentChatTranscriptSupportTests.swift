import Foundation
import Testing
@testable import LampBibleMacSupport

struct AgentChatTranscriptTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(
        _ role: AgentChatTranscript.Role,
        _ text: String,
        at offset: TimeInterval
    ) -> AgentChatTranscript.Message {
        AgentChatTranscript.Message(role: role, text: text, date: base.addingTimeInterval(offset))
    }

    @Test func transcriptsWrittenBeforeSyncStillLoad() throws {
        // The shape the chat pane wrote before transcripts synced: no
        // conversation identity and no record of which Mac owns the session.
        let legacy = """
        {
          "messages" : [
            { "date" : 800000000, "id" : "8A6C1D2E-3F40-4A5B-9C6D-7E8F90A1B2C3", "role" : "user", "text" : "Hello" }
          ],
          "sessionID" : "session-1"
        }
        """
        let transcript = try AgentChatTranscriptStore.decode(Data(legacy.utf8))

        #expect(transcript.messages.map(\.text) == ["Hello"])
        #expect(transcript.conversationID == nil)
        // Until transcripts synced, a session could only have been made here.
        #expect(transcript.resumableSessionID(forInstall: "any-install") == "session-1")
    }

    @Test func onlyTheOwningInstallMayResume() {
        let transcript = AgentChatTranscript(sessionID: "session-1", sessionInstallID: "mac-a")

        #expect(transcript.resumableSessionID(forInstall: "mac-a") == "session-1")
        #expect(transcript.resumableSessionID(forInstall: "mac-b") == nil)
    }

    @Test func attributionOnlyFillsAMissingOwner() {
        let unattributed = AgentChatTranscript(sessionID: "session-1")
        let owned = AgentChatTranscript(sessionID: "session-1", sessionInstallID: "mac-a")
        let sessionless = AgentChatTranscript()

        #expect(unattributed.attributingSession(toInstall: "mac-b").sessionInstallID == "mac-b")
        #expect(owned.attributingSession(toInstall: "mac-b").sessionInstallID == "mac-a")
        #expect(sessionless.attributingSession(toInstall: "mac-b").sessionInstallID == nil)
    }

    @Test func transcriptsRoundTrip() throws {
        let transcript = AgentChatTranscript(
            conversationID: UUID(),
            startedAt: base,
            sessionID: "session-1",
            sessionInstallID: "mac-a",
            messages: [message(.user, "Hi", at: 1), message(.assistant, "Hello", at: 2)]
        )
        let decoded = try AgentChatTranscriptStore.decode(AgentChatTranscriptStore.encode(transcript))
        #expect(decoded == transcript)
    }

    @Test func transcriptFilenamesCannotAddressOtherPaths() {
        #expect(AgentChatTranscriptStore.isTranscriptFilename("native-chat-claude.json"))
        #expect(AgentChatTranscriptStore.isTranscriptFilename("native-chat-openCode.json"))
        #expect(!AgentChatTranscriptStore.isTranscriptFilename("native-chat-.json"))
        #expect(!AgentChatTranscriptStore.isTranscriptFilename("native-chat-../x.json"))
        #expect(!AgentChatTranscriptStore.isTranscriptFilename("native-chat-a/b.json"))
        #expect(!AgentChatTranscriptStore.isTranscriptFilename("draft-sync.json"))
        #expect(!AgentChatTranscriptStore.isTranscriptFilename("native-chat-claude.md"))
    }
}

struct AgentChatTranscriptMergeTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let conversation = UUID()

    private func message(_ text: String, at offset: TimeInterval) -> AgentChatTranscript.Message {
        AgentChatTranscript.Message(role: .user, text: text, date: base.addingTimeInterval(offset))
    }

    @Test func aLongerCopyOfTheConversationWinsWithItsSession() {
        let first = message("one", at: 1)
        let second = message("two", at: 2)
        let local = AgentChatTranscript(
            conversationID: conversation,
            sessionID: "a", sessionInstallID: "mac-a",
            messages: [first]
        )
        let incoming = AgentChatTranscript(
            conversationID: conversation,
            sessionID: "b", sessionInstallID: "mac-b",
            messages: [first, second]
        )

        #expect(AgentChatTranscriptMerge.merge(local: local, incoming: incoming) == incoming)
        #expect(AgentChatTranscriptMerge.merge(local: incoming, incoming: local) == incoming)
    }

    @Test func conversationsCarriedOnInTwoPlacesKeepEveryMessage() {
        let shared = message("shared", at: 1)
        let fromA = message("from a", at: 3)
        let fromB = message("from b", at: 2)
        let local = AgentChatTranscript(
            conversationID: conversation,
            sessionID: "a", sessionInstallID: "mac-a",
            messages: [shared, fromA]
        )
        let incoming = AgentChatTranscript(
            conversationID: conversation,
            sessionID: "b", sessionInstallID: "mac-b",
            messages: [shared, fromB]
        )

        let merged = AgentChatTranscriptMerge.merge(local: local, incoming: incoming)
        #expect(merged.messages.map(\.text) == ["shared", "from b", "from a"])
        // Neither provider session has seen the other Mac's turns.
        #expect(merged.sessionID == nil)
        // Both Macs reach the same result.
        #expect(AgentChatTranscriptMerge.merge(local: incoming, incoming: local).messages == merged.messages)
    }

    @Test func aClearSpreadsToOtherMacs() {
        let old = AgentChatTranscript(
            conversationID: conversation,
            startedAt: base,
            messages: [message("old", at: 1)]
        )
        let cleared = AgentChatTranscript(conversationID: UUID(), startedAt: base.addingTimeInterval(10))

        #expect(AgentChatTranscriptMerge.merge(local: old, incoming: cleared) == cleared)
        #expect(AgentChatTranscriptMerge.merge(local: cleared, incoming: old) == cleared)
    }

    @Test func chattingAfterAClearElsewhereKeepsTheConversation() {
        let continued = AgentChatTranscript(
            conversationID: conversation,
            startedAt: base,
            messages: [message("old", at: 1), message("after the clear", at: 20)]
        )
        let cleared = AgentChatTranscript(conversationID: UUID(), startedAt: base.addingTimeInterval(10))

        #expect(AgentChatTranscriptMerge.merge(local: cleared, incoming: continued) == continued)
    }
}

struct AgentChatContinuationTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(
        _ role: AgentChatTranscript.Role,
        _ text: String
    ) -> AgentChatTranscript.Message {
        AgentChatTranscript.Message(role: role, text: text, date: base)
    }

    @Test func aFreshConversationIsSentAsIs() {
        #expect(AgentChatContinuation.prompt(continuing: [], with: "Hello") == "Hello")
    }

    @Test func theRecapCarriesEarlierTurnsInOrderBeforeTheNewMessage() {
        let prompt = AgentChatContinuation.prompt(
            continuing: [message(.user, "Tighten the opening"), message(.assistant, "Done — cut 40 words.")],
            with: "Now add a closing prayer"
        )

        let user = prompt.range(of: "User: Tighten the opening")
        let assistant = prompt.range(of: "Assistant: Done — cut 40 words.")
        let newMessage = prompt.range(of: "Now add a closing prayer")
        #expect(user != nil && assistant != nil && newMessage != nil)
        #expect(user!.lowerBound < assistant!.lowerBound)
        #expect(assistant!.lowerBound < newMessage!.lowerBound)
        #expect(prompt.contains("reread them"))
        #expect(prompt.hasSuffix("Now add a closing prayer"))
    }

    @Test func theOldestTurnsAreDroppedFirstWhenTheBudgetRunsOut() {
        let earlier = (1...10).map { message(.user, "turn \($0) " + String(repeating: "x", count: 80)) }

        let prompt = AgentChatContinuation.prompt(continuing: earlier, with: "next", characterBudget: 300)

        #expect(prompt.contains("turn 10"))
        #expect(!prompt.contains("turn 1 "))
        #expect(prompt.contains("earlier messages omitted]"))
    }

    @Test func anOversizedLatestMessageKeepsItsEnd() {
        let long = "beginning " + String(repeating: "x", count: 1_000) + " ending"

        let prompt = AgentChatContinuation.prompt(
            continuing: [message(.assistant, long)],
            with: "next",
            characterBudget: 200
        )

        #expect(prompt.contains("ending"))
        #expect(!prompt.contains("beginning"))
    }
}

struct AgentChatResumeFailureTests {
    // Captured from each CLI asked to resume a session it doesn't have.
    private let claude = """
    No conversation found with session ID: 0b6f1c2e-0000-4000-8000-000000000001
    {"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"0b6f1c2e-0000-4000-8000-000000000001","errors":["No conversation found with session ID: 0b6f1c2e-0000-4000-8000-000000000001"]}
    """
    private let codex = "Error: thread/resume: thread/resume failed: no rollout found for thread id 0b6f1c2e-0000-4000-8000-000000000001 (code -32600)"
    private let openCode = "\u{1B}[91m\u{1B}[1mError: \u{1B}[0mSession not found"

    @Test func eachProvidersMissingSessionIsRecognised() {
        #expect(AgentChatResumeFailure.indicatesMissingSession(in: claude))
        #expect(AgentChatResumeFailure.indicatesMissingSession(in: codex))
        #expect(AgentChatResumeFailure.indicatesMissingSession(in: openCode))
    }

    @Test func otherFailuresKeepTheSession() {
        // These leave the session intact; starting over would discard the
        // provider's fuller record of it for nothing.
        #expect(!AgentChatResumeFailure.indicatesMissingSession(in: "Error: Invalid API key · Please run /login"))
        #expect(!AgentChatResumeFailure.indicatesMissingSession(in: "stream disconnected before completion: error sending request"))
        #expect(!AgentChatResumeFailure.indicatesMissingSession(in: "Rate limit reached"))
    }

    @Test func claudesEarlyFailureIsReportedRatherThanSwallowed() {
        let summary = AgentChatRunSummary.summarize(output: claude, provider: .claude)

        #expect(summary.response.isEmpty)
        #expect(summary.failure == "No conversation found with session ID: 0b6f1c2e-0000-4000-8000-000000000001")
    }
}

struct LampInstallIdentityTests {
    @Test func theIdentityIsCreatedOnceAndKept() throws {
        let suite = "lamp-install-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = LampInstallIdentity.current(in: defaults)
        #expect(!first.isEmpty)
        #expect(LampInstallIdentity.current(in: defaults) == first)
    }
}
