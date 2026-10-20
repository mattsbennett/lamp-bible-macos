import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

/// The migration refuses to move a library when it meets an archive entry it
/// cannot place, which is the right instinct and also the thing that would
/// block a real migration over one stray file. Core holds that check against
/// a tree it builds itself; the Mac's own producers live here, so this is
/// where a fourth one adding a folder gets caught.
///
/// Everything below is written by the real exporters wherever one exists —
/// `exportPortableBackup`, `exportPortableWorkspaces`, the deck export inside
/// it, the settings codec — and packed with `LampSyncArchive.create(from:)`,
/// which is what the archive pass does.
struct MigrationCoversTheMacsExportTests {
    @Test func everyEntryTheMacPublishesHasAPlaceInTheMigration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-migration-cover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)

        let library = LampLibrary(rootURL: libraryRoot)
        try await fillPersonalContent(of: library, at: libraryRoot)
        try makeDecks(in: libraryRoot)
        try makeWorkspace(in: libraryRoot)
        // The Finder's leavings, which survive into an archive under `Media/`
        // because media filenames may legitimately begin with a dot.
        try write("", at: "Media/.DS_Store", in: libraryRoot)

        _ = try await library.exportPortableBackup(to: outgoing)
        try LampWorkspaceSync.exportPortableWorkspaces(from: libraryRoot, to: outgoing)
        try writeSettingsAndPreferences(to: outgoing)
        try writeCompatibilityFiles(to: outgoing)

        let archive = try LampSyncArchive.create(from: outgoing)
        let paths = archive.entries.map(\.path)
        // The test is only worth as much as the tree it packs.
        #expect(paths.contains { $0.hasPrefix("Modules/") || $0.hasPrefix("Study/") })
        #expect(paths.contains { $0.hasPrefix("Workspaces/") })
        #expect(paths.contains { $0.hasPrefix("Compatibility/") })
        #expect(paths.contains(LampPortableBackupLayout.settingsPath))

        let unplaceable = LampSyncLibraryMigration.unplaceableEntries(in: archive)
        #expect(
            unplaceable.isEmpty,
            "the migration cannot place these, so it would refuse to run: \(unplaceable)"
        )
    }

    /// And the check has teeth: a folder no producer writes today is reported
    /// rather than guessed at, which is what makes the test above worth
    /// running. This is the failure a fourth producer would cause.
    @Test func afolderNoProducerWritesIsReportedRatherThanGuessedAt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-migration-stray-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a reading plan's own folder, say", at: "Something/new.json", in: root)
        try write("", at: LampPortableBackupLayout.settingsPath, in: root)

        let archive = try LampSyncArchive.create(from: root)
        #expect(LampSyncLibraryMigration.unplaceableEntries(in: archive) == ["Something/new.json"])
    }

    // MARK: - A library with something of everything in it

    private func fillPersonalContent(of library: LampLibrary, at libraryRoot: URL) async throws {
        let image = LampDevotionalMediaReference(
            id: "ref-1", type: .image, filename: "sunrise.jpg", mimeType: "image/jpeg"
        )
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "writing-1",
            moduleID: "personal-devotionals",
            moduleName: "Writing",
            title: "Morning",
            content: "Light on the water.",
            mediaJSON: String(decoding: try JSONEncoder().encode([image]), as: UTF8.self)
        ))
        try write(
            "a photograph", at: "Media/Devotionals/writing-1/sunrise.jpg", in: libraryRoot
        )

        // Deleted, so the personal deletion ledger is written too.
        _ = try await library.savePersonalDevotional(LampDevotional(
            id: "writing-2",
            moduleID: "personal-devotionals",
            moduleName: "Writing",
            title: "Evening",
            content: "And it was so."
        ))
        try await library.deletePersonalDevotional(id: "writing-2")

        try await library.saveVerseNote(LampVerseNote(
            id: "note-1", reference: 1_001_001, content: "In the beginning."
        ))
        let set = try await library.saveHighlightSet(
            LampHighlightSet(id: "set-1", name: "Psalms", translationID: "KJVs")
        )
        #expect(set.id == "set-1")
    }

    private func makeDecks(in libraryRoot: URL) throws {
        let store = LampPresentationDeckStore(rootURL: libraryRoot)
        try FileManager.default.createDirectory(
            at: store.assetsDirectoryURL, withIntermediateDirectories: true
        )
        try Data("a deck".utf8).write(
            to: store.decksDirectoryURL.appendingPathComponent("sunday.lampdeck")
        )
        try Data("an image".utf8).write(
            to: store.assetsDirectoryURL.appendingPathComponent("a1b2c3.jpg")
        )
        // Writes `deleted-decks.json` beside them.
        try LampPresentationDeckSync.recordDeletion(of: "last-week", in: libraryRoot)
    }

    private func makeWorkspace(in libraryRoot: URL) throws {
        try write(
            "# Notes toward Sunday",
            at: "AgentWorkspaces/Devotionals/talk-123/outline.md",
            in: libraryRoot
        )
        try write(
            "a gathered fact",
            at: "AgentWorkspaces/Devotionals/talk-123/context/fact.md",
            in: libraryRoot
        )
        try write(
            #"["lesson-builder"]"#,
            at: "AgentWorkspaces/Devotionals/talk-123/.lamp/enabled-skills.json",
            in: libraryRoot
        )
        try write(
            "---\nname: lesson-builder\n---\n",
            at: "AgentSkills/lesson-builder/SKILL.md",
            in: libraryRoot
        )
    }

    // MARK: - The two the controller writes directly

    private func writeSettingsAndPreferences(to outgoing: URL) throws {
        let defaults = UserDefaults(suiteName: "com.neus.lamp.migration-cover-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        defaults.set(18.0, forKey: "reader.fontSize")
        try LampPortableSettingsCodec.encode(from: defaults).write(
            to: outgoing.appendingPathComponent(LampPortableBackupLayout.settingsPath)
        )

        let ledger = LampSharedPreferenceLedger()
        let url = outgoing.appendingPathComponent(LampPortableBackupLayout.sharedPreferencesPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try LampSyncPreferenceState.encode(ledger).write(to: url)
    }

    /// The compatibility publisher's output: one file per content kind under
    /// `Compatibility/`, plus its manifest. Shaped from the same constants the
    /// controller composes those paths from.
    private func writeCompatibilityFiles(to outgoing: URL) throws {
        for (kind, filename) in [
            (LampSyncContentKind.notes, "notes.lamp"),
            (LampSyncContentKind.devotionals, "devotionals.lamp"),
            (LampSyncContentKind.highlights, "set-1-highlights.lamp"),
        ] {
            try write(
                "compatible bytes",
                at: "\(LampPortableBackupLayout.compatibleDirectory)/\(kind.rawValue)/\(filename)",
                in: outgoing
            )
        }
        try write(
            "DevotionalMedia bytes",
            at: "\(LampPortableBackupLayout.compatibleDirectory)/DevotionalMedia/writing-1/sunrise.jpg",
            in: outgoing
        )
        let manifest = LampCompatibilityManifest(files: [])
        try JSONEncoder().encode(manifest).write(
            to: outgoing.appendingPathComponent(
                LampPortableBackupLayout.compatibilityManifestPath
            )
        )
    }

    private func write(_ contents: String, at relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}
