import Foundation
import LampCore
import LampModuleKit

/// What this Mac has to publish that no ledger records.
///
/// `LampLibrary.personalChangeStamp()` answers for everything written through
/// the personal and plan ledgers: a note, a writing, a highlight, a plan
/// followed, a reading ticked. Nothing records a module arriving or going, a
/// deck being saved, or a workspace document being edited — those are files,
/// and the library's record of them *is* the files. So they are read off the
/// filesystem, and a pass follows when the answer differs from the one taken
/// when the last pass started. Without this a plan deleted here, or a module
/// installed here, sat on this Mac until somebody pressed Sync.
///
/// The marks are compared as a whole and for difference, never ordered
/// against each other. A sync installs another device's files with their
/// modification dates intact, so a file written by a Mac whose clock ran fast
/// is dated in the future, and "the newest date in the library" would then
/// sit above everything that happened after it — every later change
/// invisible. A set keyed by path has no such horizon: a date going
/// backwards is a difference like any other.
///
/// Cheap on purpose, because it is asked every few seconds: two directory
/// stats, one file stat, and a walk of the decks, the skills and each
/// workspace's own files. Nothing is opened, read or hashed.
public enum LampSyncLocalWork {
    /// Directories whose *membership* is the change. A module is installed
    /// and removed as whole files, so the directory's own date moves and the
    /// files inside it need not be listed: a library of two hundred modules
    /// is two stats here.
    ///
    /// The media folders are not among them. A book's pictures arrive with
    /// the book and a writing's attachments with the writing, so a change to
    /// either is already answered for — by this list, or by the personal
    /// ledger.
    private static let membershipDirectories = ["Modules", "Databases"]

    /// Marks for everything this Mac publishes outside the ledgers, keyed by
    /// where it is. Each value is a modification time in milliseconds, and
    /// means nothing on its own: only the set, against the set taken when the
    /// last pass started.
    public static func marks(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> [String: Int64] {
        let root = libraryRoot.standardizedFileURL
        var marks: [String: Int64] = [:]

        for name in membershipDirectories {
            if let time = modified(root.appendingPathComponent(name, isDirectory: true)) {
                marks[name] = time
            }
        }

        // Modules removed here. Nothing else records them — a note, a writing
        // and a highlight set each leave a trace in the personal ledger as
        // they go, and a deck in its own, but removing a module leaves none —
        // so this file is the only sign a removal happened, and the pass that
        // carries it reads the very same file.
        if let time = modified(LampSyncRemovedModules.url(inLibraryAt: root)) {
            marks[LampSyncRemovedModules.filename] = time
        }

        // The decks themselves, listed rather than walked: a deck is edited
        // in place, while the images it shows are in a folder of their own
        // and are immutable at a path — an image is written where it is
        // absent and never again, so a changed one is nothing this Mac could
        // publish, and the folder's own date is all that could matter.
        //
        // Not the record of the decks deleted. It is a ledger: it travels in
        // the settings bundle, and a pass applying another device's copy
        // writes it here. Counted, every pass would leave work behind for the
        // next one to find, and this Mac would sync every six seconds for as
        // long as it was open — the same trap as a workspace's bookkeeping,
        // and this one needed only one deck deleted anywhere to spring. There
        // is nothing to lose by leaving it out: deleting a deck here removes
        // the deck's own file, which is read.
        let decks = LampPresentationDeckStore(rootURL: root).decksDirectoryURL
        for (path, time) in list(decks, from: root, fileManager: fileManager)
        where !path.hasSuffix(LampPresentationDeckSync.deletionsFilename) {
            marks[path] = time
        }
        if let time = modified(decks.appendingPathComponent(
            LampPresentationDeckStore.assetsDirectoryName, isDirectory: true
        )) {
            marks[key(for: decks, from: root).map { "\($0)/\(LampPresentationDeckStore.assetsDirectoryName)" }
                ?? LampPresentationDeckStore.assetsDirectoryName] = time
        }

        // The custom skills, which sync as one catalog for every workspace.
        // Walked, since a skill is a small folder of files somebody edits.
        marks.merge(
            walk(WorkspaceSkillStore.catalogDirectory(in: root), from: root, fileManager: fileManager)
        ) { first, _ in first }

        // Each workspace's own files, by the same reading the export takes:
        // the documents a person wrote and the context they gathered. Not the
        // bookkeeping a pass writes beside them — the file ledger, the
        // compacted revisions — because a pass writing those would leave work
        // behind for the next pass to find, and the two would chase each
        // other for as long as the app was open.
        for workspace in (try? LampWorkspaceSync.workspaces(in: root, fileManager: fileManager)) ?? [] {
            let files = (try? LampWorkspaceSync.workspaceFiles(
                in: workspace, fileManager: fileManager
            )) ?? [:]
            for (key, file) in files {
                marks["\(LampWorkspaceSync.portableDirectoryName)/\(workspace.lastPathComponent)/\(key)"] =
                    file.modified
            }
        }

        return marks
    }

    /// The files directly in a folder, keyed by their path within the
    /// library. No descent: a caller that wants the whole tree walks it.
    private static func list(
        _ directory: URL,
        from root: URL,
        fileManager: FileManager
    ) -> [String: Int64] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: []
        ) else { return [:] }
        var marks: [String: Int64] = [:]
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]), values.isRegularFile == true, values.isSymbolicLink != true,
                  let date = values.contentModificationDate,
                  let key = key(for: url, from: root) else { continue }
            marks[key] = Int64(date.timeIntervalSince1970 * 1_000)
        }
        return marks
    }

    /// Where something is, as the library would say it: the path inside the
    /// library root, or nil for anything that is not inside it.
    private static func key(for url: URL, from root: URL) -> String? {
        let prefix = root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Every file under `root`, keyed by its path within the library. Only
    /// files: a deck deleted takes its key with it, and one added brings its
    /// own, so the folders' own dates would say nothing these do not.
    ///
    /// Hidden files are included. A workspace keeps some of what it syncs
    /// inside `.lamp`, and a tree that skipped them would call a library
    /// unchanged when it was not.
    private static func walk(
        _ tree: URL,
        from root: URL,
        fileManager: FileManager
    ) -> [String: Int64] {
        var marks: [String: Int64] = [:]
        guard let walker = fileManager.enumerator(
            at: tree,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: []
        ) else { return marks }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]) else { continue }
            // A link is skipped here as it is everywhere else: what it points
            // at is not this library's to publish, and following one could
            // walk out of the library altogether.
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  let date = values.contentModificationDate,
                  let key = key(for: url, from: root) else { continue }
            marks[key] = Int64(date.timeIntervalSince1970 * 1_000)
        }
        return marks
    }

    private static func modified(_ url: URL) -> Int64? {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return nil }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}
