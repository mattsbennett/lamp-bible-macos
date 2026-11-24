import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMac
@testable import LampBibleMacSupport

/// `Documentation/decisions/0004` in lamp-bible-core: a save puts one writing
/// in its place in the list rather than reading every writing again.
///
/// The risk that buys is a list this app maintains by hand drifting from the
/// one the library would give it. So each of these saves something and then
/// asks the library for the whole list, and the two must agree — in contents
/// and in order.
@MainActor
struct WritingListSpliceTests {
    /// `ai` turns the AI features on, which the take-in of a requested
    /// writing is gated behind: without it that path returns before it does
    /// anything, and a test of it would pass for the wrong reason.
    private func model(ai: Bool = false) throws -> (model: LibraryModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-splice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let defaults = UserDefaults(suiteName: "lamp.splice.\(UUID().uuidString)")!
        if ai { defaults.set(true, forKey: LampPreferenceDefaults.aiFeaturesKey) }
        return (LibraryModel(library: library, defaults: defaults), root)
    }

    private func writing(
        _ id: String, title: String, series: String? = nil, order: Int? = nil, date: String? = nil
    ) -> LampDevotional {
        LampDevotional(
            id: id,
            moduleID: LampPersonalModule.writing.id,
            moduleName: LampPersonalModule.writing.name,
            title: title,
            date: date,
            seriesName: series,
            seriesOrder: order,
            content: "The body of \(title).",
            isEditable: true
        )
    }

    private func matchesTheLibrary(_ model: LibraryModel) async throws -> Bool {
        let listed = try await model.library.devotionals()
        return model.devotionals.map(\.id) == listed.map(\.id)
    }

    @Test func aSavedWritingLandsWhereTheLibraryWouldPutIt() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }

        for (id, title) in [("c", "Candle"), ("a", "Altar"), ("b", "Bread")] {
            _ = try await model.savePersonalDevotional(writing(id, title: title))
            #expect(try await matchesTheLibrary(model))
        }
        #expect(model.devotionals.map(\.title) == ["Altar", "Bread", "Candle"])
    }

    /// A title, a date or a series decides where the library puts a writing,
    /// so an edit can move it. The row cannot simply be replaced in place.
    @Test func anEditThatMovesAWritingMovesItInTheList() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, title) in [("a", "Altar"), ("b", "Bread"), ("c", "Candle")] {
            _ = try await model.savePersonalDevotional(writing(id, title: title))
        }

        _ = try await model.savePersonalDevotional(writing("a", title: "Zeal"))

        #expect(model.devotionals.map(\.title) == ["Bread", "Candle", "Zeal"])
        #expect(try await matchesTheLibrary(model))
    }

    @Test func aSeriesAndADateOrderTheSameWayTheLibraryDoes() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await model.savePersonalDevotional(
            writing("plain", title: "Standalone", date: "2026-02-01")
        )
        _ = try await model.savePersonalDevotional(
            writing("s2", title: "Second", series: "Advent", order: 2)
        )
        _ = try await model.savePersonalDevotional(
            writing("s1", title: "First", series: "Advent", order: 1)
        )
        _ = try await model.savePersonalDevotional(
            writing("early", title: "Earlier", date: "2026-01-01")
        )

        #expect(try await matchesTheLibrary(model))
        #expect(model.devotionals.map(\.id) == ["early", "plain", "s1", "s2"])
    }

    /// A writing that already exists is not started again — and the check
    /// cannot be made against the list in memory, because the list is filled
    /// after launch rather than during it. Before this was asked of the
    /// library, a pending request naming an existing writing overwrote its
    /// title and body with the ones the request carried.
    @Test func aPendingStartDoesNotOverwriteAWritingThatExists() async throws {
        let (model, root) = try model(ai: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        // Written straight to the library, so the model's list is empty —
        // which is what a launch looks like now.
        _ = try await model.library.savePersonalDevotional(LampDevotional(
            id: "already-here",
            moduleID: LampPersonalModule.writing.id,
            moduleName: LampPersonalModule.writing.name,
            title: "What the writer called it",
            content: "The body the writer wrote.",
            isEditable: true
        ))
        #expect(model.devotionals.isEmpty)

        try LampWritingStarts.write(
            LampWritingStarts.Start(
                id: "already-here",
                title: "What the request called it",
                draft: "The draft the request carried."
            ),
            inApplicationSupport: support
        )

        await model.takeInRequestedWritings(applicationSupportURL: support)

        let held = try await model.library.personalDevotional(id: "already-here")
        #expect(held?.title == "What the writer called it")
        #expect(held?.content == "The body the writer wrote.")
        // And the request is forgotten rather than tried again next launch.
        #expect(LampWritingStarts.pending(inApplicationSupport: support).isEmpty)
    }

    @Test func aDeletedWritingLeavesTheList() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, title) in [("a", "Altar"), ("b", "Bread")] {
            _ = try await model.savePersonalDevotional(writing(id, title: title))
        }

        try await model.deletePersonalDevotional(id: "a")

        #expect(model.devotionals.map(\.id) == ["b"])
        #expect(try await matchesTheLibrary(model))
    }

    /// Writings tied on everything the order looks at — two called
    /// "Untitled", which auto-titled drafts are — still land where the
    /// library would put them. The order ends at the id for that reason.
    @Test func writingsTiedOnEverythingKeepTheLibrarysOrder() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }

        for id in ["b", "a", "c"] {
            _ = try await model.savePersonalDevotional(writing(id, title: "Untitled"))
            #expect(try await matchesTheLibrary(model))
        }
        #expect(model.devotionals.map(\.id) == ["a", "b", "c"])
    }

    /// A writing whose stored copy is dated ahead of this Mac — synced from a
    /// device whose clock runs fast — still has its edit shown. The first
    /// version of the splice compared the two dates and kept the old body.
    @Test func anEditOfAFutureDatedWritingIsShown() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let ahead = Date().addingTimeInterval(60 * 60 * 24)
        _ = try await model.library.savePersonalDevotional(
            LampDevotional(
                id: "a",
                moduleID: LampPersonalModule.writing.id,
                moduleName: LampPersonalModule.writing.name,
                title: "Altar",
                content: "The copy from the other device.",
                lastModified: ahead,
                isEditable: true
            ),
            preserveLastModified: true
        )
        await model.refreshNow()
        #expect(model.devotionals.first?.content == "The copy from the other device.")

        _ = try await model.savePersonalDevotional(
            writing("a", title: "Altar"), reviewTexts: []
        )

        #expect(model.devotionals.first?.content == "The body of Altar.")
        #expect(try await matchesTheLibrary(model))
    }

    /// A save of the same writing twice in the same second: the stored copy
    /// keeps whole seconds while the copy just saved still has its fractions,
    /// so a comparison that was not to the second dropped the newer body.
    @Test func twoSavesInOneSecondKeepTheLaterBody() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await model.savePersonalDevotional(writing("a", title: "Altar"))

        var edited = writing("a", title: "Altar")
        edited = LampDevotional(
            id: "a",
            moduleID: edited.moduleID,
            moduleName: edited.moduleName,
            title: "Altar",
            content: "A second body, saved in the same second.",
            isEditable: true
        )
        _ = try await model.savePersonalDevotional(edited)

        #expect(model.devotionals.first?.content == "A second body, saved in the same second.")
        #expect(try await matchesTheLibrary(model))
    }
}
