import Foundation
import LampCore
import Testing
@testable import LampBibleMac

/// The writing editor's review marks, followed and cleared.
@MainActor
struct WritingReviewSessionTests {
    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }

    @Test func theMarksAreReadAndCounted() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One deux three.\n\nFour cinq six."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(
            from: "One two three.\n\nFour five six.", to: new
        ))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 2 }
        #expect(session.ranges.map { (new as NSString).substring(with: $0) } == ["deux", "cinq"])
    }

    /// Review's case: the writer types into a marked passage and clears it
    /// before the save that would carry the marks. The clear still lands.
    @Test func aClearAfterTypingIntoAMarkStillClears() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One alpha beta gamma three."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(from: "One two three.", to: new))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        let typed = "One alpha mine beta gamma three."
        session.textChanged(typed)
        session.clear(range: (typed as NSString).range(of: "gamma"))
        try await waitUntil {
            let review = try? store.review(writingID: "w")
            return review?.highlightedRanges(in: typed).map { (typed as NSString).substring(with: $0) } == ["alpha", "beta"]
        }
    }

    /// Codex's case: the ✓ is pressed on text the page holds but has not
    /// reported yet, twice, and typing goes on past both before the text is
    /// reported. Each clear lands, in the text it was made in.
    @Test func clearsAheadOfTheirTextLandAsTypingGoesOn() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One alpha three.\n\nFour beta six.\n\nSeven gamma nine."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(
            from: "One two three.\n\nFour five six.\n\nSeven eight nine.", to: new
        ))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 3 }

        func marking(_ word: String, in text: String) -> String {
            text.replacingOccurrences(
                of: word, with: "\(LampWritingReview.markStart)\(word)\(LampWritingReview.markEnd)"
            )
        }
        let first = "One alpha three.\n\nFour beta six. More."
        session.clear(markedMarkdown: marking("beta", in: first), pageText: first)
        let second = "One alpha three.\n\nFour beta six. More.\n\nSeven gamma nine. And"
        session.clear(markedMarkdown: marking("alpha", in: second), pageText: second)
        let reported = "One alpha three.\n\nFour beta six. More.\n\nSeven gamma nine. And more."
        session.textChanged(reported)
        try await waitUntil {
            let review = try? store.review(writingID: "w")
            let known = WritingReviewTexts.shared.known(for: "w")
            return review?.carryingToText(reported, from: known).highlightedRanges(in: reported)
                .map { (reported as NSString).substring(with: $0) } == ["gamma"]
        }
        try await waitUntil { session.count == 1 }
    }

    /// Codex's case: markers can change how the page writes what is round
    /// them, so the marked Markdown with its markers taken out is text the
    /// page never held. A page that sends no text of its own clears only
    /// where its marked Markdown matches the writing here, and nothing is
    /// remembered from it.
    @Test func aClearWithNoPageTextIsMadeOnlyInTheWritingHere() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "no-page-text-\(UUID().uuidString)"
        let new = "One alpha three.\n\nFour beta six."
        try store.save(LampWritingReview(writingID: id).markingAssistantChange(
            from: "One two three.\n\nFour five six.", to: new
        ))
        let before = try store.review(writingID: id)
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 2 }

        let ahead = "One alpha three.\n\nFour beta six. More."
        session.clear(markedMarkdown: ahead.replacingOccurrences(
            of: "beta", with: "\(LampWritingReview.markStart)beta\(LampWritingReview.markEnd)"
        ))
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.review(writingID: id) == before)
        #expect(!session.texts.contains(ahead))
    }

    /// Codex's case: a selection inside an autolink. The page (iOS a70d4db,
    /// its script in the Mac's copy) takes the whole link between its
    /// markers and writes it as it always does, and sends its own text
    /// beside it; the clear lands, from the writing here or from that text.
    @Test func aSelectionInsideAnAutolinkClears() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "autolink-\(UUID().uuidString)"
        let link = "<https://example.org>"
        let new = "See \(link) now."
        try store.save(LampWritingReview(writingID: id).markingAssistantChange(from: "See it now.", to: new))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        let marked = "See \(LampWritingReview.markStart)\(link)\(LampWritingReview.markEnd) now."
        session.clear(markedMarkdown: marked, pageText: new)
        try await waitUntil { (try? store.review(writingID: id))?.isEmpty == true }

        // Ahead of the writing here: made in the page's own text.
        try store.save(LampWritingReview(writingID: id + "-ahead").markingAssistantChange(from: "See it now.", to: new))
        let ahead = new + " More."
        let other = WritingReviewSession()
        let followingAhead = Task {
            await other.follow(writingID: id + "-ahead", text: new, libraryRootURL: root, isShown: true)
        }
        defer { followingAhead.cancel() }
        try await waitUntil { other.count == 1 }
        other.clear(
            markedMarkdown: "See \(LampWritingReview.markStart)\(link)\(LampWritingReview.markEnd) now. More.",
            pageText: ahead
        )
        try await waitUntil { (try? store.review(writingID: id + "-ahead"))?.isEmpty == true }
    }

    /// Codex's case: typing into a marked passage, not yet saved, splits it.
    /// Both halves are still counted and drawn, not nothing.
    @Test func unsavedTypingIntoAMarkKeepsItCounted() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One alpha beta gamma three."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(from: "One two three.", to: new))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        let typed = "One alpha mine beta gamma three."
        session.textChanged(typed)
        try await waitUntil {
            session.ranges.map { (typed as NSString).substring(with: $0) } == ["alpha", "beta gamma"]
        }
        #expect(session.count > 0)
    }

    /// Codex's case: another window took the assistant's draft in, and its
    /// marks are made, but its save has not landed. A clear in a window that
    /// still holds the text before carries nothing from the draft it never
    /// held, so the draft's new words keep their mark.
    @Test func aClearLeavesTheMarksOfADraftItsWindowNeverHeld() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "other-window-\(UUID().uuidString)"
        let held = "One alpha three.\n\nFour five six."
        let draft = "One alpha three.\n\nFour beta six."
        try store.save(
            LampWritingReview(writingID: id)
                .markingAssistantChange(from: "One two three.\n\nFour five six.", to: held)
                .markingAssistantChange(from: held, to: draft)
        )
        WritingReviewTexts.shared.remember(draft, for: id)
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: held, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        session.clear(range: (held as NSString).range(of: "alpha"))
        try await waitUntil {
            let review = try? store.review(writingID: id)
            return review?.highlightedRanges(in: draft).map { (draft as NSString).substring(with: $0) } == ["beta"]
        }
    }

    /// Codex's case: the window takes an assistant's draft in and the
    /// writer types into it before the text settles. The draft is held at
    /// once, so a clear still carries its mark from it.
    @Test func aDraftTakenInIsHeldBeforeTypingIntoIt() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "draft-held-\(UUID().uuidString)"
        let before = "One two three."
        let draft = "One alpha beta gamma three."
        try store.save(LampWritingReview(writingID: id).markingAssistantChange(from: before, to: draft))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: before, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.texts == [before] }
        try await Task.sleep(for: .milliseconds(100))

        session.holds(draft)
        let typed = "One alpha mine beta gamma three."
        session.textChanged(typed)
        session.clear(range: (typed as NSString).range(of: "gamma"))
        try await waitUntil {
            let review = try? store.review(writingID: id)
            return review?.highlightedRanges(in: typed).map { (typed as NSString).substring(with: $0) } == ["alpha", "beta"]
        }
    }

    /// Codex's case: marks turned off and on again, with an edit between.
    /// The texts the editor held before are kept, to carry from.
    @Test func turningMarksOffAndOnKeepsTheTextsHeld() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "off-and-on-\(UUID().uuidString)"
        let session = WritingReviewSession()
        let first = Task { await session.follow(writingID: id, text: "One alpha three.", libraryRootURL: root, isShown: true) }
        try await waitUntil { session.texts == ["One alpha three."] }
        first.cancel()
        await session.follow(writingID: id, text: "One alpha three. More.", libraryRootURL: root, isShown: false)
        let again = Task { await session.follow(writingID: id, text: "One alpha three. More.", libraryRootURL: root, isShown: true) }
        defer { again.cancel() }
        #expect(session.texts == ["One alpha three.", "One alpha three. More."])

        let other = Task { await session.follow(writingID: "another-\(id)", text: "Else.", libraryRootURL: root, isShown: true) }
        defer { other.cancel() }
        try await waitUntil { session.texts == ["Else."] }
    }

    /// What `.lamp/editor.md` tells a Terminal agent: the passages still
    /// marked, that nothing is once the writer clears them, and that
    /// nothing is when no mark was ever made.
    @Test func theAgentIsToldWhatIsMarkedAsItIsDrawn() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let new = "One deux three.\n\nFour five six."
        try LampWritingReviewStore(rootURL: root).save(LampWritingReview(writingID: "w").markingAssistantChange(
            from: "One two three.\n\nFour five six.", to: new
        ))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.agentNote?.contains("- \"deux\"") == true }
        session.clearAll()
        try await waitUntil { session.agentNote?.contains("Everything in the writing has been read and cleared") == true }

        let unmarked = WritingReviewSession()
        let followingUnmarked = Task {
            await unmarked.follow(writingID: "never-marked", text: "Mine.", libraryRootURL: root, isShown: true)
        }
        defer { followingUnmarked.cancel() }
        try await waitUntil { unmarked.agentNote?.contains("Everything in the writing has been read and cleared") == true }
    }

    /// A marks file that cannot be read leaves the agent told marks are on
    /// but unread, never nothing (which it is told means off) nor that
    /// everything has been read.
    @Test func marksThatCannotBeReadAreSaidToBeUnread() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampWritingReviewStore(rootURL: root).save(
            LampWritingReview(writingID: "w").markingAssistantChange(from: "a b", to: "a c")
        )
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        #expect(files.count == 1)
        for file in files { try Data("not a review".utf8).write(to: file) }
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: "a c", libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.agentNote != nil }
        try await Task.sleep(for: WritingReviewSession.checkInterval + .milliseconds(300))
        #expect(session.agentNote == WritingChatTurns.unreadReviewNote)
        // A draw before any read, as a rejection from the page asks for,
        // still says unread rather than that nothing is marked.
        session.marksRejected()
        try await Task.sleep(for: WritingReviewSession.settleDelay + .milliseconds(200))
        #expect(session.agentNote == WritingChatTurns.unreadReviewNote)
    }

    /// Read once, then unreadable: the agent is told the marks are unread,
    /// not the last note read, until a read succeeds again.
    @Test func marksThatBecomeUnreadableAreSaidToBeUnread() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampWritingReviewStore(rootURL: root).save(
            LampWritingReview(writingID: "w").markingAssistantChange(from: "a b", to: "a c")
        )
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: "a c", libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.agentNote?.contains("- \"c\"") == true }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        let saved = try files.map { ($0, try Data(contentsOf: $0)) }
        for file in files { try Data("not a review".utf8).write(to: file) }
        try await waitUntil { session.agentNote == WritingChatTurns.unreadReviewNote }
        session.marksRejected()
        try await Task.sleep(for: WritingReviewSession.settleDelay + .milliseconds(200))
        #expect(session.agentNote == WritingChatTurns.unreadReviewNote, "a draw meanwhile still says unread")
        for (file, data) in saved { try data.write(to: file) }
        try await waitUntil { session.agentNote?.contains("- \"c\"") == true }
    }

    @Test func turnedOffNothingIsShown() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampWritingReviewStore(rootURL: root).save(
            LampWritingReview(writingID: "w").markingAssistantChange(from: "a b", to: "a c")
        )
        let session = WritingReviewSession()
        var sent: [String?] = []
        session.onMarksChanged = { sent.append($0) }
        await session.follow(writingID: "w", text: "a c", libraryRootURL: root, isShown: false)
        #expect(session.count == 0)
        #expect(sent == [nil])
        #expect(session.agentNote == nil, "the agent is told nothing of marks that are off")
        // A rejection the page sends after marks went off draws again, and
        // still says nothing.
        session.marksRejected()
        try await Task.sleep(for: WritingReviewSession.settleDelay + .milliseconds(200))
        #expect(session.agentNote == nil)
    }

    @Test func aPlaceInLineIsFilledInOrderAndGivingUpMovesTheLineOn() async {
        let log = Log()
        let first = WritingReviewWork.shared.reserve()
        WritingReviewWork.shared.run { await log.add("second") }
        let third = WritingReviewWork.shared.reserve()
        third.giveUp()
        first.fill { await log.add("first") }
        await WritingReviewWork.shared.drained()
        #expect(await log.entries == ["first", "second"])
    }

    @Test func workFilledInAfterItsPlaceGaveUpIsDroppedNotRunLate() async throws {
        let work = WritingReviewWork.shared
        let saved = work.reservationPatience
        defer { work.reservationPatience = saved }
        work.reservationPatience = .milliseconds(100)
        let log = Log()
        let late = work.reserve()
        work.run { await log.add("after") }
        await work.drained()
        late.fill { await log.add("late") }
        try await Task.sleep(for: .milliseconds(200))
        await work.drained()
        #expect(await log.entries == ["after"])
    }

    private actor Log {
        var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
    }
}
