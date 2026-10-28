import Foundation
import Testing
@testable import LampBibleMacSupport

/// Holding the app open until what was typed has been written.
///
/// Quit asks everything to write and then waits on this count, so the count is
/// what decides whether an edit survives closing the app. Most of what is held
/// here is about letting go: a hook that never says it is finished stops the
/// app quitting at all, which is worse than the bug it exists to fix.
@MainActor
struct PendingWritesTests {
    @Test func anappWithNothingToWriteGoesStraightAway() {
        let writes = LampPendingWrites()
        var finished = false

        let quiet = writes.flushAll { finished = true }

        #expect(quiet, "nothing was outstanding, so there is nothing to wait for")
        #expect(
            finished == false,
            "the caller goes ahead on the return value; calling back as well would answer twice"
        )
    }

    /// An editor holding something registers, is asked, and starts a write. The
    /// app waits for that write and not for the asking.
    @Test func thewaitLastsUntilTheWriteItStartedIsDone() {
        let writes = LampPendingWrites()
        writes.register(UUID()) { writes.begin() }
        var finished = false

        let quiet = writes.flushAll { finished = true }

        #expect(quiet == false)
        #expect(finished == false, "the write has not landed yet")

        writes.end()

        #expect(finished, "the last write finished, so the app may go")
    }

    @Test func everyWriteHasToFinishBeforeTheAppGoes() {
        let writes = LampPendingWrites()
        writes.register(UUID()) { writes.begin() }
        writes.register(UUID()) { writes.begin() }
        var finished = false

        #expect(writes.flushAll { finished = true } == false)
        writes.end()
        #expect(finished == false, "one editor has written; the other has not")

        writes.end()
        #expect(finished)
    }

    /// A save that fails still ends. Waiting for a write that already gave up
    /// would hold the app open for ever.
    @Test func afailedWriteStillCountsAsFinished() {
        let writes = LampPendingWrites()
        writes.register(UUID()) { writes.begin() }
        var finished = false
        #expect(writes.flushAll { finished = true } == false)

        writes.end()

        #expect(finished, "end() says the write is over, not that it succeeded")
    }

    /// The five-second deadline gives up on a write and lets the app quit. A
    /// write landing afterwards must not then answer a question already
    /// answered.
    @Test func awriteThatLandsAfterTheWaitWasAbandonedSaysNothing() {
        let writes = LampPendingWrites()
        writes.register(UUID()) { writes.begin() }
        var finished = false
        #expect(writes.flushAll { finished = true } == false)

        writes.cancelQuietHandler()
        writes.end()

        #expect(finished == false, "the deadline already let the app go")
    }

    @Test func aneditorThatHasGoneAwayIsNotAsked() {
        let writes = LampPendingWrites()
        let id = UUID()
        var asked = 0
        writes.register(id) { asked += 1 }

        writes.unregister(id)
        #expect(writes.flushAll {} )

        #expect(asked == 0)
        #expect(writes.registrationCount == 0)
    }

    /// Reopening the same editor must not leave two registrations behind, or a
    /// stale one would be asked to write on behalf of a view that is gone.
    @Test func registeringTwiceUnderOneKeyKeepsOneRegistration() {
        let writes = LampPendingWrites()
        let id = UUID()
        writes.register(id) {}
        writes.register(id) {}

        #expect(writes.registrationCount == 1)
    }

    /// Belt and braces: an unbalanced `end()` must not drive the count below
    /// zero, where a later real write would never bring it back to quiet.
    @Test func anunmatchedEndDoesNotBreakTheCount() {
        let writes = LampPendingWrites()
        writes.end()
        writes.end()
        #expect(writes.isQuiet)

        writes.register(UUID()) { writes.begin() }
        var finished = false
        #expect(writes.flushAll { finished = true } == false)
        writes.end()

        #expect(finished, "the count still reaches quiet after a stray end()")
    }
}
