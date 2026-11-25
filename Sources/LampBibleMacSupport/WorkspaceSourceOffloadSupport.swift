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
        /// Those of `sources` the **last pass's own listing** showed on the
        /// server, at the revision this Mac has recorded for them.
        ///
        /// The subset matters: offloading deletes the only local copy, so one
        /// the server never took would simply be gone (`0020`). And a record
        /// alone does not say the server still has it — `installedRevision`
        /// is a memory of one upload that nothing refreshes, so a source
        /// deleted from the folder by hand would keep its confirmation for
        /// ever (`0021`).
        public let onTheServer: Set<String>

        public init(
            writingID: String,
            lastActivity: Date?,
            sources: [String],
            onTheServer: Set<String>
        ) {
            self.writingID = writingID
            self.lastActivity = lastActivity
            self.sources = sources
            self.onTheServer = onTheServer
        }
    }

    /// One source the policy would put back on the server.
    public struct Candidate: Equatable, Sendable, Comparable {
        public let writingID: String
        public let relativePath: String

        public init(writingID: String, relativePath: String) {
            self.writingID = writingID
            self.relativePath = relativePath
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
                    Candidate(writingID: workspace.writingID, relativePath: source)
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
    /// `observation` is what the pass that just finished saw. A source first
    /// confirmed during *that* pass is not in it — the listing is taken at
    /// the gather, before the uploads — so it waits one more pass, which is
    /// the safe direction.
    @WritingWorkspaceFiles
    public static func workspaces(
        inLibraryAt libraryRootURL: URL,
        writings: [String: Date],
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
            guard let writingID = LampWritingWorkspaceLayout.writingID(
                ofFolder: name, among: writings.keys
            ) else { continue }
            let ledger = WorkspaceFileLedger.load(in: folder)
            // Not a candidate while it is new here, however it came: see
            // `WorkspaceFileLedger.isNewHere`.
            let sources = contextRelativePaths(in: folder, fileManager: fileManager)
                .filter {
                    !ledger.isNewHere(
                        WorkspaceFileLedger.contextKey($0), now: now, grace: arrivalGrace
                    )
                }
            var onTheServer: Set<String> = []
            for relativePath in sources {
                guard let path = try? LampWritingWorkspaceLayout.contextPath(
                    folder: name, relativePath: relativePath
                ),
                observation.shows(path, atRevisionOf: records)
                else { continue }
                onTheServer.insert(relativePath)
            }
            found.append(
                Workspace(
                    writingID: writingID,
                    lastActivity: lastActivity(
                        ofWorkspaceAt: folder,
                        writingSaved: writings[writingID],
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

/// What a finished sync pass saw of the server: which store it was, what the
/// manifest counted as members, and what the listing of the workspaces'
/// context folders said each source's revision was.
///
/// **One value, from one place.** It used to be three — a listing on the
/// controller, a member set on the controller, and a copy for the pane —
/// and a review found them disagreeing about which server they described.
/// The gather writes it, labelled with the source its own store was built
/// from; nothing else does.
///
/// It is the only thing that has looked at the server. A record's
/// `installedRevision` is a memory of one upload that nothing refreshes, so
/// a source deleted from the sync folder by hand keeps it for ever; an
/// offload on that alone would delete the last copy (`decisions/0021`).
public struct ServerObservation: Equatable, Sendable {
    /// The store this came from, as the records name it.
    public let source: String
    /// Every path the manifest counted as a member.
    public let members: Set<String>
    /// What the listing of each source's folder said its revision was.
    public let revisions: [String: String]
    public let at: Date

    /// How long a look at the server answers for anything. A pass runs every
    /// few minutes while sync is on, so the sweep never reaches this; it
    /// bites where it should — a button pressed with sync off, or on a Mac
    /// that synced once days ago. A listing from last Tuesday has not seen
    /// the server today.
    public static let lifetime: TimeInterval = 15 * 60

    public init(
        source: String, members: Set<String>, revisions: [String: String], at: Date = Date()
    ) {
        self.source = source
        self.members = members
        self.revisions = revisions
        self.at = at
    }

    /// Whether this can answer for `source` now: the same server, and
    /// recently enough. Changing folders or turning sync off makes the last
    /// look worthless however recent it is, because Offload would delete
    /// against one server while Download fetched from another.
    public func answers(for source: String, now: Date = Date()) -> Bool {
        self.source == source && now.timeIntervalSince(at) < Self.lifetime
    }

    /// Whether the listing showed `path` at the revision this Mac recorded
    /// for it on this server.
    func shows(_ path: String, atRevisionOf records: LampSyncFileRecords) -> Bool {
        guard let installed = records.record(path, in: source)?.installedRevision,
              let listed = revisions[path]
        else { return false }
        return LampSyncConditionalWrite.namesSameRevision(listed, installed)
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

    public var digest: String { read.digest }

    fileprivate init(relativePath: String, file: URL, read: LampVerifiedFileRead) {
        self.relativePath = relativePath
        self.file = file
        self.read = read
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
        guard file.resolvingSymlinksInPath().path
                .hasPrefix(context.resolvingSymlinksInPath().path + "/"),
              let read = try? LampVerifiedFileRead.read(file)
        else { return nil }
        return VerifiedSource(relativePath: relativePath, file: file, read: read)
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
        /// A folder on disk. `holdsSourcesNotHere` when something under it
        /// is only on the server, or on its way: removing the folder deletes
        /// those everywhere too, and the row shows nothing of them.
        case folder(holdsSourcesNotHere: Bool)
        /// Let go to the server; not here.
        case onTheServer
        /// Asked back; not here yet.
        case comingBack
    }

    /// Where the source is under the context directory. What a row is
    /// called, too: two offloaded files named `history.pdf` in different
    /// folders are two different sources, and a reader deleting one from the
    /// server has to be able to tell which.
    public let relativePath: String
    public let state: State
    public let byteCount: Int?

    public var id: String { relativePath }
    public var isHere: Bool {
        switch state {
        case .here, .folder: true
        case .onTheServer, .comingBack: false
        }
    }
    /// Whether Remove deletes something with no copy on this Mac, which it
    /// asks about first.
    public var removesWhatIsNotHere: Bool {
        switch state {
        case .onTheServer, .comingBack, .folder(holdsSourcesNotHere: true): true
        case .here, .folder(holdsSourcesNotHere: false): false
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

        public init(name: String, isDirectory: Bool, byteCount: Int?) {
            self.name = name
            self.isDirectory = isDirectory
            self.byteCount = byteCount
        }
    }

    /// The table: every row, from what is on disk and what is not here.
    ///
    /// Compared in NFC, as the ledger's keys are — macOS hands back a name
    /// with a combining mark decomposed, and a source would otherwise be
    /// drawn twice, once as itself and once as "On the server".
    public static func rows(
        onDisk: [DiskEntry], notHere: [String: WorkspaceSourceAct]
    ) -> [SourceRow] {
        let notHere = Dictionary(
            notHere.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [SourceRow] = []
        var shown: Set<String> = []
        for entry in onDisk {
            let path = entry.name.precomposedStringWithCanonicalMapping
            shown.insert(path)
            if entry.isDirectory {
                let holds = notHere.keys.contains { $0.hasPrefix(path + "/") }
                rows.append(SourceRow(relativePath: path, state: .folder(holdsSourcesNotHere: holds)))
            } else {
                rows.append(SourceRow(relativePath: path, state: .here, byteCount: entry.byteCount))
            }
        }
        for (path, act) in notHere where !shown.contains(path) {
            rows.append(SourceRow(
                relativePath: path, state: act == .offloaded ? .onTheServer : .comingBack
            ))
        }
        return rows.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    /// The rows for one workspace, read now.
    @WritingWorkspaceFiles
    public static func rows(
        inWorkspaceAt workspace: URL, fileManager: FileManager = .default
    ) -> [SourceRow] {
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let entries = ((try? fileManager.contentsOfDirectory(
            at: context, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []).map { url -> DiskEntry in
            let values = try? url.resourceValues(forKeys: keys)
            return DiskEntry(
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory == true,
                byteCount: values?.fileSize
            )
        }
        return rows(
            onDisk: entries,
            notHere: LampWorkspaceSync.sourcesNotHere(in: workspace, fileManager: fileManager)
        )
    }
}
