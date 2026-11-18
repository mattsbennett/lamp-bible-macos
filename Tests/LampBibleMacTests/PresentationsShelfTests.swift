import Foundation
import Testing
@testable import LampBibleMac

/// What the Presentations section shows of the library's decks.
struct PresentationsShelfTests {
    private func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + n * 86_400) }

    private var shelf: PresentationsShelf {
        PresentationsShelf(decks: [
            .init(id: "easter", title: "Easter Sunday 2026", writingID: nil, writingTitle: nil, modified: day(1)),
            .init(id: "gideon", title: "Gideon: The Upper Hand", writingID: "w-gideon", writingTitle: "Gideon", modified: day(9)),
            .init(id: "psalm", title: "Psalm 23 Meditation", writingID: nil, writingTitle: nil, modified: day(5)),
            .init(id: "versions", title: "Why So Many Versions?", writingID: "w-versions",
                  writingTitle: "Why are there so many Bible versions?", modified: day(5)),
        ])
    }

    @Test func aChipsCountFollowsTheSearch() {
        #expect(shelf.count(of: .all, query: "") == 4)
        #expect(shelf.count(of: .fromWriting, query: "") == 2)
        #expect(shelf.count(of: .standalone, query: "") == 2)
        // Judged: "All 8" over a search showing one deck said the opposite
        // of what was beneath it.
        #expect(shelf.count(of: .all, query: "easter") == 1)
        #expect(shelf.count(of: .fromWriting, query: "easter") == 0)
        #expect(shelf.count(of: .standalone, query: " Easter ") == 1)
    }

    @Test func aDeckIsFoundByItsWritingsTitleToo() {
        #expect(shelf.shown(filter: .all, sort: .title, query: "bible versions").map(\.id) == ["versions"])
        #expect(shelf.shown(filter: .standalone, sort: .title, query: "bible versions").isEmpty)
    }

    @Test func recentFirstOrByTitleAndTiesByTitle() {
        #expect(shelf.shown(filter: .all, sort: .recent, query: "").map(\.id) == ["gideon", "psalm", "versions", "easter"])
        #expect(shelf.shown(filter: .all, sort: .title, query: "").map(\.id) == ["easter", "gideon", "psalm", "versions"])
        #expect(shelf.shown(filter: .fromWriting, sort: .recent, query: "").map(\.id) == ["gideon", "versions"])
    }
}
