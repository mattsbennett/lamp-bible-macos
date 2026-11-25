import Foundation
@testable import LampBibleMacSupport
import Testing

/// `lamp-bible-core/Documentation/decisions/0017`: a revision this Mac
/// compacted away is claimed as held, on the evidence of the retired list
/// compaction writes as it deletes — so the plan stops downloading it on
/// every pass.
///
/// The gather itself lives in `LibrarySyncController`, which is in the app
/// target and not reachable from here, so the rule it applies is tested
/// directly — as `mergedIntoTheLibrary` is.
struct RevisionMembersHeldTests {
    private let workspace = "Workspaces/Writing/W1-abc"

    private func library() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-retired-\(UUID().uuidString)")
    }

    private func workspaceURL(in library: URL, named name: String) throws -> URL {
        let url = LampWritingWorkspace.root(libraryRootURL: library, fileManager: .default)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: which paths are revisions at all

    /// Nothing but a writing's revision is ever a candidate. A workspace's
    /// document, its context, a deck, a module: absence there means what it
    /// has always meant, and claiming it would stop a real download.
    ///
    /// `Workspaces/Skills/…/Revisions/index.json` is the one a reviewer
    /// found. A custom skill is published by copying its whole directory
    /// with no extension filter, so a skill that happens to keep a folder
    /// called `Revisions` publishes files that match this shape exactly.
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
    func treatsNothingButArevisionAsAcandidate(path: String) {
        #expect(
            LampWorkspaceSync.claimableRevisionMembers(among: [path], heldAsFiles: []).isEmpty,
            "offered \(path)"
        )
    }

    @Test func offersArevisionThatHasNoFile() {
        let kept = "\(workspace)/Revisions/1700000002000-B.json"
        let gone = "\(workspace)/Revisions/1700000001000-A.json"

        #expect(
            LampWorkspaceSync.claimableRevisionMembers(
                among: [kept, gone], heldAsFiles: [kept]
            ) == [gone]
        )
    }

    /// There is no name parsing left to test: a claim matches the name
    /// compaction wrote down, folded. These are the two names the store
    /// itself writes and accepts, and both must be claimable once retired —
    /// the parser that used to derive an id from a name could not see the
    /// second, and fetched it for ever.
    @Test(arguments: [
        "1700000001000-7A1C9E42-3B55-4D21-9A7E-0C2F5B8D6E11.json",
        "7A1C9E42-3B55-4D21-9A7E-0C2F5B8D6E11.json",
    ])
    func claimsEitherNameTheStoreWrites(name: String) async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Some readable history, so the trust guard is satisfied.
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B", in: workspace, createdAt: start
        )
        let list = workspace.appendingPathComponent(".lamp/retired-revisions.json")
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        try Data((existing + "\(UUID().uuidString) \(name)\n").utf8).write(to: list)

        let member = "Workspaces/Writing/W1/Revisions/\(name)"
        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [member], heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed == [member])
    }

    /// A listing that differs only in case names the same file, and the pass
    /// refuses two members that differ only in case, so folding cannot be
    /// choosing between two of them.
    @Test func matchesAnameWhateverItsCase() async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B",
            in: workspace, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let name = "1700000001000-7A1C9E42-3B55-4D21-9A7E-0C2F5B8D6E11.json"
        let list = workspace.appendingPathComponent(".lamp/retired-revisions.json")
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        try Data((existing + "\(UUID().uuidString) \(name)\n").utf8).write(to: list)

        // The id's hex in the other case, with the extension left alone:
        // `.JSON` would be a different kind of file altogether, which
        // `storedRevisions` never reads and compaction therefore never
        // deletes, so it is rightly not claimable.
        let shouted = "Workspaces/Writing/W1/Revisions/"
            + name.replacingOccurrences(of: ".json", with: "").lowercased() + ".json"
        #expect(shouted.contains("7a1c9e42"), "the stem really did change case")
        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [shouted], heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed == [shouted])
    }

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

    // MARK: the claim, end to end against a real workspace

    /// Two of the reader's own edits close enough together to be merged: the
    /// originals are deleted and retired, so their published copies are
    /// claimed rather than fetched back for ever.
    @Test func claimsWhatCompactionRetired() async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A lamp", after: "A lamp unto",
            in: workspace, createdAt: start
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A lamp unto", after: "A lamp unto my feet",
            in: workspace, createdAt: start.addingTimeInterval(60)
        )

        let retired = DevotionalAgentRevisionStore.retiredRevisions(in: workspace)
        try #require(!retired.isEmpty, "compaction merged the two and retired the originals")

        // The names compaction recorded, which are the names the export
        // published — not a name built from the id, which is the inference
        // this design exists to avoid.
        let members = retired.map { "Workspaces/Writing/W1/Revisions/\($0.publishedName)" }
        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: members, heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed == Set(members))
    }

    /// A revision this Mac never retired is not claimed, however plausible
    /// its name — that is the difference between evidence and a guess, and
    /// it is what keeps a member another Mac wrote coming down the first
    /// time.
    @Test func claimsNothingItDidNotRetire() async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "one", after: "one two",
            in: workspace, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let stranger = "Workspaces/Writing/W1/Revisions/1700000001000-\(UUID().uuidString).json"
        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [stranger], heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed.isEmpty)
    }

    /// A workspace whose history is gone altogether, list and all, claims
    /// nothing and fetches once.
    ///
    /// This is the case the previous design got wrong: it inferred
    /// supersession from *any* local history existing, so one new edit saved
    /// into an emptied folder made it claim every older member and the
    /// server's only copies were skipped. With the list, an emptied `.lamp`
    /// has no evidence and claims nothing.
    @Test func claimsNothingWhenTheListIsGoneToo() async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W-lost")

        // The history is gone, and then the writer saves something new.
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "fresh", after: "fresh start",
            in: workspace, createdAt: Date()
        )

        let older = "Workspaces/Writing/W-lost/Revisions/1600000000000-\(UUID().uuidString).json"
        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [older], heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed.isEmpty, "a new edit is not evidence that an old revision was compacted")
    }

    /// A retirement says the replacement was here *then*. If the history is
    /// lost afterwards, the replacement went with it and the server's copy of
    /// the retired original may be the only one left — so a workspace holding
    /// no revision file claims nothing, list or no list.
    @Test func claimsNothingOnceTheReplacementIsGoneToo() async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B", in: workspace, createdAt: start
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A B", after: "A B C",
            in: workspace, createdAt: start.addingTimeInterval(60)
        )
        let retired = Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id))
        try #require(!retired.isEmpty)
        let members = retired.map {
            "Workspaces/Writing/W1/Revisions/1700000001000-\($0.uuidString).json"
        }

        // The history is lost; the list survives beside it.
        try FileManager.default.removeItem(
            at: workspace.appendingPathComponent(".lamp/revisions")
        )
        try #require(!Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id)).isEmpty)
        try #require(DevotionalAgentRevisionStore
            .claimableRetiredNames(in: workspace).isEmpty)

        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: members, heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed.isEmpty, "the only recoverable copies must stay fetchable")
    }

    /// Everything a surviving demotable merge covers stays fetchable —
    /// including an *untagged* original, which the first version of this
    /// retired. `removingReplaced` needs a holder for every id the merge
    /// covers and only one of them has to know a turn, so retiring the
    /// untagged one blocks the demotion for good.
    @Test func keepsEverythingAdemotableMergeCoversFetchable() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // An agent's run, merged without a turn — the legacy shape.
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, before: "one", after: "one two",
            in: workspace, createdAt: start
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, before: "one two", after: "one two three",
            in: workspace, createdAt: start.addingTimeInterval(60)
        )

        let kept = try DevotionalAgentRevisionStore.revisions(in: workspace)
        let merges = kept.filter {
            $0.turnID == nil && $0.kind == .agentEdit && $0.replacedRevisionIDs?.isEmpty == false
        }
        try #require(!merges.isEmpty, "the two agent edits merged, untagged")
        let covered = Set(merges.flatMap { $0.replacedRevisionIDs ?? [] })
        let retired = Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id))

        #expect(
            retired.intersection(covered).isEmpty,
            "nothing a demotable merge covers may be retired"
        )
    }

    /// A retirement from long ago is overridden by what the history needs
    /// now.
    ///
    /// A legacy untagged merge arriving later can displace the tagged
    /// replacement that justified a retirement, and then `removingReplaced`
    /// wants that original back. The list is evidence of a past deletion,
    /// not a standing verdict.
    @Test func lettsAliveDemotionOverrideAnOldRetirement() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // An agent's run that merges without a turn: the legacy shape.
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, before: "one", after: "one two",
            in: workspace, createdAt: start
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit, before: "one two", after: "one two three",
            in: workspace, createdAt: start.addingTimeInterval(60)
        )
        let merges = try DevotionalAgentRevisionStore.revisions(in: workspace).filter {
            $0.turnID == nil && $0.kind == .agentEdit && $0.replacedRevisionIDs?.isEmpty == false
        }
        let covered = try #require(merges.first?.replacedRevisionIDs?.first)

        // As though an earlier pass had retired that original, before this
        // merge turned up and made it wanted again.
        let list = workspace.appendingPathComponent(".lamp/retired-revisions.json")
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        try Data((existing + "\(covered.uuidString) 1600000000000-\(covered.uuidString).json\n").utf8)
            .write(to: list)
        try #require(Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id))
            .contains(covered))

        let claimable = DevotionalAgentRevisionStore.claimableRetiredNames(in: workspace)

        #expect(
            !claimable.contains(DevotionalAgentRevisionStore.foldedName(
                "1600000000000-\(covered.uuidString).json"
            )),
            "the demotion wants it back, retired or not"
        )
    }

    /// A replacement that is there but unreadable is no replacement. Its
    /// filename satisfied the guard this replaced, and then the retired
    /// originals — the only recoverable copies — were claimed rather than
    /// fetched.
    @Test func claimsNothingWhenTheOnlyHistoryLeftWillNotDecode() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let revisions = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        try Data("{ this is not a revision".utf8).write(
            to: revisions.appendingPathComponent("1700000002000-\(UUID().uuidString).json")
        )
        let retired = UUID()
        try Data("\(retired.uuidString) 1600000000000-\(retired.uuidString).json\n".utf8).write(
            to: workspace.appendingPathComponent(".lamp/retired-revisions.json")
        )
        try #require(Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id))
            .contains(retired))

        #expect(
            DevotionalAgentRevisionStore.claimableRetiredNames(in: workspace).isEmpty,
            "a file that will not decode is not evidence the history survived"
        )
    }

    /// The list is appended to, not rewritten: an autosave that compacts must
    /// not pay for every id retired before it.
    @Test func appendsToTheListRatherThanRewritingIt() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let metadata = workspace.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let list = metadata.appendingPathComponent("retired-revisions.json")

        // An id retired earlier, then an append interrupted mid-id with no
        // newline after it. Writing straight onto that fragment would glue
        // the next good id to it and lose the retirement.
        let old = UUID()
        try Data("\(old.uuidString) old.json\n9F3A17".utf8).write(to: list)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B", in: workspace, createdAt: start
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A B", after: "A B C",
            in: workspace, createdAt: start.addingTimeInterval(60)
        )

        let ids = Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id))
        #expect(ids.contains(old), "what was already retired is still retired")
        #expect(ids.count > 1, "and the new retirements were added")
        let text = try String(contentsOf: list, encoding: .utf8)
        #expect(text.hasPrefix(old.uuidString), "appended, so the first line is untouched")
        #expect(!text.contains("\"ids\""), "a line per id, not a rewritten document")
        #expect(
            !text.contains("9F3A17-"),
            "the new id began a line of its own rather than joining the fragment"
        )
    }

    /// One damaged byte loses its own line and nothing else.
    ///
    /// Decoding the whole file as UTF-8 first meant a single bad byte
    /// anywhere answered "nothing is retired" — after which compaction would
    /// append good entries behind the damage and neither the old nor the new
    /// ones would ever be seen again, so the downloads would repeat for ever.
    @Test func keepsTheGoodLinesAroundAdamagedOne() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let metadata = workspace.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

        let before = UUID()
        let after = UUID()
        var bytes = Data("\(before.uuidString) a.json\n".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, UInt8(ascii: "\n")])
        bytes.append(Data("\(after.uuidString) b.json\n".utf8))
        try bytes.write(to: metadata.appendingPathComponent("retired-revisions.json"))

        let ids = Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id))

        #expect(ids == [before, after])
    }

    /// The list is local state and must never be published: it lives in
    /// `.lamp`, where only `revisions/` is carried out.
    @Test func keepsTheListOutOfWhatSyncCarries() async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B", in: workspace, createdAt: start
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A B", after: "A B C",
            in: workspace, createdAt: start.addingTimeInterval(60)
        )
        try #require(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".lamp/retired-revisions.json").path
        ))

        let exported = root.appendingPathComponent("Exported", isDirectory: true)
        try await LampWorkspaceSync.exportPortableWorkspaces(from: root, to: exported)

        let published = FileManager.default.enumerator(at: exported, includingPropertiesForKeys: nil)
        var names: [String] = []
        while case let url as URL = published?.nextObject() { names.append(url.lastPathComponent) }
        #expect(!names.contains("retired-revisions.json"))
    }

    // MARK: what the log may say

    /// The log line says where, never what the reader called it.
    @Test func namesTheFolderAndNotTheReadersOwnFilename() {
        let folders = LampSyncDiagnostics.folders(named: [
            "WritingReview/W1__My Private Doubts.json",
            "Workspaces/Writing/W1-abc/Revisions/1-A.json",
            "Workspaces/Presentations/easter.lampdeck",
        ])

        #expect(!folders.contains("My Private Doubts"))
        #expect(!folders.contains(".json"))
        #expect(folders == "Workspaces/Presentations, Workspaces/Writing, WritingReview")
    }

    /// And nothing a publisher named either. A book's picture lives under its
    /// module id, and a module id carries words from the book's title.
    @Test func namesNoModuleTheReaderHas() {
        let folders = LampSyncDiagnostics.folders(named: [
            "BookMedia/nic-romans-moo/plate-3.png",
            "Media/Notes/43011035/tomb.png",
            "Workspaces/Writing/W1-abc/Revisions/1-A.json",
        ])

        #expect(!folders.contains("nic-romans-moo"))
        #expect(folders == "BookMedia, Media, Workspaces/Writing")
    }

    /// A bare name is all name, so it gives up none of itself.
    @Test func givesUpNothingForAbareFilename() {
        #expect(!LampSyncDiagnostics.folders(named: ["My Private Doubts.lamp"])
            .contains("My Private Doubts"))
    }
}
