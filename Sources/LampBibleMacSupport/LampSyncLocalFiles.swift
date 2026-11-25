import Foundation
import LampCore
import LampModuleKit

/// Where this Mac keeps the things it publishes.
///
/// The generic half — the `LampSyncLocalFile` value, `describe` and `locals` —
/// lives in `LampModuleKit` beside the pass engine, because every client
/// needs it. This is the half that knows a *Mac* library: its installed
/// modules, its editable collections, the files a writing embeds, the
/// pictures a book shows, its decks and its workspaces.
///
/// That seam is where the differences between the apps actually are, and
/// where this afternoon's bugs were.
extension LampSyncLocalFiles {
    public static func installedModules(
        _ modules: [LampInstalledModuleFile]
    ) -> (candidates: [Candidate], unplaceable: [Unreadable]) {
        var candidates: [Candidate] = []
        var unplaceable: [Unreadable] = []
        for module in modules {
            do {
                let path = try module.syncPath()
                // An installed module whose ID is a collection's, `notes` or
                // `writing`, would be published at the path every note or
                // every writing is published at, in their place. It stays on
                // this Mac, and is said so, rather than hide the collection.
                guard LampSyncLocalDeletion.target(of: path) != .collection else {
                    unplaceable.append(Unreadable(
                        path: path,
                        reason: "Its ID, “\(module.module.id)”, is the one Lamp Bible publishes every note or writing under, so it is kept on this Mac rather than published."
                    ))
                    continue
                }
                candidates.append(Candidate(
                    path: path,
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
    /// Notes and writings are exported under the published ID
    /// (`LampSyncMacPassLibrary.remoteNotesModuleID`, `remoteWritingModuleID`),
    /// and the digest is taken over those bytes. Highlights are compiled per set,
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
    /// Whether a `NoteMedia/...` path belongs to a notes **module** rather
    /// than to one of the reader's own notes. Three segments to the module's
    /// own folder, four to a verse's.
    public static func isNoteModuleMedia(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).count == 3
    }

    /// The pictures installed notes modules hold, to publish.
    ///
    /// A module's pictures are not inside its `.lamp`, so this library's
    /// copy is the only one, and a library without them shows the notes
    /// with their pictures missing. One module at a time, so a module whose
    /// files have gone cannot hide another's.
    public static func noteModuleMedia(
        for modules: [(moduleID: String, filenames: [String])],
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> (candidates: [Candidate], missing: [Unreadable]) {
        var candidates: [Candidate] = []
        var missing: [Unreadable] = []
        for module in modules {
            for filename in module.filenames {
                guard let localURL = LampPortableDevotionalMedia.folderURL(
                    rootURL: libraryRoot, scope: .note,
                    ownerID: LampLibrary.noteModuleMediaOwnerID(module.moduleID)
                )?.appendingPathComponent(filename),
                    let path = try? LampSyncFolderLayout.noteModuleMediaPath(
                        moduleID: module.moduleID, filename: filename
                    )
                else { continue }
                guard fileManager.fileExists(atPath: localURL.path),
                      let values = try? localURL.resourceValues(
                          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true
                else {
                    missing.append(Unreadable(
                        path: path,
                        reason: "A note in \(module.moduleID) refers to a picture "
                            + "the library does not hold"
                    ))
                    continue
                }
                candidates.append(Candidate(path: path, kind: .noteMedia, url: localURL))
            }
        }
        return (candidates, missing)
    }

    /// The pictures the reader's notes hold, to publish.
    ///
    /// One note at a time, as writings are, so a single note referring to a
    /// file the library has lost cannot hide every other note's pictures.
    /// - Parameter members: as `devotionalMedia`.
    public static func noteMedia(
        for notes: [LampVerseNote],
        remoteModuleID: String,
        inLibraryAt libraryRoot: URL,
        members: Set<String> = [],
        fileManager: FileManager = .default
    ) -> (candidates: [Candidate], missing: [Unreadable]) {
        var candidates: [Candidate] = []
        var missing: [Unreadable] = []
        for note in notes {
            let owner = LampSyncDevotionalMedia.Owner(
                id: LampLibrary.noteMediaOwnerID(note.reference), mediaJSON: note.mediaJSON
            )
            do {
                candidates.append(contentsOf: try LampSyncDevotionalMedia.outgoingFileURLs(
                    scope: .note, owners: [owner], to: remoteModuleID,
                    from: libraryRoot, fileManager: fileManager
                ).map {
                    Candidate(path: $0.remotePath, kind: .noteMedia, url: $0.localURL)
                })
            } catch LampSyncDevotionalMedia.UploadError.invalidLocalFile(let path) {
                missing.append(Unreadable(
                    path: path,
                    reason: "A note on "
                        + LampPersonalMarkdownWriter.noteHeading(reference: note.reference)
                        + " refers to a file the library does not hold"
                ))
            } catch {
                missing.append(Unreadable(
                    path: LampSyncFolderLayout.noteMediaDirectory + "/" + owner.id,
                    reason: error.localizedDescription
                ))
            }
        }
        candidates += mediaOnDisk(
            scope: .note, kind: .noteMedia, remoteModuleID: remoteModuleID,
            inLibraryAt: libraryRoot, members: members,
            alreadyProduced: Set(candidates.map(\.path)), fileManager: fileManager
        )
        return (candidates, missing)
    }

    /// The media files this library has on disk for one scope, as candidates.
    ///
    /// Unioned into what the owners refer to, because the two answer
    /// different questions: the owners say what *should* be published, and
    /// this says what is *here*. A picture whose writing or note the library
    /// no longer has is still a file at the member's path — and since nothing
    /// lists media, a media member with no local copy is fetched on every
    /// pass, unconditionally, and written where it already was. Five were
    /// doing exactly that (`../ScalabilityPlan.md`, the audible-detector
    /// faults).
    ///
    /// Already-produced paths win, so a file an owner refers to keeps the
    /// candidate the owner produced and nothing is claimed twice.
    private static func mediaOnDisk(
        scope: LampMediaScope,
        kind: LampSyncFileKind,
        remoteModuleID: String,
        inLibraryAt libraryRoot: URL,
        members: Set<String>,
        alreadyProduced: Set<String>,
        fileManager: FileManager
    ) -> [Candidate] {
        LampSyncDevotionalMedia.filesOnDisk(
            scope: scope, moduleID: remoteModuleID, satisfying: members,
            in: libraryRoot, fileManager: fileManager
        )
        .filter { !alreadyProduced.contains($0.remotePath) }
        .map { Candidate(path: $0.remotePath, kind: kind, url: $0.localURL) }
    }

    /// - Parameter members: the media paths the manifest already names.
    ///   Disk discovery may only say "that member is here"; a file at a path
    ///   nobody names would be *uploaded*, and a writing deleted before its
    ///   first sync leaves its pictures on disk.
    public static func devotionalMedia(
        for devotionals: [LampDevotional],
        remoteModuleID: String,
        inLibraryAt libraryRoot: URL,
        members: Set<String> = [],
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
        candidates += mediaOnDisk(
            scope: .devotional, kind: .devotionalMedia, remoteModuleID: remoteModuleID,
            inLibraryAt: libraryRoot, members: members,
            alreadyProduced: Set(candidates.map(\.path)), fileManager: fileManager
        )
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
    /// is not the stored one: `AgentWorkspaces/Writing/<ws>/outline.md`
    /// becomes `Workspaces/Writing/<ws>/Documents/outline.md`, with
    /// context, enabled skills, revisions and conversations each moved and
    /// some of them transformed. That mapping has one home — the exporter —
    /// and reimplementing it here as path arithmetic would be a second copy
    /// to drift.
    ///
    /// So the real exporter runs and says what it placed and where each file
    /// came from (`LampWorkspaceSync.WorkspaceExportRecord`). Its top folder
    /// is already `Workspaces`, so each relative path *is* the remote path.
    ///
    /// It used to copy every file into the scratch directory and enumerate
    /// what it had written — 2.9 s at two hundred and fifty workspaces,
    /// which made it the largest thing a pass did. Nothing is copied now
    /// except the documents, whose digest a later pass judges an edit by, and
    /// the transcripts and ledgers, whose bytes exist nowhere else.
    ///
    /// Decks and their images come out of the same exporter, since it calls
    /// the deck export too, and are skipped here: they are their own kinds,
    /// enumerated from the library. The deck deletion ledger is skipped for
    /// the same reason it is everywhere — it travels in the bundle. Both fall
    /// out of asking the layout what each path is, rather than being listed
    /// by hand.
    /// On `WritingWorkspaceFiles`: this exports the live library into the
    /// scratch directory, so it reads workspaces a pane may be writing.
    @WritingWorkspaceFiles
    public static func workspaceFiles(
        inLibraryAt libraryRoot: URL,
        stagingIn scratch: URL,
        fileManager: FileManager = .default
    ) throws -> [Candidate] {
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let record = LampWorkspaceSync.WorkspaceExportRecord()
        try LampWorkspaceSync.exportPortableWorkspaces(
            from: libraryRoot, to: scratch, writingFolder: .perFile,
            recording: record, fileManager: fileManager
        )
        return record.placed.compactMap { path, url, isFixedAtItsPath in
            switch LampSyncFolderLayout.kind(of: path) {
            case .workspaceFile:
                return Candidate(
                    path: path, kind: .workspaceFile, url: url,
                    isFixedAtItsPath: isFixedAtItsPath
                )
            case .writingDocument:
                // Published under its name in NFC, as the phone names it: a
                // name macOS hands back decomposed is the same document.
                guard let document = LampWritingWorkspaceLayout.document(ofPath: path),
                      let published = try? LampWritingWorkspaceLayout.documentPath(
                          folder: document.folder, name: document.name
                      ) else { return nil }
                return Candidate(
                    path: published, kind: .writingDocument, url: url,
                    isFixedAtItsPath: isFixedAtItsPath
                )
            default:
                return nil
            }
        }
    }

    /// The pictures a pass publishes for this library's books and any the
    /// server already holds pictures for, by core's rules: an ID this Mac
    /// also holds as another kind of module gives up only the pictures in
    /// `Media/Books/<id>`, which no other kind of module writes to.
    public static func bookMedia(
        books: Set<String>,
        otherModules: Set<String>,
        remotePaths: [String],
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> (candidates: [Candidate], unplaceable: [Unreadable]) {
        let found = LampBookMediaFiles.outgoing(
            books: books, otherModules: otherModules, remotePaths: remotePaths,
            folders: { LampBookMediaFiles.libraryFolders(libraryRootURL: libraryRoot, moduleID: $0) },
            fileManager: fileManager
        )
        return (
            found.files.map { Candidate(path: $0.remotePath, kind: .bookMedia, url: $0.url) },
            found.unplaceable.map { Unreadable(path: $0.path, reason: $0.reason) }
        )
    }

    /// The pictures a book shows, as this library keeps them.
    ///
    /// The rules are core's (`LampBookMediaFiles`): which files are a book's,
    /// in the reader's order of folders, and only for the books named — the
    /// books in the library, or ones the manifest already names. These are
    /// a library's only copy, since a book's module holds only their
    /// metadata. Immutable at a path, like the files a writing embeds.
    public static func bookMedia(
        forBookModuleIDs moduleIDs: Set<String>,
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> (candidates: [Candidate], unplaceable: [Unreadable]) {
        let found = LampBookMediaFiles.outgoing(forBookModuleIDs: moduleIDs, fileManager: fileManager) {
            LampBookMediaFiles.libraryFolders(libraryRootURL: libraryRoot, moduleID: $0)
        }
        return (
            found.files.map { Candidate(path: $0.remotePath, kind: .bookMedia, url: $0.url) },
            found.unplaceable.map { Unreadable(path: $0.path, reason: $0.reason) }
        )
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

    /// Each writing's review marks, one file each, kept at the path the
    /// server keeps them at under the library. A file whose name is not a
    /// review's is left out, as the server would leave it out of a listing.
    public static func writingReviews(
        inLibraryAt libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> [Candidate] {
        // The paths are core's (`LampWritingReviewStore.paths`), which
        // the phone sends from too: a record is sent under the path the
        // layout makes for it, never under the name a file happens to
        // have in the folder.
        let store = LampWritingReviewStore(rootURL: libraryRoot)
        return ((try? store.paths()) ?? []).compactMap { path in
            let url = libraryRoot.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return Candidate(path: path, kind: .writingReview, url: url)
        }
    }

    /// The server's revision for each file the manifest names but no folder
    /// listing reaches — media, workspace files, writing documents — by
    /// listing their folders rather than asking after each file.
    ///
    /// These used to be asked for one at a time, which is one request per
    /// revision file, context file, transcript and picture, sequentially, on
    /// every pass: some fourteen thousand of them at two hundred and fifty
    /// workspaces. A folder's listing answers for everything in it at once,
    /// and on WebDAV it carries the same ETag a request for the file would
    /// have returned, so what the plan is given does not change.
    ///
    /// Where a listing carries no revision — the folder provider's does not
    /// — the file is asked after as before, but only when the listing shows
    /// it is there at all. A member that is absent used to cost a request
    /// that came back with nothing; now it costs none.
    ///
    /// A folder that cannot be listed falls back to asking after each of its
    /// members, so a server that refuses a listing behaves as it did.
    public static func revisionsOfUnlistedMembers(
        _ paths: [String], from store: any LampSyncRemoteStore
    ) async -> [String: String] {
        var byDirectory: [String: [String]] = [:]
        for path in paths {
            let directory = path.contains("/")
                ? String(path[path.startIndex..<path.lastIndex(of: "/")!])
                : ""
            byDirectory[directory, default: []].append(path)
        }
        var revisions: [String: String] = [:]
        for (directory, members) in byDirectory.sorted(by: { $0.key < $1.key }) {
            let listing = try? await store.list(directory: directory)
            guard let listing else {
                for path in members {
                    if let revision = try? await store.revision(path: path) {
                        revisions[path] = revision
                    }
                }
                continue
            }
            let entries = Dictionary(
                listing.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }
            )
            for path in members {
                guard let entry = entries[path], !entry.isDirectory else { continue }
                if let revision = entry.revision {
                    revisions[path] = revision
                } else if let revision = try? await store.revision(path: path) {
                    revisions[path] = revision
                }
            }
        }
        return revisions
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
}
