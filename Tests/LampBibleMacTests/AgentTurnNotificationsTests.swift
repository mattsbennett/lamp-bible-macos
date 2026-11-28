import CloudKit
import Foundation
import LampBibleMacSupport
import Testing
@testable import LampBibleMac

struct AgentTurnNotificationsTests {
    @Test func excerptReadsAsPlainWords() {
        let reply = """
        ## The point

        **Grace** is *given*, not earned — see [John 3:16](lampbible://verse/43003016).

        - first
        - second
        """
        #expect(AgentTurnNotifications.excerpt(of: reply)
            == "The point Grace is given, not earned — see John 3:16. first second")
    }

    @Test func excerptLeavesOutCodeAndImages() {
        let reply = "Here:\n```swift\nlet x = 1\n```\n![chart](a.png) Done."
        #expect(AgentTurnNotifications.excerpt(of: reply) == "Here: Done.")
    }

    @Test func excerptIsCutAtAWord() {
        let reply = String(repeating: "word ", count: 100)
        let excerpt = AgentTurnNotifications.excerpt(of: reply, limit: 22)
        #expect(excerpt == "word word word word\u{2026}")
    }

    @MainActor
    @Test func aRepliedTurnSaysOnlyThatWhenTheReplyIsHidden() {
        #expect(AgentTurnNotifications.body(for: .replied("**Yes.**"), showsReply: true) == "Yes.")
        #expect(AgentTurnNotifications.body(for: .replied("**Yes.**"), showsReply: false) == "Replied.")
        #expect(AgentTurnNotifications.body(for: .failed("Signed out."), showsReply: true)
            == "Couldn\u{2019}t finish: Signed out.")
    }

    @Test func aRouteSurvivesTheNotificationsUserInfo() {
        let chat = UUID()
        for route in [AgentTurnRoute.readerChat(chat), .writing("w-1")] {
            #expect(AgentTurnRoute(userInfo: route.userInfo) == route)
        }
        #expect(AgentTurnRoute(userInfo: [:]) == nil)
        #expect(AgentTurnRoute(userInfo: ["lampTurnRouteKind": "readerChat", "lampTurnRouteID": "nope"]) == nil)
    }

    /// A wait is told on the same record type with the same fields an end
    /// has, so no schema changes (`decisions/0045`), with its own turn id, and
    /// who waits, never on what.
    @MainActor
    @Test func aWaitIsAnEndsRecordWithItsOwnNameAndTurn() {
        let turn = UUID()
        let ended = AgentTurnPush.record(for: AgentTurnPush.Ended(
            deviceID: "phone-1", chat: .writing("w1"), turnID: turn, title: "Talk", subtitle: "",
            outcome: .replied("Done."), endedAt: Date()
        ), showsReply: true)
        let waiting = AgentTurnPush.Waiting(
            deviceID: "phone-1", chat: .writing("w1"), title: "Talk", providerName: "Codex",
            began: Date(timeIntervalSince1970: 2_000)
        )
        let record = AgentTurnPush.record(for: waiting)
        #expect(record.recordType == ended.recordType)
        #expect(Set(record.allKeys()).isSubset(of: Set(ended.allKeys())))
        #expect(record.recordID.recordName == "wait.phone-1.\(LampAgentRemoteHosting.Chat.writing("w1").id)")
        #expect(record.recordID.recordName != ended.recordID.recordName)
        let waitTurn = record["turnID"] as? String
        #expect(waitTurn == waiting.waitID.uuidString)
        #expect(waitTurn != turn.uuidString)
        #expect(record["outcome"] as? String == "waiting")
        #expect(record["summary"] as? String == "Codex is waiting for your answer.")
        #expect(record["body"] as? String == record["summary"] as? String)
        #expect(record["subtitle"] as? String == "")
        #expect(record["kind"] as? String == "writing")
        #expect(record["writingID"] as? String == "w1")
        #expect(record["endedAt"] as? Date == Date(timeIntervalSince1970: 2_000))
        // Every word in it is the provider's name, the chat's, or Lamp's.
        let words = record.allKeys().compactMap { record[$0] as? String }.joined(separator: " ")
        #expect(!words.contains("make") && !words.contains("/"))
    }

    /// A wait record to delete is kept, across launches, until its delete
    /// went or found it gone.
    @Test func waitsToClearAreKeptUntilCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "wait-clears-\(UUID().uuidString)"))
        AgentTurnPush.PendingClears.add("wait.a.b", in: defaults)
        AgentTurnPush.PendingClears.add("wait.a.b", in: defaults)
        AgentTurnPush.PendingClears.add("wait.a.c", in: defaults)
        #expect(AgentTurnPush.PendingClears.names(in: defaults) == ["wait.a.b", "wait.a.c"])
        AgentTurnPush.PendingClears.remove("wait.a.b", in: defaults)
        #expect(AgentTurnPush.PendingClears.names(in: defaults) == ["wait.a.c"])
    }

    @Test func aWaitIsToldOnceAndTakenBack() {
        #expect(AgentTurnPush.change(wasWaiting: false, isWaiting: true) == .tell)
        #expect(AgentTurnPush.change(wasWaiting: true, isWaiting: true) == .none)
        #expect(AgentTurnPush.change(wasWaiting: true, isWaiting: false) == .clear)
        #expect(AgentTurnPush.change(wasWaiting: false, isWaiting: false) == .none)
    }

    @MainActor
    @Test func aPushedTurnIsOneRecordPerPhoneAndChat() {
        let chat = UUID()
        let turn = UUID()
        let ended = AgentTurnPush.Ended(
            deviceID: "phone-1", chat: .reader(chat), turnID: turn,
            title: "Reader Chat", subtitle: "", outcome: .replied("**Grace** is given."),
            endedAt: Date(timeIntervalSince1970: 1_000)
        )
        let record = AgentTurnPush.record(for: ended, showsReply: true)
        #expect(record.recordType == "AgentTurnEnded")
        #expect(record.recordID.recordName == "turn.phone-1.\(chat.uuidString)")
        #expect(record["deviceID"] as? String == "phone-1")
        #expect(record["chatID"] as? String == chat.uuidString)
        #expect(record["kind"] as? String == "reader")
        #expect(record["writingID"] == nil)
        #expect(record["turnID"] as? String == turn.uuidString)
        #expect(record["subtitle"] as? String == "")
        #expect(record["outcome"] as? String == "replied")
        #expect(record["summary"] as? String == "Replied.")
        #expect(record["body"] as? String == "Grace is given.")
        #expect(record["endedAt"] as? Date == Date(timeIntervalSince1970: 1_000))
        #expect(record["collapseID"] == nil)
    }

    @MainActor
    @Test func withoutTheReplyAllowedItsWordsAreNotWrittenAtAll() {
        let ended = AgentTurnPush.Ended(
            deviceID: "phone-1", chat: .writing("w-1"), turnID: UUID(),
            title: "Sermon", subtitle: "", outcome: .replied("Secret words."), endedAt: Date()
        )
        let record = AgentTurnPush.record(for: ended, showsReply: false)
        #expect(record["kind"] as? String == "writing")
        #expect(record["writingID"] as? String == "w-1")
        #expect(record["chatID"] as? String == "writing:w-1")
        #expect(record["body"] as? String == "Replied.")
        let written = record.allKeys().compactMap { record[$0] as? String }
        #expect(!written.contains { $0.contains("Secret") })
    }

    @MainActor
    @Test func aStopLampMadeIsStoppedAndAFailureFailed() {
        #expect(AgentTurnPush.outcomeName(.stoppedByLamp("Usage limit reached.")) == "stopped")
        #expect(AgentTurnPush.outcomeName(.failed("Signed out.")) == "failed")
        #expect(AgentTurnPush.outcomeName(.replied("Yes.")) == "replied")
    }
}
