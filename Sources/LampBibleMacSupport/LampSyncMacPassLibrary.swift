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

    private let library: LampLibrary
    private let workspace: URL
    private let fileManager: FileManager
    private let readRemote: (String) async throws -> Data

    /// `workspace` is a scratch directory for this pass; `readRemote` fetches
    /// a path's bytes, which only writing attachments need.
    public init(
        library: LampLibrary,
        workspace: URL,
        fileManager: FileManager = .default,
        readRemote: @escaping (String) async throws -> Data
    ) {
        self.library = library
        self.workspace = workspace
        self.fileManager = fileManager
        self.readRemote = readRemote
    }

    // MARK: - Installing

    public func install(_ path: String, from url: URL) async throws {
        guard let kind = LampSyncFolderLayout.kind(of: path) else {
            throw PassError.unsupported(path)
        }
        switch kind {
        case .module(.notes), .module(.highlights):
            _ = try await library.importPersonalStudyData(from: url, forSync: true)
        case .module(.devotionals):
            try await installWritings(from: url, remotePath: path)
        case .module:
            _ = try await library.install(from: url)
        case .deck:
            try installFile(from: url, to: deckStore.decksDirectoryURL, named: path)
        case .deckAsset:
            try installFile(from: url, to: deckStore.assetsDirectoryURL, named: path)
        case .devotionalMedia, .bookMedia, .workspaceFile:
            // Enumerated and planned, but installed by the parts of the pass
            // that know where they belong. Reported rather than ignored, so
            // nothing goes missing quietly.
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
