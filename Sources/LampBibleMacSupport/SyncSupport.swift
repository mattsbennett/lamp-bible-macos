import Foundation
import LampModuleKit

/// Preserve the support module's public archive name while the codec lives in core.
public typealias LampSyncArchive = LampModuleKit.LampSyncArchive

/// Copies the user-authored portion of devotional agent workspaces into and out
/// of a portable backup. Custom skills are synchronized once as a shared catalog,
/// along with each workspace's enabled-skill selection. Generated instructions,
/// provider configuration, provider skill copies, and the primary draft are
/// deliberately rebuilt from their canonical sources on each Mac.
public enum LampWorkspaceSync {
    public static let portableDirectoryName = LampPortableBackupLayout.workspacesDirectory

    private static let agentWorkspacesPath = ["AgentWorkspaces", "Devotionals"]
    private static let portableWorkspacesPath = [portableDirectoryName, "Devotionals"]
    private static let supportedDocumentExtensions: Set<String> = [
        "md", "markdown", "txt", "text",
    ]
    private static let generatedDocumentNames: Set<String> = [
        "agents.md", "claude.md", "devotional_context.md", "draft.md",
    ]
    private static let bundledSkillNames: Set<String> = ["build-lamp-deck"]

    /// Run legacy workspace migration during the local pull transaction so
    /// exporting the prepared library does not change the live workspace.
    public static func prepareLibraryForSync(
        at libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        try WorkspaceSkillStore.migrateAllWorkspaces(
            in: libraryRoot,
            fileManager: fileManager
        )
    }

    public static func exportPortableWorkspaces(
        from libraryRoot: URL,
        to backupRoot: URL,
        fileManager: FileManager = .default
    ) throws {
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
                fileManager: fileManager
            )
        }

        let sourceRoot = appending(agentWorkspacesPath, to: libraryRoot)
        guard fileManager.fileExists(atPath: sourceRoot.path) else { return }

        let destinationRoot = appending(portableWorkspacesPath, to: backupRoot)
        for workspace in try childDirectories(of: sourceRoot, fileManager: fileManager) {
            let portableWorkspace = destinationRoot
                .appendingPathComponent(workspace.lastPathComponent, isDirectory: true)

            for document in try childFiles(of: workspace, fileManager: fileManager)
            where isPortableDocument(document) {
                try copyPreservingModificationDate(
                    from: document,
                    to: portableWorkspace
                        .appendingPathComponent("Documents", isDirectory: true)
                        .appendingPathComponent(document.lastPathComponent),
                    fileManager: fileManager
                )
            }

            try copyTree(
                from: workspace.appendingPathComponent("context", isDirectory: true),
                to: portableWorkspace.appendingPathComponent("Context", isDirectory: true),
                fileManager: fileManager
            )

            let selection = WorkspaceSkillStore.selectionURL(in: workspace)
            if fileManager.fileExists(atPath: selection.path) {
                try copyPreservingModificationDate(
                    from: selection,
                    to: portableWorkspace.appendingPathComponent("EnabledSkills.json"),
                    fileManager: fileManager
                )
            }

            try copyTree(
                from: workspace
                    .appendingPathComponent(".lamp", isDirectory: true)
                    .appendingPathComponent("revisions", isDirectory: true),
                to: portableWorkspace.appendingPathComponent("Revisions", isDirectory: true),
                allowedExtensions: ["json"],
                fileManager: fileManager
            )
        }
    }

    public static func importPortableWorkspaces(
        from backupRoot: URL,
        into libraryRoot: URL,
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

        let sourceRoot = appending(portableWorkspacesPath, to: backupRoot)
        guard fileManager.fileExists(atPath: sourceRoot.path) else { return }

        let destinationRoot = appending(agentWorkspacesPath, to: libraryRoot)
        for portableWorkspace in try childDirectories(of: sourceRoot, fileManager: fileManager) {
            let workspace = destinationRoot
                .appendingPathComponent(portableWorkspace.lastPathComponent, isDirectory: true)

            let documents = portableWorkspace.appendingPathComponent("Documents", isDirectory: true)
            for document in try childFilesIfPresent(of: documents, fileManager: fileManager)
            where isPortableDocument(document) {
                try mergeFile(
                    from: document,
                    to: workspace.appendingPathComponent(document.lastPathComponent),
                    fileManager: fileManager
                )
            }

            try mergeTree(
                from: portableWorkspace.appendingPathComponent("Context", isDirectory: true),
                to: workspace.appendingPathComponent("context", isDirectory: true),
                fileManager: fileManager
            )
            try WorkspaceContextFileStore.consolidate(
                in: workspace,
                libraryRootURL: libraryRoot,
                fileManager: fileManager
            )

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
        }
    }

    private static func isPortableDocument(_ url: URL) -> Bool {
        supportedDocumentExtensions.contains(url.pathExtension.lowercased())
            && !generatedDocumentNames.contains(url.lastPathComponent.lowercased())
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
                fileManager: fileManager
            )
        }
    }

    private static func mergeTree(
        from source: URL,
        to destination: URL,
        allowedExtensions: Set<String>? = nil,
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
            try mergeFile(
                from: url,
                to: destination.appendingPathComponent(String(path.dropFirst(prefix.count))),
                fileManager: fileManager
            )
        }
    }

    private static func copyPreservingModificationDate(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let values = try source.resourceValues(forKeys: [.contentModificationDateKey])
        try ensureSafeDestination(destination, fileManager: fileManager)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        if let modifiedAt = values.contentModificationDate {
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

    private static func isSafeDirectory(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
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
public typealias LampWebDAVModuleJSONDocument = LampModuleKit.LampWebDAVModuleJSONDocument
public typealias LampWebDAVModuleJSONAdapter = LampModuleKit.LampWebDAVModuleJSONAdapter

public enum LampSyncError: LocalizedError {
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
}
