import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Noticing work this Mac has to publish that no ledger records.
///
/// `personalChangeStamp()` covers the study content — a note, a writing, a
/// highlight, a tick — because every one of those writes a ledger. A module
/// installed or removed, a deck saved, a workspace document written: none of
/// them writes anything but the file itself, so none of them used to start a
/// pass, and they waited on this Mac until somebody pressed Sync. The user
/// deleted a plan on the Mac and had to sync by hand, twice, before looking
/// for it on the phone.
///
/// Every test here stamps the whole library with one old date first, so a
/// change is a change rather than two writes landing in the same millisecond.
struct LampSyncLocalWorkTests {
    private let old = Date(timeIntervalSince1970: 1_600_000_000)
    private let newer = Date(timeIntervalSince1970: 1_700_000_000)
    private var fileManager: FileManager { .default }

    /// A library with one of everything this looks at.
    private func makeLibrary() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-local-work-\(UUID().uuidString)", isDirectory: true)
        for file in [
            "Modules/mcheyne.lamp",
            "Databases/mcheyne.sqlite",
            "Presentations/sunday.lampdeck",
            "Presentations/Assets/picture.png",
            "AgentSkills/write-a-devotional/SKILL.md",
            "AgentWorkspaces/Devotionals/Advent/notes.md",
            "AgentWorkspaces/Devotionals/Advent/context/isaiah.md",
            "AgentWorkspaces/Devotionals/Advent/.lamp/DeletedFiles.json",
            "Indexes/StrongsIndex.sqlite",
            "Bundled/bundled_modules.db.zlib",
        ] {
            try write("{}", to: root.appendingPathComponent(file))
        }
        try stamp(root, to: old)
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Every file and folder given one date, so nothing differs by accident.
    private func stamp(_ root: URL, to date: Date) throws {
        var urls = [root]
        if let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { urls.append(url) }
        }
        // Deepest first: setting a date on a file touches its folder.
        for url in urls.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private func marks(_ root: URL) -> [String: Int64] {
        LampSyncLocalWork.marks(inLibraryAt: root, fileManager: fileManager)
    }

    // MARK: - Modules

    /// The user's own report: a plan deleted here, and nothing to say so.
    @Test func removingAModuleIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        try fileManager.removeItem(at: library.appendingPathComponent("Modules/mcheyne.lamp"))
        try fileManager.removeItem(at: library.appendingPathComponent("Databases/mcheyne.sqlite"))

        #expect(marks(library) != before)
    }

    /// Recording the removal is a change in its own right, so a removal is
    /// noticed even where the module files were already gone.
    @Test func recordingARemovalIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        try LampSyncRemovedModules.record(
            LampInstalledModule(id: "plan-abc", kind: .plan, name: "The Gospels"),
            inLibraryAt: library
        )

        let after = marks(library)
        #expect(after != before)
        #expect(after[LampSyncRemovedModules.filename] != nil)
    }

    @Test func installingAModuleIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        try write("{}", to: library.appendingPathComponent("Modules/plan-abc.lamp"))
        try write("{}", to: library.appendingPathComponent("Databases/plan-abc.sqlite"))

        #expect(marks(library) != before)
    }

    /// A folder whose membership is the change is read by its own date, so a
    /// library of hundreds of modules costs one stat rather than hundreds.
    @Test func theModuleFoldersAreNotListedFileByFile() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }

        let marks = marks(library)

        #expect(marks["Modules"] != nil)
        #expect(marks["Databases"] != nil)
        #expect(marks["Modules/mcheyne.lamp"] == nil)
    }

    // MARK: - Decks

    @Test func savingADeckAgainIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        let deck = library.appendingPathComponent("Presentations/sunday.lampdeck")
        try write("{\"slides\":[]}", to: deck)
        try fileManager.setAttributes([.modificationDate: newer], ofItemAtPath: deck.path)

        #expect(marks(library) != before)
    }

    /// A deleted deck leaves no file to report it, so the folder's own date is
    /// read too — the deletion is the only thing that moved.
    @Test func deletingADeckIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        try fileManager.removeItem(at: library.appendingPathComponent("Presentations/sunday.lampdeck"))

        #expect(marks(library) != before)
    }

    @Test func addingADecksPictureIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        try write("png", to: library.appendingPathComponent("Presentations/Assets/second.png"))

        #expect(marks(library) != before)
    }

    /// Deleting a deck, as `deleteSelectedDeck` does it: the deletion is
    /// recorded for the other devices, and the deck's own file goes. The file
    /// going is what is read here — see `therecordOfDeletedDecksIsNotWork`
    /// for why the record itself cannot be.
    @Test func deletingADeckThroughItsOwnPathIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        try LampPresentationDeckSync.recordDeletion(of: "sunday", in: library)
        try fileManager.removeItem(at: library.appendingPathComponent("Presentations/sunday.lampdeck"))

        #expect(marks(library) != before)
    }

    /// The ledger of deleted decks is not read, because a pass writes it:
    /// applying another device's copy saves it here. Counting it would leave
    /// work behind for the next pass to find, and this Mac would sync every
    /// six seconds for as long as it was open — and one deck deleted on any
    /// device was all it would have taken.
    @Test func therecordOfDeletedDecksIsNotWork() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        try LampPresentationDeckSync.recordDeletion(of: "sunday", in: library)
        let before = marks(library)

        // As a pass would: the same record written again, a moment later.
        try LampPresentationDeckSync.recordDeletion(of: "sunday", in: library)
        let ledger = library
            .appendingPathComponent("Presentations")
            .appendingPathComponent(LampPresentationDeckSync.deletionsFilename)
        try fileManager.setAttributes([.modificationDate: newer], ofItemAtPath: ledger.path)

        #expect(marks(library) == before)
        #expect(marks(library).keys.contains { $0.hasSuffix(LampPresentationDeckSync.deletionsFilename) } == false)
    }

    // MARK: - Workspaces and skills

    @Test func editingAWorkspaceDocumentIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        let document = library
            .appendingPathComponent("AgentWorkspaces/Devotionals/Advent/notes.md")
        try write("What Advent is for.", to: document)
        try fileManager.setAttributes([.modificationDate: newer], ofItemAtPath: document.path)

        #expect(marks(library) != before)
    }

    @Test func gatheringContextForAWorkspaceIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        try write(
            "Isaiah 40",
            to: library.appendingPathComponent(
                "AgentWorkspaces/Devotionals/Advent/context/isaiah-40.md"
            )
        )

        #expect(marks(library) != before)
    }

    @Test func editingASkillIsWorkToPublish() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        let skill = library.appendingPathComponent("AgentSkills/write-a-devotional/SKILL.md")
        try write("# How to write one", to: skill)
        try fileManager.setAttributes([.modificationDate: newer], ofItemAtPath: skill.path)

        #expect(marks(library) != before)
    }

    /// The one that matters most. A pass writes a workspace's own bookkeeping
    /// as it exports it — the file ledger, the compacted revisions — so a
    /// reading that counted those would find work left behind by every pass,
    /// and this Mac would sync, notice its own writing, and sync again for as
    /// long as the app stayed open.
    @Test func whatAPassWritesBesideAWorkspaceIsNotWork() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let workspace = library.appendingPathComponent("AgentWorkspaces/Devotionals/Advent")
        let before = marks(library)

        var ledger = WorkspaceFileLedger.load(in: workspace)
        ledger.noteChanges(present: ["Documents/notes.md": 1])
        try ledger.save(in: workspace)
        try write("{}", to: workspace.appendingPathComponent(".lamp/revisions/1.json"))
        try write("{}", to: workspace.appendingPathComponent(".lamp/native-chat-claude.json"))

        #expect(marks(library) == before)
    }

    /// What a pass rebuilds on each Mac is not published and not read here:
    /// the generated instructions, the draft, the provider's own copies.
    @Test func generatedWorkspaceDocumentsAreNotWork() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let workspace = library.appendingPathComponent("AgentWorkspaces/Devotionals/Advent")
        let before = marks(library)

        for generated in ["agents.md", "claude.md", "devotional_context.md", "draft.md"] {
            try write("generated", to: workspace.appendingPathComponent(generated))
        }

        #expect(marks(library) == before)
    }

    // MARK: - Every kind of content

    /// Where the Mac keeps each kind of file sync carries, and so what in the
    /// reading moves when one of them changes.
    ///
    /// Exhaustive on purpose. A kind added to `LampSyncFileKind` or
    /// `LampSyncContentKind` stops this compiling until somebody says where
    /// the Mac keeps it — which is the mistake this guards: `gather()` grew a
    /// home for every kind, and a kind left out of *this* reading syncs only
    /// when something else starts a pass.
    ///
    /// An empty list means nothing of its own has to move: it arrives with
    /// something that does.
    private func homes(of kind: LampSyncFileKind) -> [String] {
        switch kind {
        case .module:
            // Every module is installed and removed as whole files in these
            // two folders, whatever is inside it. The content of a notes,
            // writings or highlights module also lives in the user database,
            // and the personal ledger answers for that.
            return ["Modules", "Databases"]
        case .devotionalMedia, .bookMedia:
            // A writing's attachments are saved with the writing and a book's
            // pictures arrive with the book, so each is already answered for
            // — by the personal ledger, or by the module folders above.
            return []
        case .deck:
            return ["Presentations/sunday.lampdeck"]
        case .deckAsset:
            // Immutable at a path, so only the folder's own date can matter.
            return ["Presentations/Assets"]
        case .workspaceFile:
            return [
                "Workspaces/Advent/Documents/notes.md",
                "Workspaces/Advent/Context/isaiah.md",
                "AgentSkills/write-a-devotional/SKILL.md",
            ]
        }
    }

    @Test func everyKindOfSyncedFileIsReadFromSomewhere() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let marks = marks(library)
        let kinds: [LampSyncFileKind] =
            LampSyncContentKind.allCases.map { .module($0) }
                + [.devotionalMedia, .bookMedia, .deck, .deckAsset, .workspaceFile]

        for kind in kinds {
            for home in homes(of: kind) {
                #expect(marks[home] != nil, "\(kind) is kept at \(home), which nothing here reads")
            }
        }
    }

    // MARK: - What is not work

    /// Indexes and the bundled modules are built here from what is already
    /// here, and travel nowhere.
    @Test func whatIsNeverPublishedIsNotWork() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let before = marks(library)

        let index = library.appendingPathComponent("Indexes/StrongsIndex.sqlite")
        try write("rebuilt", to: index)
        try fileManager.setAttributes([.modificationDate: newer], ofItemAtPath: index.path)
        try write("rebuilt", to: library.appendingPathComponent("Bundled/second.db.zlib"))

        #expect(marks(library) == before)
    }

    @Test func thesameLibraryAsksTheSameQuestionTwice() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }

        #expect(marks(library) == marks(library))
    }

    /// A library that holds none of this answers with nothing rather than
    /// failing: sync may be switched on before anything has been put in it.
    @Test func anEmptyLibraryHasNoWork() throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-local-work-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(marks(root).isEmpty)
    }

    /// A link is skipped here as it is everywhere else: what it points at is
    /// not this library's to publish, and following one could walk out of the
    /// library altogether.
    @Test func alinkIsNotFollowed() throws {
        let library = try makeLibrary()
        defer { try? fileManager.removeItem(at: library) }
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-outside-\(UUID().uuidString)", isDirectory: true)
        try write("{}", to: outside.appendingPathComponent("elsewhere.lampdeck"))
        defer { try? fileManager.removeItem(at: outside) }

        try fileManager.createSymbolicLink(
            at: library.appendingPathComponent("Presentations/Linked"),
            withDestinationURL: outside
        )

        #expect(marks(library).keys.contains { $0.hasSuffix("elsewhere.lampdeck") } == false)
    }
}
