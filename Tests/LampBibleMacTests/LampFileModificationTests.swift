import Foundation
import LampBibleMacSupport
import Testing

/// A file's date as it is now, however long the URL asked about was kept.
struct LampFileModificationTests {
    @Test func aKeptURLSeesEveryWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        var seen: [Date] = []
        for round in 0..<20 {
            try Data("v\(round)".utf8).write(to: url, options: .atomic)
            seen.append(try #require(LampFileModification.date(of: url)))
        }
        #expect(Set(seen).count == seen.count)
        // What it replaces: the same URL asked again answers from what it
        // kept the first time.
        let first = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try Data("later".utf8).write(to: url, options: .atomic)
        let again = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(first == again)
        #expect(LampFileModification.date(of: url) != first)
    }
}
