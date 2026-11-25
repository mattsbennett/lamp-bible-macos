import Foundation
import LampModuleKit
import Testing

@testable import LampBibleMacSupport

/// The rule for putting a writing's sources back on the server once the
/// writing has been left alone.
///
/// Stated without a file system on purpose. The sweep that will call this runs
/// unattended and deletes the only local copy of a file, so the rule deciding
/// *which* files is the part worth pinning sentence by sentence; reading the
/// dates off disk and carrying the answer out are tested separately.
struct WorkspaceSourceOffloadTests {
    private typealias Workspace = WorkspaceSourceOffload.Workspace
    private typealias Candidate = WorkspaceSourceOffload.Candidate

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func idle(
        _ writingID: String,
        days: Double,
        sources: [String],
        onTheServer: Set<String>? = nil
    ) -> Workspace {
        Workspace(
            writingID: writingID,
            lastActivity: now.addingTimeInterval(-days * 24 * 60 * 60),
            sources: sources,
            onTheServer: onTheServer ?? Set(sources)
        )
    }

    @Test func nothingIsOffloadedWhenTheSettingIsNever() {
        let workspaces = [Self.idle("a", days: 365, sources: ["big.pdf", "notes/other.pdf"])]
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: workspaces, after: .never, heldBy: [], now: Self.now
            ).isEmpty,
            """
            Never has to mean never. It is the default, so a reader who has not \
            chosen must not find their sources gone.
            """
        )
    }

    @Test func anOpenWritingIsNeverOffloaded() {
        let workspaces = [Self.idle("a", days: 4_000, sources: ["big.pdf"])]
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: workspaces, after: .oneMonth, heldBy: ["a"], now: Self.now
            ).isEmpty,
            """
            An open editor is a writing being worked on now, whatever its saved \
            date says, and its agent pane is inside it — so a chat or a Terminal \
            turn mid-flight is held by the same check.
            """
        )
    }

    @Test func aWritingWhoseActivityIsUnknownIsKept() {
        let workspaces = [
            Workspace(
                writingID: "a", lastActivity: nil,
                sources: ["big.pdf"], onTheServer: ["big.pdf"]
            )
        ]
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: workspaces, after: .oneMonth, heldBy: [], now: Self.now
            ).isEmpty,
            """
            The answer to not knowing is to keep. Keeping a source too long \
            costs disk; taking one too early costs a fetch the reader did not ask \
            for, and may cost it on a connection they do not have.
            """
        )
    }

    @Test func aSourceTheServerHasNotTakenIsLeftWhileItsNeighboursGo() {
        let workspaces = [
            Self.idle(
                "a", days: 200,
                sources: ["taken.pdf", "pending.pdf"],
                onTheServer: ["taken.pdf"]
            )
        ]
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: workspaces, after: .oneMonth, heldBy: [], now: Self.now
            ) == [Candidate(writingID: "a", relativePath: "taken.pdf")],
            """
            Offloading deletes the only local copy, so a source the server has \
            not confirmed would simply be gone. One pending file must not hold \
            back the rest of the workspace either.
            """
        )
    }

    @Test func inactivityIsStrictlyLongerThanTheSetting() {
        let exactly = Workspace(
            writingID: "a",
            lastActivity: Self.now.addingTimeInterval(-30 * 24 * 60 * 60),
            sources: ["big.pdf"], onTheServer: ["big.pdf"]
        )
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: [exactly], after: .oneMonth, heldBy: [], now: Self.now
            ).isEmpty,
            "A writing left alone for exactly a month has not yet passed “after one month”."
        )

        let aSecondMore = Workspace(
            writingID: "a",
            lastActivity: Self.now.addingTimeInterval(-30 * 24 * 60 * 60 - 1),
            sources: ["big.pdf"], onTheServer: ["big.pdf"]
        )
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: [aSecondMore], after: .oneMonth, heldBy: [], now: Self.now
            ) == [Candidate(writingID: "a", relativePath: "big.pdf")]
        )
    }

    @Test func candidatesComeBackInOneOrder() {
        let workspaces = [
            Self.idle("b", days: 200, sources: ["second.pdf", "first.pdf"]),
            Self.idle("a", days: 200, sources: ["only.pdf"]),
        ]
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: workspaces, after: .oneMonth, heldBy: [], now: Self.now
            ) == [
                Candidate(writingID: "a", relativePath: "only.pdf"),
                Candidate(writingID: "b", relativePath: "first.pdf"),
                Candidate(writingID: "b", relativePath: "second.pdf"),
            ],
            """
            One order, so a batch that fails half way through fails the same way \
            twice — and so a reader watching the space come back sees the same \
            work each time rather than a shuffle.
            """
        )
    }

    @Test func aWorkspaceWithNoSourcesContributesNothing() {
        let workspaces = [
            Self.idle("a", days: 400, sources: []),
            Self.idle("b", days: 400, sources: ["big.pdf"]),
        ]
        #expect(
            WorkspaceSourceOffload.offloadable(
                from: workspaces, after: .oneMonth, heldBy: [], now: Self.now
            ) == [Candidate(writingID: "b", relativePath: "big.pdf")],
            "A workspace whose sources have all gone already is simply done, not an error."
        )
    }

    /// The setting is this Mac's own, and has to survive a build that has
    /// never heard of what was saved.
    @Test func anUnknownChoiceReadsAsNever() {
        let defaults = UserDefaults(suiteName: "WorkspaceSourceOffloadTests.unknown")!
        defaults.removePersistentDomain(forName: "WorkspaceSourceOffloadTests.unknown")
        #expect(WorkspaceSourceOffload.After.chosen(in: defaults) == .never)

        defaults.set("everyFortnight", forKey: WorkspaceSourceOffload.After.settingKey)
        #expect(
            WorkspaceSourceOffload.After.chosen(in: defaults) == .never,
            """
            A newer build's choice read by an older one must fall back to the \
            setting that does nothing, not to the first case in the list.
            """
        )

        defaults.set("sixMonths", forKey: WorkspaceSourceOffload.After.settingKey)
        #expect(WorkspaceSourceOffload.After.chosen(in: defaults) == .sixMonths)
        defaults.removePersistentDomain(forName: "WorkspaceSourceOffloadTests.unknown")
    }

    /// Changing the stored spelling orphans every Mac's saved choice, and
    /// adding this key to the synced settings would push one Mac's disk
    /// policy onto another.
    /// A look at the server goes stale, and belongs to one server.
    ///
    /// The pane's Offload has no pass behind it, so it acts on the last
    /// one's look. While sync is on a pass runs every few minutes and the
    /// lifetime is never reached; it bites where it should — sync turned
    /// off, or a Mac that synced once days ago. And a look at one server
    /// answers for no other: Offload would otherwise delete against the old
    /// folder while Download fetched from the new.
    @Test func alookAtTheServerIsOnlyGoodForSoLongAndForOneServer() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = ServerObservation(
            source: "webdav:example", members: ["a"], revisions: ["a": "\"r1\""], at: at
        )
        #expect(observation.answers(for: "webdav:example", now: at))
        #expect(
            !observation.answers(
                for: "webdav:example", now: at.addingTimeInterval(ServerObservation.lifetime)
            ),
            "a quarter of an hour on, it is a memory again rather than a look"
        )
        #expect(
            !observation.answers(for: "folder:/Volumes/Other", now: at),
            "and it never answered for a server it did not look at"
        )
    }

    /// The Context list is a table over two inputs — what the reader did,
    /// and what is on disk — and nothing else. Every row state, enumerated.
    @Test func everyRowComesFromWhatWasDoneAndWhatIsHere() {
        typealias Entry = WorkspaceSourceOffload.DiskEntry
        let rows = WorkspaceSourceOffload.rows(
            onDisk: [
                Entry(name: "here.pdf", isDirectory: false, byteCount: 10),
                Entry(name: "empty", isDirectory: true, byteCount: nil),
                Entry(name: "notes", isDirectory: true, byteCount: nil),
                // An act on a file that is here says nothing: the file is.
                Entry(name: "back again.pdf", isDirectory: false, byteCount: 20),
            ],
            notHere: [
                "away.pdf": .offloaded,
                "coming.pdf": .wanted,
                "notes/inside.pdf": .offloaded,
            ]
        )
        #expect(rows == [
            SourceRow(relativePath: "away.pdf", state: .onTheServer),
            SourceRow(relativePath: "back again.pdf", state: .here, byteCount: 20),
            SourceRow(relativePath: "coming.pdf", state: .comingBack),
            SourceRow(relativePath: "empty", state: .folder(holdsSourcesNotHere: false)),
            SourceRow(relativePath: "here.pdf", state: .here, byteCount: 10),
            SourceRow(relativePath: "notes", state: .folder(holdsSourcesNotHere: true)),
            SourceRow(relativePath: "notes/inside.pdf", state: .onTheServer),
        ])
        #expect(
            rows.filter(\.removesWhatIsNotHere).map(\.relativePath)
                == ["away.pdf", "coming.pdf", "notes", "notes/inside.pdf"],
            """
            Remove asks first exactly where it would delete something with no \
            copy on this Mac — including a folder that looks empty but holds \
            sources only on the server.
            """
        )
    }

    /// A name macOS hands back decomposed is the same source as the ledger's
    /// composed key, not a second row.
    @Test func adecomposedNameIsOneRow() {
        let composed = "Grégoire.pdf"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        // Equal as Swift strings, which compare by canonical equivalence —
        // but not as the bytes a file system or a server path holds.
        #expect(Array(composed.unicodeScalars) != Array(decomposed.unicodeScalars))
        let rows = WorkspaceSourceOffload.rows(
            onDisk: [.init(name: decomposed, isDirectory: false, byteCount: 1)],
            notHere: [composed: .offloaded]
        )
        #expect(rows.count == 1, "drawn once, as itself, not again as “On the server”")
        #expect(rows.first?.state == .here)
    }

    /// One act per path, by construction, and each verb is an assignment.
    @Test func eachSourceHoldsOneActAndEachVerbSetsIt() {
        let key = WorkspaceFileLedger.contextKey("history.pdf")
        var ledger = WorkspaceFileLedger()
        ledger.synced = [key: 7]

        let baseline = ledger.noteOffloaded(key)
        #expect(baseline == 7)
        #expect(ledger.acts[key] == .offloaded)
        #expect(ledger.synced?[key] == nil)

        ledger.noteWanted(key)
        #expect(ledger.acts[key] == .wanted, "asking back replaces the offload; it cannot be both")

        ledger.forgetAct(key, restoring: baseline)
        #expect(ledger.acts[key] == nil)
        #expect(ledger.synced?[key] == 7, "an attempt that did not go through leaves nothing behind")

        ledger.noteWanted(key)
        ledger.recordDeletion(of: key)
        #expect(ledger.acts[key] == nil, "a deleted source is neither on the server nor on its way")

        ledger.noteOffloaded(key)
        ledger.noteChanges(present: [key: 1])
        #expect(ledger.acts[key] == nil, "a file here answers whatever was done to its path")
    }

    /// A folder that has taken an offloaded file's own path holds it.
    ///
    /// Removing the folder deletes that source everywhere, because the
    /// removal counts the path itself; the confirmation has to count it too,
    /// or a click deletes the only copy of a different source unasked.
    @Test func afolderAtAnOffloadedPathAsksBeforeItIsRemoved() {
        let rows = WorkspaceSourceOffload.rows(
            onDisk: [.init(name: "history.pdf", isDirectory: true, byteCount: nil)],
            notHere: ["history.pdf": .offloaded]
        )
        #expect(rows == [SourceRow(relativePath: "history.pdf", state: .folder(holdsSourcesNotHere: true))])
        #expect(rows.first?.removesWhatIsNotHere == true)
    }

    /// What a pass installs arrives here, though the gather never sees it.
    ///
    /// A pass installs sources between the gather's note and the record of
    /// what is now present, so the gather's own stamp never runs for them —
    /// and a source downloaded into a closed, idle writing read as settled,
    /// and the next sweep could take it straight back.
    @Test func asourceApassInstalledArrivesNow() {
        let key = WorkspaceFileLedger.contextKey("downloaded.pdf")
        var ledger = WorkspaceFileLedger()
        ledger.synced = [:]
        ledger.noteWanted(key)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        ledger.recordSynced([key: 1], now: now)

        #expect(ledger.arrivedAt[key] == WorkspaceFileLedger.milliseconds(now))
        #expect(
            ledger.isNewHere(key, now: now, grace: WorkspaceSourceOffload.arrivalGrace),
            "left alone for the grace, like anything else that has just arrived"
        )
        #expect(ledger.acts[key] == nil, "and the ask is answered")
    }

    /// The portable timestamp that settles deletions is not moved by an
    /// arrival here. Another Mac judges a deletion against it, and a download
    /// on this Mac is not a fact about when the source came to be.
    @Test func anArrivalHereLeavesTheSharedTimestampAlone() {
        let key = WorkspaceFileLedger.contextKey("downloaded.pdf")
        var ledger = WorkspaceFileLedger()
        ledger.synced = [:]
        ledger.presentSince[key] = 5
        ledger.recordSynced([key: 1], now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ledger.presentSince[key] == 5)
    }

    /// A link at an offloaded path is not the source being here.
    ///
    /// The withholding already said so; the row did not, and hid Download
    /// while telling the agent the source was local.
    @Test func alinkAtAnOffloadedPathLeavesItOnTheServer() {
        let rows = WorkspaceSourceOffload.rows(
            onDisk: [.init(name: "history.pdf", isDirectory: false, byteCount: 0, isRegularFile: false)],
            notHere: ["history.pdf": .offloaded]
        )
        #expect(rows == [SourceRow(relativePath: "history.pdf", state: .onTheServer)])
    }

    /// A source attached to a workspace that had never synced still gets the
    /// grace. The first pass records what is there and returns, and used to
    /// return before stamping anything.
    @Test func thefirstPassStillStampsArrival() {
        let key = WorkspaceFileLedger.contextKey("attached.pdf")
        var ledger = WorkspaceFileLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.noteChanges(present: [key: 1], now: now)
        #expect(ledger.arrivedAt[key] == WorkspaceFileLedger.milliseconds(now))
        #expect(ledger.presentSince[key] == nil, "the shared timestamp is still not touched")
    }

    @Test func theSettingIsThisMacsOwn() {
        #expect(WorkspaceSourceOffload.After.settingKey == "writing.sources.offloadAfter")
        #expect(
            !LampPortableSettingsCodec.syncedKeys.contains(
                WorkspaceSourceOffload.After.settingKey
            ),
            """
            A desktop with room to spare should not inherit a laptop's policy. \
            The reader's chat retention is per-Mac for the same reason.
            """
        )
    }
}

/// Reading the policy's inputs off a real workspace.
///
/// The clock is the part worth proving against files rather than in the
/// abstract: the obvious answer — the newest modification date in the
/// workspace tree — is wrong in a way that only shows up on disk, because the
/// act of offloading writes into the very tree it reads.
struct WorkspaceSourceOffloadGatheringTests {
    private static let writingID = "personal-devotionals:A1B2C3"

    private struct Fixture {
        let library: URL
        let workspace: URL
        let context: URL
    }

    private static func makeWorkspace() throws -> Fixture {
        let library = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offload-gather-\(UUID().uuidString)", isDirectory: true)
        let folder = LampWritingWorkspaceLayout.directoryName(for: writingID)
        let workspace = library
            .appendingPathComponent("AgentWorkspaces", isDirectory: true)
            .appendingPathComponent("Writing", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(
            at: context, withIntermediateDirectories: true
        )
        return Fixture(library: library, workspace: workspace, context: context)
    }

    private static func write(
        _ text: String, to url: URL, modified: Date
    ) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path
        )
    }

    /// Records `names` as having been here since long ago: synced by an
    /// earlier pass, and present since the epoch.
    private static func settle(_ names: [String], in workspace: URL) async throws {
        var ledger = await WorkspaceFileLedger.load(in: workspace)
        var synced = ledger.synced ?? [:]
        for name in names {
            let key = WorkspaceFileLedger.contextKey(name)
            synced[key] = 0
            ledger.arrivedAt[key] = 0
        }
        ledger.synced = synced
        try await ledger.save(in: workspace)
    }

    /// A workspace holding one recorded source, gathered against a given
    /// listing. `seen` is the revision the pass's listing showed for that
    /// source, or nil for a listing that did not show it at all.
    private static func gathered(
        recorded: String, seen: String?
    ) async throws -> WorkspaceSourceOffload.Workspace {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }
        try write("%PDF", to: fixture.context.appendingPathComponent("big.pdf"), modified: Date())

        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: fixture.workspace.lastPathComponent, relativePath: "big.pdf"
        )
        let source = "webdav:example"
        var records = LampSyncFileRecords()
        records.recordUpload(path, in: source, digest: "d", revision: recorded)
        records.confirmRecorded([path: recorded], in: source)
        try records.save(toLibraryAt: fixture.library)

        // Present for a long time, as the sources the sweep is for are: with
        // no history a source counts as new here, is never a candidate, and
        // every "is not offloaded" below would pass for the wrong reason.
        try await Self.settle(["big.pdf"], in: fixture.workspace)

        let workspaces = await WorkspaceSourceOffload.workspaces(
            inLibraryAt: fixture.library,
            writings: [writingID: Date()],
            observation: ServerObservation(
                source: source,
                members: [path],
                revisions: seen.map { [path: $0] } ?? [:]
            )
        )
        return workspaces[0]
    }

    @Test func theWritingsOwnDateAndItsDocumentsAndItsChatAllCount() async throws {
        let fixture = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }

        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let outlineDate = saved.addingTimeInterval(3_600)

        try Self.write(
            "# Outline", to: fixture.workspace.appendingPathComponent("outline.md"),
            modified: outlineDate
        )

        let fromDocuments = await WorkspaceSourceOffload.lastActivity(
            ofWorkspaceAt: fixture.workspace, writingSaved: saved
        )
        #expect(
            fromDocuments == outlineDate,
            """
            An outline edit does not move the writing's saved date, so the \
            documents have to be read too, or a writing worked on all week \
            through its notes would read as idle.
            """
        )

        let spokenAt = outlineDate.addingTimeInterval(3_600)
        let turn = UUID()
        let said = "What did Irenaeus say about this?"
        let transcript = AgentChatTranscript(
            conversationID: UUID(), sessionID: "s", sessionInstallID: "i",
            messages: [
                AgentChatTranscript.Message(role: .user, text: said, date: spokenAt)
            ],
            events: [
                AgentChatTranscript.Event(
                    turn: turn, date: spokenAt,
                    kind: AgentChatTranscript.Event.said, role: .user, text: said
                )
            ]
        )
        try AgentChatTranscriptStore.save(
            transcript, providerID: "claude", in: fixture.workspace
        )

        let withChat = await WorkspaceSourceOffload.lastActivity(
            ofWorkspaceAt: fixture.workspace, writingSaved: saved
        )
        #expect(
            withChat == spokenAt,
            """
            Research that never touched the draft is still work on this \
            writing, and a message is dated by the reader's act.
            """
        )
    }

    /// The trap the clock is built to avoid.
    @Test func writingTheLedgerDoesNotLookLikeActivity() async throws {
        let fixture = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }

        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        try Self.write(
            "# Outline", to: fixture.workspace.appendingPathComponent("outline.md"),
            modified: saved
        )
        let before = await WorkspaceSourceOffload.lastActivity(
            ofWorkspaceAt: fixture.workspace, writingSaved: saved
        )

        // What an offload does: note it in the ledger, which lands inside the
        // workspace under `.lamp/`.
        var ledger = await WorkspaceFileLedger.load(in: fixture.workspace)
        await ledger.noteOffloaded(WorkspaceFileLedger.contextKey("big.pdf"))
        try await ledger.save(in: fixture.workspace)

        let after = await WorkspaceSourceOffload.lastActivity(
            ofWorkspaceAt: fixture.workspace, writingSaved: saved
        )
        #expect(
            after == before,
            """
            If the clock were the newest modification date in the workspace \
            tree, the offload would refresh the very date that triggered it and \
            the sweep could never run twice. The ledger, the transcripts' own \
            file dates, a sync pass and an opening of the pane all write in \
            here; none of them may read as the reader working.
            """
        )
    }

    @Test func aSourceOnDiskIsFoundAndAnOffloadedOneIsNot() async throws {
        let fixture = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }

        try Self.write(
            "%PDF", to: fixture.context.appendingPathComponent("here.pdf"),
            modified: Date()
        )
        let nested = fixture.context.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Self.write(
            "%PDF", to: nested.appendingPathComponent("deeper.pdf"), modified: Date()
        )

        try Self.write(
            "%PDF", to: fixture.context.appendingPathComponent("a-first.pdf"),
            modified: Date()
        )

        let found = await WorkspaceSourceOffload.contextRelativePaths(in: fixture.workspace)
        #expect(
            found == ["a-first.pdf", "here.pdf", "notes/deeper.pdf"],
            """
            Paths are relative to the context directory, which is what a member \
            path and a ledger key are built from, and nested sources count.
            """
        )

        try FileManager.default.removeItem(
            at: fixture.context.appendingPathComponent("here.pdf")
        )
        let afterOffload = await WorkspaceSourceOffload.contextRelativePaths(
            in: fixture.workspace
        )
        #expect(
            afterOffload == ["a-first.pdf", "notes/deeper.pdf"],
            "An offloaded source has no file, so it is simply not a candidate again."
        )
    }

    /// A record is a memory of one upload; the listing is what the server
    /// says now.
    ///
    /// Nothing ever refreshes `installedRevision`. A source deleted from the
    /// sync folder by hand is not noticed by a pass — `LampSyncFilePlan`
    /// answers `.none` for an unchanged local copy with no listing, and the
    /// absence report covers listed kinds only — so the confirmation stands
    /// for ever while the server has nothing. Offloading on it would delete
    /// the last copy in existence.
    @Test func asourceTheServerNoLongerListsIsNotOffloaded() async throws {
        let fixture = try await Self.gathered(recorded: "\"r1\"", seen: nil)
        #expect(
            fixture.onTheServer.isEmpty,
            "The pass listed the folder and this source was not in it."
        )
    }

    @Test func asourceTheServerHoldsAtAnotherRevisionIsNotOffloaded() async throws {
        let fixture = try await Self.gathered(recorded: "\"r1\"", seen: "\"r2\"")
        #expect(
            fixture.onTheServer.isEmpty,
            """
            Another device wrote over it. The next pass installs that copy, \
            and it may go after; deleting now would lose what has not arrived.
            """
        )
    }

    /// An upload whose bundle update has not confirmed it vouches for
    /// nothing.
    ///
    /// The uploaded digest and the pending revision move together, and the
    /// installed revision stays where it was until the update confirms — so
    /// after a failed update the record's digest names new bytes and its
    /// installed revision names old ones. A listing showing the old revision
    /// would otherwise vouch for bytes the server never confirmed.
    @Test func apendingUploadVouchesForNothing() async throws {
        let fixture = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }
        try Self.write("%PDF", to: fixture.context.appendingPathComponent("big.pdf"), modified: Date())
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: fixture.workspace.lastPathComponent, relativePath: "big.pdf"
        )
        var records = LampSyncFileRecords()
        records.recordUpload(path, in: "webdav:example", digest: "old", revision: "\"r1\"")
        records.confirmRecorded([path: "\"r1\""], in: "webdav:example")
        // The next upload, whose update failed.
        records.recordUpload(path, in: "webdav:example", digest: "new", revision: "\"r2\"")
        try records.save(toLibraryAt: fixture.library)
        try await Self.settle(["big.pdf"], in: fixture.workspace)

        let workspaces = await WorkspaceSourceOffload.workspaces(
            inLibraryAt: fixture.library,
            writings: [Self.writingID: Date()],
            observation: ServerObservation(
                source: "webdav:example", members: [path], revisions: [path: "\"r1\""]
            )
        )
        #expect(workspaces.first?.onTheServer.isEmpty == true)
    }

    @Test func asourceTheListingAgreesWithMayGo() async throws {
        let fixture = try await Self.gathered(recorded: "\"r1\"", seen: "\"r1\"")
        #expect(fixture.onTheServer == ["big.pdf"])
    }

    /// The listing is taken at the gather, before the uploads, so a source
    /// first confirmed during that same pass is not in it and waits one more.
    @Test func asourceConfirmedDuringThatPassWaitsForTheNext() async throws {
        let fixture = try await Self.gathered(recorded: "\"r1\"", seen: nil)
        #expect(
            fixture.sources == ["big.pdf"] && fixture.onTheServer.isEmpty,
            "Still a source, just not yet one this Mac may let go of."
        )
    }

    /// A source that has just arrived is left alone, however it came.
    ///
    /// None of the writing's activity clocks moves when a source is attached
    /// — no draft is saved, nothing is said, no document changes. So a PDF
    /// attached to a six-month-old writing, in preparation for working on
    /// it, was uploaded on the next pass, listed on the one after, and
    /// offloaded by the sweep after that. No review round found it; the
    /// grace moving onto arrival closed it, which is how the rule was known
    /// to be the right one.
    @Test func asourceAttachedToAnOldWritingIsNotTakenStraightBack() async throws {
        let fixture = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }
        try Self.write("%PDF", to: fixture.context.appendingPathComponent("old.pdf"), modified: Date())
        try Self.write("%PDF", to: fixture.context.appendingPathComponent("new.pdf"), modified: Date())

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = await WorkspaceFileLedger.load(in: fixture.workspace)
        ledger.synced = [
            WorkspaceFileLedger.contextKey("old.pdf"): 0,
            WorkspaceFileLedger.contextKey("new.pdf"): 0,
        ]
        ledger.arrivedAt[WorkspaceFileLedger.contextKey("old.pdf")] = 0
        // Attached yesterday.
        ledger.arrivedAt[WorkspaceFileLedger.contextKey("new.pdf")] =
            WorkspaceFileLedger.milliseconds(now.addingTimeInterval(-24 * 60 * 60))
        try await ledger.save(in: fixture.workspace)

        let workspaces = await WorkspaceSourceOffload.workspaces(
            inLibraryAt: fixture.library,
            writings: [Self.writingID: Date(timeIntervalSince1970: 0)],
            observation: ServerObservation(source: "webdav:example", members: [], revisions: [:]),
            now: now
        )
        #expect(
            workspaces.first?.sources == ["old.pdf"],
            "the one here for years is a candidate; the one attached yesterday is not"
        )
    }

    /// A source not yet seen by any pass is new here too: it has landed, and
    /// the gather that would stamp when has not run.
    @Test func asourceNoPassHasRecordedIsNewHere() async throws {
        let ledger = WorkspaceFileLedger()
        #expect(
            ledger.isNewHere(
                WorkspaceFileLedger.contextKey("just landed.pdf"),
                now: Date(), grace: WorkspaceSourceOffload.arrivalGrace
            ),
            """
            Otherwise the sweep straight after the pass that installed a \
            download could take the file that pass had just brought.
            """
        )
    }

    /// The listing is not enough once the server has stopped counting the
    /// source: another device may have removed and reaped it after the
    /// gather looked.
    @Test func asourceTheClosingManifestDropsIsNotOffloaded() async throws {
        let fixture = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }
        try Self.write("%PDF", to: fixture.context.appendingPathComponent("big.pdf"), modified: Date())
        let path = try LampWritingWorkspaceLayout.contextPath(
            folder: fixture.workspace.lastPathComponent, relativePath: "big.pdf"
        )
        var records = LampSyncFileRecords()
        records.recordUpload(path, in: "webdav:example", digest: "d", revision: "\"r1\"")
        records.confirmRecorded([path: "\"r1\""], in: "webdav:example")
        try records.save(toLibraryAt: fixture.library)
        try await Self.settle(["big.pdf"], in: fixture.workspace)

        let workspaces = await WorkspaceSourceOffload.workspaces(
            inLibraryAt: fixture.library,
            writings: [Self.writingID: Date()],
            observation: ServerObservation(
                source: "webdav:example", members: [], revisions: [path: "\"r1\""]
            )
        )
        #expect(workspaces.first?.onTheServer.isEmpty == true)
    }

    @Test func aWorkspaceWhoseWritingIsGoneIsSkipped() async throws {
        let fixture = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.library) }
        try Self.write(
            "%PDF", to: fixture.context.appendingPathComponent("big.pdf"), modified: Date()
        )

        try await Self.settle(["big.pdf"], in: fixture.workspace)
        let known = await WorkspaceSourceOffload.workspaces(
            inLibraryAt: fixture.library,
            writings: [Self.writingID: Date()],
            observation: ServerObservation(source: "webdav:example", members: [], revisions: [:])
        )
        #expect(known.count == 1)
        #expect(known.first?.sources == ["big.pdf"])
        #expect(
            known.first?.onTheServer.isEmpty == true,
            "No record, so nothing is known to be on the server, so nothing may go."
        )

        let orphaned = await WorkspaceSourceOffload.workspaces(
            inLibraryAt: fixture.library,
            writings: ["personal-devotionals:SOMETHING-ELSE": Date()],
            observation: ServerObservation(source: "webdav:example", members: [], revisions: [:])
        )
        #expect(
            orphaned.isEmpty,
            """
            A workspace outlives its writing — deleting a writing leaves the \
            folder — and sweeping an orphan is housekeeping of a different kind.
            """
        )
    }
}
