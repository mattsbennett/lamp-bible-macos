import Foundation
import LampBibleMacSupport
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
        #expect(wanted == Set(merges.flatMap { $0.replacedRevisionIDs ?? [] }))
        #expect(!wanted.isEmpty)
        #expect(first != nil || second != nil)
    }
}
