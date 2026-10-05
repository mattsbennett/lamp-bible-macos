import Foundation
import LampModuleKit

/// Preserve the support module's public archive name while the codec lives in core.
public typealias LampSyncArchive = LampModuleKit.LampSyncArchive

/// Copies the user-authored portion of devotional agent workspaces, and
/// presentation decks, into and out of a portable backup. Custom skills are synchronized once as a shared catalog,
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
        // Compacted here, inside the staged transaction, so what gets published
        // is the merged history rather than every autosave since the last sync.
        for workspace in try childDirectoriesIfPresent(
            of: appending(agentWorkspacesPath, to: libraryRoot),
            fileManager: fileManager
        ) {
            try DevotionalAgentRevisionStore.compact(in: workspace)
        }
    }

    public static func exportPortableWorkspaces(
        from libraryRoot: URL,
        to backupRoot: URL,
        installID: String = LampInstallIdentity.current(),
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

        try LampPresentationDeckSync.exportDecks(from: libraryRoot, to: backupRoot, fileManager: fileManager)

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

            try exportConversations(
                from: workspace,
                to: portableWorkspace.appendingPathComponent(
                    conversationsDirectoryName,
                    isDirectory: true
                ),
                installID: installID,
                fileManager: fileManager
            )

            var fileLedger = WorkspaceFileLedger.load(in: workspace)
            fileLedger.noteChanges(present: try workspaceFiles(in: workspace, fileManager: fileManager)
                .mapValues(\.modified))
            try fileLedger.save(in: workspace)
            if !fileLedger.isEmpty {
                // Possibly all that's left of the workspace to send.
                try fileManager.createDirectory(at: portableWorkspace, withIntermediateDirectories: true)
                try fileLedger.portable.write(
                    to: portableWorkspace.appendingPathComponent(WorkspaceFileLedger.portableFilename)
                )
            }
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

        try LampPresentationDeckSync.importDecks(from: backupRoot, into: libraryRoot, fileManager: fileManager)

        let sourceRoot = appending(portableWorkspacesPath, to: backupRoot)
        guard fileManager.fileExists(atPath: sourceRoot.path) else { return }

        let destinationRoot = appending(agentWorkspacesPath, to: libraryRoot)
        for portableWorkspace in try childDirectories(of: sourceRoot, fileManager: fileManager) {
            let workspace = destinationRoot
                .appendingPathComponent(portableWorkspace.lastPathComponent, isDirectory: true)

            // Deletions made here since the last sync are noted before anything
            // arrives, or the incoming copies would simply put the files back.
            var fileLedger = WorkspaceFileLedger.load(in: workspace)
            fileLedger.noteChanges(present: try workspaceFiles(in: workspace, fileManager: fileManager)
                .mapValues(\.modified))
            fileLedger.merge(WorkspaceFileLedger.portable(
                in: portableWorkspace.appendingPathComponent(WorkspaceFileLedger.portableFilename)
            ))

            let documents = portableWorkspace.appendingPathComponent("Documents", isDirectory: true)
            for document in try childFilesIfPresent(of: documents, fileManager: fileManager)
            where isPortableDocument(document) {
                let key = WorkspaceFileLedger.documentKey(document.lastPathComponent)
                if fileLedger.isDeleted(key, modified: modificationTime(of: document)) { continue }
                try mergeFile(
                    from: document,
                    to: workspace.appendingPathComponent(document.lastPathComponent),
                    fileManager: fileManager
                )
            }

            try mergeTree(
                from: portableWorkspace.appendingPathComponent("Context", isDirectory: true),
                to: workspace.appendingPathComponent("context", isDirectory: true),
                skipping: { path, modified in
                    fileLedger.isDeleted(WorkspaceFileLedger.contextKey(path), modified: modified)
                },
                fileManager: fileManager
            )
            try WorkspaceContextFileStore.consolidate(
                in: workspace,
                libraryRootURL: libraryRoot,
                fileManager: fileManager
            )
            // Deleted elsewhere since this Mac's copy was saved.
            for (key, file) in try workspaceFiles(in: workspace, fileManager: fileManager)
            where fileLedger.isDeleted(key, modified: file.modified) {
                if WorkspaceFileLedger.isContextKey(key) {
                    try WorkspaceContextFileStore.removeSyncedContextFile(
                        at: file.url, libraryRootURL: libraryRoot, fileManager: fileManager
                    )
                } else {
                    try fileManager.removeItem(at: file.url)
                }
            }
            fileLedger.recordSynced(try workspaceFiles(in: workspace, fileManager: fileManager)
                .mapValues(\.modified))
            try fileLedger.save(in: workspace)

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
            // The union merge above brings back any original that another Mac
            // still holds, even after it was compacted away here. Compacting the
            // merged set recognises those against the revisions that replaced them.
            try DevotionalAgentRevisionStore.compact(in: workspace)

            try importConversations(
                from: portableWorkspace.appendingPathComponent(
                    conversationsDirectoryName,
                    isDirectory: true
                ),
                into: workspace,
                fileManager: fileManager
            )
        }
    }

    /// Chat transcripts travel; the providers' own session stores do not. A
    /// transcript is enough to read a conversation on another Mac and to carry it
    /// on from a recap, at a few kilobytes rather than the providers' private,
    /// version-specific files.
    private static let conversationsDirectoryName = "Conversations"

    private static func exportConversations(
        from workspace: URL,
        to destination: URL,
        installID: String,
        fileManager: FileManager
    ) throws {
        let source = AgentChatTranscriptStore.directory(in: workspace)
        guard fileManager.fileExists(atPath: source.path) else { return }
        for url in try childFiles(of: source, fileManager: fileManager)
        where AgentChatTranscriptStore.isTranscriptFilename(url.lastPathComponent) {
            // An unreadable transcript stays where it is rather than spreading.
            guard let transcript = try? AgentChatTranscriptStore.decode(Data(contentsOf: url))
            else { continue }
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try ensureSafeDestination(target, fileManager: fileManager)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            // Stamped on the way out, so the other Mac can tell the session is
            // this one's even if the transcript predates ownership being recorded.
            try AgentChatTranscriptStore
                .encode(transcript.attributingSession(toInstall: installID))
                .write(to: target, options: .atomic)
        }
    }

    private static func importConversations(
        from source: URL,
        into workspace: URL,
        fileManager: FileManager
    ) throws {
        for incomingURL in try childFilesIfPresent(of: source, fileManager: fileManager)
        where AgentChatTranscriptStore.isTranscriptFilename(incomingURL.lastPathComponent) {
            guard let incoming = try? AgentChatTranscriptStore.decode(Data(contentsOf: incomingURL))
            else { continue }
            let localURL = AgentChatTranscriptStore.directory(in: workspace)
                .appendingPathComponent(incomingURL.lastPathComponent)

            let merged: AgentChatTranscript
            if fileManager.fileExists(atPath: localURL.path) {
                let values = try localURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LampSyncError.unsafeArchivePath
                }
                // Last-writer-wins by modification date would drop whichever side
                // chatted less recently, so the two copies are reconciled instead.
                if let local = try? AgentChatTranscriptStore.decode(Data(contentsOf: localURL)) {
                    merged = AgentChatTranscriptMerge.merge(local: local, incoming: incoming)
                    guard merged != local else { continue }
                } else {
                    merged = incoming
                }
            } else {
                merged = incoming
            }

            try ensureSafeDestination(localURL, fileManager: fileManager)
            try fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AgentChatTranscriptStore.encode(merged).write(to: localURL, options: .atomic)
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
        skipping shouldSkip: ((_ relativePath: String, _ modified: Int64) -> Bool)? = nil,
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
            let relativePath = String(path.dropFirst(prefix.count))
            if let shouldSkip, shouldSkip(relativePath, modificationTime(of: url)) { continue }
            try mergeFile(
                from: url,
                to: destination.appendingPathComponent(relativePath),
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

    private static func modificationTime(of url: URL) -> Int64 {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return WorkspaceFileLedger.milliseconds(date ?? .distantPast)
    }

    /// The workspace's own files that sync carries: top-level documents and
    /// everything in `context`, keyed as `WorkspaceFileLedger` keys them.
    static func workspaceFiles(
        in workspace: URL,
        fileManager: FileManager
    ) throws -> [String: (url: URL, modified: Int64)] {
        var files: [String: (url: URL, modified: Int64)] = [:]
        for document in try childFilesIfPresent(of: workspace, fileManager: fileManager)
        where isPortableDocument(document) {
            files[WorkspaceFileLedger.documentKey(document.lastPathComponent)] =
                (document, modificationTime(of: document))
        }
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        guard isSafeDirectory(context),
              let enumerator = fileManager.enumerator(
                at: context,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return files }
        let prefix = context.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard values.isRegularFile == true, path.hasPrefix(prefix) else { continue }
            files[WorkspaceFileLedger.contextKey(String(path.dropFirst(prefix.count)))] =
                (url, modificationTime(of: url))
        }
        return files
    }

    private static func isSafeDirectory(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

/// What sync last saw of a workspace's own files, and which have been deleted
/// or added since, so that a deletion reaches other Macs instead of being undone
/// by their copies. Times are milliseconds since 1970.
///
/// Workspace files change outside Lamp too — agents and Finder delete them —
/// so deletions are found by comparing with the last sync rather than recorded
/// as they happen.
struct WorkspaceFileLedger: Codable, Equatable {
    static let portableFilename = "DeletedFiles.json"
    private static let localFilename = "sync-files.json"

    var formatVersion = 1
    /// Files present after the last sync, with their modification times. Nil
    /// until a first sync, which records what's there and nothing more: a Mac
    /// first syncing after an upgrade must not treat its files as new.
    var synced: [String: Int64]?
    var deletedAt: [String: Int64] = [:]
    /// When context files appeared here. Context files are links to shared
    /// objects whose modification times are those of whichever copy came
    /// first, so a file added again could look older than its own deletion.
    var presentSince: [String: Int64] = [:]

    struct Portable: Codable, Equatable {
        var formatVersion = 1
        var deletedAt: [String: Int64]
        var presentSince: [String: Int64]

        func write(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    static func documentKey(_ filename: String) -> String { "Documents/" + filename }
    static func contextKey(_ relativePath: String) -> String { "Context/" + relativePath }
    static func isContextKey(_ key: String) -> Bool { key.hasPrefix("Context/") }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    var isEmpty: Bool { deletedAt.isEmpty && presentSince.isEmpty }
    var portable: Portable { Portable(deletedAt: deletedAt, presentSince: presentSince) }

    static func load(in workspace: URL) -> WorkspaceFileLedger {
        guard let data = try? Data(contentsOf: url(in: workspace)),
              let ledger = try? JSONDecoder().decode(WorkspaceFileLedger.self, from: data)
        else { return WorkspaceFileLedger() }
        return ledger
    }

    func save(in workspace: URL) throws {
        let destination = Self.url(in: workspace)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: destination, options: .atomic)
    }

    static func portable(in url: URL) -> Portable? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Portable.self, from: data)
    }

    private static func url(in workspace: URL) -> URL {
        AgentChatTranscriptStore.directory(in: workspace).appendingPathComponent(localFilename)
    }

    /// Compares the files present now with those at the last sync.
    mutating func noteChanges(present: [String: Int64], now: Date = Date()) {
        guard let synced else {
            self.synced = present
            return
        }
        let time = Self.milliseconds(now)
        for (key, modified) in synced where present[key] == nil {
            // A document's deletion covers the last version this Mac had, so a
            // later edit made elsewhere survives it. Context files' times aren't
            // comparable across Macs, so theirs is when it was noticed.
            let deleted = Self.isContextKey(key) ? time : modified
            deletedAt[key] = max(deletedAt[key] ?? .min, deleted)
        }
        for key in present.keys where synced[key] == nil && Self.isContextKey(key) {
            presentSince[key] = max(presentSince[key] ?? .min, time)
        }
        self.synced = present
    }

    mutating func recordSynced(_ present: [String: Int64]) {
        synced = present
    }

    mutating func merge(_ portable: Portable?) {
        guard let portable else { return }
        deletedAt.merge(portable.deletedAt) { max($0, $1) }
        presentSince.merge(portable.presentSince) { max($0, $1) }
    }

    func isDeleted(_ key: String, modified: Int64) -> Bool {
        guard let deleted = deletedAt[key] else { return false }
        return deleted >= max(modified, presentSince[key] ?? .min)
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
