import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

/// A module removed here leaves no trace of its own — a note, a writing and a
/// highlight set each leave one in the personal ledger, and a deck in its
/// own, but a module is not something the library tracks the life of. So
/// without writing it down, sync sees only a member this device no longer
/// holds, and fetches it back: deleting a translation looks as though it
/// worked until the next pass.
struct LampSyncRemovedModulesTests {
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-removed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aRemovedModuleIsRecordedAtThePathItWasPublishedAt() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }

        let path = try LampSyncRemovedModules.record(
            LampInstalledModule(id: "NIC", kind: .commentary, name: "NIC"),
            inLibraryAt: library,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(path == "Commentaries/NIC.lamp")
        let records = LampSyncRemovedModules.load(fromLibraryAt: library)
        #expect(records.removedAt["Commentaries/NIC.lamp"] == 1_800_000_000_000)
    }

    /// Local, like the per-path records: it must never reach the server.
    @Test func theRecordCannotTravelInAnArchive() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        try LampSyncRemovedModules.record(
            LampInstalledModule(id: "KJVs", kind: .translation, name: "KJV"),
            inLibraryAt: library
        )
        try Data("a real payload".utf8).write(
            to: library.appendingPathComponent("manifest.json")
        )

        #expect(try LampSyncArchive.create(from: library).entries.map(\.path) == ["manifest.json"])
    }

    @Test func aRecordIsKeptUntilTheManifestCarriesIt() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        var records = LampSyncRemovedModules()
        records.record("Translations/KJVs.lamp", at: 100)
        records.record("Books/atonement.lamp", at: 200)
        try records.save(toLibraryAt: library)

        // Tombstoned by a pass: the manifest says it now, so this need not.
        var reloaded = LampSyncRemovedModules.load(fromLibraryAt: library)
        reloaded.forget(["Translations/KJVs.lamp"])
        try reloaded.save(toLibraryAt: library)

        let after = LampSyncRemovedModules.load(fromLibraryAt: library)
        #expect(after.removedAt["Translations/KJVs.lamp"] == nil)
        #expect(
            after.removedAt["Books/atonement.lamp"] == 200,
            "one that has not been carried yet is still this Mac's to remember"
        )
    }

    @Test func removingSomethingTwiceKeepsTheLaterTime() {
        var records = LampSyncRemovedModules()
        records.record("Translations/KJVs.lamp", at: 500)
        records.record("Translations/KJVs.lamp", at: 100)
        #expect(records.removedAt["Translations/KJVs.lamp"] == 500)
    }

    @Test func damagedRecordsStartFreshRatherThanFailing() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        try Data("{ not json".utf8).write(
            to: LampSyncRemovedModules.url(inLibraryAt: library)
        )
        #expect(LampSyncRemovedModules.load(fromLibraryAt: library).removedAt.isEmpty)
    }
}
