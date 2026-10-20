import Foundation
import LampBibleMacSupport
import Testing

/// What someone is told before moving their library. Tested because two of
/// the consequences are invisible from this Mac — an un-updated phone stops
/// receiving deletions, and the first sync afterwards fetches the library
/// once — so a later tidy-up of the wording could quietly drop the only
/// warning about either.
struct LampSyncMoveOfferTests {
    @Test func theMoveNamesTheVersionTheOtherDevicesNeedAndWhereToFindIt() {
        let explanation = LampSyncMoveOffer.migrate.explanation
        #expect(explanation.contains("1.2.0"))
        #expect(explanation.contains("iPhone and iPad"))
        #expect(
            explanation.contains("About in Lamp Bible's Settings"),
            "the version number is useless without saying where it is read"
        )
    }

    @Test func theMoveSaysDeletionsStopReachingAnOlderDevice() {
        let explanation = LampSyncMoveOffer.migrate.explanation
        #expect(explanation.contains("delete"))
        #expect(
            explanation.lowercased().contains("rather than losing"),
            "an older device keeps what it has; that has to be said plainly"
        )
    }

    @Test func theMoveSaysTheFirstSyncIsSlow() {
        #expect(LampSyncMoveOffer.migrate.explanation.contains("longer than usual"))
    }

    @Test func theMoveSaysItIsSafeToRunAgain() {
        #expect(LampSyncMoveOffer.migrate.explanation.contains("safe to"))
    }

    /// Joining is the one that cannot be undone, so it says so and says to
    /// check the address first.
    @Test func joiningWarnsThatTheTwoLibrariesWouldBeMerged() {
        let explanation = LampSyncMoveOffer.join.explanation
        #expect(explanation.contains("no undo"))
        #expect(explanation.contains("sync address"))
        #expect(explanation.contains("merge"))
    }

    @Test func eachOfferHasItsOwnTitleAndButton() {
        #expect(LampSyncMoveOffer.migrate.title != LampSyncMoveOffer.join.title)
        #expect(LampSyncMoveOffer.migrate.buttonTitle == "Move Library")
        #expect(LampSyncMoveOffer.join.buttonTitle == "Join Library")
    }
}
