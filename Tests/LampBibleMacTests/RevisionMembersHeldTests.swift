import Foundation
@testable import LampBibleMacSupport
import Testing

/// `lamp-bible-core/Documentation/decisions/0016`: a revision this Mac
/// compacted away is claimed as held, so the plan stops downloading it on
/// every pass.
///
/// The gather itself lives in `LibrarySyncController`, which is in the app
/// target and not reachable from here, so the rule it applies is tested
/// directly — as `mergedIntoTheLibrary` is.
struct RevisionMembersHeldTests {
    private let workspace = "Workspaces/Writing/W1-abc"

    @Test func claimsArevisionThatIsRecordedButNoLongerAfile() {
        let kept = "\(workspace)/Revisions/1700000002000-B.json"
        let compactedAway = "\(workspace)/Revisions/1700000001000-A.json"

        let claimed = LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [kept, compactedAway],
            heldAsFiles: [kept]
        )

        #expect(claimed == [compactedAway])
    }

    /// The whole point: a member still on disk is published as a file, so
    /// claiming it as held-without-a-file would be a lie — and a lie that
    /// would stop it being uploaded.
    @Test func doesNotClaimArevisionItStillHoldsAsAfile() {
        let path = "\(workspace)/Revisions/1700000001000-A.json"

        let claimed = LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [path], heldAsFiles: [path]
        )

        #expect(claimed.isEmpty)
    }

    /// Nothing but a revision is claimed. A workspace's document, its
    /// context, a deck, a module: absence there means what it has always
    /// meant, and claiming it would stop a real download.
    ///
    /// `Workspaces/Skills/…/Revisions/index.json` is the one a reviewer
    /// found. A custom skill is published by copying its whole directory
    /// with no extension filter, so a skill that happens to keep a folder
    /// called `Revisions` publishes files that match this shape exactly —
    /// and they are ordinary files of the skill's, with none of the
    /// write-once, compaction-only history this claim reasons about.
    @Test(arguments: [
        "Workspaces/Writing/W1-abc/draft.md",
        "Workspaces/Writing/W1-abc/context/notes.pdf",
        "Workspaces/Writing/W1-abc/Revisions/nested/1700000001000-A.json",
        "Workspaces/Skills/my-skill/Revisions/index.json",
        "Workspaces/Devotionals/W1-abc/Revisions/1700000001000-A.json",
        "Workspaces/Presentations/easter.lampdeck",
        "Translations/bsb.lamp",
        "Workspaces/Writing/W1-abc/Revisions/notjson.txt",
        "Workspaces/Writing/W1-abc/Revisions/.json",
        "Workspaces/Writing//Revisions/1700000001000-A.json",
        "Revisions/1700000001000-A.json",
    ])
    func claimsNothingButArevision(path: String) {
        let claimed = LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [path], heldAsFiles: []
        )

        #expect(claimed.isEmpty, "claimed \(path)")
    }

    /// The shape the real library was in: one surviving merge and the run of
    /// intermediate merges it replaced, none of which it names.
    ///
    /// This is why matching `replacedRevisionIDs` was not enough — a merge
    /// unions its two sides' *covered* ids, never their own, so an
    /// intermediate merge is named by nothing that outlives it. On the real
    /// library that rule reached 10 of 43 members; absence reaches all of
    /// them.
    @Test func claimsEveryIntermediateMergeOfArun() {
        let survivor = "\(workspace)/Revisions/1700000000900-FINAL.json"
        let intermediates = (1...8).map {
            "\(workspace)/Revisions/17000000000\($0)0-M\($0).json"
        }

        let claimed = LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: intermediates + [survivor],
            heldAsFiles: [survivor]
        )

        #expect(claimed == Set(intermediates))
    }

    /// A demotion needs every id the untagged merge replaced. One of them
    /// claimed as held never arrives, so the merge keeps a turn's changes
    /// under no turn's name for good — so that one is left unclaimed.
    @Test func leavesArevisionAdemotionIsStillWaitingFor() {
        let wanted = UUID()
        let other = UUID()
        let needed = "\(workspace)/Revisions/1700000001000-\(wanted.uuidString).json"
        let ordinary = "\(workspace)/Revisions/1700000002000-\(other.uuidString).json"
        let survivor = "\(workspace)/Revisions/1700000003000-C.json"

        let claimed = LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [needed, ordinary, survivor],
            heldAsFiles: [survivor],
            stillWantedForDemotion: [wanted]
        )

        #expect(claimed == [ordinary], "the wanted one stays fetchable")
    }

    /// The names on disk are a UUID as Foundation spells it, upper case. A
    /// store or a server that spelled one in lower case must still match, or
    /// the exception silently stops applying.
    @Test func matchesAwantedIDWhateverItsCase() {
        let wanted = UUID()
        let lower = "\(workspace)/Revisions/1700000001000-\(wanted.uuidString.lowercased()).json"

        let claimed = LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [lower], heldAsFiles: [], stillWantedForDemotion: [wanted]
        )

        #expect(claimed.isEmpty)
    }

    /// A wanted id is matched as the whole name, not anywhere in it: a
    /// different revision whose name merely contains one must still be
    /// claimed, or one id keeps a second file downloading for ever.
    @Test func doesNotMistakeAdifferentRevisionForAwantedOne() {
        let wanted = UUID()
        let different = "\(workspace)/Revisions/1700000001000-\(wanted.uuidString)-B.json"

        let claimed = LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [different], heldAsFiles: [], stillWantedForDemotion: [wanted]
        )

        #expect(claimed == [different])
    }

    /// The log line says where, never what the reader called it.
    ///
    /// The first version took the first two components of the whole path,
    /// which for anything two deep is the folder *and the filename* — so a
    /// review of a document published as `WritingReview/<id>__<name>.json`
    /// put that document's name in the public part of the log, which is what
    /// a sysdiagnose collects and a person sends on.
    @Test func namesTheFolderAndNotTheReadersOwnFilename() {
        let review = "WritingReview/W1__My Private Doubts.json"
        let folders = LampSyncDiagnostics.folders(named: [
            review,
            "Workspaces/Writing/W1-abc/Revisions/1-A.json",
            "Workspaces/Presentations/easter.lampdeck",
        ])

        #expect(!folders.contains("My Private Doubts"))
        #expect(!folders.contains(".json"))
        #expect(folders == "Workspaces/Presentations, Workspaces/Writing, WritingReview")
    }

    /// And nothing a publisher named either. A book's picture lives under its
    /// module id, and a module id carries words from the book's title, so a
    /// second component is kept only where the layout fixes it.
    @Test func namesNoModuleTheReaderHas() {
        let folders = LampSyncDiagnostics.folders(named: [
            "BookMedia/nic-romans-moo/plate-3.png",
            "Media/Notes/43011035/tomb.png",
            "Workspaces/Writing/W1-abc/Revisions/1-A.json",
        ])

        #expect(!folders.contains("nic-romans-moo"))
        #expect(!folders.contains("moo"))
        #expect(folders == "BookMedia, Media, Workspaces/Writing")
    }

    /// A bare name is all name, so it gives up none of itself.
    @Test func givesUpNothingForAbareFilename() {
        let folders = LampSyncDiagnostics.folders(named: ["My Private Doubts.lamp"])

        #expect(!folders.contains("My Private Doubts"))
    }

    /// The id is read off the end of the name, past the four dashes a UUID
    /// has of its own and the millisecond stamp in front of it.
    @Test func readsTheIDOffTheEndOfAname() {
        let id = UUID()
        #expect(
            LampWorkspaceSync.revisionID(
                named: "\(workspace)/Revisions/1700000001000-\(id.uuidString).json"
            ) == id
        )
        // Nothing that is not one, rather than something near enough.
        #expect(LampWorkspaceSync.revisionID(named: "\(workspace)/Revisions/17-A.json") == nil)
        #expect(LampWorkspaceSync.revisionID(named: "\(workspace)/draft.md") == nil)
        #expect(
            LampWorkspaceSync.revisionID(
                named: "\(workspace)/Revisions/\(id.uuidString).json"
            ) == nil,
            "a name with no stamp in front of the id is not one the store wrote"
        )
    }

    /// Which workspace a member belongs to, for reading only the histories
    /// that can change the answer.
    @Test func namesTheWorkspaceAmemberBelongsTo() {
        #expect(
            LampWorkspaceSync.workspaceIdentifier(
                ofRevisionAt: "Workspaces/Writing/W1-abc/Revisions/1-A.json"
            ) == "W1-abc"
        )
        #expect(
            LampWorkspaceSync.workspaceIdentifier(
                ofRevisionAt: "Workspaces/Skills/my-skill/Revisions/index.json"
            ) == nil
        )
    }

    /// The reading half, against a real workspace.
    ///
    /// Worth its own test because the way this fails is silent: a field read
    /// by the wrong name, or a decode that throws, gives an empty set — and
    /// an empty set is exactly "claim everything", which is the bug back
    /// again with no sign of it.
    @Test func readsTheWantedIDsOutOfArealWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-wanted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Two of the reader's own edits, close enough together to be merged
        // into one record. Nothing the person typed carries a turn, so the
        // merge is untagged and is what a demotion would be weighed against.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A lamp", after: "A lamp unto",
            in: root, createdAt: start
        )
        let second = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A lamp unto", after: "A lamp unto my feet",
            in: root, createdAt: start.addingTimeInterval(60)
        )

        let wanted = try DevotionalAgentRevisionStore.idsWantedForDemotion(in: root)

        // Whatever the store chose to keep, the ids the surviving untagged
        // merge names are the ones a demotion would need.
        let kept = try DevotionalAgentRevisionStore.revisions(in: root)
        let merges = kept.filter { $0.turnID == nil && $0.replacedRevisionIDs?.isEmpty == false }
        try #require(!merges.isEmpty, "the two edits were merged into one record")
        // A user edit's merge is not one a demotion can ever be waiting for:
        // nothing the person typed carries a turn, and a merge never crosses
        // kinds, so its parts can never supply the tagged holder a demotion
        // needs. Keeping them fetchable would download and discard a
        // revision every pass for a demotion that cannot happen.
        #expect(merges.allSatisfy { $0.kind == .userEdit })
        #expect(wanted.isEmpty, "a user edit's merge wants nothing fetched")
        #expect(first != nil || second != nil)

        // An agent's merge does want its parts, and the same workspace says
        // so once one is there.
        let turn = UUID()
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, turnID: turn, before: "one", after: "one two",
            in: root, createdAt: start.addingTimeInterval(3_600)
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, turnID: turn, before: "one two", after: "one two three",
            in: root, createdAt: start.addingTimeInterval(3_660)
        )
        // Those two carry a turn, so their merge does too and is not a
        // candidate. What this proves is the kind test, not the turn test:
        // the set stays empty while every untagged merge is a user's.
        #expect(try DevotionalAgentRevisionStore.idsWantedForDemotion(in: root).isEmpty)
    }

    /// A workspace whose history is gone altogether claims nothing.
    ///
    /// The claim says a missing revision was superseded by one that is here.
    /// Where none is here — a folder restored without its `.lamp`, a
    /// directory deleted by hand — nothing superseded anything, and the
    /// server's copies are the only way back. Claiming them would be worse
    /// than fetching them.
    @Test func claimsNothingFromAworkspaceWithNoHistoryLeft() async throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-lost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let root = LampWritingWorkspace.root(libraryRootURL: library, fileManager: .default)
        let emptied = root.appendingPathComponent("W-lost", isDirectory: true)
        try FileManager.default.createDirectory(at: emptied, withIntermediateDirectories: true)

        let member = "Workspaces/Writing/W-lost/Revisions/1700000001000-A.json"
        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [member], heldAsFiles: [], inLibraryAt: library
        )

        #expect(claimed.isEmpty)
        #expect(!DevotionalAgentRevisionStore.holdsAnyRevision(in: emptied))
    }
}
