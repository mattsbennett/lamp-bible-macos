import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import LampModuleKit
import Security

@MainActor
final class LibrarySyncController: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case off
        case folder
        case webDAV

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .off: "Off"
            case .folder: "iCloud Drive or Folder"
            case .webDAV: "WebDAV"
            }
        }
    }

    @Published private(set) var isSyncing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let automaticSync = LampSyncOnce()

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: "sync.provider") ?? "off") ?? .off }
        set {
            defaults.set(newValue.rawValue, forKey: "sync.provider")
            objectWillChange.send()
        }
    }

    var folderName: String? {
        guard let url = try? resolveFolderURL() else { return nil }
        return url.lastPathComponent
    }

    var endpoint: String {
        get { defaults.string(forKey: "sync.webdav.endpoint") ?? "" }
        set { defaults.set(newValue, forKey: "sync.webdav.endpoint") }
    }

    var username: String {
        get { defaults.string(forKey: "sync.webdav.username") ?? "" }
        set { defaults.set(newValue, forKey: "sync.webdav.username") }
    }

    func updateWebDAVPassword(_ password: String) -> Bool {
        do {
            try SyncSecretStore.setPassword(password)
            errorMessage = nil
            statusMessage = "WebDAV password saved."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Lamp Bible Sync Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: "sync.folderBookmark")
            provider = .folder
            errorMessage = nil
            objectWillChange.send()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncAutomaticallyIfNeeded(library: LampLibrary) async {
        guard !isSyncing,
              defaults.bool(forKey: "sync.automatic"),
              provider != .off else { return }
        do {
            try await automaticSync.run {
                guard await self.sync(library: library) else {
                    throw AutomaticSyncError.failed
                }
            }
        } catch {
            // Keep the gate open; sync(library:) reports operational errors.
        }
    }

    @discardableResult
    func sync(library: LampLibrary) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        errorMessage = nil
        statusMessage = "Preparing sync…"
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-sync-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: workspace) }
            try LampSyncSettingsCommit.recover(
                from: library.rootURL, to: defaults, fileManager: fileManager
            )
            let incoming = workspace.appendingPathComponent("Incoming", isDirectory: true)
            let outgoing = workspace.appendingPathComponent("Outgoing", isDirectory: true)

            switch provider {
            case .off:
                throw LibrarySyncError.providerNotConfigured
            case .folder:
                let folder = try resolveFolderURL()
                let preferenceSource = "folder:\(folder.standardizedFileURL.path)"
                var preferenceLedgerToPublish: LampSharedPreferenceLedger?
                var observedFolder: LampSyncArchive?
                let hasScope = folder.startAccessingSecurityScopedResource()
                defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
                try await LampSyncEngine.run(
                    pullAndMerge: {
                        let observed: LampSyncArchive
                        do {
                            observed = try await LampSyncFolderPublisher.capture(
                                from: folder, fileManager: self.fileManager
                            )
                        } catch LampSyncFolderPublisher.FolderError.incompletePublication {
                            self.statusMessage = "Recovering interrupted folder sync…"
                            observed = try await LampSyncFolderPublisher.recoverIncompletePublication(
                                from: folder, fileManager: self.fileManager
                            )
                        }
                        observedFolder = observed
                        if observed.entries.contains(where: {
                            $0.path == LampPortableBackupLayout.manifestPath
                        }) {
                            self.statusMessage = "Merging changes from \(folder.lastPathComponent)…"
                            try observed.extract(to: incoming, fileManager: self.fileManager)
                            let stagedSettings = try self.beginStagedSettings()
                            defer { stagedSettings.discard() }
                            try await library.withStagedChanges { stagedLibrary in
                                _ = try await stagedLibrary.importPortableBackup(from: incoming)
                                preferenceLedgerToPublish = try self.importSettingsAndMergePreferences(
                                    from: incoming, source: preferenceSource,
                                    targetDefaults: stagedSettings.defaults,
                                    storedIn: stagedSettings.domainName
                                )
                                try LampWorkspaceSync.importPortableWorkspaces(
                                    from: incoming, into: stagedLibrary.rootURL,
                                    fileManager: self.fileManager
                                )
                                try self.ensureSettingsUnchanged(stagedSettings)
                                try self.stageSettingsCommit(
                                    stagedSettings, highlightMapping: nil,
                                    in: stagedLibrary.rootURL
                                )
                            }
                            try LampSyncSettingsCommit.recover(
                                from: library.rootURL, to: self.defaults,
                                fileManager: self.fileManager
                            )
                        } else {
                            try await library.withStagedChanges { stagedLibrary in
                                try LampWorkspaceSync.prepareLibraryForSync(
                                    at: stagedLibrary.rootURL, fileManager: self.fileManager
                                )
                            }
                        }
                    },
                    publish: {
                        self.statusMessage = "Publishing library…"
                        _ = try await library.exportPortableBackup(to: outgoing)
                        try self.exportSettings(to: outgoing)
                        if preferenceLedgerToPublish == nil {
                            preferenceLedgerToPublish = try self.mergePreferenceLedger(
                                remote: nil,
                                source: preferenceSource
                            )
                        }
                        if let preferenceLedgerToPublish {
                            try self.exportPreferenceLedger(preferenceLedgerToPublish, to: outgoing)
                        }
                        try LampWorkspaceSync.exportPortableWorkspaces(
                            from: library.rootURL,
                            to: outgoing,
                            fileManager: self.fileManager
                        )
                        guard let observedFolder else {
                            throw LampSyncFolderPublisher.FolderError.unreadable(folder.path)
                        }
                        let archive = try LampSyncArchive.create(
                            from: outgoing, fileManager: self.fileManager
                        )
                        try await LampSyncFolderPublisher.publish(
                            archive,
                            to: folder,
                            replacing: observedFolder,
                            fileManager: self.fileManager
                        )
                        if let preferenceLedgerToPublish {
                            try self.rememberPreferenceLedger(
                                preferenceLedgerToPublish,
                                source: preferenceSource
                            )
                        }
                    },
                    complete: {
                        self.defaults.set(Date(), forKey: "sync.lastCompleted")
                        self.statusMessage = "Synced \(Date().formatted(date: .abbreviated, time: .shortened))"
                    }
                )
            case .webDAV:
                guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
                    throw LibrarySyncError.invalidWebDAVURL
                }
                let storedPassword = SyncSecretStore.password ?? ""
                let credentials = username.isEmpty && storedPassword.isEmpty
                    ? nil : LampWebDAVCredentials(username: username, password: storedPassword)
                let client = LampWebDAVClient(baseURL: url, credentials: credentials)
                let preferenceSource = "webdav:\(url.absoluteString)"
                var preferenceLedgerToPublish: LampSharedPreferenceLedger?
                var iOSImportSummary = IOSWebDAVImportSummary()
                var archiveSnapshot: LampSyncArchiveRemote.Snapshot?
                var remoteCompatibilityManifest: LampCompatibilityManifest?
                try await LampSyncEngine.run(
                    pullAndMerge: {
                        statusMessage = "Downloading WebDAV library…"
                        let stagedSettings = try beginStagedSettings()
                        defer { stagedSettings.discard() }
                        try await library.withStagedChanges { stagedLibrary in
                            try LampWorkspaceSync.prepareLibraryForSync(
                                at: stagedLibrary.rootURL, fileManager: fileManager
                            )
                            do {
                                archiveSnapshot = try await LampSyncArchiveRemote.read(from: client)
                                if let archiveSnapshot {
                                    do {
                                        _ = try archiveSnapshot.writeCondition
                                    } catch {
                                        iOSImportSummary.failures.append(
                                            "lamp-bible.lampsync (the server did not supply a strong ETag)"
                                        )
                                    }
                                    let archive = archiveSnapshot.archive
                                    remoteCompatibilityManifest = archiveSnapshot.compatibilityManifest
                                    try archive.extract(to: incoming)
                                    iOSImportSummary.failures.append(contentsOf:
                                        normalizeArchivedDevotionalJSON(in: incoming)
                                    )
                                    do {
                                        _ = try await stagedLibrary.importPortableBackup(from: incoming)
                                    } catch {
                                        // Scan the canonical iOS folders even if the archive fails.
                                        iOSImportSummary.failures.append(
                                            "lamp-bible.lampsync (\(error.localizedDescription))"
                                        )
                                    }
                                    do {
                                        preferenceLedgerToPublish = try importSettingsAndMergePreferences(
                                            from: incoming, source: preferenceSource,
                                            targetDefaults: stagedSettings.defaults,
                                            storedIn: stagedSettings.domainName
                                        )
                                    } catch {
                                        iOSImportSummary.failures.append(
                                            "lamp-bible.lampsync settings (\(error.localizedDescription))"
                                        )
                                    }
                                    do {
                                        try LampWorkspaceSync.importPortableWorkspaces(
                                            from: incoming,
                                            into: stagedLibrary.rootURL,
                                            fileManager: fileManager
                                        )
                                    } catch {
                                        iOSImportSummary.failures.append(
                                            "lamp-bible.lampsync workspaces (\(error.localizedDescription))"
                                        )
                                    }
                                }
                            } catch {
                                iOSImportSummary.failures.append(
                                    "lamp-bible.lampsync (\(error.localizedDescription))"
                                )
                            }
                            statusMessage = "Importing iPhone and iPad library…"
                            iOSImportSummary.merge(try await importIOSWebDAVContent(
                                using: client, into: workspace,
                                library: stagedLibrary,
                                compatibilityManifest: remoteCompatibilityManifest
                            ))
                            guard iOSImportSummary.failures.isEmpty else {
                                throw LibrarySyncError.incompleteRemoteImport(iOSImportSummary.failures)
                            }
                            try ensureSettingsUnchanged(stagedSettings)
                            try stageSettingsCommit(
                                stagedSettings,
                                highlightMapping: iOSImportSummary.highlightModuleIDsBySet,
                                in: stagedLibrary.rootURL
                            )
                        }
                        try LampSyncSettingsCommit.recover(
                            from: library.rootURL, to: defaults, fileManager: fileManager
                        )
                    },
                    publish: {
                        statusMessage = "Uploading WebDAV library…"
                        _ = try await library.exportPortableBackup(to: outgoing)
                        try exportSettings(to: outgoing)
                        if preferenceLedgerToPublish == nil {
                            preferenceLedgerToPublish = try mergePreferenceLedger(
                                remote: nil,
                                source: preferenceSource
                            )
                        }
                        if let preferenceLedgerToPublish {
                            try exportPreferenceLedger(preferenceLedgerToPublish, to: outgoing)
                        }
                        try LampWorkspaceSync.exportPortableWorkspaces(
                            from: library.rootURL,
                            to: outgoing,
                            fileManager: fileManager
                        )
                        let compatible = try await prepareIOSWebDAVContent(
                            using: client, from: workspace,
                            library: library,
                            imported: iOSImportSummary
                        )
                        for file in compatible.files {
                            let destination = outgoing
                                .appendingPathComponent(LampPortableBackupLayout.compatibleDirectory)
                                .appendingPathComponent(file.remotePath)
                            try fileManager.createDirectory(
                                at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try file.data.write(to: destination, options: .atomic)
                        }
                        let compatibilityManifest = LampCompatibilityManifest(
                            files: try compatible.files.map { file in
                                LampCompatibilityManifest.File(
                                    path: file.remotePath,
                                    data: file.data,
                                    baseRevision: try file.baseRevision()
                                )
                            }
                        )
                        try JSONEncoder().encode(compatibilityManifest).write(
                            to: outgoing.appendingPathComponent(
                                LampPortableBackupLayout.compatibilityManifestPath
                            ),
                            options: .atomic
                        )
                        let archive = try LampSyncSettingsArchive.preservingRemoteEntry(
                            in: LampSyncArchive.create(from: outgoing),
                            from: archiveSnapshot?.archive
                        )
                        try await LampSyncArchiveRemote.publish(
                            archive,
                            replacing: archiveSnapshot,
                            in: client
                        )
                        if let preferenceLedgerToPublish {
                            try rememberPreferenceLedger(
                                preferenceLedgerToPublish,
                                source: preferenceSource
                            )
                        }
                        statusMessage = "Publishing iPhone and iPad compatible library…"
                        try await publishIOSWebDAVContent(
                            using: client,
                            batch: compatible
                        )
                    },
                    complete: {
                        defaults.set(Date(), forKey: "sync.lastCompleted")
                        let date = Date().formatted(date: .abbreviated, time: .shortened)
                        if iOSImportSummary.downloadedCount > 0 {
                            statusMessage = "Synced \(date) — downloaded \(iOSImportSummary.downloadedCount) item\(iOSImportSummary.downloadedCount == 1 ? "" : "s")"
                        } else {
                            statusMessage = "Synced \(date)"
                        }
                    }
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            isSyncing = false
            return false
        }
        isSyncing = false
        return true
    }

    private func importIOSWebDAVContent(
        using client: LampWebDAVClient,
        into workspace: URL,
        library: LampLibrary,
        compatibilityManifest: LampCompatibilityManifest?
    ) async throws -> IOSWebDAVImportSummary {
        let importDirectory = workspace.appendingPathComponent("iOS WebDAV", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        var summary = IOSWebDAVImportSummary()
        var highlightModuleIDsBySet = defaults.dictionary(
            forKey: Self.iOSHighlightModuleIDsBySetKey
        ) as? [String: String] ?? [:]

        for source in IOSWebDAVModuleDirectory.allCases {
            let filenames: [String]
            do {
                filenames = try await client.listModuleFilenames(directory: source.rawValue)
            } catch {
                summary.failures.append(
                    "\(source.rawValue) (could not list folder: \(error.localizedDescription))"
                )
                continue
            }
            var candidates: [IOSWebDAVImportCandidate] = []
            for filename in filenames.sorted() where LampSyncModuleFiles.moduleID(from: filename) != nil {
                let remotePath = "\(source.rawValue)/\(filename)"
                var superseded = false
                do {
                    guard let remote = try await client.read(path: remotePath) else {
                        throw LampSyncError.invalidResponse
                    }
                    do {
                        summary.writeConditions[remotePath] = try LampSyncConditionalWrite.condition(
                            for: remote
                        )
                    } catch {
                        summary.writeConditions[remotePath] = .unconditional
                        summary.failures.append(
                            "\(remotePath) (the server did not supply a strong ETag)"
                        )
                    }
                    superseded = compatibilityManifest?.supersedes(
                        path: remotePath,
                        revision: remote.revision
                    ) == true
                    let isJSON = filename.lowercased().hasSuffix(".json")
                    if isJSON {
                        let documents = try LampWebDAVModuleJSONAdapter.documents(
                            from: remote.data,
                            kind: source.kind,
                            fallbackModuleID: remoteModuleStem(filename)
                        )
                        candidates.append(contentsOf: documents.map { document in
                            IOSWebDAVImportCandidate(
                                filename: filename, remotePath: remotePath,
                                moduleID: document.moduleID, data: document.data,
                                syncIdentity: LampSyncModuleFiles.canonicalIdentity(
                                    document.syncIdentity, isNotes: source == .notes
                                ),
                                isJSON: true, superseded: superseded, remoteSetID: nil
                            )
                        })
                    } else {
                        let data = try compressedModuleData(remote.data, filename: filename)
                        let descriptor = try LampPortableModuleInspector.inspectRemote(
                            data: remote.data, filename: filename,
                            fallbackID: remoteModuleStem(filename),
                            expectedKind: source.kind, fileManager: fileManager
                        )
                        let remoteSetID = source == .highlights
                            ? try LampWebDAVPersonalArchiveAdapter.highlightSetID(
                                in: data, fileManager: fileManager
                            )
                            : nil
                        candidates.append(IOSWebDAVImportCandidate(
                            filename: filename, remotePath: remotePath,
                            moduleID: descriptor.id, data: data,
                            syncIdentity: LampSyncModuleFiles.canonicalIdentity(
                                descriptor.id, isNotes: source == .notes
                            ),
                            isJSON: false, superseded: superseded,
                            remoteSetID: remoteSetID
                        ))
                    }
                } catch {
                    if !superseded {
                        summary.failures.append("\(remotePath) (\(error.localizedDescription))")
                    }
                }
            }

            let selectedIndices = LampSyncModuleFiles.preferredCandidateIndices(
                candidates.map {
                    .init(
                        identity: $0.syncIdentity, path: $0.remotePath,
                        isSuperseded: $0.superseded
                    )
                }
            )
            for index in selectedIndices {
                let candidate = candidates[index]
                do {
                    switch source {
                    case .notes, .highlights, .devotionals:
                        let localURL = importDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(candidate.isJSON ? "json" : "lamp")
                        try candidate.data.write(to: localURL, options: .atomic)
                        if source == .devotionals {
                            let incoming = try await library.personalDevotionalCandidates(
                                from: localURL
                            )
                            let imported = try await library.importPersonalDevotional(from: localURL)
                            let incomingIDs = Set(incoming.map(\.id))
                            let retained = try await library.personalDevotionals()
                                .filter { incomingIDs.contains($0.id) }
                            let mediaModuleID = candidate.isJSON
                                ? remoteModuleStem(candidate.filename)
                                : candidate.moduleID
                            try await LampSyncDevotionalMedia.downloadToLibrary(
                                for: retained, from: mediaModuleID,
                                into: library.rootURL
                            ) { path in
                                guard let file = try await client.read(path: path) else {
                                    throw LibrarySyncError.incompleteRemoteImport([path])
                                }
                                return file.data
                            }
                            summary.devotionals += imported.count
                        } else {
                            let result = try await library.importPersonalStudyData(from: localURL)
                            summary.studyEntries += result.importedCount
                        }
                        if let remoteSetID = candidate.remoteSetID {
                            highlightModuleIDsBySet[remoteSetID] = safeRemoteIdentifier(
                                remoteModuleStem(candidate.filename)
                            )
                        }

                    case .translations, .dictionaries, .commentaries, .books, .plans, .quizzes:
                        let moduleURL = importDirectory
                            .appendingPathComponent(safeRemoteIdentifier(candidate.moduleID))
                            .appendingPathExtension("lamp")
                        if candidate.isJSON {
                            _ = try LampModuleCompiler().compile(
                                data: candidate.data,
                                sourceFilename: candidate.filename,
                                destinationURL: moduleURL
                            )
                        } else {
                            try candidate.data.write(to: moduleURL, options: .atomic)
                        }
                        _ = try await library.install(from: moduleURL)
                        summary.modules += 1
                    }
                } catch {
                    summary.failures.append(
                        "\(candidate.remotePath) (\(error.localizedDescription))"
                    )
                }
            }
        }

        summary.highlightModuleIDsBySet = highlightModuleIDsBySet
        return summary
    }

    private func normalizeArchivedDevotionalJSON(in backupDirectory: URL) -> [String] {
        let directory = backupDirectory.appendingPathComponent(LampPortableBackupLayout.devotionalsDirectory, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let urls = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.path < $1.path }
        var failures: [String] = []

        for url in urls {
            do {
                let documents = try LampWebDAVModuleJSONAdapter.documents(
                    from: Data(contentsOf: url, options: .mappedIfSafe),
                    kind: .devotional,
                    fallbackModuleID: url.deletingPathExtension().lastPathComponent
                )
                try fileManager.removeItem(at: url)
                for (index, document) in documents.enumerated() {
                    let filename = documents.count == 1
                        ? "\(document.moduleID).json"
                        : "\(document.moduleID)-\(index + 1).json"
                    try document.data.write(
                        to: url.deletingLastPathComponent().appendingPathComponent(filename),
                        options: .atomic
                    )
                }
            } catch {
                // This is a disposable extracted copy. Excluding the bad file
                // lets the rest of the archive and the live WebDAV folders load;
                // the original remote file remains untouched and is reported.
                try? fileManager.removeItem(at: url)
                failures.append(
                    "lamp-bible.lampsync/Devotionals/\(url.lastPathComponent) (\(error.localizedDescription))"
                )
            }
        }
        return failures
    }

    private func prepareIOSWebDAVContent(
        using client: LampWebDAVClient,
        from workspace: URL,
        library: LampLibrary,
        imported: IOSWebDAVImportSummary
    ) async throws -> IOSWebDAVExportBatch {
        let exportDirectory = workspace.appendingPathComponent("iOS Exports", isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        var files: [IOSWebDAVExportFile] = []

        // Publish media before the module that references it. An unchanged
        // existing remote file needs no write; a different file at the same
        // immutable path is a conflict, not an overwrite.
        let localMedia = try LampSyncDevotionalMedia.outgoingFiles(
            for: await library.personalDevotionals(),
            to: "devotionals", from: library.rootURL,
            fileManager: fileManager
        )
        for media in try await LampSyncDevotionalMedia.pendingUploads(
            localMedia, readRemote: { try await client.read(path: $0) }
        ) {
            files.append(IOSWebDAVExportFile(
                remotePath: media.remotePath, data: media.data,
                condition: media.condition
            ))
        }

        for export in [
            (
                module: LampPersonalModule.notes,
                directory: LampSyncContentKind.notes.rawValue,
                filename: "notes.lamp",
                iOSModuleID: "notes",
                archiveKind: LampWebDAVPersonalArchiveKind.notes
            ),
            (
                module: LampPersonalModule.writing,
                directory: LampSyncContentKind.devotionals.rawValue,
                filename: "devotionals.lamp",
                iOSModuleID: "devotionals",
                archiveKind: LampWebDAVPersonalArchiveKind.devotionals
            ),
        ] {
            let localURL = exportDirectory.appendingPathComponent(export.filename)
            try await library.exportPersonalModule(export.module, format: .lamp, to: localURL)
            let archive = try LampWebDAVPersonalArchiveAdapter.archive(
                Data(contentsOf: localURL, options: .mappedIfSafe),
                replacingModuleIDWith: export.iOSModuleID,
                kind: export.archiveKind,
                mediaRootURL: library.rootURL,
                fileManager: fileManager
            )
            let remotePath = "\(export.directory)/\(export.filename)"
            files.append(IOSWebDAVExportFile(
                remotePath: remotePath,
                data: archive,
                condition: try imported.writeCondition(for: remotePath)
            ))
        }

        var highlightModuleIDsBySet = defaults.dictionary(
            forKey: Self.iOSHighlightModuleIDsBySetKey
        ) as? [String: String] ?? [:]
        for set in try await library.highlightSets() {
            let moduleID = safeRemoteIdentifier(
                highlightModuleIDsBySet[set.id] ?? set.id
            )
            guard let document = try await LampSyncPersonalExport.highlightsIfPresent({
                try await library.personalHighlightsDocument(
                    translationID: set.translationID,
                    moduleID: moduleID,
                    name: set.name,
                    setID: set.id
                )
            }) else { continue }
            let localURL = exportDirectory.appendingPathComponent(document.suggestedModuleFilename)
            _ = try LampModuleCompiler().compile(
                data: document.jsonData,
                sourceFilename: document.suggestedJSONFilename,
                destinationURL: localURL
            )
            let remotePath = "\(LampSyncContentKind.highlights.rawValue)/\(document.suggestedModuleFilename)"
            files.append(IOSWebDAVExportFile(
                remotePath: remotePath,
                data: try Data(contentsOf: localURL, options: .mappedIfSafe),
                condition: try imported.writeCondition(for: remotePath)
            ))
            highlightModuleIDsBySet[set.id] = moduleID
        }
        return IOSWebDAVExportBatch(
            files: files,
            highlightModuleIDsBySet: highlightModuleIDsBySet
        )
    }

    private func publishIOSWebDAVContent(
        using client: LampWebDAVClient,
        batch: IOSWebDAVExportBatch
    ) async throws {
        let preparedDirectories = Set(batch.files.map {
            String($0.remotePath.prefix { $0 != "/" })
        })
        try await LampSyncCompatibilityPublisher.publish(
            batch.files.map {
                .init(
                    remotePath: $0.remotePath,
                    data: $0.data,
                    condition: $0.condition
                )
            },
            in: client,
            prepareDirectory: { try await client.createDirectory($0) }
        )
        if !preparedDirectories.contains(LampSyncContentKind.highlights.rawValue) {
            try await client.createDirectory(LampSyncContentKind.highlights.rawValue)
        }
        defaults.set(
            batch.highlightModuleIDsBySet,
            forKey: Self.iOSHighlightModuleIDsBySetKey
        )
    }

    private func compressedModuleData(_ data: Data, filename: String) throws -> Data {
        guard filename.lowercased().hasSuffix(".db") else { return data }
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            throw LampSyncError.archiveConversionFailed
        }
        return compressed
    }

    private func remoteModuleStem(_ filename: String) -> String {
        LampSyncModuleFiles.moduleID(from: filename)
            ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }

    private func safeRemoteIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let identifier = String(scalars)
        return identifier.isEmpty ? "personal-highlights" : identifier
    }

    private static let iOSHighlightModuleIDsBySetKey = "sync.webdav.iosHighlightModuleIDsBySet"

    private func resolveFolderURL() throws -> URL {
        guard let data = defaults.data(forKey: "sync.folderBookmark") else {
            throw LibrarySyncError.folderNotConfigured
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            let refreshed = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(refreshed, forKey: "sync.folderBookmark")
        }
        return url
    }

    private func exportSettings(to directory: URL) throws {
        let data = try LampPortableSettingsCodec.encode(from: defaults)
        try data.write(
            to: directory.appendingPathComponent(LampPortableBackupLayout.settingsPath),
            options: .atomic
        )
    }

    private func importSettings(
        from directory: URL,
        excluding excludedKeys: Set<String> = [],
        to targetDefaults: UserDefaults
    ) throws {
        let url = directory.appendingPathComponent(LampPortableBackupLayout.settingsPath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try LampPortableSettingsCodec.apply(
            Data(contentsOf: url),
            to: targetDefaults,
            excluding: excludedKeys
        )
    }

    private func importSettingsAndMergePreferences(
        from directory: URL,
        source: String,
        targetDefaults: UserDefaults,
        storedIn domainName: String
    ) throws -> LampSharedPreferenceLedger {
        let remote = try readPreferenceLedger(from: directory)
        let hasSharedHistory = remote != nil || cachedPreferenceLedger(for: source) != nil
        try importSettings(
            from: directory,
            excluding: hasSharedHistory ? LampSharedPreferenceLedger.sharedKeys : [],
            to: targetDefaults
        )
        return try mergePreferenceLedger(
            remote: remote, source: source,
            targetDefaults: targetDefaults, storedIn: domainName
        )
    }

    private func readPreferenceLedger(from directory: URL) throws -> LampSharedPreferenceLedger? {
        let url = directory.appendingPathComponent(LampPortableBackupLayout.sharedPreferencesPath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try LampSyncPreferenceState.decode(Data(contentsOf: url))
    }

    private func mergePreferenceLedger(
        remote: LampSharedPreferenceLedger?,
        source: String,
        targetDefaults: UserDefaults? = nil,
        storedIn domainName: String? = Bundle.main.bundleIdentifier
    ) throws -> LampSharedPreferenceLedger {
        let targetDefaults = targetDefaults ?? defaults
        let local = try LampSharedPreferenceLedger.explicitValues(
            from: targetDefaults,
            storedIn: domainName
        )
        let merged = try LampSharedPreferenceLedger.merge(
            local: local,
            base: cachedPreferenceLedger(for: source),
            remote: remote
        )
        try merged.apply(to: targetDefaults)
        return merged
    }

    private func beginStagedSettings() throws -> StagedSyncSettings {
        let domainName = "lamp-sync-settings-\(UUID().uuidString)"
        guard let stagedDefaults = UserDefaults(suiteName: domainName) else {
            throw LampLibraryError.syncConflict("Could not prepare sync settings.")
        }
        let baseline = LampSyncSettingsCommit.explicitSettings(from: defaults)
        stagedDefaults.setPersistentDomain(baseline, forName: domainName)
        return StagedSyncSettings(
            defaults: stagedDefaults, domainName: domainName, baseline: baseline,
            highlightMappingBaseline: defaults.dictionary(
                forKey: Self.iOSHighlightModuleIDsBySetKey
            ) as? [String: String]
        )
    }

    private func ensureSettingsUnchanged(_ staged: StagedSyncSettings) throws {
        let current = LampSyncSettingsCommit.explicitSettings(from: defaults)
        guard NSDictionary(dictionary: current).isEqual(to: staged.baseline) else {
            throw LampLibraryError.syncConflict("Local settings changed during sync import.")
        }
        let currentHighlightMapping = defaults.dictionary(
            forKey: Self.iOSHighlightModuleIDsBySetKey
        ) as? [String: String]
        guard (currentHighlightMapping ?? [:]) == (staged.highlightMappingBaseline ?? [:]) else {
            throw LampLibraryError.syncConflict("Local highlight sync mapping changed during import.")
        }
    }

    private func stageSettingsCommit(
        _ staged: StagedSyncSettings,
        highlightMapping: [String: String]?,
        in libraryRoot: URL
    ) throws {
        let planned = staged.defaults.persistentDomain(forName: staged.domainName) ?? [:]
        let settingsChanged = !NSDictionary(dictionary: planned).isEqual(to: staged.baseline)
        let mappingChanged = highlightMapping.map {
            $0 != (staged.highlightMappingBaseline ?? [:])
        } ?? false
        guard settingsChanged || mappingChanged else { return }
        try LampSyncSettingsCommit.stage(
            baseline: staged.baseline, planned: planned,
            highlightMappingBaseline: staged.highlightMappingBaseline,
            plannedHighlightMapping: highlightMapping,
            in: libraryRoot, fileManager: fileManager
        )
    }

    private func exportPreferenceLedger(
        _ ledger: LampSharedPreferenceLedger,
        to directory: URL
    ) throws {
        let url = directory.appendingPathComponent(LampPortableBackupLayout.sharedPreferencesPath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try LampSyncPreferenceState.encode(ledger).write(to: url, options: .atomic)
    }

    private static let preferenceLedgerStateKey = "sync.sharedPreferences.bases"

    private func cachedPreferenceLedger(for source: String) -> LampSharedPreferenceLedger? {
        LampSyncPreferenceState.cached(
            for: source, in: defaults, key: Self.preferenceLedgerStateKey
        )
    }

    private func rememberPreferenceLedger(
        _ ledger: LampSharedPreferenceLedger,
        source: String
    ) throws {
        try LampSyncPreferenceState.remember(
            ledger, for: source, in: defaults, key: Self.preferenceLedgerStateKey
        )
    }
}

private typealias IOSWebDAVModuleDirectory = LampSyncContentKind

private struct StagedSyncSettings {
    let defaults: UserDefaults
    let domainName: String
    let baseline: [String: Any]
    let highlightMappingBaseline: [String: String]?

    func discard() {
        defaults.removePersistentDomain(forName: domainName)
    }
}

private extension LampSyncContentKind {
    var kind: LampModuleKind {
        switch self {
        case .translations: .translation
        case .dictionaries: .dictionary
        case .commentaries: .commentary
        case .books: .book
        case .devotionals: .devotional
        case .notes: .notes
        case .plans: .plan
        case .highlights: .highlights
        case .quizzes: .quiz
        }
    }
}

private struct IOSWebDAVImportCandidate {
    let filename: String
    let remotePath: String
    let moduleID: String
    let data: Data
    let syncIdentity: String
    let isJSON: Bool
    let superseded: Bool
    let remoteSetID: String?
}

private struct IOSWebDAVExportFile {
    let remotePath: String
    let data: Data
    let condition: LampSyncWriteCondition

    func baseRevision() throws -> String? {
        switch condition {
        case .ifAbsent: nil
        case .ifRevision(let revision): revision
        case .unconditional: throw LibrarySyncError.missingRemoteRevision(remotePath)
        }
    }
}

private struct IOSWebDAVExportBatch {
    let files: [IOSWebDAVExportFile]
    let highlightModuleIDsBySet: [String: String]
}

private struct IOSWebDAVImportSummary {
    var studyEntries = 0
    var devotionals = 0
    var modules = 0
    var failures: [String] = []
    var writeConditions: [String: LampSyncWriteCondition] = [:]
    var highlightModuleIDsBySet: [String: String]?

    var personalItemCount: Int { studyEntries + devotionals }
    var downloadedCount: Int { personalItemCount + modules }

    mutating func merge(_ other: IOSWebDAVImportSummary) {
        studyEntries += other.studyEntries
        devotionals += other.devotionals
        modules += other.modules
        failures.append(contentsOf: other.failures)
        writeConditions.merge(other.writeConditions) { _, newer in newer }
        if let mapping = other.highlightModuleIDsBySet {
            highlightModuleIDsBySet = mapping
        }
    }

    func writeCondition(for path: String) throws -> LampSyncWriteCondition {
        let condition = writeConditions[path] ?? .ifAbsent
        guard condition != .unconditional else {
            throw LibrarySyncError.missingRemoteRevision(path)
        }
        return condition
    }
}

private enum AutomaticSyncError: Error {
    case failed
}

private enum LibrarySyncError: LocalizedError {
    case providerNotConfigured
    case folderNotConfigured
    case invalidWebDAVURL
    case incompleteRemoteImport([String])
    case missingRemoteRevision(String)

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured: "Choose a sync provider first."
        case .folderNotConfigured: "Choose an iCloud Drive or local folder for sync."
        case .invalidWebDAVURL: "Enter a valid HTTP or HTTPS WebDAV folder URL."
        case .incompleteRemoteImport(let failures):
            "Sync stopped before publishing because \(failures.count) remote item\(failures.count == 1 ? "" : "s") could not be imported: \(failures.prefix(3).joined(separator: "; "))"
        case .missingRemoteRevision(let path):
            "Sync stopped because the server did not provide an ETag for \(path)."
        }
    }
}

private enum SyncSecretStore {
    private static let service = "com.neus.Lamp-Bible.macOS.sync"
    private static let account = "webdav-password"

    static var password: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LibrarySyncError.providerNotConfigured }
    }
}
