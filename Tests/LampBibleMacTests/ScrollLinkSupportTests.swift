import Foundation
import Testing
@testable import LampBibleMacSupport

struct ScrollLinkSupportTests {
    private let genesis1 = 1_001_000

    @Test func anchorPrefersTheEntryThatCoversTheVerse() {
        let anchors = [
            VerseAnchor(reference: genesis1 + 1, endReference: genesis1 + 5),
            VerseAnchor(reference: genesis1 + 8),
        ]

        #expect(VerseAnchorResolver.anchor(for: genesis1 + 3, in: anchors)?.reference == genesis1 + 1)
        #expect(VerseAnchorResolver.anchor(for: genesis1 + 8, in: anchors)?.reference == genesis1 + 8)
    }

    @Test func theMostSpecificCoveringEntryWins() {
        let anchors = [
            VerseAnchor(reference: genesis1 + 1, endReference: genesis1 + 10),
            VerseAnchor(reference: genesis1 + 4, endReference: genesis1 + 6),
        ]

        #expect(VerseAnchorResolver.anchor(for: genesis1 + 5, in: anchors)?.reference == genesis1 + 4)
        #expect(VerseAnchorResolver.anchor(for: genesis1 + 2, in: anchors)?.reference == genesis1 + 1)
    }

    @Test func gapsFallBackToTheLastEntryThatBeganEarlier() {
        // A commentary that covers verses 1 and 9 should stay on verse 1's note
        // while the reader passes through the verses it says nothing about.
        let anchors = [
            VerseAnchor(reference: genesis1 + 1),
            VerseAnchor(reference: genesis1 + 9),
        ]

        #expect(VerseAnchorResolver.anchor(for: genesis1 + 5, in: anchors)?.reference == genesis1 + 1)
        #expect(VerseAnchorResolver.anchor(for: genesis1 + 20, in: anchors)?.reference == genesis1 + 9)
    }

    @Test func versesBeforeAnyEntryResolveToTheFirstOne() {
        let anchors = [
            VerseAnchor(reference: genesis1 + 12),
            VerseAnchor(reference: genesis1 + 4),
        ]

        #expect(VerseAnchorResolver.anchor(for: genesis1 + 1, in: anchors)?.reference == genesis1 + 4)
        #expect(VerseAnchorResolver.anchor(for: genesis1 + 1, in: []) == nil)
    }

    @Test func anEndReferenceBeforeItsStartIsIgnored() {
        let anchor = VerseAnchor(reference: genesis1 + 7, endReference: genesis1 + 2)

        #expect(anchor.endReference == genesis1 + 7)
        #expect(anchor.covers(genesis1 + 7))
        #expect(!anchor.covers(genesis1 + 4))
    }

    @Test func theFirstPaneToMoveKeepsControlWhileItIsStillMoving() {
        var arbiter = ScrollLinkArbiter(settleInterval: 0.25)
        let start = Date()

        let readerTookControl = arbiter.claim(.reader, at: start)
        // The reader's scroll lands in the tool panel, which reports it right back.
        let echo = arbiter.claim(.tool, at: start.addingTimeInterval(0.02))
        let readerKeptControl = arbiter.claim(.reader, at: start.addingTimeInterval(0.05))

        #expect(readerTookControl)
        #expect(!echo)
        #expect(readerKeptControl)
        #expect(arbiter.owner == .reader)
    }

    @Test func controlPassesOnceTheDrivingPaneGoesQuiet() {
        var arbiter = ScrollLinkArbiter(settleInterval: 0.25)
        let start = Date()

        let readerTookControl = arbiter.claim(.reader, at: start)
        let toolTooSoon = arbiter.claim(.tool, at: start.addingTimeInterval(0.1))
        let toolAfterSettling = arbiter.claim(.tool, at: start.addingTimeInterval(0.3))
        // Ownership has genuinely changed hands, not just been shared.
        let readerLockedOut = arbiter.claim(.reader, at: start.addingTimeInterval(0.31))

        #expect(readerTookControl)
        #expect(!toolTooSoon)
        #expect(toolAfterSettling)
        #expect(!readerLockedOut)
        #expect(arbiter.owner == .tool)
    }

    @Test func resettingLetsEitherPaneDriveImmediately() {
        var arbiter = ScrollLinkArbiter(settleInterval: 0.25)
        let start = Date()

        let readerTookControl = arbiter.claim(.reader, at: start)
        arbiter.reset()
        let ownerAfterReset = arbiter.owner
        let toolTookControl = arbiter.claim(.tool, at: start.addingTimeInterval(0.01))

        #expect(readerTookControl)
        #expect(ownerAfterReset == nil)
        #expect(toolTookControl)
    }
}
