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
}
