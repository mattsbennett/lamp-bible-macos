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

/// The collision that could cost somebody every note they have written.
///
/// An installed module's ID can equal a reserved collection ID — import an
/// exported notes file and it may well be `notes` — and that collection's
/// path is the file this Mac publishes every note into. Removing the module
/// is local and harmless; *recording* it tombstones the collection, and the
/// phone honours such a tombstone by deleting the lot, with only a later save
/// to save it.
struct RemovedModulesNeverTombstoneACollectionTests {
    @Test(arguments: [
        (LampModuleKind.notes, "notes", "Notes/notes.lamp"),
        (LampModuleKind.devotional, "devotionals", "Devotionals/devotionals.lamp"),
    ])
    func removingAModuleThatCollidesWithACollectionRecordsNothing(
        kind: LampModuleKind, moduleID: String, path: String
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-collision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorded = try LampSyncRemovedModules.record(
            LampInstalledModule(id: moduleID, kind: kind, name: "Imported"),
            inLibraryAt: root
        )

        #expect(
            recorded == String?.none,
            "recording \(path) tombstones the collection, and a client that honours it deletes every item in it"
        )
        #expect(LampSyncRemovedModules.load(fromLibraryAt: root).removedAt.isEmpty)
    }

    /// And a module that merely shares the *kind* is still recorded: a second
    /// notes module is a real module, and refusing to record its removal
    /// would bring it back on the next pass.
    @Test func asecondNotesModuleIsStillRecorded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-collision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorded = try LampSyncRemovedModules.record(
            LampInstalledModule(id: "grandads-notes", kind: .notes, name: "Grandad's Notes"),
            inLibraryAt: root
        )

        #expect(recorded == "Notes/grandads-notes.lamp")
    }
}
