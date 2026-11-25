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
    @Test(arguments: [
        "Workspaces/Writing/W1-abc/draft.md",
        "Workspaces/Writing/W1-abc/context/notes.pdf",
        "Workspaces/Writing/W1-abc/Revisions/nested/1700000001000-A.json",
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
}
