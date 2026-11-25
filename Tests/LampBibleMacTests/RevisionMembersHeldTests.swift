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
        try Data((existing + "\(UUID().uuidString) \(name);\n").utf8).write(to: list)

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
        try Data((existing + "\(UUID().uuidString) \(name);\n").utf8).write(to: list)

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

    /// `0017`'s remedy: a tagged record dropped under an untagged merge puts
    /// that merge's originals back on the wanted list.
    ///
    /// The merge is what `removingReplaced` would demote in the tagged
    /// record's favour if the originals it covers were all here — and a
    /// retirement from an earlier pass is what keeps them away. Taking them
    /// off the list lets the next pass fetch them, and the demotion gets its
    /// chance. The case this closes is the one where the other Mac can
    /// restore to an intermediate version and this one cannot.
    @Test func putsBackWhatAdemotionWouldNeedWhenAtaggedRecordIsDropped() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let revisions = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)

        let a = UUID(), b = UUID(), c = UUID()
        func sorted(_ ids: [UUID]) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
        // The tagged record, and the untagged merge that subsumes it.
        let tagged = DevotionalAgentRevision(
            kind: .agentEdit, beforeMarkdown: "one", afterMarkdown: "one two",
            replacedRevisionIDs: sorted([a, b]), turnID: UUID()
        )
        let untagged = DevotionalAgentRevision(
            kind: .agentEdit, beforeMarkdown: "one", afterMarkdown: "one two three",
            replacedRevisionIDs: sorted([a, b, c])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        for revision in [tagged, untagged] {
            try encoder.encode(revision).write(
                to: revisions.appendingPathComponent("1700000001000-\(revision.id.uuidString).json")
            )
        }
        // An earlier pass retired the originals the merge covers, plus one
        // unrelated retirement that must survive untouched.
        let unrelated = UUID()
        let list = workspace.appendingPathComponent(".lamp/retired-revisions.json")
        let lines = ([a, b, c, unrelated]).map { "\($0.uuidString) 1600000000000-\($0.uuidString).json;" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: list)

        try DevotionalAgentRevisionStore.compact(in: workspace)

        let retired = Set(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id))
        #expect(retired.isDisjoint(with: [a, b, c]), "the demotion's originals are fetchable again")
        #expect(retired.contains(unrelated), "and nothing else was disturbed")

        // And the tagged record itself is not retired. Freeing the originals
        // alone is useless — the demotion needs a holder that knows a turn,
        // so retiring the record that supplies it means the next pass fetches
        // the originals, still cannot demote, and retires them again.
        #expect(
            !retired.contains(tagged.id),
            "the holder the demotion needs stays fetchable too"
        )
    }

    /// An entry carrying the same published name in another case does not go
    /// on suppressing a revision the demotion wants back.
    @Test func freesEveryRetirementUnderAwantedName() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let metadata = workspace.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        // Some readable history, or `claimableRetiredNames` answers nothing
        // whatever the list says and the check is vacuous.
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B",
            in: workspace, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let wanted = UUID(), twin = UUID()
        let name = "1600000000000-\(wanted.uuidString).json"
        let list = metadata.appendingPathComponent("retired-revisions.json")
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        try Data((
            existing
                + "\(wanted.uuidString) \(name);\n"
                + "\(twin.uuidString) \(name.lowercased());\n"
        ).utf8).write(to: list)

        try DevotionalAgentRevisionStore.unretireForTesting([wanted], in: workspace)

        let names = DevotionalAgentRevisionStore.claimableRetiredNames(in: workspace)
        #expect(
            !names.contains(DevotionalAgentRevisionStore.foldedName(name)),
            "no spelling of that name is left suppressing it"
        )
    }

    /// A log that cannot be read is left exactly as it is, never truncated.
    @Test func leavesAnunreadableLogAlone() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let metadata = workspace.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let list = metadata.appendingPathComponent("retired-revisions.json")
        let kept = UUID()
        try Data("\(kept.uuidString) a.json;\n".utf8).write(to: list)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: list.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: list.path
        ) }

        try DevotionalAgentRevisionStore.unretireForTesting([UUID()], in: workspace)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: list.path
        )
        #expect(
            DevotionalAgentRevisionStore.retiredRevisions(in: workspace).map(\.id) == [kept],
            "the log survived a pass that could not read it"
        )
    }

    /// Two missing members whose names fold alike are both left alone.
    ///
    /// A folded match would otherwise claim both on one retirement, and the
    /// pass checks `0013`'s case collisions among the planned downloads —
    /// which a claim has already taken them out of. So the collision would
    /// go unreported and the other member, which may be a revision a
    /// demotion needs, would be dropped in silence.
    @Test func leavesTwoNamesThatFoldAlikeToThePass() async throws {
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
        try Data((existing + "\(UUID().uuidString) \(name);\n").utf8).write(to: list)

        let one = "Workspaces/Writing/W1/Revisions/\(name)"
        let other = "Workspaces/Writing/W1/Revisions/"
            + name.replacingOccurrences(of: ".json", with: "").lowercased() + ".json"
        try #require(one != other)

        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: [one, other], heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed.isEmpty)
    }

    /// A link where the list should be is refused, read and written.
    ///
    /// `FileHandle` follows one, so compaction appended retirement entries
    /// into whatever it pointed at — and the write *succeeding* is why `try?`
    /// did not protect the other file.
    @Test func willNotReadOrWriteAlinkWhereTheListBelongs() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let metadata = workspace.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

        let elsewhere = root.appendingPathComponent("not-for-the-list.txt")
        try Data("someone else's bytes\n".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: metadata.appendingPathComponent("retired-revisions.json"),
            withDestinationURL: elsewhere
        )

        // Reading answers nothing rather than reading the other file.
        #expect(DevotionalAgentRevisionStore.retiredRevisions(in: workspace).isEmpty)

        // And a compaction that would retire something leaves it alone.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B", in: workspace, createdAt: start
        )
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A B", after: "A B C",
            in: workspace, createdAt: start.addingTimeInterval(60)
        )

        #expect(
            try Data(contentsOf: elsewhere) == Data("someone else's bytes\n".utf8),
            "nothing was appended through the link"
        )
    }

    /// Two workspaces using the same filename are not a collision.
    ///
    /// Counting basenames rather than whole paths made every workspace's
    /// `autosave.json` collide with every other's, so none of them was ever
    /// claimed and all were fetched for ever — the loop this exists to stop,
    /// reintroduced by the guard against a different one.
    @Test func doesNotMistakeTwoWorkspacesForAcollision() async throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        var members: [String] = []
        for name in ["W1", "W2"] {
            let workspace = try workspaceURL(in: root, named: name)
            _ = try DevotionalAgentRevisionStore.record(
                kind: .userEdit, before: "A", after: "A B",
                in: workspace, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let list = workspace.appendingPathComponent(".lamp/retired-revisions.json")
            let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
            try Data((existing + "\(UUID().uuidString) autosave.json;\n").utf8).write(to: list)
            members.append("Workspaces/Writing/\(name)/Revisions/autosave.json")
        }

        let claimed = await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
            members: members, heldAsFiles: [], inLibraryAt: root
        )

        #expect(claimed == Set(members))
    }

    /// A record cut short is skipped, not read as a shorter name.
    ///
    /// An append of `draft.json.backup.json` interrupted after `draft.json`
    /// would otherwise be a valid retirement for a different file that
    /// really exists — and the next append, which starts a line of its own,
    /// would leave the fragment looking complete for ever.
    @Test func skipsArecordCutShortRatherThanReadingAshorterName() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let metadata = workspace.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let id = UUID()
        try Data("\(id.uuidString) draft.json\n".utf8).write(
            to: metadata.appendingPathComponent("retired-revisions.json")
        )

        let read = DevotionalAgentRevisionStore.retiredRevisions(in: workspace)

        #expect(read.isEmpty, "no terminator, so the name may be a truncation of another")
    }

    /// A published name is recorded as it is, whatever it holds. The store
    /// reads any `.json` in the folder, so a name can carry a space — or a
    /// newline, which is the list's own record separator.
    @Test func roundTripsAnawkwardPublishedName() throws {
        let root = library()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try workspaceURL(in: root, named: "W1")
        let revisions = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try DevotionalAgentRevisionStore.record(
            kind: .userEdit, before: "A", after: "A B", in: workspace, createdAt: start
        )

        // Written by hand, as an import of someone else's folder could leave
        // it: a leading space, and a newline inside the name.
        let awkward = " run\nthrough.json"
        let id = UUID()
        let list = workspace.appendingPathComponent(".lamp/retired-revisions.json")
        let encoded = awkward.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        )!
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        try Data((existing + "\(id.uuidString) \(encoded);\n").utf8).write(to: list)

        let read = DevotionalAgentRevisionStore.retiredRevisions(in: workspace)

        #expect(read.contains(
            DevotionalAgentRevisionStore.RetiredRevision(id: id, publishedName: awkward)
        ))
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
        try Data("\(retired.uuidString) 1600000000000-\(retired.uuidString).json;\n".utf8).write(
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
        try Data("\(old.uuidString) old.json;\n9F3A17".utf8).write(to: list)

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
        var bytes = Data("\(before.uuidString) a.json;\n".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, UInt8(ascii: "\n")])
        bytes.append(Data("\(after.uuidString) b.json;\n".utf8))
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

/// What the retired list actually claims, as one property instead of one
/// test per guess.
///
/// `lamp-bible-core/Documentation/decisions/0017`. A retirement says *this
/// Mac holds that history in merged form*, and that is exactly true when a
/// retired file coming back would change nothing the store keeps. Four
/// versions of a predicate about demotions were each wrong in a new way,
/// every one shipping a test that encoded the version it came with — which
/// is how the same thing was wrong four rounds running. This is the check
/// the list is held to instead: if it fails, the fault is in `compact` or
/// `removingReplaced`, not in anything beside them.
///
/// **The property holds given a precondition**: that no untagged merge
/// covers a change that knows its turn. `canMerge` refuses to cross turns
/// and refuses to mix kinds, so this build never writes that shape — only an
/// older one could. Outside the precondition the kept set genuinely depends
/// on which files are present, and so on arrival order; a reviewer found the
/// case and `0017` accepts it. What is still true there, and asserted here,
/// is what the code's own comment promises: the answer does not depend on
/// the order the folder happened to list, and running it twice changes
/// nothing.
struct RetirementKeepsWhatItClaimsTests {
    /// A small deterministic generator, seeded per case: runs of edits by
    /// the person and by an agent, merged runs, turns on some and not
    /// others, **coverage that overlaps between merges**, and an id that is
    /// never present at all.
    ///
    /// The overlap matters. A first version drew fresh ids for every merge's
    /// coverage, so no two merges ever shared a change and the one shape
    /// that breaks the unconditional property could not be generated.
    private func revisions(seed: UInt64) -> [DevotionalAgentRevision] {
        var state = seed | 1
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var made: [DevotionalAgentRevision] = []
        var text = "lamp"
        var at = start
        let turns = [UUID(), UUID()]

        // A pool the merges draw their coverage from, so they overlap, plus
        // one id nothing ever holds.
        let pool = (0..<4).map { _ in UUID() }
        let neverPresent = UUID()

        // In runs, so revisions really are mergeable: a merge needs the same
        // kind, the same turn, a contiguous before/after and a gap inside
        // the policy's.
        for _ in 0..<(2 + next(3)) {
            let agent = next(2) == 0
            let turn = agent && next(3) != 0 ? turns[next(turns.count)] : nil
            for _ in 0..<(2 + next(3)) {
                let before = text
                text += " \(made.count)"
                at = at.addingTimeInterval(Double(30 + next(600)))
                var covered: [UUID] = []
                for _ in 0..<next(3) { covered.append(pool[next(pool.count)]) }
                if next(4) == 0 { covered.append(neverPresent) }
                made.append(
                    DevotionalAgentRevision(
                        createdAt: at,
                        kind: agent ? .agentEdit : .userEdit,
                        beforeMarkdown: before,
                        afterMarkdown: text,
                        replacedRevisionIDs: covered.isEmpty
                            ? nil
                            : Array(Set(covered)).sorted { $0.uuidString < $1.uuidString },
                        turnID: turn
                    )
                )
            }
            at = at.addingTimeInterval(Double(8 * 3_600))
        }

        // Singles standing for pooled changes, some of which know a turn —
        // which is what can put an untagged merge over a tagged change.
        for id in pool where next(2) == 0 {
            at = at.addingTimeInterval(60)
            made.append(
                DevotionalAgentRevision(
                    id: id, createdAt: at, kind: .agentEdit,
                    beforeMarkdown: "p", afterMarkdown: "p q",
                    turnID: next(2) == 0 ? turns[next(turns.count)] : nil
                )
            )
        }
        if let first = made.first, next(2) == 0 { made.append(first) }
        return made
    }

    /// Whether any untagged merge covers a change that knows its turn —
    /// the shape only an older build can write.
    private func anUntaggedMergeCoversAtaggedChange(
        _ revisions: [DevotionalAgentRevision]
    ) -> Bool {
        let tagged = Set(revisions.lazy.filter { $0.turnID != nil }.map(\.id))
        for revision in revisions
        where revision.turnID == nil && revision.replacedRevisionIDs?.isEmpty == false {
            if !Set(revision.replacedRevisionIDs ?? []).isDisjoint(with: tagged) { return true }
        }
        return false
    }

    @Test(arguments: Array(1...60) as [UInt64])
    func aretiredRevisionComingBackChangesNothingKept(seed: UInt64) throws {
        let all = revisions(seed: seed)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let kept = DevotionalAgentRevisionCompactor.compact(all, now: now)
        let keptIDs = Set(kept.map(\.id))
        let dropped = all.filter { !keptIDs.contains($0.id) }
        guard !dropped.isEmpty else { return }

        guard !anUntaggedMergeCoversAtaggedChange(all) else {
            // Outside the precondition. What is kept really does depend on
            // what is present, so only the two promises the code makes for
            // itself are asserted: order does not decide, and twice is the
            // same as once.
            //
            // Compared with each other, not with `kept`: `compact` reduces
            // first and *then* merges, so a merge it forms can subsume
            // something it kept, and a further reduction drops that. Benign
            // — the next compaction settles it — and nothing to do with the
            // list, but it means `kept` is not the baseline for either
            // promise.
            let forwards = DevotionalAgentRevisionCompactor.removingReplaced(kept)
            let backwards = DevotionalAgentRevisionCompactor.removingReplaced(kept.reversed())
            let twice = DevotionalAgentRevisionCompactor.removingReplaced(forwards)
            #expect(
                Set(forwards.map(\.id)) == Set(backwards.map(\.id)),
                "seed \(seed): the order the folder listed decided what is kept"
            )
            #expect(
                Set(twice.map(\.id)) == Set(forwards.map(\.id)),
                "seed \(seed): reducing twice is not the same as once"
            )
            return
        }

        for take in 1...min(dropped.count, 3) {
            for start in 0...(dropped.count - take) {
                let returning = Array(dropped[start..<(start + take)])
                let after = DevotionalAgentRevisionCompactor.removingReplaced(kept + returning)
                #expect(
                    Set(after.map(\.id)) == keptIDs,
                    "seed \(seed): \(returning.count) returning changed what is kept"
                )
            }
        }
    }
}
