import Foundation
import LampModuleKit
import SQLite3

public struct LampSyncArchive: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let data: Data
        public let modifiedAt: Date

        public init(path: String, data: Data, modifiedAt: Date) {
            self.path = path
            self.data = data
            self.modifiedAt = modifiedAt
        }
    }

    public let formatVersion: Int
    public let entries: [Entry]

    public init(formatVersion: Int = 1, entries: [Entry]) {
        self.formatVersion = formatVersion
        self.entries = entries
    }

    public static func create(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> LampSyncArchive {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return LampSyncArchive(entries: []) }
        let prefix = directory.standardizedFileURL.path + "/"
        let entries = try enumerator.compactMap { item -> Entry? in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(prefix) else { throw LampSyncError.unsafeArchivePath }
            return Entry(
                path: String(standardizedPath.dropFirst(prefix.count)),
                data: try Data(contentsOf: url),
                modifiedAt: values.contentModificationDate ?? Date()
            )
        }
        return LampSyncArchive(entries: entries.sorted { $0.path < $1.path })
    }

    public func compressedData() throws -> Data {
        let data = try JSONEncoder().encode(self)
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    public static func decode(compressedData: Data) throws -> LampSyncArchive {
        let data = try (compressedData as NSData).decompressed(using: .zlib) as Data
        let archive = try JSONDecoder().decode(LampSyncArchive.self, from: data)
        guard archive.formatVersion == 1 else { throw LampSyncError.unsupportedArchiveVersion }
        return archive
    }

    public func extract(
        to directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.standardizedFileURL.path + "/"
        for entry in entries {
            guard !entry.path.hasPrefix("/"),
                  !entry.path.split(separator: "/").contains("..") else {
                throw LampSyncError.unsafeArchivePath
            }
            let destination = directory.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(root) else { throw LampSyncError.unsafeArchivePath }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: destination, options: .atomic)
            try fileManager.setAttributes(
                [.modificationDate: entry.modifiedAt],
                ofItemAtPath: destination.path
            )
        }
    }
}

public enum LampFolderSync {
    public static func merge(
        from source: URL,
        into destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let archive = try LampSyncArchive.create(from: source, fileManager: fileManager)
        try archive.extract(to: destination, fileManager: fileManager)
    }
}

/// Copies the user-authored portion of devotional agent workspaces into and out
/// of a portable backup. Custom skills are synchronized once as a shared catalog,
/// along with each workspace's enabled-skill selection. Generated instructions,
/// provider configuration, provider skill copies, and the primary draft are
/// deliberately rebuilt from their canonical sources on each Mac.
public enum LampWorkspaceSync {
    public static let portableDirectoryName = "Workspaces"

    private static let agentWorkspacesPath = ["AgentWorkspaces", "Devotionals"]
    private static let portableWorkspacesPath = [portableDirectoryName, "Devotionals"]
    private static let supportedDocumentExtensions: Set<String> = [
        "md", "markdown", "txt", "text",
    ]
    private static let generatedDocumentNames: Set<String> = [
        "agents.md", "claude.md", "devotional_context.md", "draft.md",
    ]
    private static let bundledSkillNames: Set<String> = ["build-lamp-deck"]

    public static func exportPortableWorkspaces(
        from libraryRoot: URL,
        to backupRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        try WorkspaceSkillStore.migrateAllWorkspaces(
            in: libraryRoot,
            fileManager: fileManager
        )

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
        try WorkspaceSkillStore.migrateAllWorkspaces(
            in: libraryRoot,
            fileManager: fileManager
        )

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
        guard destinationData != sourceData else { return false }
        let destinationDate = destinationDate ?? .distantPast
        let sourceDate = sourceDate ?? .distantPast
        let difference = sourceDate.timeIntervalSince(destinationDate)
        if abs(difference) > 0.001 { return difference > 0 }

        // Timestamp precision varies by sync provider. A stable byte ordering
        // makes equal-time conflicts converge instead of oscillating forever.
        return destinationData.lexicographicallyPrecedes(sourceData)
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

public struct LampWebDAVClient: Sendable {
    public let baseURL: URL
    public let credentials: LampWebDAVCredentials?
    private let session: URLSession

    public init(
        baseURL: URL,
        credentials: LampWebDAVCredentials? = nil,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session ?? Self.makeSession()
    }

    public func download(filename: String) async throws -> Data? {
        let request = try makeRequest(method: "GET", filename: filename)
        return try await data(for: request)
    }

    public func download(relativePath: String) async throws -> Data? {
        let request = try makeRequest(method: "GET", relativePath: relativePath)
        return try await data(for: request)
    }

    private func data(for request: URLRequest) async throws -> Data? {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LampSyncError.invalidResponse }
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw LampSyncError.httpStatus(response.statusCode)
        }
        return data
    }

    public func upload(_ data: Data, filename: String) async throws {
        var request = try makeRequest(method: "PUT", filename: filename)
        try await upload(data, using: &request)
    }

    public func upload(_ data: Data, relativePath: String) async throws {
        var request = try makeRequest(method: "PUT", relativePath: relativePath)
        try await upload(data, using: &request)
    }

    private func upload(_ data: Data, using request: inout URLRequest) async throws {
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LampSyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw LampSyncError.httpStatus(response.statusCode)
        }
    }

    public func createDirectory(_ directory: String) async throws {
        var request = try makeRequest(
            method: "MKCOL",
            relativePath: directory.hasSuffix("/") ? directory : directory + "/"
        )
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LampSyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) || response.statusCode == 405 else {
            throw LampSyncError.httpStatus(response.statusCode)
        }
    }

    public func listFilenames(directory: String) async throws -> [String] {
        let path = directory.hasSuffix("/") ? directory : directory + "/"
        var request = try makeRequest(method: "PROPFIND", relativePath: path)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LampSyncError.invalidResponse }
        if response.statusCode == 404 { return [] }
        guard (200..<300).contains(response.statusCode) else {
            throw LampSyncError.httpStatus(response.statusCode)
        }
        let parser = LampWebDAVHrefParser(data: data)
        return try parser.filenames().filter { $0 != directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    }

    public func makeRequest(method: String, filename: String) throws -> URLRequest {
        guard !filename.contains("/"), !filename.contains("..") else {
            throw LampSyncError.unsafeArchivePath
        }
        return try makeRequest(method: method, relativePath: filename)
    }

    private func makeRequest(method: String, relativePath: String) throws -> URLRequest {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LampSyncError.unsafeArchivePath
        }
        var url = baseURL
        for component in components {
            url.appendPathComponent(String(component))
        }
        if relativePath.hasSuffix("/"), !url.path.hasSuffix("/"),
           var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            urlComponents.path += "/"
            if let directoryURL = urlComponents.url { url = directoryURL }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let credentials {
            let token = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func makeSession() -> URLSession {
        // Do not share HTTP auth state with unrelated requests made by the app.
        // A stale credential in URLSession.shared can replace the explicit Basic
        // header after a challenge and make corrected WebDAV settings keep
        // returning 401 until the process is relaunched.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }
}

private final class LampWebDAVHrefParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var isReadingHref = false
    private var currentHref = ""
    private var hrefs: [String] = []

    init(data: Data) {
        self.data = data
    }

    func filenames() throws -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw LampSyncError.invalidResponse }
        var seen = Set<String>()
        return hrefs.compactMap { href in
            let decoded = href.removingPercentEncoding ?? href
            let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let name = trimmed.split(separator: "/").last.map(String.init),
                  !name.isEmpty,
                  seen.insert(name).inserted else { return nil }
            return name
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard (qName ?? elementName).split(separator: ":").last == "href" else { return }
        isReadingHref = true
        currentHref = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingHref { currentHref += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard (qName ?? elementName).split(separator: ":").last == "href" else { return }
        isReadingHref = false
        hrefs.append(currentHref.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum LampWebDAVPersonalArchiveKind: Sendable {
    case notes
    case devotionals

    fileprivate var entryTable: String {
        switch self {
        case .notes: "note_entries"
        case .devotionals: "devotional_entries"
        }
    }
}

public enum LampWebDAVPersonalArchiveAdapter {
    /// The two apps use different IDs for their default editable collections.
    /// Rewrite the Mac archive's module IDs before publishing it into the iOS
    /// folder layout so iOS merges the rows into its existing collection.
    public static func archive(
        _ compressedData: Data,
        replacingModuleIDWith moduleID: String,
        kind: LampWebDAVPersonalArchiveKind,
        fileManager: FileManager = .default
    ) throws -> Data {
        guard !moduleID.isEmpty,
              !moduleID.contains("/"),
              !moduleID.contains("\0"),
              let databaseData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            throw LampSyncError.archiveConversionFailed
        }
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-ios-sync-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: databaseURL, options: .atomic)
        defer {
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(atPath: databaseURL.path + "-journal")
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw LampSyncError.archiveConversionFailed
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw LampSyncError.archiveConversionFailed
        }
        do {
            try updateModuleID(in: database, table: "module_format", column: "module_id", to: moduleID)
            try updateModuleID(in: database, table: "module_meta", column: "id", to: moduleID)
            try updateModuleID(in: database, table: kind.entryTable, column: "module_id", to: moduleID)
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw LampSyncError.archiveConversionFailed
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }

        let rewrittenData = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        guard let compressed = try? (rewrittenData as NSData).compressed(using: .zlib) as Data else {
            throw LampSyncError.archiveConversionFailed
        }
        return compressed
    }

    public static func highlightSetID(
        in compressedData: Data,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard let databaseData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            throw LampSyncError.archiveConversionFailed
        }
        let databaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-ios-highlight-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try databaseData.write(to: databaseURL, options: .atomic)
        defer { try? fileManager.removeItem(at: databaseURL) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw LampSyncError.archiveConversionFailed
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id FROM highlight_meta LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private static func updateModuleID(
        in database: OpaquePointer,
        table: String,
        column: String,
        to moduleID: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE \(table) SET \(column) = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LampSyncError.archiveConversionFailed
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, moduleID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw LampSyncError.archiveConversionFailed
        }
    }
}

public struct LampWebDAVModuleJSONDocument: Equatable, Sendable {
    public let data: Data
    public let moduleID: String

    public init(data: Data, moduleID: String) {
        self.data = data
        self.moduleID = moduleID
    }
}

/// Converts the legacy JSON envelopes still written by the iOS app into the
/// canonical per-module documents consumed by LampModuleKit on macOS.
public enum LampWebDAVModuleJSONAdapter {
    public static func documents(
        from data: Data,
        kind: LampModuleKind,
        fallbackModuleID: String
    ) throws -> [LampWebDAVModuleJSONDocument] {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LampSyncError.invalidModuleJSON
        }
        let fallbackID = safeIdentifier(fallbackModuleID)

        switch kind {
        case .devotional:
            if let entries = root["entries"] as? [Any] {
                return try entries.enumerated().map { index, value in
                    guard let entry = value as? [String: Any] else {
                        throw LampSyncError.invalidModuleJSON
                    }
                    return try devotionalDocument(
                        entry,
                        fallbackModuleID: "\(fallbackID)-\(index + 1)"
                    )
                }
            }
            return [try devotionalDocument(root, fallbackModuleID: fallbackID)]

        case .notes:
            if root["meta"] == nil, let entries = root["entries"] as? [Any] {
                return try noteDocuments(
                    entries: entries,
                    metadata: root,
                    fallbackModuleID: fallbackID
                )
            }

        case .highlights:
            if root["meta"] == nil, let highlights = root["highlights"] as? [Any] {
                root = try canonicalHighlights(
                    root: root,
                    highlights: highlights,
                    fallbackModuleID: fallbackID
                )
            }

        case .translation, .dictionary, .commentary, .book, .plan, .quiz:
            break
        }

        root = canonicalRoot(root, kind: kind, fallbackModuleID: fallbackID)
        return [LampWebDAVModuleJSONDocument(
            data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
            moduleID: moduleID(in: root) ?? fallbackID
        )]
    }

    private static func devotionalDocument(
        _ source: [String: Any],
        fallbackModuleID: String
    ) throws -> LampWebDAVModuleJSONDocument {
        var root = source
        var meta = root["meta"] as? [String: Any] ?? [:]
        if meta.isEmpty {
            for key in [
                "id", "title", "subtitle", "author", "date", "tags", "category",
                "series", "keyScriptures", "created", "lastModified",
            ] where root[key] != nil {
                meta[key] = root[key]
            }
        }
        let identifier = string(meta["id"]) ?? string(root["id"]) ?? fallbackModuleID
        meta["schemaVersion"] = string(meta["schemaVersion"]) ?? "1.0"
        meta["id"] = safeIdentifier(identifier)
        meta["type"] = "devotional"
        meta["title"] = string(meta["title"])
            ?? string(root["title"])
            ?? "Untitled"
        root["meta"] = meta
        // The iOS model treats markdownContent as the preferred representation
        // when both the legacy block tree and Markdown are present.
        if let markdown = string(root["markdownContent"]), !markdown.isEmpty {
            root["content"] = markdown
        }
        guard root.keys.contains("content") else {
            throw LampSyncError.invalidModuleJSON
        }
        return LampWebDAVModuleJSONDocument(
            data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
            moduleID: safeIdentifier(identifier)
        )
    }

    private static func noteDocuments(
        entries: [Any],
        metadata: [String: Any],
        fallbackModuleID: String
    ) throws -> [LampWebDAVModuleJSONDocument] {
        var entriesByBook: [Int: [[String: Any]]] = [:]
        for value in entries {
            guard let entry = value as? [String: Any],
                  let reference = integer(entry["verseId"]),
                  reference > 0,
                  reference / 1_000_000 > 0 else { continue }
            entriesByBook[reference / 1_000_000, default: []].append(entry)
        }

        return try entriesByBook.keys.sorted().map { bookNumber in
            let identifier = safeIdentifier("\(fallbackModuleID)-\(bookNumber)")
            let bookEntries = entriesByBook[bookNumber] ?? []
            let chapters = Dictionary(grouping: bookEntries) { entry in
                (integer(entry["verseId"]) ?? 0) / 1_000 % 1_000
            }.keys.sorted().map { chapterNumber -> [String: Any] in
                let verses = (Dictionary(grouping: bookEntries) { entry in
                    (integer(entry["verseId"]) ?? 0) / 1_000 % 1_000
                }[chapterNumber] ?? []).compactMap { entry -> [String: Any]? in
                    guard let reference = integer(entry["verseId"]),
                          let content = entry["content"], isMeaningful(content) else { return nil }
                    var verse: [String: Any] = ["sv": reference, "commentary": content]
                    for key in ["title", "lastModified", "footnotes"] where entry[key] != nil {
                        verse[key] = entry[key]
                    }
                    if let verseReferences = entry["verseRefs"] as? [Any] {
                        let endReferences = verseReferences.compactMap { value -> Int? in
                            guard let object = value as? [String: Any] else { return nil }
                            return integer(object["ev"]) ?? integer(object["sv"])
                        }.filter { $0 >= reference }
                        if let endReference = endReferences.max(), endReference > reference {
                            verse["ev"] = endReference
                        }
                    }
                    return verse
                }
                return ["chapter": chapterNumber, "verses": verses]
            }
            var meta: [String: Any] = [
                "schemaVersion": "1.0",
                "id": identifier,
                "type": "notes",
                "name": string(metadata["name"]) ?? "Notes",
            ]
            for key in ["description", "author"] where metadata[key] != nil {
                meta[key] = metadata[key]
            }
            let root: [String: Any] = [
                "meta": meta,
                "book": bookName(bookNumber),
                "bookNumber": bookNumber,
                "chapters": chapters,
            ]
            return LampWebDAVModuleJSONDocument(
                data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                moduleID: identifier
            )
        }
    }

    private static func canonicalHighlights(
        root: [String: Any],
        highlights: [Any],
        fallbackModuleID: String
    ) throws -> [String: Any] {
        let grouped = Dictionary(grouping: highlights) { value -> Int in
            guard let entry = value as? [String: Any] else { return 0 }
            return integer(entry["ref"]) ?? 0
        }
        let verses: [[String: Any]] = grouped.keys.filter { $0 > 0 }.sorted().map { reference in
            let spans = (grouped[reference] ?? []).compactMap { value -> [String: Any]? in
                guard let entry = value as? [String: Any],
                      integer(entry["sc"]) != nil,
                      integer(entry["ec"]) != nil else { return nil }
                var span: [String: Any] = [
                    "sc": integer(entry["sc"])!,
                    "ec": integer(entry["ec"])!,
                    "style": integer(entry["style"]) ?? 0,
                ]
                if entry["color"] != nil { span["color"] = entry["color"] }
                return span
            }
            return ["ref": reference, "highlights": spans]
        }
        let identifier = safeIdentifier(string(root["id"]) ?? fallbackModuleID)
        var meta: [String: Any] = [
            "schemaVersion": "1.0",
            "id": identifier,
            "type": "highlights",
            "translationId": string(root["translationId"]) ?? "unknown",
            "name": string(root["name"]) ?? "Highlights",
        ]
        for key in ["description", "created", "lastModified", "themes"] where root[key] != nil {
            meta[key] = root[key]
        }
        return ["meta": meta, "verses": verses]
    }

    private static func canonicalRoot(
        _ source: [String: Any],
        kind: LampModuleKind,
        fallbackModuleID: String
    ) -> [String: Any] {
        var root = source
        var meta = root["meta"] as? [String: Any] ?? root
        meta["schemaVersion"] = string(meta["schemaVersion"]) ?? "1.0"
        if kind != .commentary {
            meta["id"] = safeIdentifier(string(meta["id"]) ?? fallbackModuleID)
            meta["type"] = kind.rawValue
        }
        if kind == .dictionary, string(meta["name"]) == nil {
            meta["name"] = fallbackModuleID
        }
        root["meta"] = meta
        return root
    }

    private static func moduleID(in root: [String: Any]) -> String? {
        guard let meta = root["meta"] as? [String: Any] else { return nil }
        return string(meta["id"])
    }

    private static func safeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let identifier = String(value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        })
        return identifier.isEmpty ? "webdav-module" : identifier
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func isMeaningful(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let value = value as? String {
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let value = value as? [Any] { return !value.isEmpty }
        if let value = value as? [String: Any] { return !value.isEmpty }
        return true
    }

    private static func bookName(_ number: Int) -> String {
        let names = [
            "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
            "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
            "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer", "Lam",
            "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah", "Mic", "Nah",
            "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt", "Mark", "Luke", "John",
            "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil", "Col", "1Thess",
            "2Thess", "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas", "1Pet",
            "2Pet", "1John", "2John", "3John", "Jude", "Rev",
        ]
        guard names.indices.contains(number - 1) else { return "Book\(number)" }
        return names[number - 1]
    }
}

public enum LampSyncError: LocalizedError {
    case unsafeArchivePath
    case unsupportedArchiveVersion
    case invalidResponse
    case httpStatus(Int)
    case archiveConversionFailed
    case invalidModuleJSON

    public var errorDescription: String? {
        switch self {
        case .unsafeArchivePath: "The sync archive contains an unsafe file path."
        case .unsupportedArchiveVersion: "This Lamp Bible sync archive version is not supported."
        case .invalidResponse: "The sync server returned an invalid response."
        case .httpStatus(let status): "The sync server returned HTTP status \(status)."
        case .archiveConversionFailed: "Lamp Bible could not prepare personal content for cross-device sync."
        case .invalidModuleJSON: "The WebDAV module JSON is not in a supported Lamp Bible format."
        }
    }
}
