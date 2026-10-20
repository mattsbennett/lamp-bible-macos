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
    /// Writings two devices changed at the same moment, waiting for someone to
    /// say which version they meant. Sync keeps this Mac's copy until then.
    @Published private(set) var conflicts: [LampSyncConflict] = []
    /// Set when the server still holds an archive: this library can move to
    /// the per-file layout, or — if only another device ever synced here —
    /// be joined. Offered rather than done, because a Mac that joins
    /// republishes its whole library into whatever it joined.
    @Published private(set) var moveOffer: LampSyncMoveOffer?

    /// The revision of the archive the last pass imported.
    ///
    /// The revision, not the archive: an archive holds every file's bytes, so
    /// keeping one to offer a move with would pin a whole library — on this
    /// user's, better than half a gigabyte — resident until the app quit. The
    /// move reads it again when it is actually pressed.
    ///
    /// It is load-bearing rather than a convenience. On WebDAV the move
    /// replaces the archive with the bundle, so anything living only in an
    /// archive this Mac never imported would be lost; passing the revision
    /// that *was* imported makes the write refuse if the archive has moved
    /// since.
    private var importedArchiveRevision: String??

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
            print("[LibrarySync] move failed: \(error)")
            errorMessage = LampSyncErrorText.sentence(for: error)
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
    /// Sync, and start again once if another device published while this
    /// pass was running.
    ///
    /// The pass reads the archive at the start and writes it at the end, and
    /// in between it exports the whole library — minutes, on a real library.
    /// A phone that publishes anywhere inside that window takes the write,
    /// correctly: what this pass built does not contain what the phone just
    /// wrote, so letting it through would discard it. But the user pressed
    /// Sync Now and nothing synced, and pressing it again is the whole
    /// remedy, so the second attempt is ours to make rather than theirs.
    ///
    /// Once only. If something is publishing continuously, the honest
    /// outcome is to say so rather than to keep a button spinning. The
    /// decision is `LampSyncPassRetry`, shared and checked against the model.
    func sync(library: LampLibrary) async -> Bool {
        var passesRun = 0
        while true {
            let succeeded = await runSyncPass(library: library)
            passesRun += 1
            guard LampSyncPassRetry.shouldRunAgain(
                passesRun: passesRun,
                lastPassSucceeded: succeeded,
                lostRace: archiveRaceLost
            ) else { return succeeded }
            statusMessage = "Another device published while syncing — starting again…"
        }
    }

    /// Set when the archive write lost to another device's publish, which is
    /// the one failure worth repeating the pass for: nothing is wrong, this
    /// pass is simply out of date, and the next one starts from what won.
    private var archiveRaceLost = false

    private func runSyncPass(library: LampLibrary) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        archiveRaceLost = false
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
                var preferenceMerge: LampSharedPreferenceLedger.Merge?
                var observedFolder: LampSyncArchive?
                let hasScope = folder.startAccessingSecurityScopedResource()
                defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }

                // The same branch as WebDAV, over the folder as a store. The
                // scope above is held for the store's whole lifetime, which
                // is this pass, as it requires.
                let directory = LampSyncDirectoryStore(root: folder)
                if case .perFile(let opened) = try await LampSyncLibraryLayout.of(directory) {
                    moveOffer = nil
                    importedArchiveRevision = nil
                    try await runBundlePass(
                        library: library,
                        store: directory,
                        source: LampSyncFileRecords.folderSource(folder),
                        preferenceSource: preferenceSource,
                        workspace: workspace
                    )
                    break
                }

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
                                preferenceMerge = try self.importSettingsAndMergePreferences(
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
                        if preferenceMerge == nil {
                            preferenceMerge = try self.mergePreferenceLedger(
                                remote: nil,
                                source: preferenceSource
                            )
                        }
                        if let preferenceMerge {
                            self.reportDisputedPreferences(preferenceMerge)
                            try self.exportPreferenceLedger(
                                preferenceMerge.publishable, to: outgoing
                            )
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
                        if let preferenceMerge {
                            try self.rememberPreferenceLedger(
                                preferenceMerge.baseline,
                                source: preferenceSource
                            )
                        }
                    },
                    complete: {
                        // Captured already, so which kind of library this is
                        // costs nothing to decide.
                        if let observedFolder {
                            // A folder has no revision to condition on, and
                            // the move leaves its files where they are, so
                            // re-capturing at the time loses nothing.
                            self.importedArchiveRevision = .some(nil)
                            self.moveOffer = LampSyncSettingsStore
                                .earlierLibrary(ofArchive: observedFolder) == .phone
                                ? .join : .migrate
                        }
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

                // A library on the per-file layout syncs through the new
                // pass. One still on the archive is carried by everything
                // below, exactly as before, and offered the move.
                if case .perFile(let opened) = try await LampSyncLibraryLayout.of(client) {
                    moveOffer = nil
                    importedArchiveRevision = nil
                    try await runBundlePass(
                        library: library,
                        store: client,
                        source: LampSyncFileRecords.webDAVSource(url),
                        preferenceSource: preferenceSource,
                        workspace: workspace
                    )
                    break
                }
                var preferenceMerge: LampSharedPreferenceLedger.Merge?
                var iOSImportSummary = IOSWebDAVImportSummary()
                var archiveSnapshot: LampSyncArchiveRemote.Snapshot?
                // What this pass leaves at the archive path. The move must
                // be conditioned on this, not on what the pass read: the
                // publish below replaces the archive, so comparing against
                // the revision read at the start compares against this Mac's
                // own write and never matches.
                var publishedArchiveRevision: String?
                // Kept apart from a nil snapshot, which also means "there is
                // no archive yet" — a first publish, which must go ahead.
                var archiveReadFailed = false
                // Files the server would not take, reported once the pass ends.
                var unpublishedFiles: [String] = []
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
                                        preferenceMerge = try importSettingsAndMergePreferences(
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
                                // Losing the read here is not cosmetic: with no
                                // snapshot the publish below would have nothing
                                // to replace, so it would write as though the
                                // archive were absent and lose to the one that
                                // is there. That is reported below as a refusal
                                // to publish rather than attempted and lost.
                                print("[LibrarySync] archive read failed: \(error)")
                                archiveReadFailed = true
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
                        if preferenceMerge == nil {
                            preferenceMerge = try mergePreferenceLedger(
                                remote: nil,
                                source: preferenceSource
                            )
                        }
                        if let preferenceMerge {
                            reportDisputedPreferences(preferenceMerge)
                            try exportPreferenceLedger(
                                preferenceMerge.publishable, to: outgoing
                            )
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
                        guard !archiveReadFailed else {
                            // Publishing now would write as a creation and
                            // lose to the archive that is there, reporting a
                            // lost race for what was really a failed read.
                            throw LibrarySyncError.archiveUnreadable
                        }
                        do {
                            publishedArchiveRevision = try await LampSyncArchiveRemote.publish(
                                archive,
                                replacing: archiveSnapshot,
                                in: client
                            )
                        } catch {
                            // Which two revisions disagreed is the diagnosis,
                            // and the error carries neither. A nil snapshot
                            // here means this wrote as a creation.
                            let now = try? await client.revision(
                                path: LampSyncLayout.archivePath
                            )
                            print(
                                "[LibrarySync] archive write failed: replacing "
                                + "\(archiveSnapshot?.revision ?? "nothing (no snapshot read)")"
                                + ", server holds \(now ?? "nothing")"
                            )
                            // A revision that moved means another device
                            // published, rather than anything being wrong
                            // here. Worth starting again from what it wrote.
                            archiveRaceLost = LampSyncPassRetry.lostRace(
                                read: archiveSnapshot?.revision, serverNow: now
                            )
                            throw error
                        }
                        if let preferenceMerge {
                            try rememberPreferenceLedger(
                                preferenceMerge.baseline,
                                source: preferenceSource
                            )
                        }
                        statusMessage = "Publishing iPhone and iPad compatible library…"
                        let refused = try await publishIOSWebDAVContent(
                            using: client,
                            batch: compatible
                        )
                        unpublishedFiles = await describeRefusals(
                            refused, in: compatible, using: client
                        )
                    },
                    complete: {
                        // The archive is in hand, so which kind of library
                        // this is costs nothing to decide — asking the server
                        // again would download all of it a second time.
                        if let snapshot = archiveSnapshot {
                            // The archive this pass just published, whose
                            // content is this library's by construction.
                            importedArchiveRevision = .some(publishedArchiveRevision)
                            moveOffer = LampSyncSettingsStore
                                .earlierLibrary(ofArchive: snapshot.archive) == .phone
                                ? .join : .migrate
                        }
                        defaults.set(Date(), forKey: "sync.lastCompleted")
                        let date = Date().formatted(date: .abbreviated, time: .shortened)
                        var synced = "Synced \(date)"
                        if iOSImportSummary.downloadedCount > 0 {
                            synced += " — downloaded \(iOSImportSummary.downloadedCount) item\(iOSImportSummary.downloadedCount == 1 ? "" : "s")"
                        }
                        // The pass did finish, so this is not an error; but
                        // saying nothing would claim a file is on the server
                        // when it is not.
                        if !unpublishedFiles.isEmpty {
                            synced += " — \(unpublishedFiles.count) file\(unpublishedFiles.count == 1 ? " was" : "s were") not published: \(unpublishedFiles.prefix(3).joined(separator: ", "))"
                        }
                        statusMessage = synced
                    }
                )
            }
        } catch {
            print("[LibrarySync] pass failed: \(error)")
            errorMessage = LampSyncErrorText.sentence(for: error)
            statusMessage = nil
            isSyncing = false
            await refreshConflicts(library: library)
            return false
        }
        isSyncing = false
        await refreshConflicts(library: library)
        return true
    }

    /// Re-read what is waiting to be decided. Cheap, and the list changes
    /// underneath the settings pane whenever a run brings a new disagreement
    /// home or the writing behind an old one is deleted.
    func refreshConflicts(library: LampLibrary) async {
        conflicts = (try? await library.pendingSyncConflicts()) ?? []
    }

    /// Keep one version. The kept copy is dated later than both, so the next
    /// run publishes it and the other device stops offering its own.
    func resolve(
        _ conflict: LampSyncConflict,
        keeping side: LampSyncConflict.Side,
        library: LampLibrary
    ) async {
        do {
            _ = try await library.resolveSyncConflict(id: conflict.id, keeping: side)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshConflicts(library: library)
    }

    /// Stop asking, and leave this Mac's copy as it is.
    func dismiss(_ conflict: LampSyncConflict, library: LampLibrary) async {
        do {
            try await library.discardSyncConflict(id: conflict.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshConflicts(library: library)
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
                            let imported = try await library.importPersonalDevotional(
                                from: localURL, forSync: true
                            )
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
                            let result = try await library.importPersonalStudyData(
                                from: localURL, forSync: true
                            )
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

    /// Report the files the server would not take, and say of each whether
    /// it actually failed to land.
    ///
    /// `writeAndConfirm` raises the same refusal whether the server rejected
    /// the write or accepted it and then answered with a revision too weak
    /// to confirm it by. One leaves the file unpublished and one does not,
    /// and the error alone cannot tell them apart — which is worth knowing
    /// before telling the user their notes are not on the server.
    ///
    /// `LampSyncConditionalWrite.landing` answers from the revision only
    /// when the file is still where the condition left it — not written.
    /// A file that moved could have been moved by this write or by the
    /// device whose write refused it, so those are undecidable, and settled
    /// here by comparing the bytes.
    ///
    /// Returns the paths genuinely left unpublished.
    @discardableResult
    private func describeRefusals(
        _ refused: [String],
        in batch: IOSWebDAVExportBatch,
        using client: LampWebDAVClient
    ) async -> [String] {
        var unpublished: [String] = []
        for path in refused {
            guard let file = batch.files.first(where: { $0.remotePath == path }) else {
                continue
            }
            let now = try? await client.revision(path: path)
            var landing = LampSyncConditionalWrite.landing(
                condition: file.condition, serverRevision: now
            )
            if landing == .undecidable {
                // Only a failure reaches here, so the one read it costs is
                // worth not guessing about a file the user is about to be
                // told is missing — or told is published when it is not.
                let remote = try? await client.read(path: path)
                landing = remote?.data == file.data ? .wrote : .didNotWrite
            }
            if landing == .wrote {
                print(
                    "[LibrarySync] \(path) landed but could not be confirmed: sent "
                    + "\(Self.describe(file.condition)), server now holds "
                    + "\(now ?? "nothing")"
                )
            } else {
                unpublished.append(path)
                print(
                    "[LibrarySync] refused \(path): sent "
                    + "\(Self.describe(file.condition)), server holds \(now ?? "nothing")"
                )
            }
        }
        return unpublished
    }

    private static func describe(_ condition: LampSyncWriteCondition) -> String {
        switch condition {
        case .unconditional: "unconditionally"
        case .ifAbsent: "if-absent"
        case .ifRevision(let revision): "if-revision \(revision)"
        }
    }

    /// Returns the paths the server refused; the rest of the batch is
    /// published either way.
    private func publishIOSWebDAVContent(
        using client: LampWebDAVClient,
        batch: IOSWebDAVExportBatch
    ) async throws -> [String] {
        let preparedDirectories = Set(batch.files.map {
            String($0.remotePath.prefix { $0 != "/" })
        })
        let attempt = try await LampSyncCompatibilityPublisher.publishReportingRefusals(
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
        return attempt.refused
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
    ) throws -> LampSharedPreferenceLedger.Merge {
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

    /// Say which shared preferences the two devices disagree about.
    ///
    /// Not an error: the sync carries everything else, and neither value is
    /// published or overwritten. It stays disputed until the two devices are
    /// given the same value, so it has to be visible or it will sit there.
    private func reportDisputedPreferences(_ merge: LampSharedPreferenceLedger.Merge) {
        guard !merge.disputed.isEmpty else { return }
        let names = merge.disputed.joined(separator: ", ")
        statusMessage = "Left as they are, changed on both devices: \(names)"
        print("[SharedPreferences] disputed, published by neither: \(names)")
    }

    private func mergePreferenceLedger(
        remote: LampSharedPreferenceLedger?,
        source: String,
        targetDefaults: UserDefaults? = nil,
        storedIn domainName: String? = Bundle.main.bundleIdentifier
    ) throws -> LampSharedPreferenceLedger.Merge {
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
        // A disputed field is left out, so this Mac keeps what its user
        // set rather than having it replaced by the other device's value.
        try merged.applicable.apply(to: targetDefaults)
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

// MARK: - Design B

extension LibrarySyncController {
    /// Moves this library to the per-file layout, then syncs it.
    ///
    /// Only ever from a deliberate press. The archive the last pass read is
    /// what it plans from, so nothing is downloaded again, and an archive
    /// holding an entry the move cannot place stops it *before* anything is
    /// written — with the paths named, so the reason is legible rather than a
    /// refusal halfway through.
    @discardableResult
    func move(library: LampLibrary) async -> Bool {
        guard let offer = moveOffer, let imported = importedArchiveRevision else { return false }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-move-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: workspace) }

            // Whichever provider this library is on. The folder keeps its
            // security scope for as long as its store is alive, which is
            // until this move and the pass after it have finished.
            let store: any LampSyncRemoteStore
            let source: String
            let preferenceSource: String
            var folderScope: URL?
            switch provider {
            case .webDAV:
                guard let url = URL(string: endpoint) else {
                    throw LibrarySyncError.invalidWebDAVURL
                }
                let storedPassword = SyncSecretStore.password ?? ""
                let credentials = username.isEmpty && storedPassword.isEmpty
                    ? nil : LampWebDAVCredentials(username: username, password: storedPassword)
                store = LampWebDAVClient(baseURL: url, credentials: credentials)
                source = LampSyncFileRecords.webDAVSource(url)
                preferenceSource = "webdav:\(url.absoluteString)"
            case .folder:
                let folder = try resolveFolderURL()
                if folder.startAccessingSecurityScopedResource() { folderScope = folder }
                store = LampSyncDirectoryStore(root: folder)
                source = LampSyncFileRecords.folderSource(folder)
                preferenceSource = "folder:\(folder.standardizedFileURL.path)"
            case .off:
                throw LibrarySyncError.providerNotConfigured
            }
            defer { folderScope?.stopAccessingSecurityScopedResource() }

            statusMessage = "Reading the library one more time…"
            let archive = try await archiveToMove(from: store, importedRevision: imported)

            // Named before anything is written, so the reason is legible
            // rather than a refusal halfway through.
            let unplaceable = LampSyncLibraryMigration.unplaceableEntries(in: archive)
            guard unplaceable.isEmpty else {
                errorMessage = "Sync cannot place these, so the library was left as it is: "
                    + unplaceable.prefix(5).joined(separator: ", ")
                return false
            }

            statusMessage = offer == .migrate
                ? "Moving the library…"
                : "Joining the library…"
            let moved = try await LampSyncLibraryMigration.migrate(
                in: store, imported: archive, revision: imported
            )

            moveOffer = nil
            importedArchiveRevision = nil
            statusMessage = "Moved. Checking every file once…"
            try await runBundlePass(
                library: library,
                store: store,
                source: source,
                preferenceSource: preferenceSource,
                workspace: workspace
            )
            return true
        } catch {
            print("[LibrarySync] move failed: \(error)")
            errorMessage = LampSyncErrorText.sentence(for: error)
            return false
        }
    }

    /// Reads the library to move, now that someone has asked for it.
    ///
    /// Read rather than remembered, so no archive is held between passes. On
    /// WebDAV it must still be the one this Mac's last pass left there: the
    /// move replaces the archive with the bundle, so an archive another
    /// device wrote since holds content this library never took in, and
    /// publishing from this library afterwards would drop it.
    ///
    /// The revision to compare is the one that pass *published*, not the one
    /// it read — the pass replaces the archive at its end, so comparing
    /// against the read revision compares against this Mac's own write and
    /// refuses every time.
    private func archiveToMove(
        from store: any LampSyncRemoteStore,
        importedRevision: String?
    ) async throws -> LampSyncArchive {
        if case .folder = provider {
            // A folder's files are left where they are by the move, so
            // anything added since is adopted by the next pass rather than
            // lost. Nothing to condition on, and nothing at risk.
            return try await LampSyncFolderPublisher.capture(
                from: try resolveFolderURL(), fileManager: fileManager
            )
        }
        guard let snapshot = try await LampSyncArchiveRemote.read(from: store) else {
            throw LibrarySyncError.archiveUnreadable
        }
        guard LampSyncConditionalWrite.namesSameRevision(
            snapshot.revision, importedRevision
        ) else {
            throw LibrarySyncError.libraryMovedOn
        }
        return snapshot.archive
    }

    /// One pass over a library that has moved to the per-file layout.
    func runBundlePass(
        library: LampLibrary,
        store: any LampSyncRemoteStore,
        source: String,
        preferenceSource: String,
        workspace: URL
    ) async throws {
        statusMessage = "Syncing…"
        var records = LampSyncFileRecords.load(
            fromLibraryAt: library.rootURL, fileManager: fileManager
        )
        // The mapping used to live in UserDefaults alone. Seeded rather than
        // read, so a Mac that has synced before does not mint fresh module
        // IDs and publish a second module for every highlight set it has.
        records.seedHighlightModuleIDs(
            defaults.dictionary(forKey: Self.iOSHighlightModuleIDsBySetKey) as? [String: String]
                ?? [:],
            in: source
        )

        let exports = workspace.appendingPathComponent("Exports", isDirectory: true)
        let staging = workspace.appendingPathComponent("Staging", isDirectory: true)
        let settings = LampSyncBundleSettings(
            defaults: defaults, libraryRoot: library.rootURL,
            source: preferenceSource, fileManager: fileManager
        )
        // What the pass learns while installing, which it cannot write to the
        // records itself: the pass holds those exclusively while it runs.
        let learned = LampSyncMacPassLibrary.Learned()
        let passLibrary = LampSyncMacPassLibrary(
            library: library, workspace: staging, fileManager: fileManager, learned: learned
        ) { path in
            guard let file = try await store.read(path: path) else {
                throw LibrarySyncError.incompleteRemoteImport([path])
            }
            return file.data
        }

        // Copied out before the pass, which holds `records` exclusively
        // while it runs.
        let highlightModuleIDs = records.highlightModuleIDs(in: source)

        var plannedSettings: LampSyncBundleSettings.Planned?
        var ledgers: LampSyncBundleLedgers.Contribution?
        var manifest = LampSyncLibraryManifest()
        var gaps: [LampSyncLocalFiles.Unreadable] = []
        var skippedHighlightSets: [String] = []

        // What the server sent, when it sent something unusable.
        //
        // Both requests, labelled, because they can disagree: the read that
        // failed used the **GET's** ETag, while a PROPFIND is a different
        // request and some WebDAV servers answer only one of them. Reporting
        // the PROPFIND alone could show a perfectly good value for a GET that
        // carried none, and send the next day's work in the wrong direction.
        func reportingWeakRevision<T>(_ work: () async throws -> T) async throws -> T {
            do {
                return try await work()
            } catch LampSyncSettingsStore.StoreError.unversioned {
                let path = LampSyncFolderLayout.bundlePath
                let onGet = try? await store.read(path: path)?.revision
                let onPropfind = try? await store.revision(path: path)
                func shown(_ revision: String??) -> String {
                    guard let revision, let revision else { return "none" }
                    return "“\(revision)”"
                }
                throw LibrarySyncError.weakBundleETag(
                    "GET \(shown(onGet)), PROPFIND \(shown(onPropfind))"
                )
            }
        }

        let outcome = try await reportingWeakRevision {
            try await LampSyncBundlePass(
            store: store, library: passLibrary, source: source
        ).run(
            gathering: {
                let gathered = try await self.gather(
                    library: library, store: store, source: source,
                    exports: exports, staging: staging,
                    highlightModuleIDs: highlightModuleIDs, manifest: manifest,
                    passLibrary: passLibrary, learned: learned
                )
                gaps = gathered.gaps
                skippedHighlightSets = gathered.skippedHighlightSets
                return gathered.gathered
            },
            records: &records,
            receiving: { bundle in
                manifest = bundle.manifest
                plannedSettings = try settings.receive(bundle)
                try await LampSyncBundleLedgers.apply(
                    bundle, to: library, fileManager: self.fileManager
                )
                // Read after applying, so what goes back up includes what was
                // just taken in, and read here because the update's change
                // cannot await.
                ledgers = try await LampSyncBundleLedgers.prepareContribution(
                    from: library, fileManager: self.fileManager
                )
            },
            contributing: { bundle in
                if let plannedSettings {
                    try settings.contribute(plannedSettings, to: &bundle)
                }
                try ledgers?.apply(to: &bundle)
            }
        )
        }

        // A highlight set's module ID lives only in the module on the server,
        // so a set stays unpublished until a pass has read one.
        for (setID, moduleID) in learned.highlightModuleIDsBySet {
            records.setHighlightModuleID(moduleID, forSet: setID, in: source)
        }
        try records.save(toLibraryAt: library.rootURL, fileManager: fileManager)
        if let plannedSettings {
            try settings.remember(plannedSettings)
            reportDisputedPreferences(plannedSettings.merge)
        }
        defaults.set(Date(), forKey: "sync.lastCompleted")
        report(outcome, gaps: gaps, skippedHighlightSets: skippedHighlightSets, manifest: manifest)
    }

    private struct GatheredLibrary {
        var gathered = LampSyncBundlePass.Gathered()
        var gaps: [LampSyncLocalFiles.Unreadable] = []
        var skippedHighlightSets: [String] = []
    }

    /// Everything this Mac holds, as remote paths with digests.
    ///
    /// Every kind the archive used to carry has a home here: the installed
    /// modules, the three editable collections, the files a writing embeds,
    /// the pictures a book shows, the decks and their images, and the
    /// workspaces. A kind left out would simply stop syncing, quietly, so
    /// this is the list to check against the layout when one is added.
    private func gather(
        library: LampLibrary,
        store: any LampSyncRemoteStore,
        source: String,
        exports: URL,
        staging: URL,
        highlightModuleIDs: [String: String],
        manifest: LampSyncLibraryManifest,
        passLibrary: LampSyncMacPassLibrary,
        learned: LampSyncMacPassLibrary.Learned
    ) async throws -> GatheredLibrary {
        var result = GatheredLibrary()
        var candidates: [LampSyncLocalFiles.Candidate] = []

        let modules = try await library.installedModuleFiles()
        let placed = LampSyncLocalFiles.installedModules(modules)
        candidates += placed.candidates
        result.gaps += placed.unplaceable

        // A set's module ID exists only inside the module it was published
        // under, so a Mac that has not recorded one asks the server before
        // concluding anything. Learning it only when a module was *installed*
        // left a set whose bytes this Mac already had waiting for ever.
        var moduleIDs = highlightModuleIDs
        let sets = try await library.highlightSets()
        if sets.contains(where: { moduleIDs[$0.id] == nil }) {
            let onServer = try await LampSyncHighlightModules.discover(in: store)
            // What is recorded wins: it is this Mac's own history with this
            // source, and discovery is only filling gaps.
            moduleIDs.merge(onServer) { recorded, _ in recorded }
            for (setID, moduleID) in onServer { learned.note(setID: setID, moduleID: moduleID) }

            // Anything still unknown is a set no module on the server claims,
            // which is the one case where minting an ID is right rather than
            // the way a library ends up holding the same highlights twice.
            // Avoiding every module ID already spoken for — discovered on the
            // server or recorded here for another set — and each one minted
            // just now, so two unclaimed sets cannot land on one file either.
            var taken = Set(moduleIDs.values)
            for set in sets where moduleIDs[set.id] == nil {
                let minted = LampSyncHighlightModules.mintedModuleID(
                    forSet: set.id, avoiding: taken
                )
                taken.insert(minted)
                moduleIDs[set.id] = minted
                learned.note(setID: set.id, moduleID: minted)
            }
        }

        let collections = try await passLibrary.editableCollections { setID in
            moduleIDs[setID]
        }
        candidates += collections.candidates
        result.skippedHighlightSets = collections.skipped

        let writings = try await library.personalDevotionals()
        let media = LampSyncLocalFiles.devotionalMedia(
            for: writings,
            remoteModuleID: LampSyncMacPassLibrary.remoteWritingModuleID,
            inLibraryAt: library.rootURL,
            fileManager: fileManager
        )
        candidates += media.candidates

        // A book's pictures, for the books in the library and any the
        // manifest already names — the gate that keeps a picture belonging to
        // something else from going up as a book's.
        var bookIDs = Set(
            modules.filter { $0.module.kind == .book }.map(\.module.id)
        )
        for member in manifest.members where member.kind == .bookMedia {
            let components = member.path.split(separator: "/").map(String.init)
            if components.count >= 3 { bookIDs.insert(components[1]) }
        }
        let pictures = LampSyncLocalFiles.bookMedia(
            forBookModuleIDs: bookIDs, inLibraryAt: library.rootURL, fileManager: fileManager
        )
        candidates += pictures.candidates
        result.gaps += pictures.unplaceable

        let decks = LampSyncLocalFiles.decks(
            inLibraryAt: library.rootURL, fileManager: fileManager
        )
        candidates += decks.candidates
        result.gaps += decks.unplaceable

        candidates += try LampSyncLocalFiles.workspaceFiles(
            inLibraryAt: library.rootURL,
            stagingIn: exports,
            fileManager: fileManager
        )

        let described = LampSyncLocalFiles.describe(candidates, fileManager: fileManager)
        result.gathered.local = described.files
        result.gaps += described.unreadable
        result.gaps += LampSyncLocalFiles.unresolved(
            media.missing, candidates: media.candidates, manifest: manifest
        )

        // The paths no folder listing reaches: the manifest names them, so
        // their revisions are asked for one at a time.
        for member in manifest.members where !(member.kind?.isListed ?? true) {
            if let revision = try await store.revision(path: member.path) {
                result.gathered.extraListing[member.path] = revision
            }
        }
        return result
    }

    /// What the pass did, in one line, and what it could not do.
    ///
    /// A gap is not a failure: the pass carried everything else, and saying
    /// nothing would leave someone believing a file is on the server when it
    /// is not.
    private func report(
        _ outcome: LampSyncBundlePass.Outcome,
        gaps: [LampSyncLocalFiles.Unreadable],
        skippedHighlightSets: [String],
        manifest: LampSyncLibraryManifest
    ) {
        // Named, not just counted. "sent 1" cannot be chased: working out
        // afterwards which file it was has cost real time more than once,
        // and the outcome has carried the paths all along.
        func listed(_ paths: [String], _ verb: String) -> String {
            let names = paths.prefix(3).map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            let rest = paths.count - names.count
            return "\(verb) \(paths.count): \(names.joined(separator: ", "))"
                + (rest > 0 ? " and \(rest) more" : "")
        }

        var parts = ["Synced \(Date().formatted(date: .abbreviated, time: .shortened))"]
        let down = outcome.installed + outcome.reconciled
        if !down.isEmpty {
            parts.append(listed(down.sorted(), "brought down"))
        }
        if !outcome.uploaded.isEmpty {
            parts.append(listed(outcome.uploaded.sorted(), "sent"))
        }
        if !gaps.isEmpty {
            parts.append(
                "\(gaps.count) not sent: \(gaps.prefix(3).map(\.path).joined(separator: ", "))"
            )
        }
        if !skippedHighlightSets.isEmpty {
            parts.append(
                "waiting on the server for: \(skippedHighlightSets.joined(separator: ", "))"
            )
        }
        if !outcome.failures.isEmpty {
            parts.append(outcome.failures.prefix(2).joined(separator: "; "))
        }
        statusMessage = parts.joined(separator: " — ")
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
    case archiveUnreadable
    case libraryMovedOn
    case weakBundleETag(String)

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured: "Choose a sync provider first."
        case .folderNotConfigured: "Choose an iCloud Drive or local folder for sync."
        case .invalidWebDAVURL: "Enter a valid HTTP or HTTPS WebDAV folder URL."
        case .archiveUnreadable:
            "Sync stopped before publishing because the remote library could not be read. Publishing now would have written over it as though it were not there. Nothing was changed; try again."
        case .incompleteRemoteImport(let failures):
            "Sync stopped before publishing because \(failures.count) remote item\(failures.count == 1 ? "" : "s") could not be imported: \(failures.prefix(3).joined(separator: "; "))"
        case .missingRemoteRevision(let path):
            "Sync stopped because the server did not provide an ETag for \(path)."
        case .weakBundleETag(let seen):
            "The server did not give the sync file a strong ETag, so it could not be written over safely. Nothing was changed. It answered: \(seen)."
        case .libraryMovedOn:
            "The library on the server changed after the last sync, so the move was not started. Nothing was changed. Sync Now again, then move."
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
