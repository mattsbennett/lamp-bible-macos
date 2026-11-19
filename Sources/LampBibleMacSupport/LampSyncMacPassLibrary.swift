import Foundation
import LampCore
import LampModuleKit

/// The Mac's side of a Design B pass: installing one file, merging the ones
/// both sides changed, and removing one deleted elsewhere.
///
/// Each install is the same library call the archive pass already made for
/// that kind of file — the difference under B is only that a file arrives on
/// its own rather than inside a library-sized archive.
public struct LampSyncMacPassLibrary: LampSyncPassLibrary {
    /// The kinds `install` merges *into* the library rather than keeping as
    /// a file of their own.
    ///
    /// A member of one of these may leave no file at its path — an empty
    /// highlight set exports to nothing, and an imported notes module is
    /// folded into this Mac's own notes — and a member with no local copy is
    /// downloaded on every pass, for ever. A gather says it holds such a path
    /// instead, through `heldWithoutAFile`.
    ///
    /// Kept beside `install` because it has to agree with it: a kind that
    /// starts being merged, or stops, has to be added or removed here in the
    /// same breath, and nothing else would notice.
    public static let mergedIntoTheLibrary: Set<LampSyncFileKind> = [
        .module(.notes), .module(.devotionals), .module(.highlights),
    ]

    /// The IDs the editable collections are published under, which are
    /// core's: `Notes/notes.lamp` and, since bundle format 4,
    /// `Writing/writing.lamp`. The Mac's own are `personal-notes` and
    /// `personal-devotionals`; its export writes the published ID into the
    /// module (`personalArchive(_:moduleID:)`), and its import merges by item,
    /// whatever ID the module carries.
    public static let remoteNotesModuleID = LampSyncLocalDeletion.notesCollectionID
    public static let remoteWritingModuleID = LampSyncLocalDeletion.writingCollectionID

    public enum PassError: LocalizedError, Equatable {
        case unsupported(String)
        case refusedToDeleteACollection(String)
        case missingRemoteFile(String)
        case deletedHereDuringThePass(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let path):
                "Sync does not yet handle \(path)."
            case .refusedToDeleteACollection(let path):
                "\(path) holds your own writing, so sync will not delete it here."
            case .missingRemoteFile(let path):
                "\(path) is named by the library but is not on the server."
            case .deletedHereDuringThePass(let path):
                "\(path) was deleted on this Mac while sync was running, so it was left deleted."
            }
        }
    }

    /// What a pass learns from the files it installs, for the caller to keep.
    ///
    /// A reference because installing happens inside the pass, which holds
    /// the records exclusively while it runs.
    public final class Learned: @unchecked Sendable {
        /// Each highlight set's module ID, read from the module that carries
        /// it. Without this a set stays unpublished for ever: a set with no
        /// recorded module ID is skipped rather than given a fresh one, and
        /// the ID only exists in the module already on the server.
        public private(set) var highlightModuleIDsBySet: [String: String] = [:]

        public init() {}

        public func note(setID: String, moduleID: String) {
            highlightModuleIDsBySet[setID] = moduleID
        }
    }

    private let library: LampLibrary
    private let workspace: URL
    private let fileManager: FileManager
    private let learned: Learned
    /// Module ID to highlight set ID, the inverse of what the records keep.
    /// A tombstone names a module path; deleting the set it stands for needs
    /// the set's own ID, and this is the only place that direction is known.
    private let highlightSetIDsByModule: [String: String]
    private let readRemote: (String) async throws -> Data

    /// `workspace` is a scratch directory for this pass; `readRemote` fetches
    /// a path's bytes, which only writing attachments need.
    public init(
        library: LampLibrary,
        workspace: URL,
        fileManager: FileManager = .default,
        learned: Learned = Learned(),
        highlightSetIDsByModule: [String: String] = [:],
        readRemote: @escaping (String) async throws -> Data
    ) {
        self.highlightSetIDsByModule = highlightSetIDsByModule
        self.library = library
        self.workspace = workspace
        self.fileManager = fileManager
        self.learned = learned
        self.readRemote = readRemote
    }

    // MARK: - Installing

    /// Installs a file, and says what this Mac then holds at that path.
    ///
    /// An editable collection is merged into the library, so what this Mac
    /// would publish afterwards is its *own* export of the merged content —
    /// different bytes from the ones that arrived, because the two clients
    /// encode the same values differently. Returning that export's digest is
    /// what stops the two devices trading encodings for ever. Everything else
    /// is stored as it arrived, so the bytes received are the truth about it
    /// and nil says so.
    @discardableResult
    public func install(_ path: String, from url: URL) async throws -> String? {
        guard let kind = LampSyncFolderLayout.kind(of: path) else {
            throw PassError.unsupported(path)
        }
        switch kind {
        case .module(.notes):
            _ = try await library.importPersonalStudyData(
                from: try named(url, as: path), forSync: true
            )
            // The reader's own notes, which are always published under the
            // collection's own name. Taking the module ID from the path
            // instead asked a third-party notes module — which arrives in
            // this same folder and is merged into the collection — for the
            // reader's pictures at `NoteMedia/<that module>/<verse>/…`,
            // where nothing has ever been, and the failure stopped its
            // install on every pass.
            try await downloadNoteMedia()
            return try await digestOfOwnExport(
                .notes,
                remoteModuleID: Self.remoteNotesModuleID, filename: "notes.lamp"
            )
        case .module(.highlights):
            let file = try named(url, as: path)
            // Read before importing: the set ID is in the module, and this is
            // the only place the mapping to its module ID can be learned.
            let setID = (try? LampWebDAVPersonalArchiveAdapter.highlightSetID(
                in: try Data(contentsOf: file, options: .mappedIfSafe)
            )) ?? nil
            if let setID, let moduleID = LampSyncFolderLayout.remoteModuleID(of: path) {
                learned.note(setID: setID, moduleID: moduleID)
            }
            _ = try await library.importPersonalStudyData(from: file, forSync: true)
            guard let setID, let moduleID = LampSyncFolderLayout.remoteModuleID(of: path),
                  let exported = try? await exportHighlights(setID: setID, moduleID: moduleID)
            else { return nil }
            return try? LampSyncContentRevision.digest(forFileAt: exported)
        case .module(.devotionals):
            try await installWritings(from: try named(url, as: path), remotePath: path)
            return try await digestOfOwnExport(
                .writing,
                remoteModuleID: Self.remoteWritingModuleID, filename: "\(Self.remoteWritingModuleID).lamp"
            )
        case .module:
            _ = try await library.install(from: try named(url, as: path))
            return nil
        case .deck:
            try installFile(from: url, to: deckStore.decksDirectoryURL, named: path)
            return nil
        case .deckAsset:
            try installFile(from: url, to: deckStore.assetsDirectoryURL, named: path)
            return nil
        case .bookMedia:
            try installBookMedia(from: url, remotePath: path)
            return nil
        case .writingReview:
            // Merged into the copy here, never put over it: this Mac may
            // hold clears the server's copy has not seen. What differs from
            // the download goes back up, by the plan's comparison on the next
            // pass, or by `reconcile` when both sides changed.
            guard let writingID = LampSyncFolderLayout.writingID(ofReviewPath: path) else {
                throw PassError.unsupported(path)
            }
            try reviewStore.takeIn(downloaded: try Data(contentsOf: url), writingID: writingID)
            return nil
        case .writingDocument:
            // Asked without knowing what was last agreed: an edit held here
            // is kept as a copy, which loses nothing.
            try takeInDocument(path, from: url, agreedDigest: nil)
            return nil
        case .workspaceFile:
            // Staged, not installed: a workspace is a tree with one importer,
            // so what arrives is gathered and taken in by `finishInstalling`.
            try stageWorkspaceFile(from: url, remotePath: path)
            return nil
        case .noteMedia where LampSyncLocalFiles.isNoteModuleMedia(path):
            // A notes module's pictures are not inside its .lamp, so they
            // arrive on their own as a book's do.
            try installNoteModuleMedia(from: url, remotePath: path)
            return nil
        case .noteMedia, .devotionalMedia:
            // One of the reader's own attachments, arriving on its own.
            //
            // Both used to be refused here, on the grounds that the notes
            // and writings collections fetch their own — but those steps run
            // only when the collection file itself arrives. A picture that
            // failed to come down once, with nothing written since, was then
            // planned every pass and refused every pass, for ever: the only
            // way out was somebody editing the writing on the *other*
            // device, which republishes the collection and sets the fetch
            // going again. The path says which owner it belongs to, which is
            // all that is needed to put it away.
            try installPersonalMedia(from: url, remotePath: path, kind: kind)
            return nil
        }
    }

    /// Notes arrive with their attachments, as writings do.
    ///
    /// Every note the library now holds is asked for, not only the ones in
    /// the file that arrived: the download skips what is already on disk, so
    /// asking widely costs a directory check per file and catches a note
    /// whose picture failed to arrive on an earlier pass.
    private func downloadNoteMedia() async throws {
        let owners = try await library.personalNotesWithMedia().map {
            LampSyncDevotionalMedia.Owner(
                id: LampLibrary.noteMediaOwnerID($0.reference), mediaJSON: $0.mediaJSON
            )
        }
        guard !owners.isEmpty else { return }
        try await LampSyncDevotionalMedia.downloadToLibrary(
            scope: .note, owners: owners, from: Self.remoteNotesModuleID, into: library.rootURL
        ) { path in
            try await readRemote(path)
        }
    }

    /// Writings arrive with their attachments: the module names them, and a
    /// writing installed without its images is published again that way.
    private func installWritings(from url: URL, remotePath: String) async throws {
        let incoming = try await library.personalDevotionalCandidates(from: url)
        _ = try await library.importPersonalDevotional(from: url, forSync: true)
        let incomingIDs = Set(incoming.map(\.id))
        let retained = try await library.personalDevotionals()
            .filter { incomingIDs.contains($0.id) }
        let moduleID = LampSyncFolderLayout.remoteModuleID(of: remotePath)
            ?? Self.remoteWritingModuleID
        try await LampSyncDevotionalMedia.downloadToLibrary(
            for: retained, from: moduleID, into: library.rootURL
        ) { path in
            try await readRemote(path)
        }
    }

    /// A book's pictures are not inside its module — `media_json` holds only
    /// their metadata — so these files are the library's only copy, and a
    /// library without them shows the book with its pictures missing.
    ///
    /// Installed where core's `LampBookMediaFiles` says this library's
    /// reader finds it: `Media/Books/<module>/`, the only folder a sync
    /// writes.
    /// A notes module's picture, under `Media/Notes/<module>/`, which is
    /// where `LampLibrary.noteMediaURL` looks for it. Keyed by the module
    /// rather than a verse: the module declares its pictures once and its
    /// notes point at them by id.
    /// One of the reader's own attachments, under `Media/<scope>/<owner>/`,
    /// which is where the resolvers look for it: a verse for a note, a
    /// writing for a writing.
    ///
    /// Both kinds carry the owner in the same place —
    /// `<Dir>/<module>/<owner>/<file>` — so one routine serves them, and
    /// anything else of that kind (a module's pictures, keyed differently)
    /// does not reach here.
    private func installPersonalMedia(
        from url: URL, remotePath: String, kind: LampSyncFileKind
    ) throws {
        let scope: LampMediaScope = kind == .noteMedia ? .note : .devotional
        let components = remotePath.split(separator: "/").map(String.init)
        guard components.count == 4,
              let destination = LampPortableDevotionalMedia.folderURL(
                  rootURL: library.rootURL, scope: scope, ownerID: components[2]
              )?.appendingPathComponent(components[3])
        else { throw PassError.unsupported(remotePath) }
        try place(url, at: destination)
    }

    private func installNoteModuleMedia(from url: URL, remotePath: String) throws {
        let components = remotePath.split(separator: "/").map(String.init)
        guard components.count == 3,
              let destination = LampPortableDevotionalMedia.folderURL(
                  rootURL: library.rootURL, scope: .note,
                  ownerID: LampLibrary.noteModuleMediaOwnerID(components[1])
              )?.appendingPathComponent(components[2])
        else { throw PassError.unsupported(remotePath) }
        try place(url, at: destination)
    }

    private func place(_ url: URL, at destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
    }

    private func installBookMedia(from url: URL, remotePath: String) throws {
        let root = library.rootURL
        guard let destination = LampBookMediaFiles.installURL(forRemotePath: remotePath, folders: {
            LampBookMediaFiles.libraryFolders(libraryRootURL: root, moduleID: $0)
        }) else { throw PassError.unsupported(remotePath) }
        try place(url, at: destination)
    }

    private func installFile(from url: URL, to directory: URL, named path: String) throws {
        guard let filename = path.split(separator: "/").last.map(String.init) else {
            throw PassError.unsupported(path)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
    }

    /// This Mac's own export of a collection it has just merged into.
    private func digestOfOwnExport(
        _ module: LampPersonalModule,
        remoteModuleID: String,
        filename: String
    ) async throws -> String? {
        let exported = try await exportPersonal(
            module, remoteModuleID: remoteModuleID, filename: filename
        )
        return try? LampSyncContentRevision.digest(forFileAt: exported)
    }

    /// The downloaded body under a name the library will accept.
    ///
    /// A pass downloads to a scratch file with no extension, and the library
    /// decides what a file is by its extension: `importPersonalStudyData`
    /// wants `.json` or `.lamp`, `install` wants `.lamp`. Handed the scratch
    /// file as it is, every module import fails with "Choose a file with the
    /// .lamp extension" — which is what happened on the first real pass. The
    /// remote path already carries the right one.
    private func named(_ url: URL, as remotePath: String) throws -> URL {
        let filename = remotePath.split(separator: "/").last.map(String.init) ?? "module.lamp"
        let destination = workspace
            .appendingPathComponent("Incoming", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    /// Where a pass gathers the workspace files it has downloaded, in the
    /// shape `importPortableWorkspaces` expects to read.
    private var workspaceStaging: URL {
        workspace.appendingPathComponent("IncomingWorkspaces", isDirectory: true)
    }

    private func stageWorkspaceFile(from url: URL, remotePath: String) throws {
        let destination = workspaceStaging.appendingPathComponent(remotePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
    }

    /// Takes in whatever workspace files this pass gathered, together.
    ///
    /// One call rather than one per file, because the importer reads a tree:
    /// it resolves each workspace's documents against its context, its
    /// enabled skills and its file ledger, and a document imported without
    /// them would be judged against nothing.
    public func finishInstalling() async throws {
        guard fileManager.fileExists(atPath: workspaceStaging.path) else { return }
        try await LampWorkspaceSync.importPortableWorkspaces(
            from: workspaceStaging, into: library.rootURL, writingFolder: .perFile, fileManager: fileManager
        )
    }

    // MARK: - Merging

    /// Merges everything both sides changed, then re-exports each of those
    /// files from the merged library.
    ///
    /// One call for the group, and the import is by value — `forSync: true` —
    /// so a copy that only differs in how this client spells it is not a
    /// change. What goes back up is the re-export, never the copy digested
    /// before the merge ran: publishing that would push the other side's
    /// changes straight back out of the library.
    public func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL] {
        var republish: [String: URL] = [:]
        // Set IDs are read before importing, while the downloaded file is
        // still the only place they are written down.
        var highlightSets: [String: String] = [:]
        for (path, url) in downloaded where LampSyncFolderLayout.kind(of: path) == .module(.highlights) {
            highlightSets[path] = try LampWebDAVPersonalArchiveAdapter.highlightSetID(
                in: try Data(contentsOf: url, options: .mappedIfSafe)
            )
        }

        for path in downloaded.keys.sorted() {
            guard let url = downloaded[path] else { continue }
            if LampSyncFolderLayout.kind(of: path) == .writingDocument {
                // Both sides changed it: the server's copy under its name,
                // this Mac's edits kept beside it, which the next pass sends.
                // Nothing goes back up at this path, which now holds what
                // was downloaded.
                try takeInDocument(path, from: url, agreedDigest: nil)
            } else {
                try await install(path, from: url)
            }
        }

        for path in downloaded.keys.sorted() {
            guard let kind = LampSyncFolderLayout.kind(of: path) else { continue }
            switch kind {
            case .module(.notes):
                republish[path] = try await exportPersonal(
                    .notes, remoteModuleID: Self.remoteNotesModuleID,
                    filename: "notes.lamp"
                )
            case .module(.devotionals):
                republish[path] = try await exportPersonal(
                    .writing,
                    remoteModuleID: Self.remoteWritingModuleID, filename: "\(Self.remoteWritingModuleID).lamp"
                )
            case .module(.highlights):
                guard let setID = highlightSets[path],
                      let moduleID = LampSyncFolderLayout.remoteModuleID(of: path),
                      let url = try await exportHighlights(setID: setID, moduleID: moduleID)
                else { continue }
                republish[path] = url
            case .writingReview:
                // `install` merged the two copies here. If this Mac had marks
                // or clears the server's copy lacked, the merge is what goes
                // back up; if not, the server already has it all.
                //
                // Sent from a copy in this pass's workspace, never from the
                // file itself: the pass takes a URL it gathered as leave to
                // reuse the digest it took then, before the merge, and would
                // record the bytes it sent under the old one.
                guard let writingID = LampSyncFolderLayout.writingID(ofReviewPath: path) else { continue }
                let local = try reviewStore.url(writingID: writingID)
                if let held = try? Data(contentsOf: local), let arrived = downloaded[path], held != (try Data(contentsOf: arrived)) {
                    let copy = workspace.appendingPathComponent("review-\(UUID().uuidString).json")
                    try held.write(to: copy, options: .atomic)
                    republish[path] = copy
                }
            default:
                // Nothing else is merged: a read-only module is replaced
                // wholesale, and media never changes at a path.
                continue
            }
        }
        return republish
    }

    /// The three editable collections, exported ready to publish.
    ///
    /// The same export a merge re-runs afterwards, so there is one place that
    /// knows notes and writings go out through the adapter under the phone's
    /// IDs and a highlight set is compiled under the module ID this source
    /// has recorded for it.
    ///
    /// `highlightModuleID` is asked for each set, and a set it has no answer
    /// for is skipped. Minting one here would publish a second module for a
    /// set that already has one, so the caller is expected to have asked the
    /// server first — see `LampSyncHighlightModules.discover`, which reads the
    /// IDs out of the modules that are there, and only then may a set with no
    /// module anywhere be given a fresh one.
    public func editableCollections(
        highlightModuleID: (String) -> String?
    ) async throws -> (candidates: [LampSyncLocalFiles.Candidate], skipped: [String]) {
        var candidates: [LampSyncLocalFiles.Candidate] = []
        candidates.append(try LampSyncLocalFiles.personalModuleCandidate(
            remoteModuleID: Self.remoteNotesModuleID,
            kind: .notes,
            at: try await exportPersonal(
                .notes,
                remoteModuleID: Self.remoteNotesModuleID, filename: "notes.lamp"
            )
        ))
        candidates.append(try LampSyncLocalFiles.personalModuleCandidate(
            remoteModuleID: Self.remoteWritingModuleID,
            kind: .devotionals,
            at: try await exportPersonal(
                .writing,
                remoteModuleID: Self.remoteWritingModuleID, filename: "\(Self.remoteWritingModuleID).lamp"
            )
        ))

        var skipped: [String] = []
        for set in try await library.highlightSets() {
            guard let moduleID = highlightModuleID(set.id) else {
                skipped.append(set.name.isEmpty ? set.id : set.name)
                continue
            }
            guard let url = try await exportHighlights(setID: set.id, moduleID: moduleID) else {
                continue
            }
            candidates.append(try LampSyncLocalFiles.personalModuleCandidate(
                remoteModuleID: moduleID, kind: .highlights, at: url
            ))
        }
        return (candidates, skipped)
    }

    /// One editable collection, as the file it is published as.
    ///
    /// Core writes it whole — the travelling name written in from the
    /// start, and for writings the content and media made ready to travel
    /// on the way out. Both used to be done afterwards, by decompressing
    /// the exported file, rewriting it and compressing it again; that step
    /// was this app's own, so no second writer could ever have matched its
    /// bytes. Now the phone produces the same file from the same records.
    private func exportPersonal(
        _ module: LampPersonalModule,
        remoteModuleID: String,
        filename: String
    ) async throws -> URL {
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let destination = workspace.appendingPathComponent(filename)
        try await library.personalArchive(module, moduleID: remoteModuleID)
            .write(to: destination, options: .atomic)
        return destination
    }

    /// One highlight set, compiled under the module ID it is published as.
    /// Highlights do not go through the adapter: the Mac compiles them
    /// directly, with the set ID travelling in the module's own metadata.
    private func exportHighlights(setID: String, moduleID: String) async throws -> URL? {
        guard let set = try await library.highlightSets().first(where: { $0.id == setID }) else {
            return nil
        }
        guard let document = try await LampSyncPersonalExport.highlightsIfPresent({
            try await library.personalHighlightsDocument(
                translationID: set.translationID,
                moduleID: moduleID,
                name: set.name,
                setID: set.id
            )
        }) else { return nil }
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let destination = workspace.appendingPathComponent(document.suggestedModuleFilename)
        _ = try LampModuleCompiler().compile(
            data: document.jsonData,
            sourceFilename: document.suggestedJSONFilename,
            destinationURL: destination
        )
        return destination
    }

    // MARK: - Deleting

    /// Removes a file deleted on another device.
    ///
    /// The editable collections are refused outright. A tombstone on
    /// `Notes/notes.lamp` would otherwise mean "delete every note this person
    /// has written", from a pass nobody is watching — and those collections
    /// exist in every library, so a tombstone naming one is a mistake
    /// somewhere else rather than an instruction. Items are deleted through
    /// their own ledger, which is a different thing from the file.
    public func deleteLocally(_ path: String) async throws {
        // What a path means for deletion is core's rule, so the send side and
        // the receive side cannot drift: a removal this Mac records is one
        // every client will carry out, and vice versa.
        switch LampSyncLocalDeletion.target(of: path) {
        case .collection:
            throw PassError.refusedToDeleteACollection(path)
        case .unsupported:
            throw PassError.unsupported(path)
        case .deck(let filename):
            try removeFile(named: filename, from: deckStore.decksDirectoryURL)
        case .deckAsset(let filename):
            try removeFile(named: filename, from: deckStore.assetsDirectoryURL)
        case .writingReview(let writingID):
            try reviewStore.remove(writingID: writingID)
        case .writingDocument:
            // Asked without knowing what was last agreed: kept as a copy if
            // it is there at all, which loses nothing.
            try await deleteLocally(path, agreedDigest: nil)
        case .module(let moduleID):
            // A highlight module is an installed module on the phone and a
            // *set* here, so the one allowed deletion that needs translating
            // is this one. Without the mapping the Mac cannot tell which set
            // the module stands for and must not guess.
            if LampSyncFolderLayout.kind(of: path) == .module(.highlights) {
                guard let setID = highlightSetIDsByModule[moduleID] else {
                    throw PassError.unsupported(path)
                }
                try await library.deleteHighlightSet(id: setID)
            } else {
                try await library.remove(moduleID: moduleID)
            }
        }
    }

    /// A deletion made on another device, told what this Mac last agreed
    /// with the server on: a document edited here since is kept as a copy
    /// rather than removed (`LampWritingDocumentStore.remove`).
    public func deleteLocally(_ path: String, agreedDigest: String?) async throws {
        guard case .writingDocument = LampSyncLocalDeletion.target(of: path) else {
            return try await deleteLocally(path)
        }
        try documentStore.remove(path: path, agreedDigest: agreedDigest, localDevice: Self.deviceName)
        noteSynced(path)
    }

    /// A file taken from the server, told what this Mac last agreed with
    /// the server on there: a document edited here since is kept as a copy
    /// beside the server's (`LampWritingDocumentMerge`).
    public func install(_ path: String, from url: URL, agreedDigest: String?) async throws -> String? {
        guard LampSyncFolderLayout.kind(of: path) == .writingDocument else {
            return try await install(path, from: url)
        }
        try takeInDocument(path, from: url, agreedDigest: agreedDigest)
        return nil
    }

    /// One of a writing's documents, taken in by core's rule, and noted in
    /// the workspace's ledger as synced, so that removing it here later is
    /// seen as this Mac's own deletion.
    private func takeInDocument(_ path: String, from url: URL, agreedDigest: String?) throws {
        // Here at the last sync and gone now: deleted on this Mac since the
        // pass gathered, which the next pass records. Taken in, it would come
        // back, and the ledger would forget it was ever deleted. Thrown, not
        // passed over: the pass would record the server's revision as taken,
        // and the deletion would then be dated after a write it never saw.
        if let document = LampWritingWorkspaceLayout.document(ofPath: path) {
            let workspace = documentStore.rootURL.appendingPathComponent(document.folder, isDirectory: true)
            let key = WorkspaceFileLedger.documentKey(document.name)
            if !fileManager.fileExists(atPath: workspace.appendingPathComponent(document.name).path),
               WorkspaceFileLedger.load(in: workspace).synced.map({ synced in
                   synced.keys.contains { WorkspaceFileLedger.normalized($0) == key }
               }) == true {
                throw PassError.deletedHereDuringThePass(path)
            }
        }
        try documentStore.takeIn(
            downloaded: try Data(contentsOf: url), path: path, agreedDigest: agreedDigest, localDevice: Self.deviceName
        )
        noteSynced(path)
    }

    /// Notes a document as the workspace now has it, present or not, as the
    /// last sync's: what a pass put here or took away is not a change this
    /// Mac made. Best effort: a ledger that cannot be written leaves the next
    /// comparison to find it.
    private func noteSynced(_ path: String) {
        guard let document = LampWritingWorkspaceLayout.document(ofPath: path) else { return }
        let workspace = documentStore.rootURL.appendingPathComponent(document.folder, isDirectory: true)
        let file = workspace.appendingPathComponent(document.name)
        var ledger = WorkspaceFileLedger.load(in: workspace)
        // A workspace a pass has just made has no baseline yet, and with
        // none a document removed before the next export would never be
        // seen to go: the first comparison only records what is there.
        if ledger.synced == nil, let files = try? LampWorkspaceSync.workspaceFiles(in: workspace, fileManager: fileManager) {
            ledger.noteChanges(present: files.mapValues(\.modified))
        }
        ledger.noteSynced(
            WorkspaceFileLedger.documentKey(document.name),
            modified: LampFileModification.date(of: file).map(WorkspaceFileLedger.milliseconds)
        )
        try? ledger.save(in: workspace)
    }

    /// What this Mac's edits are kept under when another device changed or
    /// deleted the same document.
    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    private var documentStore: LampWritingDocumentStore {
        LampWritingDocumentStore(rootURL: LampWritingWorkspace.root(libraryRootURL: library.rootURL, fileManager: fileManager))
    }

    private func removeFile(named filename: String, from directory: URL) throws {
        let url = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private var deckStore: LampPresentationDeckStore {
        LampPresentationDeckStore(rootURL: library.rootURL)
    }

    private var reviewStore: LampWritingReviewStore {
        LampWritingReviewStore(rootURL: library.rootURL)
    }
}
