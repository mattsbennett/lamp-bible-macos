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
        session.clear(markedMarkdown: marking("beta", in: first))
        let second = "One alpha three.\n\nFour beta six. More.\n\nSeven gamma nine. And"
        session.clear(markedMarkdown: marking("alpha", in: second))
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
