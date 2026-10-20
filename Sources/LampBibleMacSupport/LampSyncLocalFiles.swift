import Foundation
import LampCore
import LampModuleKit

/// One local file as a sync pass sees it: where it belongs on the server,
/// where its bytes are now, and what they hash to.
///
/// Always a file on disk rather than bytes in hand. A pass publishes with
/// `write(fileAt:to:condition:)` and digests through a mapping, so nothing
/// here holds a module body in memory — which is what stops a library-sized
/// pass from being killed for it.
public struct LampSyncLocalFile: Equatable, Sendable {
    public let path: String
    public let kind: LampSyncFileKind
    public let url: URL
    public let digest: String

    public init(
        path: String,
        kind: LampSyncFileKind,
        url: URL,
        digest: String
    ) {
        self.path = path
        self.kind = kind
        self.url = url
        self.digest = digest
    }
}

/// Gathers what this Mac holds, in the form `LampSyncFilePlan.plan` reads.
///
/// A pass asks the library what it has, turns each thing into a remote path,
/// and hands the plan a digest per path. The plan then decides; nothing here
/// decides anything.
public enum LampSyncLocalFiles {
    /// A file to describe: its remote path, what kind of thing it is, and
    /// where its bytes are.
    public struct Candidate: Equatable, Sendable {
        public let path: String
        public let kind: LampSyncFileKind
        public let url: URL

        public init(path: String, kind: LampSyncFileKind, url: URL) {
            self.path = path
            self.kind = kind
            self.url = url
        }
    }

    /// Where a candidate's bytes turned out not to be readable. A pass reports
    /// these rather than silently publishing a shorter library.
    public struct Unreadable: Equatable, Sendable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public struct Described: Equatable, Sendable {
        public var files: [LampSyncLocalFile] = []
        public var unreadable: [Unreadable] = []
    }

    /// Digests each candidate, every pass, by reading its file.
    ///
    /// Deliberately not skipped by comparing size and modification date with
    /// what was recorded last time. SHA-256 over a whole library costs well
    /// under a second here, while a file replaced at the same size with its
    /// date preserved — a restore, `cp -p`, `rsync -t` — would be skipped and
    /// never uploaded again. A cheap shortcut that loses a file is a bad
    /// trade, and mtime is not how this project compares content.
    public static func describe(
        _ candidates: [Candidate],
        fileManager: FileManager = .default
    ) -> Described {
        var described = Described()
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate.url.path),
                  let digest = try? LampSyncContentRevision.digest(forFileAt: candidate.url)
            else {
                described.unreadable.append(
                    Unreadable(path: candidate.path, reason: "its file could not be read")
                )
                continue
            }
            described.files.append(LampSyncLocalFile(
                path: candidate.path,
                kind: candidate.kind,
                url: candidate.url,
                digest: digest
            ))
        }
        return described
    }

    /// The installed modules a library publishes, each at its kind's folder
    /// under its module ID.
    ///
    /// The stem must be the module's own ID: the phone inspects a downloaded
    /// module and refuses one whose identity disagrees with its filename, so
    /// publishing the library's storage-key filenames would fail every import
    /// rather than merely look untidy. `LampInstalledModuleFile.syncPath()`
    /// is what both clients name it by.
    ///
    /// What the library bundles is not included, because
    /// `LampLibrary.installedModuleFiles()` reads only installed databases.
    /// Membership covers the user's own content; what an app ships sits
    /// outside it, and every client already has its own copy. Publishing a
    /// bundled module would land it on the other client as a second,
    /// user-installed copy beside the one already inside its app.
    public static func installedModules(
        _ modules: [LampInstalledModuleFile]
    ) -> (candidates: [Candidate], unplaceable: [Unreadable]) {
        var candidates: [Candidate] = []
        var unplaceable: [Unreadable] = []
        for module in modules {
            do {
                candidates.append(Candidate(
                    path: try module.syncPath(),
                    kind: .module(LampSyncContentKind(module.module.kind)),
                    url: module.fileURL
                ))
            } catch {
                // A module ID that cannot be spelled as a path — one holding a
                // slash, say — is reported rather than published somewhere
                // else or silently dropped.
                unplaceable.append(Unreadable(
                    path: "\(module.module.kind.rawValue)/\(module.module.id)",
                    reason: error.localizedDescription
                ))
            }
        }
        return (candidates, unplaceable)
    }

    /// The three editable collections, which this Mac exports fresh each pass
    /// and publishes under the IDs the phone uses.
    ///
    /// Notes and writings are rewritten by
    /// `LampWebDAVPersonalArchiveAdapter` on the way out, so the bytes
    /// published are the adapter's and the digest is taken over those — the
    /// phone's format is the canonical one. Highlights are compiled per set,
    /// each under the module ID this source has recorded for that set.
    public static func personalModuleCandidate(
        remoteModuleID: String,
        kind: LampSyncContentKind,
        at url: URL
    ) throws -> Candidate {
        Candidate(
            path: try LampSyncFolderLayout.modulePath(kind: kind, moduleID: remoteModuleID),
            kind: .module(kind),
            url: url
        )
    }

    /// The images and files the writings embed.
    ///
    /// Immutable at a path: a different body gets a different name, so these
    /// are never merged and are written only where absent. Published before
    /// the module that names them, so a writing arriving on another device
    /// finds its attachments already there.
    ///
    /// A writing whose attachment the library does not hold is **reported,
    /// not withheld**. Every writing shares one module file, so withholding
    /// would stop them all over one missing image; and the gap heals by
    /// itself, because an immutable path is a predictable one — if the file
    /// comes back, a later pass writes it there with `.ifAbsent` and every
    /// device's reference resolves. A writing that references a file the
    /// library has lost is the library's own state, and sync reproducing it
    /// is not sync worsening it.
    ///
    /// Collected one writing at a time so a single bad one cannot hide the
    /// attachments of the rest.
    public static func devotionalMedia(
        for devotionals: [LampDevotional],
        remoteModuleID: String,
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> (candidates: [Candidate], missing: [Unreadable]) {
        var candidates: [Candidate] = []
        var missing: [Unreadable] = []
        for devotional in devotionals {
            do {
                candidates.append(contentsOf: try LampSyncDevotionalMedia.outgoingFileURLs(
                    for: [devotional], to: remoteModuleID, from: libraryRoot,
                    fileManager: fileManager
                ).map {
                    Candidate(path: $0.remotePath, kind: .devotionalMedia, url: $0.localURL)
                })
            } catch LampSyncDevotionalMedia.UploadError.invalidLocalFile(let path) {
                // Keyed by the attachment's own remote path, which the error
                // carries, so `unresolved` can ask the manifest about it.
                missing.append(Unreadable(
                    path: path,
                    reason: "“\(name(of: devotional))” refers to a file the library does not hold"
                ))
            } catch {
                // An attachment whose name cannot be a path, say. No remote
                // path to ask the manifest about, so it is always reported.
                missing.append(Unreadable(
                    path: name(of: devotional), reason: error.localizedDescription
                ))
            }
        }
        return (candidates, missing)
    }

    private static func name(of devotional: LampDevotional) -> String {
        devotional.title.isEmpty ? devotional.id : devotional.title
    }

    /// The reported gaps worth telling someone about: the ones the manifest
    /// does not already name as members.
    ///
    /// A file absent here but present on the server needs nothing from this
    /// device and resolves everywhere, so saying so would be noise. One in
    /// neither place is a reference nothing will supply until the file comes
    /// back, which is worth knowing. Read from the manifest, never probed.
    public static func unresolved(
        _ missing: [Unreadable],
        candidates: [Candidate],
        manifest: LampSyncLibraryManifest
    ) -> [Unreadable] {
        let onServer = Set(manifest.members.map(\.path))
        let gathered = Set(candidates.map(\.path))
        return missing.filter { gap in
            !onServer.contains(gap.path) && !gathered.contains(gap.path)
        }
    }

    /// The files in the Mac's agent workspaces.
    ///
    /// Not enumerated from the library directly, because the published shape
    /// is not the stored one: `AgentWorkspaces/Devotionals/<ws>/outline.md`
    /// becomes `Workspaces/Devotionals/<ws>/Documents/outline.md`, with
    /// context, enabled skills, revisions and conversations each moved and
    /// some of them transformed. That mapping has one home — the exporter —
    /// and reimplementing it here as path arithmetic would be a second copy
    /// to drift.
    ///
    /// So the real exporter runs into a scratch directory and what it wrote
    /// is enumerated. Its top folder is already `Workspaces`, so each
    /// relative path *is* the remote path. Workspace documents are small text
    /// files, so the copy is cheap in a way a module would not be.
    ///
    /// Decks and their images come out of the same exporter, since it calls
    /// the deck export too, and are skipped here: they are their own kinds,
    /// enumerated from the library. The deck deletion ledger is skipped for
    /// the same reason it is everywhere — it travels in the bundle. Both fall
    /// out of asking the layout what each path is, rather than being listed
    /// by hand.
    public static func workspaceFiles(
        inLibraryAt libraryRoot: URL,
        stagingIn scratch: URL,
        fileManager: FileManager = .default
    ) throws -> [Candidate] {
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: libraryRoot, to: scratch, fileManager: fileManager
        )
        let root = scratch.appendingPathComponent(
            LampPortableBackupLayout.workspacesDirectory, isDirectory: true
        )
        return tree(under: root, fileManager: fileManager).compactMap { relative, url in
            let path = "\(LampPortableBackupLayout.workspacesDirectory)/\(relative)"
            guard LampSyncFolderLayout.kind(of: path) == .workspaceFile else { return nil }
            return Candidate(path: path, kind: .workspaceFile, url: url)
        }
    }

    /// The pictures a book shows.
    ///
    /// These are not inside the `.lamp`: a book module's `media_json` holds
    /// only each file's metadata, so the files under the library's media
    /// folders are the library's **only** copy. A device that ignores them
    /// shows those books with their pictures missing.
    ///
    /// Gathered from every root `BookReaderMediaResolver` reads, in its own
    /// order of precedence, so what is published is what the reader would
    /// show. A relative path found in an earlier root wins, as it does there.
    /// Only for the module IDs passed in — books in the library, or ones the
    /// manifest already names — which is what keeps a picture belonging to
    /// something else from going up as a book's.
    ///
    /// Immutable at a path, like the files a writing embeds.
    public static func bookMedia(
        forBookModuleIDs moduleIDs: Set<String>,
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> (candidates: [Candidate], unplaceable: [Unreadable]) {
        var candidates: [Candidate] = []
        var unplaceable: [Unreadable] = []
        for moduleID in moduleIDs.sorted() {
            var taken = Set<String>()
            for root in bookMediaRoots(for: moduleID, inLibraryAt: libraryRoot) {
                for (relative, url) in tree(under: root, fileManager: fileManager) {
                    guard taken.insert(relative).inserted else { continue }
                    do {
                        candidates.append(Candidate(
                            path: try LampSyncFolderLayout.bookMediaPath(
                                moduleID: moduleID, path: relative
                            ),
                            kind: .bookMedia,
                            url: url
                        ))
                    } catch {
                        unplaceable.append(Unreadable(
                            path: "\(moduleID)/\(relative)",
                            reason: error.localizedDescription
                        ))
                    }
                }
            }
        }
        return (candidates, unplaceable)
    }

    /// Where a book's pictures may be, in the order the reader looks.
    /// `Media/Books/<id>` is the one a sync writes to, and the others are
    /// layouts libraries already have.
    public static func bookMediaRoots(
        for moduleID: String,
        inLibraryAt libraryRoot: URL
    ) -> [URL] {
        [
            "Media/Modules/\(moduleID)",
            "Media/Books/\(moduleID)",
            "Media/\(moduleID)",
            "Modules/\(moduleID)/media",
        ].map { libraryRoot.appendingPathComponent($0, isDirectory: true) }
    }

    /// Where a sync installs a book's picture: the root the reader checks
    /// second, and the only one a sync writes.
    public static func bookMediaInstallRoot(
        for moduleID: String,
        inLibraryAt libraryRoot: URL
    ) -> URL {
        libraryRoot.appendingPathComponent("Media/Books/\(moduleID)", isDirectory: true)
    }

    /// Every regular file under a directory, by its path relative to it.
    /// Links are skipped, here as everywhere: what one points at is not this
    /// library's to publish.
    private static func tree(
        under root: URL,
        fileManager: FileManager
    ) -> [(relative: String, url: URL)] {
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefix = root.standardizedFileURL.path + "/"
        var found: [(String, URL)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            found.append((String(path.dropFirst(prefix.count)), url))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// The decks and the images they show, from a library root.
    ///
    /// Decks are the `.lampdeck` files directly in the presentations folder,
    /// each published under its own ID. The deletion ledger lives in that
    /// same folder and is deliberately not among them: it is a ledger, which
    /// travels in the settings bundle under read-merge-retry, and published
    /// as a file it would be *won* rather than merged — two Macs deleting
    /// different decks would overwrite each other's record and a deleted deck
    /// would come back. `LampSyncFolderLayout.kind(of:)` returns nil for it
    /// for the same reason.
    ///
    /// Images are the regular files directly in the assets folder, under the
    /// generated names decks refer to them by, so they are immutable at a
    /// path: never merged, written only where absent.
    ///
    /// A symbolic link is skipped in both: what it points at is not this
    /// library's to publish.
    public static func decks(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> (candidates: [Candidate], unplaceable: [Unreadable]) {
        let store = LampPresentationDeckStore(rootURL: libraryRoot)
        var candidates: [Candidate] = []
        var unplaceable: [Unreadable] = []

        for url in plainFiles(in: store.decksDirectoryURL, fileManager: fileManager)
        where url.pathExtension.lowercased() == LampSyncFolderLayout.deckExtension {
            let deckID = url.deletingPathExtension().lastPathComponent
            do {
                candidates.append(Candidate(
                    path: try LampSyncFolderLayout.deckPath(deckID: deckID),
                    kind: .deck,
                    url: url
                ))
            } catch {
                unplaceable.append(Unreadable(
                    path: deckID, reason: error.localizedDescription
                ))
            }
        }

        for url in plainFiles(in: store.assetsDirectoryURL, fileManager: fileManager) {
            do {
                candidates.append(Candidate(
                    path: try LampSyncFolderLayout.deckAssetPath(filename: url.lastPathComponent),
                    kind: .deckAsset,
                    url: url
                ))
            } catch {
                unplaceable.append(Unreadable(
                    path: url.lastPathComponent, reason: error.localizedDescription
                ))
            }
        }
        return (candidates, unplaceable)
    }

    /// Regular files directly inside a directory, links and subdirectories
    /// left out. A missing directory is simply empty.
    private static func plainFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return contents.filter { url in
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Each described file in the form the plan reads, with `savedAt` looked
    /// up per path — a module file has no save time of its own, so a caller
    /// with nothing better passes nil and lets the manifest's own times rule.
    public static func locals(
        _ files: [LampSyncLocalFile],
        records: LampSyncFileRecords,
        source: String,
        savedAt: (String) -> Int64? = { _ in nil }
    ) -> [LampSyncFilePlan.Local] {
        files.map {
            records.local($0.path, in: source, digest: $0.digest, savedAt: savedAt($0.path))
        }
    }
}
