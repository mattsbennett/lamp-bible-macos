import CryptoKit
import Foundation
import LampCore
import LampModuleKit

/// Preserve the support module's public archive name while the codec lives in core.
public typealias LampSyncArchive = LampModuleKit.LampSyncArchive

/// Copies the user-authored portion of devotional agent workspaces, and
/// presentation decks, into and out of a portable backup. Custom skills are synchronized once as a shared catalog,
/// along with each workspace's enabled-skill selection. Generated instructions,
/// provider configuration, provider skill copies, and the primary draft are
/// deliberately rebuilt from their canonical sources on each Mac.
/// What a sync pass may say about itself in a log anybody can read.
public enum LampSyncDiagnostics {
    /// The folders a set of member paths falls under, for a line that says
    /// where a fault is without naming the reader's own files.
    ///
    /// Only the layout's own folder names are ever said, and a second
    /// component only where the layout fixes it. Everything else is the first
    /// component alone.
    ///
    /// Two reviewer findings, in order. Taking the first two components of
    /// the whole path named the reader's file: a path two deep is a folder
    /// and a filename, so a review at `WritingReview/<id>__<document>.json`
    /// gave up the document's name. Taking two components of the *directory*
    /// part fixed that one and not the next: a book's picture lives at
    /// `BookMedia/<module-id>/…`, and a module id carries words from the
    /// book's title, so a shared diagnostic still said which books the reader
    /// has. The only safe rule is to say nothing a reader or a publisher
    /// named, so the second component is kept for the layout's own folders
    /// and dropped everywhere else.
    public static func folders(named paths: some Sequence<String>) -> String {
        /// The layout's own second components — names the app chose, not the
        /// reader. `Workspaces/` holds several kinds and which one is the
        /// diagnosis, so these are worth telling apart.
        let fixedSecondComponents: Set<String> = [
            "Workspaces/Writing", "Workspaces/Devotionals", "Workspaces/Presentations",
            "Workspaces/Skills", "Workspaces/Conversations",
        ]
        var folders: Set<String> = []
        for path in paths {
            let parts = path.split(separator: "/")
            guard let first = parts.first, parts.count > 1 else {
                folders.insert("(the library's own folder)")
                continue
            }
            let directory = parts.dropLast()
            let twoDeep = directory.prefix(2).joined(separator: "/")
            folders.insert(fixedSecondComponents.contains(twoDeep) ? twoDeep : String(first))
        }
        return folders.sorted().joined(separator: ", ")
    }
}

public enum LampWorkspaceSync {
    public static let portableDirectoryName = LampPortableBackupLayout.workspacesDirectory

    /// The folder a workspace's revision history is published under, beside
    /// the workspace's documents.
    static let revisionsDirectoryName = "Revisions"

    /// Which of the server's revision members this Mac holds the history of
    /// although no file sits at the path.
    ///
    /// `Documentation/decisions/0016`. A revision file is written once and
    /// never edited, and the only thing that removes one is compaction, which
    /// writes every replacement before deleting anything it replaces. So for
    /// this kind — and only this kind — "no file here" means "superseded by a
    /// file that is here", and the history is held. Saying nothing instead
    /// reads as *this Mac does not hold it*, and the plan then downloads the
    /// member, `mergeTree` writes it back, and the compaction on the next
    /// line deletes it again: every pass, for ever.
    ///
    /// The successor cannot be asked instead. A merge unions the *covered*
    /// ids of its two sides, never their own ids, so an intermediate merge is
    /// named by nothing that outlives it, and `mergedID` is a truncated
    /// SHA-256 that cannot be inverted. Measured on a real library, matching
    /// replaced ids claimed 10 of 43 such members; this claims all 43.
    ///
    /// Deliberately not narrowed to paths this Mac can prove it wrote: core
    /// keeps a claim only where its own records name an install at that path
    /// and drops every other (`LampSyncBundlePass`), so a member another Mac
    /// wrote still comes down the first time, is recorded, and is claimable
    /// only once this Mac has compacted it away.
    ///
    /// The one case this gets wrong is a workspace folder restored from a
    /// backup older than some of its revisions: recorded, absent, and claimed
    /// as held, so those do not come back from the server. It is the same
    /// wrong case `mergedIntoTheLibrary` already accepts, and the alternative
    /// is fetching them for ever.
    public static func claimableRevisionMembers(
        among members: some Collection<String>,
        heldAsFiles: Set<String>
    ) -> Set<String> {
        var claimed: Set<String> = []
        for path in members where !heldAsFiles.contains(path) && namesARevision(path) {
            claimed.insert(path)
        }
        return claimed
    }

    /// When each source this library holds appeared here, by published path.
    ///
    /// `LampSyncFilePlan` needs it to tell a *replacement* from the copy a
    /// deletion was of. Without it a source attached after another Mac synced
    /// a deletion at the same path is taken for the deleted copy and removed
    /// — with its stored object pruned, so the replacement is gone for good.
    /// A reviewer found that the moment a source became deletable.
    ///
    /// From the ledger's `presentSince`, which is when this Mac noticed the
    /// file, because a context file's modification time is the shared
    /// object's and may predate its own attachment.
    @WritingWorkspaceFiles
    public static func sourceAttachmentTimes(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> [String: Int64] {
        var times: [String: Int64] = [:]
        for workspace in (try? workspaces(in: libraryRoot, fileManager: fileManager)) ?? [] {
            let ledger = WorkspaceFileLedger.load(in: workspace)
            let folder = workspace.lastPathComponent
            for (key, when) in ledger.presentSince where WorkspaceFileLedger.isContextKey(key) {
                let relative = String(key.dropFirst(WorkspaceFileLedger.contextKey("").count))
                guard let path = try? LampWritingWorkspaceLayout.contextPath(
                    folder: folder, relativePath: relative
                ) else { continue }
                times[path] = max(times[path] ?? .min, when)
            }
            // A source present since before this ledger had a baseline has no
            // stamp of its own: `noteChanges` records the first pass's files
            // and nothing more. Answered as *now* rather than left out —
            // left out, the plan takes a replacement for the copy a deletion
            // was of and removes it, pruning its stored object with it. Now
            // is wrong in the safe direction, which for this codebase is
            // bringing a deleted file back once rather than destroying one.
            //
            // Not written to the ledger. `presentSince` is published inside
            // the workspace, and stamping it here made the published bytes
            // depend on when the pass ran.
            let now = WorkspaceFileLedger.milliseconds(Date())
            for (key, _) in ledger.synced ?? [:] where WorkspaceFileLedger.isContextKey(key) {
                let relative = String(key.dropFirst(WorkspaceFileLedger.contextKey("").count))
                guard let path = try? LampWritingWorkspaceLayout.contextPath(
                    folder: folder, relativePath: relative
                ), times[path] == nil else { continue }
                times[path] = now
            }
        }
        return times
    }

    /// Whether a source is **here**: a regular file at its path under the
    /// workspace's context directory.
    ///
    /// Observed, never stored. A link does not count, as the digest walk
    /// leaves one out (`decisions/0010`); nor does a folder that has taken
    /// the path — counting one would stop withholding a member the gather
    /// has no file for, and the next pass would then try to install the
    /// server's copy over a directory.
    static func isHere(
        _ relativePath: String, inContextOf workspace: URL, fileManager: FileManager = .default
    ) -> Bool {
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        let file = context.appendingPathComponent(relativePath)
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ]) else { return false }
        // And reached without leaving the context directory. A folder on the
        // way replaced by a link to somewhere holding the same name would
        // show a regular file at the leaf, while the gather — which follows
        // no links — has no source there at all: the Download row would go
        // and the lock on the server would lift with nothing restored.
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        // No link anywhere on the way, as the gather follows none
        // (`decisions/0010`). Resolving and comparing prefixes is not the
        // same thing: a folder linked to another folder *inside* the context
        // directory resolves inside it too, and the gather still skips it.
        return reachesWithoutALink(relativePath, under: context)
    }

    /// Whether `relativePath` is reached from `context` through folders, none
    /// of them a link — the context folder itself included. The gather
    /// follows no links (`decisions/0010`), so neither may anything that
    /// decides a source is here or deletes one: resolving and comparing
    /// prefixes lets a folder linked to another folder *inside* the context
    /// directory through, and the gather still skips it.
    static func reachesWithoutALink(_ relativePath: String, under context: URL) -> Bool {
        guard let root = try? context.resourceValues(forKeys: [.isSymbolicLinkKey]),
              root.isSymbolicLink != true
        else { return false }
        var step = context
        for component in relativePath.split(separator: "/").dropLast() {
            step = step.appendingPathComponent(String(component))
            guard let link = try? step.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  link.isSymbolicLink != true
            else { return false }
        }
        return true
    }

    /// Every source this reader has done something to that is not here, with
    /// what was done. The one derivation the withholding, the pane's rows and
    /// the agent's inventory all read, so they cannot disagree.
    @WritingWorkspaceFiles
    public static func sourcesNotHere(
        in workspace: URL, fileManager: FileManager = .default
    ) -> [String: WorkspaceSourceAct] {
        let ledger = WorkspaceFileLedger.load(in: workspace)
        var notHere: [String: WorkspaceSourceAct] = [:]
        for (path, act) in ledger.contextActs()
        where act != .leaving && !isHere(path, inContextOf: workspace, fileManager: fileManager) {
            notHere[path] = WorkspaceSourceAct(act)
        }
        return notHere
    }

    /// Every workspace with sources the reader has asked to go back to the
    /// server, and which.
    @WritingWorkspaceFiles
    public static func requestedOffloads(
        inLibraryAt libraryRoot: URL, fileManager: FileManager = .default
    ) -> [(workspace: URL, paths: [String])] {
        ((try? workspaces(in: libraryRoot, fileManager: fileManager)) ?? []).compactMap { workspace in
            let paths = leavingSourceNames(in: workspace, fileManager: fileManager)
            return paths.isEmpty ? nil : (workspace, paths)
        }
    }

    /// The sources the reader has asked to go back to the server, whose files
    /// are still here.
    @WritingWorkspaceFiles
    public static func leavingSourceNames(
        in workspace: URL, fileManager: FileManager = .default
    ) -> [String] {
        WorkspaceFileLedger.load(in: workspace).contextPaths(withAct: .leaving)
            .filter { isHere($0, inContextOf: workspace, fileManager: fileManager) }
    }

    /// The sources one workspace has let go to the server and does not hold.
    @WritingWorkspaceFiles
    public static func offloadedSourceNames(in workspace: URL) -> [String] {
        sourcesNotHere(in: workspace).filter { $0.value == .offloaded }.keys.sorted()
    }

    /// What came back that was not as it left — another copy, or one whose
    /// quarantine would not take — read and cleared, for the app to say once.
    @WritingWorkspaceFiles
    public static func takeReturnNotices(
        inLibraryAt libraryRoot: URL, fileManager: FileManager = .default
    ) -> (changed: [String], unmarked: [String]) {
        var changed: [String] = []
        var unmarked: [String] = []
        for workspace in (try? workspaces(in: libraryRoot, fileManager: fileManager)) ?? [] {
            guard var ledger = WorkspaceFileLedger.loadIfReadable(in: workspace),
                  !ledger.returnNotices.isEmpty else { continue }
            let prefix = WorkspaceFileLedger.contextKey("")
            for (key, notice) in ledger.returnNotices where key.hasPrefix(prefix) {
                let path = String(key.dropFirst(prefix.count))
                switch notice {
                case .changed: changed.append(path)
                case .unmarked: unmarked.append(path)
                }
            }
            ledger.returnNotices = [:]
            try? ledger.save(in: workspace)
        }
        return (changed.sorted(), unmarked.sorted())
    }

    /// The sources asked back that have not arrived.
    ///
    /// The ask outlives the attempt: a download that failed, or whose server
    /// was briefly unreachable, keeps its row and something to press again.
    @WritingWorkspaceFiles
    public static func awaitedSourceNames(in workspace: URL) -> [String] {
        sourcesNotHere(in: workspace).filter { $0.value == .wanted }.keys.sorted()
    }

    /// Forgets whatever this Mac did to any source the server no longer
    /// counts as a member — offloaded or wanted alike.
    ///
    /// When both Macs have offloaded a source and one removes it, the other
    /// has no local file for the plan to delete, so nothing carries the
    /// deletion out here: the row would go on saying "On the server", or
    /// "Coming back" for something never coming, and a later attachment at
    /// that path could be withheld against a member that no longer exists.
    ///
    /// Judged on the **manifest**, which is what membership means, and never
    /// on a folder listing — a listing that failed is not a deletion
    /// (`decisions/0018`).
    @discardableResult
    @WritingWorkspaceFiles
    public static func forgetActsNoLongerOnTheServer(
        inLibraryAt libraryRoot: URL,
        members: Set<String>,
        fileManager: FileManager = .default
    ) -> [String] {
        // Called only with the manifest of the server the offloads went to
        // (`mayReconcileOffloads`). Not narrowed further by whether a record
        // survives: when another device deletes a source, its record is
        // reaped, and requiring one left the row on the server for ever.
        var forgotten: [String] = []
        for workspace in (try? workspaces(in: libraryRoot, fileManager: fileManager)) ?? [] {
            var ledger = WorkspaceFileLedger.load(in: workspace)
            let acted = ledger.contextActs()
            guard !acted.isEmpty else { continue }
            var changed = false
            // Not a request to leave: that source is here, and may not be on
            // the server yet — forgetting the request would cancel it.
            for path in acted.keys.sorted() where acted[path] != .leaving {
                guard let member = try? LampWritingWorkspaceLayout.contextPath(
                    folder: workspace.lastPathComponent, relativePath: path
                ), !members.contains(member)
                else { continue }
                ledger.forgetAct(WorkspaceFileLedger.contextKey(path))
                forgotten.append(member)
                changed = true
            }
            if changed { try? ledger.save(in: workspace) }
        }
        return forgotten
    }

    /// Every source this Mac has only on the server — let go, or asked back
    /// and not yet arrived — as published member paths.
    ///
    /// While there are any, sync may not be pointed at another server
    /// (owner's decision, 2026-11-25, `decisions/0021`): these exist only on
    /// the server they were offloaded to, so a different one could neither
    /// give them back nor be told to remove them.
    @WritingWorkspaceFiles
    public static func sourcesOnlyOnTheServer(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> [String]? {
        // Nil, not empty, where the workspaces could not be listed: an
        // inventory that could not be read must not lift a lock that guards
        // the only copies.
        guard let all = try? workspaces(in: libraryRoot, fileManager: fileManager) else {
            return nil
        }
        var members: [String] = []
        for workspace in all {
            // Unreadable anywhere is unreadable: see `loadIfReadable`.
            guard WorkspaceFileLedger.loadIfReadable(in: workspace) != nil else { return nil }
            for path in sourcesNotHere(in: workspace, fileManager: fileManager).keys {
                if let member = try? LampWritingWorkspaceLayout.contextPath(
                    folder: workspace.lastPathComponent, relativePath: path
                ) { members.append(member) }
            }
        }
        return members.sorted()
    }

    /// Asks for every source this Mac has let go to the server. The way out
    /// of the lock above: once they have all arrived, sync may go anywhere.
    @discardableResult
    @WritingWorkspaceFiles
    public static func askForEverySourceOnTheServer(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> Int {
        var asked = 0
        for workspace in (try? workspaces(in: libraryRoot, fileManager: fileManager)) ?? [] {
            var ledger = WorkspaceFileLedger.load(in: workspace)
            let offloaded = ledger.contextPaths(withAct: .offloaded)
            guard !offloaded.isEmpty else { continue }
            for path in offloaded {
                ledger.noteWanted(WorkspaceFileLedger.contextKey(path))
                asked += 1
            }
            try? ledger.save(in: workspace)
        }
        return asked
    }

    /// Whether sync may be pointed at `destination` while offloads are held
    /// by `heldBy`: always to nowhere — turning sync off changes no server —
    /// and otherwise only back to that server.
    ///
    /// `heldBy` is the server the offloads were *made against*, written down
    /// when the first one began. It used to be inferred: any server this Mac
    /// had a confirmed record for was taken to hold the source. A record is a
    /// memory of one upload, though, and an old server's copy may since have
    /// been deleted or overwritten — switching back to it on the strength of
    /// that record would have left Download fetching the wrong version or
    /// nothing, while the only current copy sat on the server just left.
    public static func mayPointSync(at destination: String?, heldBy: String?) -> Bool {
        guard let heldBy, let destination else { return true }
        return destination == heldBy
    }

    /// Whether a pass's manifest may settle this Mac's offloads: only one
    /// from the server they were made against. Another server's manifest
    /// never counted them, and forgetting them on its word would make them
    /// vanish while their only copy sat on the server they went to.
    public static func mayReconcileOffloads(
        withManifestOf observed: String, heldBy: String?
    ) -> Bool {
        heldBy == nil || heldBy == observed
    }

    /// Every source this library is withholding, as published member paths:
    /// let go to the server, and no file here.
    ///
    /// Read from each workspace's own ledger rather than inferred from what
    /// is missing. A new Mac has done nothing to any source, so it withholds
    /// nothing and fetches the library's sources as it always did — which is
    /// the regression the first version of this caused, and the fourth time
    /// absence turned out not to be a fact (`decisions/0018`).
    ///
    /// And only while there is no file: one back at the path — a fetch that
    /// landed, something new attached under the name — is this Mac's again,
    /// and withholding it would keep it from the server for ever.
    @WritingWorkspaceFiles
    public static func offloadedSources(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> Set<String> {
        var paths: Set<String> = []
        for workspace in (try? workspaces(in: libraryRoot, fileManager: fileManager)) ?? [] {
            for (path, act) in sourcesNotHere(in: workspace, fileManager: fileManager)
            where act == .offloaded {
                guard let member = try? LampWritingWorkspaceLayout.contextPath(
                    folder: workspace.lastPathComponent, relativePath: path
                ), namesAsource(member) else { continue }
                paths.insert(member)
            }
        }
        return paths
    }

    /// Whether `path` is a published **source**:
    /// `Workspaces/<kind>/<workspace>/Context/<name...>`.
    ///
    /// Only `Context`. A workspace publishes documents, revisions,
    /// conversations and sources, and only the sources are the hundreds of
    /// megabytes a device may reasonably decline to hold. Nested names are
    /// allowed, unlike revisions, because a reader's sources come in folders.
    public static func namesAsource(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // The writing folder is required, as `namesARevision` requires it. A
        // custom skill is published by copying its whole tree under
        // `Workspaces/Skills/<skill>`, so a skill that keeps its own
        // `Context` folder would otherwise be classified as a reader's
        // sources — and a receiving Mac would take the skill while silently
        // leaving out files it needs.
        guard parts.count >= 5, parts[0] == portableDirectoryName,
              parts[1] == WritingFolder.perFile.rawValue,
              parts[3] == "Context",
              !parts[2].isEmpty, !parts[4].isEmpty
        else { return false }
        return true
    }

    /// Whether `path` is a published revision file of a *writing* workspace:
    /// `Workspaces/Writing/<workspace>/Revisions/<name>.json`.
    ///
    /// The writing folder is required, and not merely a folder called
    /// `Revisions` three deep. A custom skill is published by copying its
    /// whole directory with no extension filter at all, so
    /// `Workspaces/Skills/<skill>/Revisions/index.json` is a perfectly
    /// ordinary file of a skill's own — and claiming that as held would stop
    /// sync restoring it. Only `Writing` carries the write-once,
    /// compaction-only history this claim reasons about.
    static func namesARevision(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0] == portableDirectoryName,
              parts[1] == WritingFolder.perFile.rawValue,
              parts[3] == revisionsDirectoryName,
              parts[4].hasSuffix(".json"),
              !parts[2].isEmpty, parts[4].count > ".json".count
        else { return false }
        return true
    }

    /// The revision members this Mac holds the history of although no file
    /// sits at the path.
    ///
    /// `decisions/0017`. Each workspace that has a missing member is asked
    /// for its retired list — the ids its own compaction removed on purpose —
    /// and a member whose id is on that list is claimed. Nothing is decoded:
    /// one small file per workspace, and only for workspaces that have a
    /// missing member at all, so an unchanged library reads nothing.
    ///
    /// This replaced two guesses that stood in for the list and each left a
    /// hole a reviewer found: inferring supersession from *any* local history
    /// existing, which a single new edit in an emptied folder satisfied; and
    /// scanning every untagged merge's replaced ids, which decoded the whole
    /// library's history on every pass while holding the owner the editor
    /// queues behind. A record says *installed here once*; only the deleter
    /// can say *removed here deliberately*.
    /// `members` is a `Collection` on purpose: it is walked twice, once for
    /// the candidates and once to count folded spellings, and a single-pass
    /// sequence would be empty the second time — which would quietly reject
    /// every claim.
    @WritingWorkspaceFiles
    public static func revisionMembersHeldWithoutAFile(
        members: some Collection<String>,
        heldAsFiles: Set<String>,
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> Set<String> {
        let missing = claimableRevisionMembers(among: members, heldAsFiles: heldAsFiles)
        guard !missing.isEmpty else { return [] }

        let root = LampWritingWorkspace.root(
            libraryRootURL: libraryRoot, fileManager: fileManager
        )
        // Two missing members whose names fold alike are left to the pass.
        // A folded match could otherwise claim both on one retirement, and
        // `0013`'s refusal of case-colliding members is checked among the
        // *planned downloads* — which a claim has already taken them out of,
        // so the collision would go unreported and the other member, which
        // may be a revision a demotion needs, would be silently dropped.
        // Folded whole **paths**, and over every member with no file rather
        // than only the revisions among them. Counting basenames made two
        // workspaces' `autosave.json` look like a collision — so both were
        // left unclaimed and fetched for ever, the thing this is here to
        // stop — and missed a real collision with a name this claim filters
        // out before counting.
        var spellings: [String: Int] = [:]
        for path in members where !heldAsFiles.contains(path) {
            spellings[DevotionalAgentRevisionStore.foldedName(path), default: 0] += 1
        }

        var claimable: [String: Set<String>] = [:]
        var claimed: Set<String> = []
        for path in missing {
            guard let identifier = workspaceIdentifier(ofRevisionAt: path),
                  let name = path.split(separator: "/").last
            else { continue }
            let names = claimable[identifier] ?? {
                let workspace = root.appendingPathComponent(identifier, isDirectory: true)
                let answer = DevotionalAgentRevisionStore.claimableRetiredNames(in: workspace)
                claimable[identifier] = answer
                return answer
            }()
            // The published name, folded, against the names compaction wrote
            // down — never an id parsed back out of the name. A revision file
            // is whatever the store called it: it writes
            // `<millis>-<uuid>.json` and accepts `<uuid>.json`, which sync's
            // own tests publish, and `storedRevisions` asks only for the
            // extension. So the only key with the store's own tolerance is
            // the name itself, and a matcher that parsed the convention broke
            // on the convention's second shape (`decisions/0017`).
            guard spellings[DevotionalAgentRevisionStore.foldedName(path)] == 1 else { continue }
            let folded = DevotionalAgentRevisionStore.foldedName(String(name))
            if names.contains(folded) { claimed.insert(path) }
        }
        return claimed
    }

    /// The workspace a published revision belongs to, from its path.
    static func workspaceIdentifier(ofRevisionAt path: String) -> String? {
        guard namesARevision(path) else { return nil }
        return String(path.split(separator: "/", omittingEmptySubsequences: false)[2])
    }

    /// The writing workspaces' folder under `Workspaces/`. A portable backup
    /// and the archive sync keep `Devotionals`, which every backup already
    /// made holds; the per-file sync layout calls it `Writing` since bundle
    /// format 4 (`LampSyncFolderLayout.writingWorkspacesDirectory`).
    public enum WritingFolder: String, Sendable {
        case backup = "Devotionals"
        case perFile = "Writing"
    }
    private static var bundledSkillNames: Set<String> { WorkspaceSkillStore.bundledSkillNames }

    /// The writing workspaces this Mac keeps, each a directory of its own.
    ///
    /// Here rather than at the caller so the path to them is written down
    /// once: `LampSyncLocalWork` reads the same workspaces this exports.
    static func workspaces(
        in libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let root = LampWritingWorkspace.root(libraryRootURL: libraryRoot, fileManager: fileManager)
        // Empty only where the folder is confirmed absent. `fileExists` and a
        // failed resource read both answer "nothing here" for a folder Lamp
        // has lost permission to search — and an inventory of nothing would
        // lift the lock that guards sources only on the server. Anything but
        // "no such file" throws, and every caller that guards the lock reads
        // a throw as unknown.
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw POSIXError(.ENOTDIR)
        }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    /// Run legacy workspace migration during the local pull transaction so
    /// exporting the prepared library does not change the live workspace.
    /// Migrates and compacts a library's workspaces before they are published.
    ///
    /// On the owner: the import below calls this with the live library root,
    /// and `migrateAllWorkspaces` rewrites every workspace's skills there.
    @WritingWorkspaceFiles
    public static func prepareLibraryForSync(
        at libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        try WorkspaceSkillStore.migrateAllWorkspaces(
            in: libraryRoot,
            fileManager: fileManager
        )
        // Compacted here, inside the staged transaction, so what gets published
        // is the merged history rather than every autosave since the last sync.
        for workspace in try childDirectoriesIfPresent(
            of: LampWritingWorkspace.root(libraryRootURL: libraryRoot, fileManager: fileManager),
            fileManager: fileManager
        ) {
            try DevotionalAgentRevisionStore.compact(in: workspace)
        }
    }

    /// Writes a portable copy of every workspace for a sync pass to publish.
    ///
    /// On the owner because it reads the live library: a workspace read while
    /// a pane was part-way through rewriting its skills or context would be
    /// published half-written.
    /// `record`, where one is given, is filled with what the export would
    /// have placed and the files are left where they are — see
    /// `WorkspaceExportRecord`. The side effects are unchanged either way:
    /// each workspace's file ledger is still saved and its document
    /// deletions still recorded, which is why this runs on every pass rather
    /// than being replaced by path arithmetic in the caller.
    @WritingWorkspaceFiles
    public static func exportPortableWorkspaces(
        from libraryRoot: URL,
        to backupRoot: URL,
        writingFolder: WritingFolder = .backup,
        installID: String = LampInstallIdentity.current(),
        recording record: WorkspaceExportRecord? = nil,
        fileManager: FileManager = .default
    ) throws {
        // A record and a backup are different jobs and cannot be done at
        // once: a backup must hold every byte in its own layout, while a
        // record deliberately leaves most files where they are, and the
        // decks a backup carries are copied without being recorded. Asking
        // for both would quietly give neither.
        precondition(
            record == nil || writingFolder == .perFile,
            "a workspace export records what it would place only for a per-file pass"
        )
        let portableRoot = backupRoot
            .appendingPathComponent(portableDirectoryName, isDirectory: true)
        let catalogRoot = WorkspaceSkillStore.catalogDirectory(in: libraryRoot)
        for skill in try childDirectoriesIfPresent(of: catalogRoot, fileManager: fileManager)
        where WorkspaceSkillStore.isValidSkillName(skill.lastPathComponent)
            && !bundledSkillNames.contains(skill.lastPathComponent.lowercased()) {
            try copyTree(
                from: skill,
                to: portableRoot
                    .appendingPathComponent("Skills", isDirectory: true)
                    .appendingPathComponent(skill.lastPathComponent, isDirectory: true),
                recordingUnder: backupRoot,
                into: record,
                staging: true,
                fileManager: fileManager
            )
        }

        // Only for a backup, which carries the decks inside it. The per-file
        // pass gathers decks and their images from the library itself and
        // `LampSyncLocalFiles.workspaceFiles` skips whatever this staged, so
        // exporting them here copied every deck and every deck image into a
        // scratch directory, on every pass, to be ignored.
        if writingFolder == .backup {
            try LampPresentationDeckSync.exportDecks(
                from: libraryRoot, to: backupRoot, fileManager: fileManager
            )
        }

        let sourceRoot = LampWritingWorkspace.root(libraryRootURL: libraryRoot, fileManager: fileManager)
        guard fileManager.fileExists(atPath: sourceRoot.path) else { return }

        let destinationRoot = appending([portableDirectoryName, writingFolder.rawValue], to: backupRoot)
        for workspace in try childDirectories(of: sourceRoot, fileManager: fileManager) {
            let portableWorkspace = destinationRoot
                .appendingPathComponent(workspace.lastPathComponent, isDirectory: true)

            for document in try childFiles(of: workspace, fileManager: fileManager)
            where isPortableDocument(document) {
                // Copied even when the rest is recorded, and the *copy* is
                // what goes into the record: see
                // `snapshotsWhatCanChangeUnderAPass`. A document's digest is
                // the agreedDigest a later pass judges "edited here since"
                // by, so what was hashed has to be what was sent, whatever a
                // pane or an agent writes meanwhile.
                try copyPreservingModificationDate(
                    from: document,
                    to: portableWorkspace
                        .appendingPathComponent("Documents", isDirectory: true)
                        .appendingPathComponent(document.lastPathComponent),
                    recordingUnder: backupRoot,
                    into: record,
                    staging: true,
                    fileManager: fileManager
                )
            }

            try copyTree(
                from: workspace.appendingPathComponent("context", isDirectory: true),
                to: portableWorkspace.appendingPathComponent("Context", isDirectory: true),
                recordingUnder: backupRoot,
                into: record,
                fileManager: fileManager
            )

            // Staged, not recorded: a pane rewrites this the moment somebody
            // ticks a skill. `isPlainFile` rather than `fileExists`, which
            // follows a link: recording a symlink's own path would have a
            // pass read, hash and publish whatever it pointed at, where
            // copying one left the scratch enumeration to skip it.
            // `childFiles` and `copyTree` exclude links already; this was the
            // one path reached without them.
            let selection = WorkspaceSkillStore.selectionURL(in: workspace)
            if isPlainFile(selection) {
                try copyPreservingModificationDate(
                    from: selection,
                    to: portableWorkspace.appendingPathComponent("EnabledSkills.json"),
                    recordingUnder: backupRoot,
                    into: record,
                    staging: true,
                    fileManager: fileManager
                )
            }

            try copyTree(
                from: workspace
                    .appendingPathComponent(".lamp", isDirectory: true)
                    .appendingPathComponent("revisions", isDirectory: true),
                to: portableWorkspace.appendingPathComponent("Revisions", isDirectory: true),
                allowedExtensions: ["json"],
                recordingUnder: backupRoot,
                into: record,
                fileManager: fileManager
            )

            // Written rather than placed: a transcript is re-encoded on the
            // way out, so there is no live file that holds those bytes. It
            // goes into the staging directory either way, and is recorded
            // from there.
            try exportConversations(
                from: workspace,
                to: portableWorkspace.appendingPathComponent(
                    conversationsDirectoryName,
                    isDirectory: true
                ),
                installID: installID,
                recordingUnder: backupRoot,
                into: record,
                fileManager: fileManager
            )

            // A ledger that is there and will not read is left exactly as it
            // is: it may hold the last offload, and the lock on where sync
            // points reads it as unknown and holds. This pass works from a
            // fresh one in memory — the worst that does is fetch an offloaded
            // source back, which loses nothing.
            let readable = WorkspaceFileLedger.loadIfReadable(in: workspace)
            var fileLedger = readable ?? WorkspaceFileLedger()
            // A source that came back and was never checked — an import that
            // failed after writing it — is checked here, before the gather
            // answers its act.
            fileLedger.checkReturns(inContextOf: workspace, sayChanged: false)
            let deleted = fileLedger.noteChanges(present: try workspaceFiles(in: workspace, fileManager: fileManager)
                .mapValues(\.modified))
            try recordDocumentDeletions(deleted, inWorkspace: workspace, libraryRoot: libraryRoot, fileManager: fileManager)
            if readable != nil { try fileLedger.save(in: workspace) }
            if !fileLedger.isEmpty {
                // Possibly all that's left of the workspace to send. Written,
                // not placed: these bytes exist nowhere else.
                let published = Self.path(
                    of: portableWorkspace
                        .appendingPathComponent(WorkspaceFileLedger.portableFilename),
                    under: backupRoot
                )
                // Staged by its published path's digest where a record is
                // being kept, as a transcript is: two workspace folder names
                // differing only in case are two published paths and one
                // file on a case-insensitive scratch volume, so the second
                // workspace's deletions would go up under both names.
                let ledgerFile = if let record, let published {
                    Self.stagedURL(for: published, under: backupRoot)
                } else {
                    portableWorkspace
                        .appendingPathComponent(WorkspaceFileLedger.portableFilename)
                }
                try fileManager.createDirectory(
                    at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileLedger.portable.write(to: ledgerFile)
                if let record, let published { record.place(ledgerFile, at: published) }
            }
        }
    }

    /// Takes a synced copy of every workspace into the live library.
    ///
    /// On `WritingWorkspaceFiles` because `libraryRoot` here is the library
    /// itself, not a staged copy: this merges each workspace's documents and
    /// context, consolidates and removes context files, and rewrites the
    /// skills selection — the same files a pane's writes and a preparation
    /// rewrite whole. A pane preparing while a pass lands simply waits for it,
    /// which is file work either way.
    @WritingWorkspaceFiles
    public static func importPortableWorkspaces(
        from backupRoot: URL,
        into libraryRoot: URL,
        writingFolder: WritingFolder = .backup,
        fileManager: FileManager = .default
    ) throws {
        // Preserve and catalog any pre-centralization local skills before
        // applying an incoming workspace selection.
        try prepareLibraryForSync(at: libraryRoot, fileManager: fileManager)

        let portableRoot = backupRoot
            .appendingPathComponent(portableDirectoryName, isDirectory: true)
        let portableCatalog = portableRoot.appendingPathComponent("Skills", isDirectory: true)
        for skill in try childDirectoriesIfPresent(of: portableCatalog, fileManager: fileManager)
        where WorkspaceSkillStore.isValidSkillName(skill.lastPathComponent)
            && !bundledSkillNames.contains(skill.lastPathComponent.lowercased()) {
            try mergeTree(
                from: skill,
                to: WorkspaceSkillStore.catalogDirectory(in: libraryRoot)
                    .appendingPathComponent(skill.lastPathComponent, isDirectory: true),
                fileManager: fileManager
            )
        }

        try LampPresentationDeckSync.importDecks(from: backupRoot, into: libraryRoot, fileManager: fileManager)

        let sourceRoot = appending([portableDirectoryName, writingFolder.rawValue], to: backupRoot)
        guard fileManager.fileExists(atPath: sourceRoot.path) else { return }

        let destinationRoot = LampWritingWorkspace.root(libraryRootURL: libraryRoot, fileManager: fileManager)
        for portableWorkspace in try childDirectories(of: sourceRoot, fileManager: fileManager) {
            let workspace = destinationRoot
                .appendingPathComponent(portableWorkspace.lastPathComponent, isDirectory: true)

            // Deletions made here since the last sync are noted before anything
            // arrives, or the incoming copies would simply put the files back.
            // An unreadable ledger is left as it is; see the export.
            let readableLedger = WorkspaceFileLedger.loadIfReadable(in: workspace)
            var fileLedger = readableLedger ?? WorkspaceFileLedger()
            fileLedger.checkReturns(inContextOf: workspace, sayChanged: false)
            let deleted = fileLedger.noteChanges(present: try workspaceFiles(in: workspace, fileManager: fileManager)
                .mapValues(\.modified))
            try recordDocumentDeletions(deleted, inWorkspace: workspace, libraryRoot: libraryRoot, fileManager: fileManager)
            fileLedger.merge(WorkspaceFileLedger.portable(
                in: portableWorkspace.appendingPathComponent(WorkspaceFileLedger.portableFilename)
            ))

            let documents = portableWorkspace.appendingPathComponent("Documents", isDirectory: true)
            for document in try childFilesIfPresent(of: documents, fileManager: fileManager)
            where isPortableDocument(document) {
                let key = WorkspaceFileLedger.documentKey(document.lastPathComponent)
                if fileLedger.isDeleted(key, modified: modificationTime(of: document)) { continue }
                try mergeFile(
                    from: document,
                    to: workspace.appendingPathComponent(document.lastPathComponent),
                    fileManager: fileManager
                )
            }

            try mergeTree(
                from: portableWorkspace.appendingPathComponent("Context", isDirectory: true),
                to: workspace.appendingPathComponent("context", isDirectory: true),
                skipping: { path, modified in
                    fileLedger.isDeleted(WorkspaceFileLedger.contextKey(path), modified: modified)
                },
                fileManager: fileManager
            )
            try WorkspaceContextFileStore.consolidate(
                in: workspace,
                libraryRootURL: libraryRoot,
                fileManager: fileManager
            )
            // Deleted elsewhere since this Mac's copy was saved. In a sync, a
            // document's deletion is the manifest's, carried out through
            // `LampWritingDocumentStore`, which keeps an edit made here; the
            // ledger judges by dates, and a slow clock dates a later edit
            // before the deletion it would then lose to.
            for (key, file) in try workspaceFiles(in: workspace, fileManager: fileManager)
            where fileLedger.isDeleted(key, modified: file.modified) {
                if writingFolder == .perFile, !WorkspaceFileLedger.isContextKey(key) { continue }
                if WorkspaceFileLedger.isContextKey(key) {
                    try WorkspaceContextFileStore.removeSyncedContextFile(
                        at: file.url, libraryRootURL: libraryRoot, fileManager: fileManager
                    )
                } else {
                    try fileManager.removeItem(at: file.url)
                }
            }
            fileLedger.recordSynced(try workspaceFiles(in: workspace, fileManager: fileManager)
                .mapValues(\.modified))
            // A source that has come back is checked against what left.
            fileLedger.checkReturns(inContextOf: workspace, sayChanged: true)
            if readableLedger != nil { try fileLedger.save(in: workspace) }

            let portableSelection = portableWorkspace.appendingPathComponent("EnabledSkills.json")
            let hasPortableSelection = fileManager.fileExists(atPath: portableSelection.path)
            if hasPortableSelection {
                try mergeFile(
                    from: portableSelection,
                    to: WorkspaceSkillStore.selectionURL(in: workspace),
                    fileManager: fileManager
                )
            } else {
                // Backward compatibility: older backups stored complete custom
                // skill folders under every workspace instead of a shared catalog.
                let portableSkills = portableWorkspace.appendingPathComponent(
                    "Skills",
                    isDirectory: true
                )
                var enabled = try WorkspaceSkillStore.enabledSkillNames(
                    in: workspace,
                    libraryRootURL: libraryRoot,
                    fileManager: fileManager
                )
                for skill in try childDirectoriesIfPresent(
                    of: portableSkills,
                    fileManager: fileManager
                ) where WorkspaceSkillStore.isValidSkillName(skill.lastPathComponent)
                    && !bundledSkillNames.contains(skill.lastPathComponent.lowercased()) {
                    enabled.insert(try WorkspaceSkillStore.importLegacySkill(
                        from: skill,
                        libraryRootURL: libraryRoot,
                        fileManager: fileManager
                    ))
                }
                if !enabled.isEmpty {
                    try WorkspaceSkillStore.applySelectionData(
                        JSONEncoder().encode(WorkspaceSkillSelection(names: enabled)),
                        to: workspace,
                        libraryRootURL: libraryRoot,
                        fileManager: fileManager
                    )
                }
            }

            try WorkspaceSkillStore.synchronizeWorkspace(
                workspace,
                libraryRootURL: libraryRoot,
                fileManager: fileManager
            )

            try mergeTree(
                from: portableWorkspace.appendingPathComponent("Revisions", isDirectory: true),
                to: workspace
                    .appendingPathComponent(".lamp", isDirectory: true)
                    .appendingPathComponent("revisions", isDirectory: true),
                allowedExtensions: ["json"],
                fileManager: fileManager
            )
            // The union merge above brings back any original that another Mac
            // still holds, even after it was compacted away here. Compacting the
            // merged set recognises those against the revisions that replaced them.
            //
            // The server is such a holder too, and the one that never lets go:
            // nothing compacts it and no tombstone covers a revision, so every
            // revision ever uploaded is still listed there. That is why the
            // gather claims the ones it has compacted away — otherwise each of
            // them arrives here, is written, and is deleted again on the line
            // below, on every pass, for ever
            // (`lamp-bible-core/Documentation/decisions/0016`).
            try DevotionalAgentRevisionStore.compact(in: workspace)

            try importConversations(
                from: portableWorkspace.appendingPathComponent(
                    conversationsDirectoryName,
                    isDirectory: true
                ),
                into: workspace,
                fileManager: fileManager
            )
        }
    }

    /// Chat transcripts travel; the providers' own session stores do not. A
    /// transcript is enough to read a conversation on another Mac and to carry it
    /// on from a recap, at a few kilobytes rather than the providers' private,
    /// version-specific files.
    private static let conversationsDirectoryName = "Conversations"

    private static func exportConversations(
        from workspace: URL,
        to destination: URL,
        installID: String,
        recordingUnder root: URL? = nil,
        into record: WorkspaceExportRecord? = nil,
        fileManager: FileManager
    ) throws {
        let source = AgentChatTranscriptStore.directory(in: workspace)
        guard fileManager.fileExists(atPath: source.path) else { return }
        for url in try childFiles(of: source, fileManager: fileManager)
        where AgentChatTranscriptStore.isTranscriptFilename(url.lastPathComponent) {
            // An unreadable transcript stays where it is rather than spreading.
            guard let transcript = try? AgentChatTranscriptStore.decode(Data(contentsOf: url))
            else { continue }
            let published = Self.path(
                of: destination.appendingPathComponent(url.lastPathComponent), under: root ?? destination
            )
            // Written where the record can tell two published paths apart,
            // for the same reason a document is staged there: two transcript
            // names differing only in case are two published paths and one
            // file on a case-insensitive scratch volume, so the second would
            // go up under both names.
            let target = if let record, let root, let published {
                Self.stagedURL(for: published, under: root)
            } else {
                destination.appendingPathComponent(url.lastPathComponent)
            }
            try ensureSafeDestination(target, fileManager: fileManager)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Stamped on the way out, so the other Mac can tell the session is
            // this one's even if the transcript predates ownership being recorded.
            try AgentChatTranscriptStore
                .encode(transcript.attributingSession(toInstall: installID))
                .write(to: target, options: .atomic)
            if let record, let published { record.place(target, at: published) }
        }
    }

    private static func importConversations(
        from source: URL,
        into workspace: URL,
        fileManager: FileManager
    ) throws {
        for incomingURL in try childFilesIfPresent(of: source, fileManager: fileManager)
        where AgentChatTranscriptStore.isTranscriptFilename(incomingURL.lastPathComponent) {
            guard let incoming = try? AgentChatTranscriptStore.decode(Data(contentsOf: incomingURL))
            else { continue }
            let localURL = AgentChatTranscriptStore.directory(in: workspace)
                .appendingPathComponent(incomingURL.lastPathComponent)

            let merged: AgentChatTranscript
            if fileManager.fileExists(atPath: localURL.path) {
                let values = try localURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LampSyncError.unsafeArchivePath
                }
                // Last-writer-wins by modification date would drop whichever side
                // chatted less recently, so the two copies are reconciled instead.
                if let local = try? AgentChatTranscriptStore.decode(Data(contentsOf: localURL)) {
                    merged = AgentChatTranscriptMerge.merge(local: local, incoming: incoming)
                    guard merged != local else { continue }
                } else {
                    merged = incoming
                }
            } else {
                merged = incoming
            }

            try ensureSafeDestination(localURL, fileManager: fileManager)
            try fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AgentChatTranscriptStore.encode(merged).write(to: localURL, options: .atomic)
        }
    }

    /// Writes down the documents the ledger has just found gone from a
    /// workspace, for the next pass to tombstone (`LampSyncRemovedModules`),
    /// so the phone and other Macs delete theirs. A document is deleted
    /// everywhere by the manifest, as a deck is; the ledger's own record
    /// goes on serving the workspace's other files. Recorded once, as the
    /// deletion is first noticed, and dated then.
    static func recordDocumentDeletions(
        _ keys: [String], inWorkspace workspace: URL, libraryRoot: URL, fileManager: FileManager
    ) throws {
        let prefix = WorkspaceFileLedger.documentKey("")
        let paths = keys.compactMap { key -> String? in
            guard key.hasPrefix(prefix) else { return nil }
            let name = String(key.dropFirst(prefix.count))
            // Never one still there, however its name is spelled.
            guard !fileManager.fileExists(atPath: workspace.appendingPathComponent(name).path) else { return nil }
            return try? LampWritingWorkspaceLayout.documentPath(folder: workspace.lastPathComponent, name: name)
        }
        guard !paths.isEmpty else { return }
        var removed = LampSyncRemovedModules.load(fromLibraryAt: libraryRoot, fileManager: fileManager)
        let now = WorkspaceFileLedger.milliseconds(Date())
        for path in paths { removed.record(path, at: now) }
        try removed.save(toLibraryAt: libraryRoot, fileManager: fileManager)
    }

    /// Core's rule, which the phone keeps to as well.
    private static func isPortableDocument(_ url: URL) -> Bool {
        LampWritingWorkspaceLayout.isDocumentName(url.lastPathComponent)
    }

    private static func appending(_ components: [String], to root: URL) -> URL {
        components.reduce(root) { result, component in
            result.appendingPathComponent(component, isDirectory: true)
        }
    }

    private static func childDirectories(
        of directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard isSafeDirectory(directory) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private static func childDirectoriesIfPresent(
        of directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try childDirectories(of: directory, fileManager: fileManager)
    }

    private static func childFiles(
        of directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard isSafeDirectory(directory) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private static func childFilesIfPresent(
        of directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try childFiles(of: directory, fileManager: fileManager)
    }

    private static func copyTree(
        from source: URL,
        to destination: URL,
        allowedExtensions: Set<String>? = nil,
        recordingUnder root: URL? = nil,
        into record: WorkspaceExportRecord? = nil,
        staging: Bool = false,
        fileManager: FileManager
    ) throws {
        guard isSafeDirectory(source),
              let enumerator = fileManager.enumerator(
                at: source,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
              ) else { return }
        let prefix = source.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            if let allowedExtensions,
               !allowedExtensions.contains(url.pathExtension.lowercased()) { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw LampSyncError.unsafeArchivePath }
            try copyPreservingModificationDate(
                from: url,
                to: destination.appendingPathComponent(String(path.dropFirst(prefix.count))),
                recordingUnder: root,
                into: record,
                staging: staging,
                fileManager: fileManager
            )
        }
    }

    private static func mergeTree(
        from source: URL,
        to destination: URL,
        allowedExtensions: Set<String>? = nil,
        skipping shouldSkip: ((_ relativePath: String, _ modified: Int64) -> Bool)? = nil,
        fileManager: FileManager
    ) throws {
        guard isSafeDirectory(source),
              let enumerator = fileManager.enumerator(
                at: source,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
              ) else { return }
        let prefix = source.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            if let allowedExtensions,
               !allowedExtensions.contains(url.pathExtension.lowercased()) { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw LampSyncError.unsafeArchivePath }
            let relativePath = String(path.dropFirst(prefix.count))
            if let shouldSkip, shouldSkip(relativePath, modificationTime(of: url)) { continue }
            try mergeFile(
                from: url,
                to: destination.appendingPathComponent(relativePath),
                fileManager: fileManager
            )
        }
    }

    /// What an export placed, and where it came from, for a caller that
    /// wants the paths rather than a second copy of the files.
    ///
    /// A pass stages a workspace so the exporter — the one place that knows
    /// what each published path is — decides the paths, and then enumerates
    /// what it wrote. Copying the files to do that was 2.9 s at two hundred
    /// and fifty workspaces, which with the per-pass compile cached and the
    /// hashing identity-keyed made it the largest thing a pass does. The cost
    /// is **per file, not per byte**: `copyItem` on APFS clones, so hard
    /// linking instead measured *slower* (4.8 s — tried and reverted), and
    /// what is left is five or so syscalls a file, fifteen thousand times.
    ///
    /// So a pass records instead: the path mapping stays exactly where it
    /// was, and nothing is copied for the kinds whose live file is what
    /// would be published anyway. What a writer can rewrite mid-pass is
    /// still copied — see `snapshotsWhatCanChangeUnderAPass`.
    public final class WorkspaceExportRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [(path: String, url: URL, isFixedAtItsPath: Bool)] = []
        /// Where each path sits in `files`, so placing a path a second time
        /// replaces the first without a scan. A linear `removeAll` here cost
        /// more than the copying this record was written to remove: at two
        /// hundred and fifty workspaces it is fifteen thousand files, and the
        /// gather measured 7.1 s of string comparisons against 2.9 s of
        /// actual copies.
        private var placements: [String: Int] = [:]

        public init() {}

        /// - Parameter isFixedAtItsPath: whether nothing rewrites this file
        ///   where it sits. True for a file recorded in place whose bytes
        ///   only ever change by the file being replaced — a revision, a
        ///   context object. False for anything staged into the scratch
        ///   directory, which has a new path every pass, and false for a
        ///   file this export wrote there itself. Carried to
        ///   `LampSyncLocalFiles.Candidate`, where it decides whether a
        ///   digest may be kept against the file's identity
        ///   (`lamp-bible-core/Documentation/decisions/0011`).
        func place(_ source: URL, at path: String, isFixedAtItsPath: Bool = false) {
            lock.lock()
            defer { lock.unlock() }
            if let placement = placements[path] {
                files[placement] = (path, source, isFixedAtItsPath)
                return
            }
            placements[path] = files.count
            files.append((path, source, isFixedAtItsPath))
        }

        /// Everything the export placed, by its path within the backup root.
        public var placed: [(path: String, url: URL, isFixedAtItsPath: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return files
        }
    }

    /// Whether a file is one this may record or one it must snapshot.
    ///
    /// A recorded path is read again later, at the gather and at the upload,
    /// so recording the live file is only sound where nothing rewrites the
    /// file at that path in between.
    ///
    /// The upload no longer trusts the gather's digest — it takes its own
    /// copy and hashes that (`lamp-bible-core/Documentation/decisions/0009`),
    /// which is what makes a *recorded* path safe at all. What that does not
    /// buy is a path whose file is rewritten under the reader between the two:
    /// the digest the plan was made from would describe bytes nobody holds,
    /// and the pass would publish a file the plan never saw.
    ///
    /// Recorded, because the path's bytes are fixed: a revision (written once
    /// under a timestamped name) and a context file (content-addressed and
    /// read-only).
    ///
    /// Snapshotted, because a writer can rewrite them mid-pass: a document
    /// (a pane, an agent or a command-line tool), a custom skill
    /// (`WorkspaceSkillStore.saveSkill`) and the enabled-skills selection
    /// (`WorkspaceSkillStore.writeSelection`, on every tick of a checkbox).
    /// Those are five or six
    /// files a workspace against fifty-odd revisions, so the copy costs
    /// almost nothing and buys the whole question away.
    ///
    /// Transcripts and the portable ledger are produced into the scratch
    /// directory in any case: there is no live file holding those bytes.
    private static let snapshotsWhatCanChangeUnderAPass = true

    /// A real file, not a link to one and not a directory.
    private static func isPlainFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    /// Places a file: copied, or recorded where a record is being kept.
    ///
    /// `staging` copies it even then, and records the copy — for a file that
    /// can be rewritten at its path while the pass runs. See
    /// `snapshotsWhatCanChangeUnderAPass`.
    private static func copyPreservingModificationDate(
        from source: URL,
        to destination: URL,
        recordingUnder root: URL? = nil,
        into record: WorkspaceExportRecord? = nil,
        staging: Bool = false,
        fileManager: FileManager
    ) throws {
        guard let record, let root, let path = Self.path(of: destination, under: root) else {
            try copyPreservingModificationDate(
                from: source, to: destination, fileManager: fileManager
            )
            return
        }
        if !staging {
            record.place(source, at: path, isFixedAtItsPath: true)
            return
        }
        // Staged under the published path's own digest rather than at the
        // destination, because two published paths can want the same file
        // there. A library on a case-sensitive volume can hold both
        // `Outline.md` and `outline.md`; the scratch directory is on the
        // system volume, which is case-insensitive, so the second copy
        // replaces the first and both paths would be published with the
        // second one's bytes. Caught by a Codex review. Nothing reads this
        // tree by name any more — the record carries the mapping — so the
        // name only has to be unique per published path.
        let staged = Self.stagedURL(for: path, under: root)
        try copyPreservingModificationDate(
            from: source, to: staged, fileManager: fileManager
        )
        record.place(staged, at: path)
    }

    /// Where a staged copy of `path` goes: one directory per published path,
    /// named by its digest, so no two published paths share a file.
    static func stagedURL(for path: String, under root: URL) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(20)
        return root
            .appendingPathComponent(stagedDirectoryName, isDirectory: true)
            .appendingPathComponent(String(digest), isDirectory: true)
            .appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// Holds the staged copies of files a pass publishes from a snapshot.
    /// Hidden, so a tree walk that skips hidden files does not meet it.
    private static let stagedDirectoryName = ".staged"

    /// Where `destination` sits inside `root`, or nil if it does not.
    private static func path(of destination: URL, under root: URL) -> String? {
        let prefix = root.standardizedFileURL.path + "/"
        let path = destination.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func copyPreservingModificationDate(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let modifiedAt = LampFileModification.date(of: source)
        try ensureSafeDestination(destination, fileManager: fileManager)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        if let modifiedAt {
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destination.path)
        }
    }

    private static func mergeFile(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let sourceValues = try source.resourceValues(forKeys: [
            .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else { return }
        let sourceData = try Data(contentsOf: source)

        if fileManager.fileExists(atPath: destination.path) {
            let destinationValues = try destination.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true else {
                throw LampSyncError.unsafeArchivePath
            }
            let destinationData = try Data(contentsOf: destination)
            guard shouldReplace(
                destinationData: destinationData,
                destinationDate: destinationValues.contentModificationDate,
                with: sourceData,
                sourceDate: sourceValues.contentModificationDate
            ) else { return }
        }

        try ensureSafeDestination(destination, fileManager: fileManager)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sourceData.write(to: destination, options: .atomic)
        if let modifiedAt = sourceValues.contentModificationDate {
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destination.path)
        }
    }

    private static func shouldReplace(
        destinationData: Data,
        destinationDate: Date?,
        with sourceData: Data,
        sourceDate: Date?
    ) -> Bool {
        LampSyncMerge.shouldReplaceFile(
            currentData: destinationData,
            currentDate: destinationDate,
            incomingData: sourceData,
            incomingDate: sourceDate
        )
    }

    private static func ensureSafeDestination(
        _ destination: URL,
        fileManager: FileManager
    ) throws {
        var parent = destination.deletingLastPathComponent()
        while parent.path != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
                let values = try parent.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true, isDirectory.boolValue else {
                    throw LampSyncError.unsafeArchivePath
                }
                return
            }
            parent.deleteLastPathComponent()
        }
    }

    private static func modificationTime(of url: URL) -> Int64 {
        WorkspaceFileLedger.milliseconds(LampFileModification.date(of: url) ?? .distantPast)
    }

    /// The workspace's own files that sync carries: top-level documents and
    /// everything in `context`, keyed as `WorkspaceFileLedger` keys them.
    static func workspaceFiles(
        in workspace: URL,
        fileManager: FileManager
    ) throws -> [String: (url: URL, modified: Int64)] {
        var files: [String: (url: URL, modified: Int64)] = [:]
        for document in try childFilesIfPresent(of: workspace, fileManager: fileManager)
        where isPortableDocument(document) {
            files[WorkspaceFileLedger.documentKey(document.lastPathComponent)] =
                (document, modificationTime(of: document))
        }
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        guard isSafeDirectory(context),
              let enumerator = fileManager.enumerator(
                at: context,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return files }
        let prefix = context.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard values.isRegularFile == true, path.hasPrefix(prefix) else { continue }
            files[WorkspaceFileLedger.contextKey(String(path.dropFirst(prefix.count)))] =
                (url, modificationTime(of: url))
        }
        return files
    }

    private static func isSafeDirectory(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

/// What sync last saw of a workspace's own files, and which have been deleted
/// or added since, so that a deletion reaches other Macs instead of being undone
/// by their copies. Times are milliseconds since 1970.
///
/// Workspace files change outside Lamp too — agents and Finder delete them —
/// so deletions are found by comparing with the last sync rather than recorded
/// as they happen.
struct WorkspaceFileLedger: Codable, Equatable {
    static let portableFilename = "DeletedFiles.json"
    private static let localFilename = "sync-files.json"

    var formatVersion = 1
    /// Files present after the last sync, with their modification times. Nil
    /// until a first sync, which records what's there and nothing more: a Mac
    /// first syncing after an upgrade must not treat its files as new.
    var synced: [String: Int64]?
    var deletedAt: [String: Int64] = [:]
    /// When context files appeared here. Context files are links to shared
    /// objects whose modification times are those of whichever copy came
    /// first, so a file added again could look older than its own deletion.
    var presentSince: [String: Int64] = [:]
    /// What this reader has done to each source, by key: let it go to the
    /// server, or asked for it back. One act per path, or none.
    ///
    /// **Local only** — it is not in `Portable`, because it is this Mac's
    /// housekeeping and no other device's business. Whether the file is
    /// *here* is never stored: it is observed, every time, from the disk.
    /// Everything the feature shows or withholds is a function of the two
    /// (`decisions/0021`, "one act per path").
    ///
    /// This replaced a set of offloaded keys and a dictionary of fetch times
    /// whose value meant "asked at" until the file arrived and "landed at"
    /// after. Four review rounds found defects in that pair, nearly all of
    /// one shape: two representations that had to agree and did not. A key
    /// cannot be both offloaded and wanted now, because it holds one value.
    ///
    /// Recorded rather than inferred, which is the fourth time that
    /// distinction has had to be made (`decisions/0016`, `0017`, `0018`).
    /// Withholding every absent source looked equivalent and is not: it
    /// cannot tell a file this Mac offloaded from one it has never seen, so a
    /// new Mac withheld every source in the library and could never fetch
    /// one. Absence is not a fact about intent.
    var acts: [String: SourceAct] = [:]

    /// When each context file was first seen **here**, by this Mac — attached
    /// here, or installed by a pass. Local only, like `acts`.
    ///
    /// Kept apart from `presentSince`, which is portable and settles
    /// deletions across devices: an arrival here is this Mac's fact, and
    /// stamping the shared one on every download would move when other Macs
    /// judge a deletion to have happened. It is what the sweep's grace runs
    /// from. A pass installs a source *between* the gather's note and the
    /// record of what is now present, so the gather never sees it arrive —
    /// both places stamp this.
    var arrivedAt: [String: Int64] = [:]

    /// The quarantine marker each offloaded source carried, kept while it is
    /// away and put back when it is downloaded. Local only.
    ///
    /// No store carries extended attributes, so a source downloaded from the
    /// server comes back without the mark macOS uses to treat a file as having
    /// come from outside. For a document that changes nothing; for a script
    /// attached as a source, which an agent in the workspace might run, it
    /// would turn a file macOS checks into one it does not. Keeping the mark
    /// is cheaper than keeping every downloaded PDF on disk.
    var quarantine: [String: String] = [:]

    /// The digest of each source as it left, so the copy that comes back can
    /// be told from another: the quarantine mark goes only onto the same
    /// bytes, and a copy that differs is said (`decisions/0022`).
    var offloadedDigest: [String: String] = [:]

    /// What a pass found about sources that came back, for the next look at
    /// the ledgers to say and clear: `changed` where the copy that came back
    /// is not the one that left, `unmarked` where its quarantine would not
    /// take. Nothing is deleted for either.
    var returnNotices: [String: ReturnNotice] = [:]

    enum ReturnNotice: String, Codable, Sendable { case changed, unmarked }

    /// Which file a request to offload was made about, as its place on disk
    /// (`device:inode`). A file attached later at the same path — the first
    /// one deleted in Finder and another dropped in under its name, between
    /// two passes or before the first — is not the one the reader chose, and
    /// carrying the request over to it would send away a file nobody asked
    /// about. Absent for a request from before this was kept.
    var leavingFile: [String: String] = [:]

    static func place(of identity: LampFileIdentity) -> String {
        "\(identity.device):\(identity.inode)"
    }

    enum SourceAct: String, Codable, Equatable, Sendable {
        /// The reader asked for this source to go back to the server. Its
        /// file is still here: the offload happens after the next sync
        /// finishes, alongside the inactivity sweep, so that every deletion
        /// happens at one moment, with a fresh look at the server and nothing
        /// else running (owner's decision, `decisions/0021`). The only act a
        /// present file keeps.
        case leaving
        /// This Mac let the file go; the server keeps it. Withheld while no
        /// file is here.
        case offloaded
        /// The reader asked for it back. Not withheld, so a pass fetches it;
        /// drawn as on its way until it arrives.
        case wanted
    }

    /// Decoded field by field, because a ledger written before a field
    /// existed must still be read.
    ///
    /// Swift's synthesized `Decodable` demands every key, default value or
    /// not, and `load` answers a *fresh* ledger when decoding throws — so
    /// adding `offloaded` silently discarded every `sync-files.json` on
    /// disk, losing what each workspace had last synced. A file removed
    /// before the next pass would then have come back. Each field is
    /// optional here so the next one added cannot do it again.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        synced = try container.decodeIfPresent([String: Int64].self, forKey: .synced)
        deletedAt = try container.decodeIfPresent(
            [String: Int64].self, forKey: .deletedAt
        ) ?? [:]
        presentSince = try container.decodeIfPresent(
            [String: Int64].self, forKey: .presentSince
        ) ?? [:]
        acts = try container.decodeIfPresent(
            [String: SourceAct].self, forKey: .acts
        ) ?? [:]
        arrivedAt = try container.decodeIfPresent(
            [String: Int64].self, forKey: .arrivedAt
        ) ?? [:]
        quarantine = try container.decodeIfPresent(
            [String: String].self, forKey: .quarantine
        ) ?? [:]
        leavingFile = try container.decodeIfPresent(
            [String: String].self, forKey: .leavingFile
        ) ?? [:]
        offloadedDigest = try container.decodeIfPresent(
            [String: String].self, forKey: .offloadedDigest
        ) ?? [:]
        returnNotices = try container.decodeIfPresent(
            [String: ReturnNotice].self, forKey: .returnNotices
        ) ?? [:]
    }

    init() {}

    struct Portable: Codable, Equatable {
        var formatVersion = 1
        var deletedAt: [String: Int64]
        var presentSince: [String: Int64]

        func write(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    /// In NFC, as core names a document: macOS can hand a name back
    /// decomposed, and one name spelled two ways is one file.
    static func documentKey(_ filename: String) -> String {
        "Documents/" + filename.precomposedStringWithCanonicalMapping
    }

    /// A key as `documentKey` now spells it. A ledger written before that
    /// can hold a document's key decomposed.
    static func normalized(_ key: String) -> String {
        key.hasPrefix("Documents/") ? documentKey(String(key.dropFirst("Documents/".count))) : key
    }
    static func contextKey(_ relativePath: String) -> String { "Context/" + relativePath }
    /// Records a deletion made on purpose, for a key whose file is already
    /// gone.
    ///
    /// The counterpart to `noteChanges` no longer inferring one for a context
    /// file: the act writes it down, and nothing else does. Stamped with when
    /// it was recorded, because context files' modification times are not
    /// comparable across Macs.
    mutating func recordDeletion(of key: String, now: Date = Date()) {
        let key = Self.normalized(key)
        deletedAt[key] = max(deletedAt[key] ?? .min, Self.milliseconds(now))
        synced?[key] = nil
        presentSince[key] = nil
        // Neither on the server for this Mac nor on its way here.
        acts[key] = nil
        quarantine[key] = nil
        offloadedDigest[key] = nil
    }

    /// This Mac lets a source go. Noted before the file is unlinked, so a
    /// crash between the two reads as "offloaded, and still here" — which the
    /// next gather clears, because the file is present — rather than as a
    /// file gone and unrecorded.
    ///
    /// Returns what the last sync recorded for the key, so a caller whose
    /// unlink then fails can put it back.
    @discardableResult
    mutating func noteOffloaded(_ key: String) -> Int64? {
        let key = Self.normalized(key)
        let baseline = synced?[key]
        acts[key] = .offloaded
        synced?[key] = nil
        return baseline
    }

    /// The reader asked for a source back.
    mutating func noteWanted(_ key: String) {
        acts[key] = .wanted
    }

    /// The reader asked for a source to go back to the server, after the
    /// next sync.
    mutating func noteLeaving(_ key: String, file: String? = nil) {
        acts[key] = .leaving
        leavingFile[key] = file
    }

    /// Whatever this Mac had done to the source no longer applies: it
    /// stayed, or another device deleted it, or the server no longer counts
    /// it. Neither "on the server" nor "on its way".
    ///
    /// `baseline`, where given, is what the last sync had recorded before an
    /// offload that did not go through; it is put back so the attempt leaves
    /// nothing behind.
    mutating func forgetAct(_ key: String, restoring baseline: Int64? = nil) {
        let key = Self.normalized(key)
        acts[key] = nil
        quarantine[key] = nil
        offloadedDigest[key] = nil
        if let baseline { synced?[key] = baseline }
    }

    /// The context paths holding `act`, relative to the context directory.
    func contextPaths(withAct act: SourceAct) -> [String] {
        let prefix = Self.contextKey("")
        return acts
            .filter { $0.value == act && $0.key.hasPrefix(prefix) }
            .map { String($0.key.dropFirst(prefix.count)) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Every context path this Mac has done anything to, with what.
    func contextActs() -> [String: SourceAct] {
        let prefix = Self.contextKey("")
        var paths: [String: SourceAct] = [:]
        for (key, act) in acts where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            if !path.isEmpty { paths[path] = act }
        }
        return paths
    }

    static func isContextKey(_ key: String) -> Bool { key.hasPrefix("Context/") }

    /// Whether a source arrived here recently enough to be left alone.
    ///
    /// The sweep's grace, by **arrival**, however the file came: a download
    /// the reader asked for, an attachment, another Mac's copy. Not by when
    /// anything was asked for — a download that took longer than the grace
    /// itself arrived already expired — and not by any of the writing's
    /// activity clocks, none of which an attachment moves: a PDF attached to
    /// a six-month-old writing, in preparation for working on it, was
    /// otherwise offloaded two passes later.
    ///
    /// Read from `arrivedAt`, which both the gather and a pass's import
    /// stamp; `synced[key] == nil` covers anything neither has recorded yet.
    func isNewHere(_ key: String, now: Date, grace: TimeInterval) -> Bool {
        let key = Self.normalized(key)
        guard let synced, synced[key] != nil else { return true }
        guard let arrived = arrivedAt[key] else { return false }
        return arrived >= Self.milliseconds(now.addingTimeInterval(-grace))
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    var isEmpty: Bool { deletedAt.isEmpty && presentSince.isEmpty }
    var portable: Portable { Portable(deletedAt: deletedAt, presentSince: presentSince) }

    static func load(in workspace: URL) -> WorkspaceFileLedger {
        guard let data = try? Data(contentsOf: url(in: workspace)),
              let ledger = try? JSONDecoder().decode(WorkspaceFileLedger.self, from: data)
        else { return WorkspaceFileLedger() }
        return ledger
    }

    /// The ledger, or nil where one is there and could not be read.
    ///
    /// `load` answers a fresh ledger for both "no ledger yet" and "a ledger
    /// that would not read", which is right for a pass — there is nothing to
    /// carry forward either way. It is wrong for the lock on where sync
    /// points: a ledger that would not read may be holding the last offload,
    /// and reading it as empty would lift the lock while the only copy sat on
    /// the server.
    ///
    /// "No ledger" only where reading it says the file does not exist.
    /// Asking `fileExists` first answered false for a ledger in a folder Lamp
    /// had lost permission to search — and an empty ledger then.
    static func loadIfReadable(in workspace: URL) -> WorkspaceFileLedger? {
        let data: Data
        do {
            data = try Data(contentsOf: url(in: workspace))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return WorkspaceFileLedger()
        } catch {
            return nil
        }
        return try? JSONDecoder().decode(WorkspaceFileLedger.self, from: data)
    }

    struct UnreadableLedger: LocalizedError {
        var errorDescription: String? {
            "This writing's sync record could not be read, so Lamp left it alone rather than write over it."
        }
    }

    func save(in workspace: URL) throws {
        let destination = Self.url(in: workspace)
        // Never over one that is there and will not read: it may hold the
        // last offload, and the lock on where sync points depends on it
        // reading as unknown. Every mutation goes through here, so the button
        // that would have written a fresh ledger over it now fails instead.
        guard Self.loadIfReadable(in: workspace) != nil else { throw UnreadableLedger() }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A binding outlives nothing but its request. What is kept about a
        // source that left goes when a copy is checked (`checkReturns`), or
        // with the source (`forgetAct`, `recordDeletion`) — not with the act,
        // which a gather answers before an interrupted import's copy has
        // been checked.
        var saved = self
        saved.leavingFile = leavingFile.filter { acts[$0.key] == .leaving }
        try encoder.encode(saved).write(to: destination, options: .atomic)
    }

    static func portable(in url: URL) -> Portable? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Portable.self, from: data)
    }

    private static func url(in workspace: URL) -> URL {
        AgentChatTranscriptStore.directory(in: workspace).appendingPathComponent(localFilename)
    }

    /// Compares the files present now with those at the last sync, and
    /// returns the keys found deleted since.
    @discardableResult
    mutating func noteChanges(present: [String: Int64], now: Date = Date()) -> [String] {
        let present = Dictionary(present.map { (Self.normalized($0.key), $0.value) }, uniquingKeysWith: max)
        let time = Self.milliseconds(now)
        guard let recorded = self.synced else {
            // The first pass records what is there and nothing more: a Mac
            // first syncing after an upgrade must not treat its files as new.
            // Except for the sweep's grace, which is this Mac's own and costs
            // nothing to give: everything here counts as arriving now, so a
            // source attached to a workspace that had never synced is not
            // offloaded at the next opportunity. The portable `presentSince`
            // is left alone, as before.
            self.synced = present
            for key in present.keys where Self.isContextKey(key) && arrivedAt[key] == nil {
                arrivedAt[key] = time
            }
            return []
        }
        let synced = Dictionary(recorded.map { (Self.normalized($0.key), $0.value) }, uniquingKeysWith: max)
        var deleted: [String] = []
        for (key, modified) in synced where present[key] == nil {
            // **A missing context file is not a deletion.** Absence is not a
            // fact about intent: a source may be gone because the reader
            // removed it, because this Mac offloaded it to free space, or
            // because something in the workspace tidied up — and inferring
            // "delete it everywhere" from any of those is how a reader loses
            // an 86 MB source they never meant to touch. It is the same
            // mistake `decisions/0016` and `0017` were written about, in a
            // third place: only the code that did the removing can say why.
            //
            // So a context deletion is recorded by the act that makes it
            // (`WorkspaceContextFileStore.deleteContextFile`), and a context
            // file that is merely absent is left to the gather, which
            // withholds it: present on the server, absent here, fetched when
            // asked for. A document keeps the old behaviour — its deletion
            // covers the last version this Mac had, so a later edit made
            // elsewhere survives it.
            guard !Self.isContextKey(key) else { continue }
            deletedAt[key] = max(deletedAt[key] ?? .min, modified)
            deleted.append(key)
        }
        for key in present.keys where synced[key] == nil && Self.isContextKey(key) {
            presentSince[key] = max(presentSince[key] ?? .min, time)
            arrivedAt[key] = time
        }
        // A file here answers whatever was done to its path — an offload whose
        // unlink never happened, a download that has landed — except a
        // request to offload it, which is about a file that is here.
        for key in present.keys where Self.isContextKey(key) && acts[key] != .leaving {
            acts[key] = nil
        }
        // And a request to offload a file that has since gone goes with it:
        // a file attached later at that path is another file, which nobody
        // asked to send away. Any such request, synced or not — one made
        // about a file attached since the last pass has no synced entry. An
        // offload notes `.offloaded` before it unlinks, so its own removal
        // never reads as this. A file replaced between two passes is caught
        // by `leavingFile` instead.
        for (key, act) in acts
        where act == .leaving && Self.isContextKey(key) && present[Self.normalized(key)] == nil {
            acts[key] = nil
        }
        self.synced = present
        return deleted
    }

    /// A document a pass put here or removed, as the last sync's: a removal
    /// a pass carried out is not this Mac's own deletion, and a document a
    /// pass brought is one whose removal later is.
    mutating func noteSynced(_ key: String, modified: Int64?) {
        guard synced != nil else { return }
        synced?[key] = modified
    }

    /// Puts back the quarantine of every source here that left with one, and
    /// forgets those that went back. One that will not take stays, to be
    /// tried after the next pass.
    /// Checks each source that has come back against what left: the same
    /// bytes get their quarantine mark back; a different copy is said, and
    /// marked with nothing — the mark was about the file that left, not
    /// about whatever now has its name. Neither case deletes anything: a
    /// missing mark is a thing to say, not a reason to throw away a file the
    /// reader may have put there (`decisions/0022`).
    ///
    /// What left is kept until a copy at the path has been checked, whenever
    /// that is: on the import that brought it, or — where that import failed
    /// after writing it — at the next gather, before the act is answered. A
    /// copy that differs is said only by the import, which knows it came from
    /// the server; at a gather it may be a file the reader put there, and its
    /// entries are simply dropped.
    mutating func checkReturns(inContextOf workspace: URL, sayChanged: Bool) {
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        let prefix = Self.contextKey("")
        for (key, left) in offloadedDigest where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            guard LampWorkspaceSync.isHere(path, inContextOf: workspace) else { continue }
            let file = context.appendingPathComponent(path)
            guard let digest = try? LampSyncContentRevision.digest(forFileAt: file) else { continue }
            defer {
                offloadedDigest[key] = nil
                quarantine[key] = nil
            }
            guard digest == left else {
                if sayChanged { returnNotices[key] = .changed }
                continue
            }
            guard let mark = quarantine[key] else { continue }
            // After consolidation, which may have swapped the download for a
            // link to an object already in the store: a mark set before it
            // would be on a copy that no longer exists. The object is
            // read-only, and macOS will not write an attribute to a file this
            // process cannot write, so the owner's write bit is lifted for the
            // one call and put back.
            var info = stat()
            guard lstat(file.path, &info) == 0 else { continue }
            let mode = info.st_mode & 0o7777
            let lifted = mode & S_IWUSR == 0
            if lifted { chmod(file.path, mode | S_IWUSR) }
            let set = Data(mark.utf8).withUnsafeBytes {
                setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            if lifted { chmod(file.path, mode) }
            if set != 0 { returnNotices[key] = .unmarked }
        }
    }

    mutating func recordSynced(_ present: [String: Int64], now: Date = Date()) {
        // What the pass has just installed arrives here now. It went in
        // after the gather's note and goes into `synced` here, so nothing
        // else would ever see it arrive — and without this a source
        // downloaded into a closed, idle writing reads as settled and the
        // sweep can take it straight back.
        let time = Self.milliseconds(now)
        let before = synced ?? [:]
        for key in present.keys where before[key] == nil && Self.isContextKey(key) {
            arrivedAt[key] = time
            if acts[key] != .leaving { acts[key] = nil }
        }
        synced = present
    }

    mutating func merge(_ portable: Portable?) {
        guard let portable else { return }
        deletedAt.merge(portable.deletedAt) { max($0, $1) }
        presentSince.merge(portable.presentSince) { max($0, $1) }
    }

    func isDeleted(_ key: String, modified: Int64) -> Bool {
        guard let deleted = deletedAt[key] else { return false }
        return deleted >= max(modified, presentSince[key] ?? .min)
    }
}

public struct LampWebDAVCredentials: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct LampWebDAVClient: Sendable, LampSyncRemoteStore {
    public let baseURL: URL
    public let credentials: LampWebDAVCredentials?
    private let storage: LampWebDAVStorage

    public init(
        baseURL: URL,
        credentials: LampWebDAVCredentials? = nil,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.storage = LampWebDAVStorage(
            baseURL: baseURL,
            credentials: credentials.map {
                .init(username: $0.username, password: $0.password)
            },
            session: session
        )
    }

    public func download(filename: String) async throws -> Data? {
        try validateFilename(filename)
        return try await mapped { try await storage.download(filename) }
    }

    public func download(relativePath: String) async throws -> Data? {
        try await mapped { try await storage.download(relativePath) }
    }

    public func read(path: String) async throws -> LampSyncRemoteFile? {
        try await mapped { try await storage.read(path: path) }
    }

    /// Forwarded, or the protocol's default fetches the whole body: an
    /// offload's read-back asks for no more than the copy it expects.
    public func readPrefix(path: String, count: Int) async throws -> LampSyncRemoteFile? {
        try await mapped { try await storage.readPrefix(path: path, count: count) }
    }

    public func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        try await mapped { try await storage.list(directory: directory) }
    }

    public func revision(path: String) async throws -> String? {
        try await mapped { try await storage.revision(path: path) }
    }

    public func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        try await mapped { try await storage.write(data, to: path, condition: condition) }
    }

    /// The streaming counterparts, forwarded so the Mac streams too. Without
    /// them the protocol's defaults hold the whole body in memory, and the
    /// archive is the whole library.
    public func read(path: String, into url: URL) async throws -> LampSyncDownloadedFile? {
        try await mapped { try await storage.read(path: path, into: url) }
    }

    public func write(
        fileAt url: URL,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        try await mapped { try await storage.write(fileAt: url, to: path, condition: condition) }
    }

    /// Forwarded rather than left to the protocol's default, which throws
    /// `deleteUnsupported`: a store that cannot delete never reaps a
    /// tombstoned file, so the bytes would stay on the server for good.
    public func delete(path: String, condition: LampSyncWriteCondition) async throws {
        try await mapped { try await storage.delete(path: path, condition: condition) }
    }

    public func upload(_ data: Data, filename: String) async throws {
        try validateFilename(filename)
        try await mapped { try await storage.upload(data, to: filename) }
    }

    public func upload(_ data: Data, relativePath: String) async throws {
        try await mapped { try await storage.upload(data, to: relativePath) }
    }

    public func createDirectory(_ directory: String) async throws {
        let path = directory.hasSuffix("/") ? directory : directory + "/"
        try await mapped { try await storage.createDirectory(path) }
    }

    public func listModuleFilenames(directory: String) async throws -> [String] {
        let items = try await LampSyncModuleFolder.list(in: self, directory: directory)
        var seen = Set<String>()
        return items.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    public func makeRequest(method: String, filename: String) throws -> URLRequest {
        try validateFilename(filename)
        do {
            return try storage.makeRequest(method: method, path: filename)
        } catch LampWebDAVStorage.StorageError.invalidPath {
            throw LampSyncError.unsafeArchivePath
        }
    }

    private func validateFilename(_ filename: String) throws {
        guard !filename.contains("/"), !filename.contains("..") else {
            throw LampSyncError.unsafeArchivePath
        }
    }

    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch LampWebDAVStorage.StorageError.invalidPath {
            throw LampSyncError.unsafeArchivePath
        } catch LampWebDAVStorage.StorageError.invalidResponse,
                LampWebDAVStorage.StorageError.invalidXML {
            throw LampSyncError.invalidResponse
        } catch LampWebDAVStorage.StorageError.preconditionFailed {
            throw LampSyncError.remoteChanged
        } catch LampWebDAVStorage.StorageError.httpStatus(let code) {
            throw LampSyncError.httpStatus(code)
        }
    }
}

/// Compatibility adapters are shared with iOS through LampModuleKit.
public typealias LampWebDAVPersonalArchiveKind = LampModuleKit.LampWebDAVPersonalArchiveKind
public typealias LampWebDAVPersonalArchiveAdapter = LampModuleKit.LampWebDAVPersonalArchiveAdapter

/// `LampSyncRefusal` because `mapped` translates the storage layer's errors
/// into these for the user's sake, and a translated refusal is still a
/// refusal. `LampSyncConditionalWrite.isRefusal` decides whether a
/// read-merge-retry reads again or gives up, and it recognises the storage
/// error, not this one — so without the conformance the settings bundle's
/// `update` would abandon a pass every time another device wrote first,
/// which is the one case it exists to recover from.
public enum LampSyncError: LocalizedError, LampSyncRefusal {
    case unsafeArchivePath
    case unsupportedArchiveVersion
    case invalidResponse
    case httpStatus(Int)
    case remoteChanged
    case archiveConversionFailed
    case invalidModuleJSON

    public var errorDescription: String? {
        switch self {
        case .unsafeArchivePath: "The sync archive contains an unsafe file path."
        case .unsupportedArchiveVersion: "This Lamp Bible sync archive version is not supported."
        case .invalidResponse: "The sync server returned an invalid response."
        case .httpStatus(let status): "The sync server returned HTTP status \(status)."
        case .remoteChanged: "The remote library changed while syncing. Sync again to merge it."
        case .archiveConversionFailed: "Lamp Bible could not prepare personal content for cross-device sync."
        case .invalidModuleJSON: "The WebDAV module JSON is not in a supported Lamp Bible format."
        }
    }

    /// Only `remoteChanged`, which is what a 412 or 428 becomes. The storage
    /// layer raises `preconditionFailed` for both and never reports either as
    /// an `httpStatus`, so no status code needs reading here.
    public var isRefusal: Bool {
        if case .remoteChanged = self { return true }
        return false
    }
}

/// What the Sync pane says above the list of decisions waiting.
///
/// Counted by kind rather than lumped together: "2 notes" tells someone where
/// to look in a way "2 items" does not.
public enum SyncConflictSummary {
    public static func text(for conflicts: [LampSyncConflict]) -> String {
        guard !conflicts.isEmpty else { return "" }
        let notes = conflicts.filter { $0.kind == .note }.count
        let writings = conflicts.count - notes
        var phrases: [String] = []
        if writings > 0 { phrases.append(writings == 1 ? "one writing" : "\(writings) writings") }
        if notes > 0 { phrases.append(notes == 1 ? "one note" : "\(notes) notes") }
        let subject = phrases.joined(separator: " and ")
        let capitalised = subject.prefix(1).uppercased() + subject.dropFirst()
        let verb = conflicts.count == 1 ? "was" : "were"
        let kept = conflicts.count == 1
            ? "Your copy is the one being kept"
            : "Your copies are the ones being kept"
        return "\(capitalised) \(verb) changed on two devices at the same moment, "
            + "so sync cannot tell which came later. \(kept) until you choose."
    }
}

/// The document bodies a sync pass has installed in a workspace, by digest.
///
/// The editor's poll sees any change to a document on disk, and cannot tell
/// the assistant writing one from a pass taking the phone's copy in: both
/// are a file that changed under it. Marking what the pass wrote would mark
/// the writer's own edits, made on their phone, as the assistant's.
///
/// A time would not settle it — the pass and the poll are not in step, and
/// a slow pass's write looks like a fast agent's. The pass knows the bytes
/// it writes, so it says so here, and the poll compares what it found with
/// them. Content is exact; it holds however late the poll is.
///
/// A few are kept for each document rather than one, so a poll that was
/// behind two of the pass's writes still recognises the older of them.
public final class WorkspaceDocumentsTakenIn: @unchecked Sendable {
    public static let shared = WorkspaceDocumentsTakenIn()

    private let lock = NSLock()
    private var digests: [String: [String]] = [:]
    /// The last body a pass put at each path, kept whole.
    ///
    /// A digest answers "was this the pass's?", which is not enough: the
    /// editor can poll after a pass installed one body and the assistant
    /// then wrote over it, and the change it sees is the two together.
    /// Marked from the text the editor last held, the writer's own words
    /// — arrived from another device — are marked as the assistant's,
    /// and a restore would offer to take them out again. The pass's body
    /// is where the assistant's change actually begins.
    private var bodies: [String: String] = [:]
    /// Enough to cover a poll that fell behind a pass; small enough that a
    /// workspace of documents costs nothing to remember.
    private static let kept = 8

    /// Said by a pass when it writes a document's body, by the document's
    /// server path.
    public func tookIn(_ data: Data, at path: String) {
        let digest = Self.digest(of: data)
        let body = String(decoding: data, as: UTF8.self)
        lock.withLock {
            var kept = digests[path, default: []].filter { $0 != digest }
            kept.append(digest)
            digests[path] = Array(kept.suffix(Self.kept))
            bodies[path] = body
        }
    }

    /// The last body a pass put at this path, for a caller working out
    /// what changed since. Taken away as it is read, so the next change
    /// is measured from what the editor holds again.
    public func lastTakenIn(at path: String) -> String? {
        lock.withLock {
            defer { bodies[path] = nil }
            return bodies[path]
        }
    }

    /// Whether this is a body a pass put here, rather than something that
    /// was written in the workspace.
    public func tookIn(_ text: String, at path: String) -> Bool {
        let digest = Self.digest(of: Data(text.utf8))
        return lock.withLock { digests[path, default: []].contains(digest) }
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

    /// What a reader has done to a source, as the pane and the sweep see it.
    /// The ledger's own value, made public; see `WorkspaceFileLedger.acts`.
    public enum WorkspaceSourceAct: String, Equatable, Sendable {
        case leaving, offloaded, wanted

        init(_ act: WorkspaceFileLedger.SourceAct) {
            switch act {
            case .leaving: self = .leaving
            case .offloaded: self = .offloaded
            case .wanted: self = .wanted
            }
        }
    }

    /// A pass this Mac has been asked for that its own work would not start.
    ///
    /// The automatic pass runs when something a pass *carries* has changed —
    /// `LampSyncLocalWork.marks` reads the workspaces' files, and deliberately
    /// not the bookkeeping beside them, so that a pass writing its own ledger
    /// does not wake the next one. Asking for an offloaded source back writes
    /// only that bookkeeping: no file changes, so nothing would notice, and
    /// on an idle library Download waited for some unrelated edit before the
    /// file came home.
    ///
    /// So the ask is recorded here, and picked up by whichever comes first:
    /// the pane asking the controller directly, the reader window's poll, or
    /// the end of a pass that was already running when it was made.
    @MainActor
    public enum LampSyncRequest {
        private static var isPending = false

        /// Ask for a pass. Costs nothing if one is already wanted.
        public static func wantAPass() { isPending = true }

        /// Whether a pass was asked for, clearing the ask.
        public static func takePending() -> Bool {
            defer { isPending = false }
            return isPending
        }
    }
