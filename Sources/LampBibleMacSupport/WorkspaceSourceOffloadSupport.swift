import Foundation
import LampModuleKit

/// Putting a writing's sources back on the server once the writing has been
/// left alone for a while.
///
/// A reader's sources are most of what a library holds — on the measured one,
/// 347.7 MB of 372.2 MB — and a PDF read once a year costs the same as one
/// read daily. Offloading is reversible: the server keeps its copy, the Context
/// pane's Download fetches it back, and the pass withholds the member in the
/// meantime rather than treating the absence as a deletion
/// (`lamp-bible-core/Documentation/decisions/0018`, `0020`).
///
/// The policy is worked out apart from the carrying out, so a test can state
/// the rule without a file system and so the caller can say what it did. That
/// is `ReaderChatWorkspaceStore.scrubbable`'s shape, and this is the same kind
/// of housekeeping.
public enum WorkspaceSourceOffload {
    /// How long a writing is left alone before its sources go back to the
    /// server.
    ///
    /// Kept on this Mac alone, and **not** in the synced settings: it governs
    /// this machine's disk. A desktop with room to spare should not inherit a
    /// laptop's policy, which is the same reason the reader's chat retention
    /// is per-Mac.
    public enum After: String, CaseIterable, Codable, Sendable {
        case never, oneMonth, threeMonths, sixMonths, oneYear

        /// Never, deliberately. Sources leaving the machine is something the
        /// reader opts into — and without a server there is nowhere for them
        /// to go, so the setting means nothing until sync is set up.
        public static let standard = After.never

        public static let settingKey = "writing.sources.offloadAfter"

        /// The reader's choice, or never where nothing has been chosen or the
        /// name saved is one this build does not know.
        public static func chosen(in defaults: UserDefaults = .standard) -> After {
            defaults.string(forKey: settingKey).flatMap(After.init(rawValue:)) ?? .standard
        }

        /// Days a writing may be left alone before its sources go, or nil to
        /// leave them alone for ever.
        public var days: Int? {
            switch self {
            case .never: nil
            case .oneMonth: 30
            case .threeMonths: 91
            case .sixMonths: 182
            case .oneYear: 365
            }
        }

        public var title: String {
            switch self {
            case .never: "Never"
            case .oneMonth: "After one month"
            case .threeMonths: "After three months"
            case .sixMonths: "After six months"
            case .oneYear: "After one year"
            }
        }
    }

    /// One writing's workspace as the policy sees it: no URLs, and no dates
    /// read here. Everything the rule needs has already been looked up.
    public struct Workspace: Equatable, Sendable {
        /// The writing this workspace belongs to.
        public let writingID: String
        /// The workspace's own folder, carried rather than derived again from
        /// the id: two ids that differ only in Unicode form are one string to
        /// Swift and two folders on disk, and re-deriving would put one
        /// writing's candidates in the other's folder.
        public let folder: URL?
        /// When the reader last did anything with this writing, or nil where
        /// that cannot be told.
        ///
        /// Deliberately **not** the newest modification date in the workspace
        /// tree. Offloading writes the ledger into the workspace, and so does
        /// every pass, every time the pane opens, and every arriving install —
        /// a clock any of those move is one an offload resets by firing.
        public let lastActivity: Date?
        /// The sources on disk now, by their path under the context folder.
        /// Ones already offloaded are not here; there is no file to take.
        public let sources: [String]
        /// Those of `sources` worth reading back from the server: members of
        /// its manifest as the last pass left it, that this Mac uploaded or
        /// downloaded. A short list, not proof — the offload reads each one
        /// back and goes only where the server's copy is these bytes (`0022`).
        public let onTheServer: Set<String>

        public init(
            writingID: String,
            folder: URL? = nil,
            lastActivity: Date?,
            sources: [String],
            onTheServer: Set<String>
        ) {
            self.writingID = writingID
            self.folder = folder
            self.lastActivity = lastActivity
            self.sources = sources
            self.onTheServer = onTheServer
        }
    }

    /// One source the policy would put back on the server.
    public struct Candidate: Equatable, Sendable, Comparable {
        public let writingID: String
        public let relativePath: String
        /// The workspace folder it is in — see `Workspace.folder`.
        public let folder: URL?

        public init(writingID: String, relativePath: String, folder: URL? = nil) {
            self.writingID = writingID
            self.relativePath = relativePath
            self.folder = folder
        }

        public static func < (lhs: Candidate, rhs: Candidate) -> Bool {
            (lhs.writingID, lhs.relativePath) < (rhs.writingID, rhs.relativePath)
        }
    }

    /// The sources a sweep would put back on the server.
    ///
    /// Held writings are never offered, whatever their age: an open editor is
    /// a writing being worked on right now, and its agent pane is inside it,
    /// so a chat or a Terminal turn mid-flight is covered by the same check.
    ///
    /// A writing whose activity cannot be dated is kept. The answer to not
    /// knowing is to keep, as it is for a chat whose transcript this build
    /// cannot read: the cost of keeping a source too long is disk, and the
    /// cost of taking one too early is a fetch the reader did not ask for.
    ///
    /// The result is sorted, so a batch that fails half way through fails the
    /// same way twice.
    public static func offloadable(
        from workspaces: [Workspace],
        after: After,
        heldBy held: Set<String>,
        now: Date
    ) -> [Candidate] {
        guard let days = after.days else { return [] }
        let window = Double(days) * 24 * 60 * 60
        var candidates: [Candidate] = []
        for workspace in workspaces {
            guard !held.contains(workspace.writingID) else { continue }
            guard let lastActivity = workspace.lastActivity else { continue }
            // Strictly longer than the window, as the chat scrub compares:
            // a writing left alone for exactly a month has not yet passed
            // "after one month".
            guard now.timeIntervalSince(lastActivity) > window else { continue }
            for source in workspace.sources where workspace.onTheServer.contains(source) {
                candidates.append(
                    Candidate(
                        writingID: workspace.writingID, relativePath: source,
                        folder: workspace.folder
                    )
                )
            }
        }
        return candidates.sorted()
    }
}

extension WorkspaceSourceOffload {
    /// How long a source that has just arrived is left alone, whatever the
    /// writing's dates say — however it arrived: fetched, attached, or copied
    /// in by another Mac. A week: long enough to read what you fetched,
    /// short enough that a source fetched and forgotten goes back on its own.
    static let arrivalGrace: TimeInterval = 7 * 24 * 60 * 60

    /// Reads the policy's inputs off disk: one entry per workspace whose
    /// writing this library still has.
    ///
    /// On the owner, which has been the measuring case throughout. A workspace
    /// whose writing has been deleted is skipped — the folder outlives the
    /// writing, and sweeping an orphan would be housekeeping of a different
    /// kind, not this.
    ///
    /// `writings` carries each writing's own saved date. It is asked for
    /// rather than read here because the library is the caller's, and because
    /// a date that travels in the personal file reads the same on both Macs.
    ///
    /// `observation` is what the pass that just finished saw: its members,
    /// as that pass left the manifest. `onTheServer` is only a short list of
    /// what is worth reading back; the offload's read of the server is what
    /// decides.
    @WritingWorkspaceFiles
    public static func workspaces(
        inLibraryAt libraryRootURL: URL,
        writings: [(id: String, modified: Date)],
        observation: ServerObservation,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [Workspace] {
        guard let folders = try? LampWorkspaceSync.workspaces(
            in: libraryRootURL, fileManager: fileManager
        ) else { return [] }
        let records = LampSyncFileRecords.load(
            fromLibraryAt: libraryRootURL, fileManager: fileManager
        )
        var found: [Workspace] = []
        for folder in folders {
            let name = folder.lastPathComponent
            // By the id's bytes, as the folder was named — not by Swift string
            // equality, which would match two ids differing only in Unicode
            // form to one folder and one date.
            guard let writing = writings.first(where: {
                LampWritingWorkspaceLayout.directoryName(for: $0.id) == name
            }) else { continue }
            let writingID = writing.id
            let ledger = WorkspaceFileLedger.load(in: folder)
            // Not a candidate while it is new here, however it came — attached
            // here, or installed by a pass: see `WorkspaceFileLedger.isNewHere`.
            let sources = contextRelativePaths(in: folder, fileManager: fileManager)
                .filter {
                    !ledger.isNewHere(
                        WorkspaceFileLedger.contextKey($0), now: now, grace: arrivalGrace
                    )
                }
            var onTheServer: Set<String> = []
            for relativePath in sources {
                // Worth reading from the server, no more: a member there that
                // this Mac uploaded or downloaded. The read decides.
                guard let path = try? LampWritingWorkspaceLayout.contextPath(
                    folder: name, relativePath: relativePath
                ),
                observation.members.contains(path),
                observation.listed.contains(path),
                records.record(path, in: observation.source)?.uploadedDigest != nil
                else { continue }
                onTheServer.insert(relativePath)
            }
            found.append(
                Workspace(
                    writingID: writingID,
                    folder: folder,
                    lastActivity: lastActivity(
                        ofWorkspaceAt: folder,
                        writingSaved: writing.modified,
                        fileManager: fileManager
                    ),
                    sources: sources,
                    onTheServer: onTheServer
                )
            )
        }
        return found
    }

    /// When the reader last did anything with a writing.
    ///
    /// Three clocks, and the newest of them wins. **Not** the newest
    /// modification date in the workspace tree, which would be the obvious
    /// thing and is wrong: an offload writes the ledger into the workspace,
    /// and so does every sync pass, every opening of the agent pane, and
    /// every arriving install. A clock any of those move is one an offload
    /// resets by firing, and the sweep would then never run twice.
    ///
    /// - the writing's own saved date, which travels in the personal file and
    ///   so reads the same on every device;
    /// - the newest message in the workspace's transcripts. Research that
    ///   never touched the draft is still work on this writing, and a message
    ///   is dated by the reader's act rather than by a file;
    /// - the newest of the writer's own documents at the top of the workspace
    ///   — an `outline.md` edit does not move the writing's saved date. This
    ///   is the one file date here, read through `stat` rather than a URL's
    ///   cached values. A document arriving from sync reads as activity,
    ///   which only ever delays an offload.
    ///
    /// Nil where none of the three says anything, and the policy then keeps
    /// the workspace.
    @WritingWorkspaceFiles
    static func lastActivity(
        ofWorkspaceAt workspace: URL,
        writingSaved: Date?,
        fileManager: FileManager = .default
    ) -> Date? {
        var dates: [Date] = []
        if let writingSaved { dates.append(writingSaved) }
        if let spoken = ReaderChatWorkspaceStore.lastSpoken(in: workspace) {
            dates.append(spoken)
        }
        let contents = (try? fileManager.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: nil
        )) ?? []
        for file in contents
        where LampWritingWorkspaceLayout.isDocumentName(file.lastPathComponent) {
            if let date = LampFileModification.date(of: file) { dates.append(date) }
        }
        return dates.max()
    }

    /// Every source on disk now, by its path under the workspace's context
    /// directory. A link is left out, as the digest walk leaves one out.
    ///
    /// An offloaded source has no file, so it is simply not here — the ledger
    /// does not need consulting to leave it alone.
    @WritingWorkspaceFiles
    static func contextRelativePaths(
        in workspace: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        let prefix = context.standardizedFileURL.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: context, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return [] }
        var paths: [String] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ]), values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if !relative.isEmpty { paths.append(relative) }
        }
        return paths.sorted()
    }
}

/// What a finished sync pass saw of the server: which store it was, as which
/// account, and which paths its manifest counts as members.
///
/// **Not proof that the server holds anything.** It used to carry the
/// listing's revisions too, and an offload was allowed where the listing, the
/// records and the local digest agreed. Fourteen review rounds found a new way
/// for those memories — taken at different times, by different code, under
/// different labels — to agree when the server did not hold the bytes
/// (`decisions/0022`). The proof is now a read of the server's copy at the
/// moment of the offload (`OffloadServer`); this only says which server the
/// last pass talked to, and which paths are worth reading.
public struct ServerObservation: Equatable, Sendable {
    /// The store this came from, as the records name it.
    public let source: String
    /// Who it was reached as (`SyncAccount.identity`); empty for a folder.
    public let account: String
    /// Every path the manifest counted as a member, as the pass left it.
    public let members: Set<String>
    /// The members the pass's listing showed with a revision. Not proof of
    /// any bytes; what Download needs to plan a fetch at all — a member the
    /// server lists without one is never fetched back, so a copy offloaded
    /// on matching bytes alone could be stuck on "Coming back" for ever.
    public let listed: Set<String>
    /// Paths the manifest records a deletion of. Only these settle an
    /// offload as gone: a path the manifest says nothing about may be one an
    /// older manifest, restored on the server, never knew.
    public let deleted: Set<String>
    public let at: Date

    /// How long a look at the server answers for anything. A pass runs every
    /// few minutes while sync is on, so the sweep never reaches this; it
    /// bites where it should — on a Mac that synced once days ago.
    public static let lifetime: TimeInterval = 15 * 60

    public init(
        source: String, account: String = "", members: Set<String>,
        listed: Set<String>? = nil, deleted: Set<String> = [], at: Date = Date()
    ) {
        self.source = source
        self.account = account
        self.members = members
        self.listed = listed ?? members
        self.deleted = deleted
        self.at = at
    }

    /// The same look, with membership and deletions as the manifest the pass
    /// wrote has them.
    public func with(members: Set<String>, deleted: Set<String>) -> ServerObservation {
        ServerObservation(
            source: source, account: account, members: members, listed: listed, deleted: deleted, at: at
        )
    }

    /// Whether this is still the look `other` was — the same pass, server
    /// and account — whatever its age. For a check made after a long read:
    /// the read is the proof, and expiring the look under it would refuse
    /// a source whose bytes have just matched.
    public func isTheSameLook(as other: ServerObservation) -> Bool {
        self == other
    }

    /// Whether this can answer for `source` as `account` now: the same
    /// server, reached the same way, and recently enough.
    public func answers(for source: String, account: String = "", now: Date = Date()) -> Bool {
        self.source == source && self.account == account
            && now.timeIntervalSince(at) < Self.lifetime
    }
}

/// The server an offload checks against, and how to read from it.
///
/// `fetch` reads a published path into a file, through the store the sync
/// is using now — the same address, the same credentials, the same folder
/// access — so what it returns is what Download would return. An offload
/// goes only where those bytes hash to the local copy's digest: no record,
/// listing, tag or account history stands in for that.
public struct OffloadServer: Sendable {
    public let source: String
    public let account: String
    /// Reads the whole of `path` into `destination`, as Download does; false
    /// where the server has no file. Whole, not a range: a partial answer
    /// that matched the local bytes would say nothing about the rest.
    public let fetch: @Sendable (_ path: String, _ destination: URL) async throws -> Bool

    public init(
        source: String, account: String,
        fetch: @escaping @Sendable (_ path: String, _ destination: URL) async throws -> Bool
    ) {
        self.source = source
        self.account = account
        self.fetch = fetch
    }
}

/// Where the offloaded sources are, and so the one place sync may point
/// while any are only there: a server, and who it is reached as.
///
/// An account belongs in it because a second account at the same address can
/// be a second library — a home folder, or the anonymous one a server serves
/// to requests without credentials. A pass reaching the address as anyone
/// else is refused outright, before it reads a manifest: one from another
/// library would otherwise settle the offloads as gone and release this.
public struct OffloadLock: Codable, Equatable, Sendable {
    public let source: String
    /// Nil for a lock written before the account was kept; the next pass at
    /// its address fills it in.
    public var account: String?

    public init(source: String, account: String?) {
        self.source = source
        self.account = account
    }

    /// Whether a pass at `source` as `account` may run while this holds.
    /// Offloads go only to a WebDAV server (`decisions/0022`), so a source
    /// here is an address, never a folder whose identity would also need
    /// keeping.
    public func admits(source: String, account: String) -> Bool {
        self.source == source && (self.account == nil || self.account == account)
    }
}

/// Who a WebDAV store is reached as.
public enum SyncAccount {
    /// No username and no password is no account at all — the client sends
    /// no credentials — and a server can answer anonymous requests with a
    /// different library from signed-in ones, even one signed in with an
    /// empty username. So the two never share a name.
    public static func identity(username: String, password: String) -> String {
        username.isEmpty && password.isEmpty ? "" : "user:" + username
    }
}

/// A source whose bytes have been hashed and whose identity was taken from
/// the same open of the file, ready to be unlinked if nothing has changed.
///
/// Made only by `verify`: there is no other way to get one. The offload's
/// unlink takes nothing else, so the step that hashes a path and then
/// deletes whatever is at it — the ordinary removal — cannot stand in for
/// it by accident. Four review rounds found a read creeping back in
/// between the check and the deletion; this is the shape that keeps one out.
public struct VerifiedSource: Equatable, Sendable {
    public let relativePath: String
    let file: URL
    let read: LampVerifiedFileRead
    /// Where the context directory really was when this was read, links
    /// resolved. The unlink requires the file to resolve under it still: `O_NOFOLLOW`
    /// and `AT_SYMLINK_NOFOLLOW` guard only the last component, so a folder
    /// on the way moved out and replaced by a link would otherwise lead the
    /// unlink to the same file in its new place (`decisions/0012`).
    let resolvedContext: String

    public var digest: String { read.digest }

    fileprivate init(
        relativePath: String, file: URL, read: LampVerifiedFileRead, resolvedContext: String
    ) {
        self.relativePath = relativePath
        self.file = file
        self.read = read
        self.resolvedContext = resolvedContext
    }

    /// Whether the file still resolves inside the context directory it was
    /// read in.
    var isStillInside: Bool {
        LampWorkspaceSync.reachesWithoutALink(relativePath, under: URL(fileURLWithPath: resolvedContext))
            && file.resolvingSymlinksInPath().path.hasPrefix(resolvedContext + "/")
    }

    /// Opens the source once and reads its identity and digest from that
    /// descriptor (`lamp-bible-core/Documentation/decisions/0012`).
    ///
    /// Nil for anything that is not a plain file here — a link, a folder, a
    /// file being written to while it was read. Each of those is a reason to
    /// leave the path alone, not an error to report.
    @WritingWorkspaceFiles
    static func verify(relativePath: String, inContext context: URL) -> VerifiedSource? {
        let file = context.appendingPathComponent(relativePath)
        let resolvedContext = context.resolvingSymlinksInPath().path
        guard LampWorkspaceSync.reachesWithoutALink(relativePath, under: context),
              file.resolvingSymlinksInPath().path.hasPrefix(resolvedContext + "/"),
              let read = try? LampVerifiedFileRead.read(file)
        else { return nil }
        return VerifiedSource(
            relativePath: relativePath, file: file, read: read, resolvedContext: resolvedContext
        )
    }
}

/// One row of a writing's Context list.
///
/// A pure function of two things: what the reader did to each source (the
/// ledger's act) and what is on disk. Nothing about a row is stored, so a row
/// cannot disagree with the withholding the pass does, or with what the
/// agent is told — they read the same two inputs.
public struct SourceRow: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        /// A file on disk.
        case here
        /// A file on disk the reader has asked to go back to the server; it
        /// goes after the next sync.
        case leaving
        /// A folder on disk. `holdsSourcesNotHere` when something under it
        /// is only on the server, or on its way: the folder cannot be removed
        /// until those are downloaded.
        case folder(holdsSourcesNotHere: Bool)
        /// Let go to the server; not here.
        case onTheServer
        /// Asked back; not here yet.
        case comingBack
        /// Not here, and a folder stands at its path: no download can land
        /// until the folder is moved. Drawn beside the folder's own row so
        /// the reader can see what it hides.
        case blockedByAFolder
        /// Away from this Mac, and the server's manifest no longer names it:
        /// nothing can bring it back. The reader may remove it from the list.
        case noLongerOnTheServer
    }

    /// Where the source is under the context directory. What a row is
    /// called, too: two offloaded files named `history.pdf` in different
    /// folders are two different sources, and a reader deleting one from the
    /// server has to be able to tell which.
    public let relativePath: String
    public let state: State
    public let byteCount: Int?

    public var id: String { state == .blockedByAFolder ? relativePath + "\u{0}blocked" : relativePath }
    public var isHere: Bool {
        switch state {
        case .here, .leaving, .folder: true
        case .onTheServer, .comingBack, .blockedByAFolder, .noLongerOnTheServer: false
        }
    }
    /// Whether Remove waits for a Download first: the row, or something
    /// under it, has no copy on this Mac. Removing it would delete the only
    /// copy, on the server — the one irreversible thing in this feature — so
    /// it is not offered (`decisions/0022`).
    public var removalWaitsForDownload: Bool {
        switch state {
        case .onTheServer, .comingBack, .blockedByAFolder, .noLongerOnTheServer,
             .folder(holdsSourcesNotHere: true): true
        case .here, .leaving, .folder(holdsSourcesNotHere: false): false
        }
    }

    public init(relativePath: String, state: State, byteCount: Int? = nil) {
        self.relativePath = relativePath
        self.state = state
        self.byteCount = byteCount
    }
}

extension WorkspaceSourceOffload {
    /// One entry at the top of a context directory.
    public struct DiskEntry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let byteCount: Int?
        /// A regular file — not a link, a socket or anything else. Only one
        /// of these is a source being here, as the withholding judges it; a
        /// link at an offloaded path must not hide the row that offers it
        /// back, or tell the agent it is local.
        public let isRegularFile: Bool

        public init(name: String, isDirectory: Bool, byteCount: Int?, isRegularFile: Bool = true) {
            self.name = name
            self.isDirectory = isDirectory
            self.byteCount = byteCount
            self.isRegularFile = isRegularFile
        }
    }

    /// The table: every row, from what is on disk and what is not here.
    ///
    /// Compared in NFC, as the ledger's keys are — macOS hands back a name
    /// with a combining mark decomposed, and a source would otherwise be
    /// drawn twice, once as itself and once as "On the server".
    public static func rows(
        onDisk: [DiskEntry],
        notHere: [String: WorkspaceSourceAct],
        leaving: Set<String> = [],
        obstructed: Set<String> = [],
        unaccounted: Set<String> = []
    ) -> [SourceRow] {
        let obstructed = Set(obstructed.map { $0.precomposedStringWithCanonicalMapping })
        let unaccounted = Set(unaccounted.map { $0.precomposedStringWithCanonicalMapping })
        let leaving = Set(leaving.map { $0.precomposedStringWithCanonicalMapping })
        let notHere = Dictionary(
            notHere.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [SourceRow] = []
        var shown: Set<String> = []
        var folders: Set<String> = []
        for entry in onDisk where entry.isDirectory || entry.isRegularFile {
            let path = entry.name.precomposedStringWithCanonicalMapping
            shown.insert(path)
            if entry.isDirectory {
                folders.insert(path)
                // Under it, or **at** it: a folder that has taken an
                // offloaded file's own path hides that source, and
                // `removeContextItem` refuses over the path itself too.
                let holds = notHere.keys.contains { $0 == path || $0.hasPrefix(path + "/") }
                rows.append(SourceRow(relativePath: path, state: .folder(holdsSourcesNotHere: holds)))
            } else {
                rows.append(SourceRow(
                    relativePath: path,
                    state: leaving.contains(path) ? .leaving : .here,
                    byteCount: entry.byteCount
                ))
            }
        }
        for (path, act) in notHere where act != .leaving {
            if unaccounted.contains(path), !shown.contains(path) {
                rows.append(SourceRow(relativePath: path, state: .noLongerOnTheServer))
            } else if folders.contains(path) || obstructed.contains(path) {
                rows.append(SourceRow(relativePath: path, state: .blockedByAFolder))
            } else if !shown.contains(path) {
                rows.append(SourceRow(
                    relativePath: path, state: act == .offloaded ? .onTheServer : .comingBack
                ))
            }
        }
        return rows.sorted {
            let order = $0.relativePath.localizedStandardCompare($1.relativePath)
            return order == .orderedSame
                ? $1.state == .blockedByAFolder
                : order == .orderedAscending
        }
    }

    /// The rows for one workspace, read now.
    @WritingWorkspaceFiles
    public static func rows(
        inWorkspaceAt workspace: URL, fileManager: FileManager = .default
    ) -> [SourceRow] {
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        let entries = ((try? fileManager.contentsOfDirectory(
            at: context, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []).map { url -> DiskEntry in
            let values = try? url.resourceValues(forKeys: keys)
            let isLink = values?.isSymbolicLink == true
            return DiskEntry(
                name: url.lastPathComponent,
                isDirectory: !isLink && values?.isDirectory == true,
                byteCount: values?.fileSize,
                isRegularFile: !isLink && values?.isRegularFile == true
            )
        }
        let notHere = LampWorkspaceSync.sourcesNotHere(in: workspace, fileManager: fileManager)
        return rows(
            onDisk: entries,
            notHere: notHere,
            leaving: Set(LampWorkspaceSync.leavingSourceNames(in: workspace, fileManager: fileManager)),
            obstructed: Set(notHere.keys.filter {
                LampWorkspaceSync.destinationIsObstructed($0, inContextOf: workspace)
            }),
            unaccounted: LampWorkspaceSync.unaccountedSourceNames(in: workspace)
        )
    }
}

