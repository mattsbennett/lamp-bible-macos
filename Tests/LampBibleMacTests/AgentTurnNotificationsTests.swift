import Foundation
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
}
