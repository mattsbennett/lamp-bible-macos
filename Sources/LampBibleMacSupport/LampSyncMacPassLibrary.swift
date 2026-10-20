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
    /// The IDs the phone publishes the editable collections under, which are
    /// therefore the IDs they are published under. The Mac's own are
    /// `personal-notes` and `personal-devotionals`;
    /// `LampWebDAVPersonalArchiveAdapter` rewrites them on the way out.
    public static let remoteNotesModuleID = "notes"
    public static let remoteWritingModuleID = "devotionals"

    public enum PassError: LocalizedError, Equatable {
        case unsupported(String)
        case refusedToDeleteACollection(String)
        case missingRemoteFile(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let path):
                "Sync does not yet handle \(path)."
            case .refusedToDeleteACollection(let path):
                "\(path) holds your own writing, so sync will not delete it here."
            case .missingRemoteFile(let path):
                "\(path) is named by the library but is not on the server."
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
    private let readRemote: (String) async throws -> Data

    /// `workspace` is a scratch directory for this pass; `readRemote` fetches
    /// a path's bytes, which only writing attachments need.
    public init(
        library: LampLibrary,
        workspace: URL,
        fileManager: FileManager = .default,
        learned: Learned = Learned(),
        readRemote: @escaping (String) async throws -> Data
    ) {
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
            return try await digestOfOwnExport(
                .notes, adapterKind: .notes,
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
                .writing, adapterKind: .devotionals,
                remoteModuleID: Self.remoteWritingModuleID, filename: "devotionals.lamp"
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
        case .workspaceFile:
            // Staged, not installed: a workspace is a tree with one importer,
            // so what arrives is gathered and taken in by `finishInstalling`.
            try stageWorkspaceFile(from: url, remotePath: path)
            return nil
        case .devotionalMedia:
            // Installed by the step that knows where a writing's attachments
            // belong. Reported rather than ignored, so nothing goes missing
            // quietly.
            throw PassError.unsupported(path)
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
    /// Installed under `Media/Books/<module>/`, which is the root
    /// `BookReaderMediaResolver` checks second and the only one a sync
    /// writes, so what arrives is what the reader finds.
    private func installBookMedia(from url: URL, remotePath: String) throws {
        let components = remotePath.split(separator: "/").map(String.init)
        guard components.count >= 3 else { throw PassError.unsupported(remotePath) }
        let moduleID = components[1]
        let relative = components.dropFirst(2).joined(separator: "/")
        let destination = LampSyncLocalFiles
            .bookMediaInstallRoot(for: moduleID, inLibraryAt: library.rootURL)
            .appendingPathComponent(relative)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
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
        adapterKind: LampWebDAVPersonalArchiveKind,
        remoteModuleID: String,
        filename: String
    ) async throws -> String? {
        let exported = try await exportPersonal(
            module, adapterKind: adapterKind,
            remoteModuleID: remoteModuleID, filename: filename
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
        try LampWorkspaceSync.importPortableWorkspaces(
            from: workspaceStaging, into: library.rootURL, fileManager: fileManager
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
            try await install(path, from: url)
        }

        for path in downloaded.keys.sorted() {
            guard let kind = LampSyncFolderLayout.kind(of: path) else { continue }
            switch kind {
            case .module(.notes):
                republish[path] = try await exportPersonal(
                    .notes, adapterKind: .notes, remoteModuleID: Self.remoteNotesModuleID,
                    filename: "notes.lamp"
                )
            case .module(.devotionals):
                republish[path] = try await exportPersonal(
                    .writing, adapterKind: .devotionals,
                    remoteModuleID: Self.remoteWritingModuleID, filename: "devotionals.lamp"
                )
            case .module(.highlights):
                guard let setID = highlightSets[path],
                      let moduleID = LampSyncFolderLayout.remoteModuleID(of: path),
                      let url = try await exportHighlights(setID: setID, moduleID: moduleID)
                else { continue }
                republish[path] = url
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
                .notes, adapterKind: .notes,
                remoteModuleID: Self.remoteNotesModuleID, filename: "notes.lamp"
            )
        ))
        candidates.append(try LampSyncLocalFiles.personalModuleCandidate(
            remoteModuleID: Self.remoteWritingModuleID,
            kind: .devotionals,
            at: try await exportPersonal(
                .writing, adapterKind: .devotionals,
                remoteModuleID: Self.remoteWritingModuleID, filename: "devotionals.lamp"
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

    /// One editable collection, exported and rewritten into the phone's
    /// format — which is the canonical one, so the digest is taken over the
    /// adapter's output rather than the Mac's own export.
    private func exportPersonal(
        _ module: LampPersonalModule,
        adapterKind: LampWebDAVPersonalArchiveKind,
        remoteModuleID: String,
        filename: String
    ) async throws -> URL {
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let exported = workspace.appendingPathComponent("export-\(filename)")
        try await library.exportPersonalModule(module, format: .lamp, to: exported)
        let rewritten = try LampWebDAVPersonalArchiveAdapter.archive(
            try Data(contentsOf: exported, options: .mappedIfSafe),
            replacingModuleIDWith: remoteModuleID,
            kind: adapterKind,
            mediaRootURL: library.rootURL,
            fileManager: fileManager
        )
        let destination = workspace.appendingPathComponent(filename)
        try rewritten.write(to: destination, options: .atomic)
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
        guard let kind = LampSyncFolderLayout.kind(of: path) else {
            throw PassError.unsupported(path)
        }
        switch kind {
        case .module(.notes), .module(.devotionals), .module(.highlights):
            throw PassError.refusedToDeleteACollection(path)
        case .module:
            guard let moduleID = LampSyncFolderLayout.remoteModuleID(of: path) else {
                throw PassError.unsupported(path)
            }
            try await library.remove(moduleID: moduleID)
        case .deck:
            try removeFile(named: path, from: deckStore.decksDirectoryURL)
        case .deckAsset:
            try removeFile(named: path, from: deckStore.assetsDirectoryURL)
        case .devotionalMedia, .bookMedia, .workspaceFile:
            // Media goes when the module that shows it goes, and a workspace
            // file's removal travels inside the tree the importer reads.
            throw PassError.unsupported(path)
        }
    }

    private func removeFile(named path: String, from directory: URL) throws {
        guard let filename = path.split(separator: "/").last.map(String.init) else {
            throw PassError.unsupported(path)
        }
        let url = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private var deckStore: LampPresentationDeckStore {
        LampPresentationDeckStore(rootURL: library.rootURL)
    }
}
