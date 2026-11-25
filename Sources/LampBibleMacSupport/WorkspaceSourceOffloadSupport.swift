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
    /// How long a source asked back is left alone for, whatever the writing's
    /// dates say. A week: long enough to read what you fetched, short enough
    /// that a source fetched and forgotten goes back on its own.
    static let fetchGrace: TimeInterval = 7 * 24 * 60 * 60

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
    /// `seen` is what the pass that just finished saw when it listed those
    /// folders. A source confirmed during *that* pass is not in it — the
    /// listing is taken at the gather, before the uploads — so it waits one
    /// more pass, which is the safe direction.
    @WritingWorkspaceFiles
    public static func workspaces(
        inLibraryAt libraryRootURL: URL,
        writings: [String: Date],
        source: String,
        seen: [String: String],
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
            // Left alone for a while after being asked for: see
            // `recentlyFetchedSources`.
            let justFetched = LampWorkspaceSync.recentlyFetchedSources(
                in: folder, since: Date().addingTimeInterval(-Self.fetchGrace)
            )
            let sources = contextRelativePaths(in: folder, fileManager: fileManager)
                .filter { !justFetched.contains($0) }
            var onTheServer: Set<String> = []
            for relativePath in sources {
                guard let path = try? LampWritingWorkspaceLayout.contextPath(
                    folder: name, relativePath: relativePath
                ) else { continue }
                guard let installed = records.record(path, in: source)?.installedRevision,
                      let listed = seen[path],
                      LampSyncConditionalWrite.namesSameRevision(listed, installed)
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
