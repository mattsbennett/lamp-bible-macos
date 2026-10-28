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

    /// Whether anything is remembered about how to reach a sync server.
    var hasRememberedDetails: Bool {
        !endpoint.isEmpty
            || !username.isEmpty
            || defaults.data(forKey: "sync.folderBookmark") != nil
            || SyncSecretStore.password != nil
    }

    /// Forgets how to reach the server: the folder, the WebDAV address and
    /// username, and the password in the keychain.
    ///
    /// Turning sync off stops syncing and keeps all of that, on purpose, so it
    /// can be turned back on without typing it again. But someone who means to
    /// disconnect — a shared Mac, a server they have stopped using — wants it
    /// gone, and Off was the only control there was. The library itself is left
    /// alone: this forgets the way to the server, not anything that was synced.
    func forgetSyncDetails() {
        provider = .off
        defaults.removeObject(forKey: "sync.webdav.endpoint")
        defaults.removeObject(forKey: "sync.webdav.username")
        defaults.removeObject(forKey: "sync.folderBookmark")
        try? SyncSecretStore.setPassword("")
        errorMessage = nil
        objectWillChange.send()
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

    /// Sync this library.
    ///
    /// One pass. The archive pass needed a second attempt when another device
    /// published inside its window, because it read the whole library at the
    /// start and wrote it at the end — minutes apart, and everything built in
    /// between was stale if anybody else wrote. A per-file pass has no such
    /// window: each file carries its own condition, and the one shared object
    /// is the settings bundle, whose `update` re-reads and re-applies on its
    /// own. So a race is handled where it happens rather than by starting
    /// over.
    @discardableResult
    func sync(library: LampLibrary) async -> Bool {
        lastSyncedChangeStamp = try? await library.personalChangeStamp()
        return await runSyncPass(library: library)
    }

    /// The library's change stamp as of the last pass, so a later one can be
    /// told from the state that pass already published.
    private var lastSyncedChangeStamp: Int64?

    /// Publishes this Mac's work when it has any, without being asked.
    ///
    /// Sync ran at launch and when the Sync button was pressed, and nothing
    /// else — so a reading ticked here sat on this Mac until someone went
    /// looking for that button, while the phone had published the same kind of
    /// change within seconds.
    ///
    /// Asked often and does nothing nearly every time: the question is two
    /// aggregates and a small blob, and a pass follows only when the answer
    /// has moved. That keeps the status line still, and keeps a pass from
    /// running while a burst of edits is still arriving.
    func syncLocalWorkIfAppeared(library: LampLibrary) async {
        guard !isSyncing,
              defaults.bool(forKey: "sync.automatic"),
              provider != .off,
              let stamp = try? await library.personalChangeStamp()
        else { return }
        guard let last = lastSyncedChangeStamp else {
            // Nothing published yet in this run. Take the stamp as the
            // baseline rather than syncing: the launch pass covers what was
            // already here, and syncing again would say the same thing twice.
            lastSyncedChangeStamp = stamp
            return
        }
        guard stamp > last else { return }
        _ = await sync(library: library)
    }


    private func runSyncPass(library: LampLibrary) async -> Bool {
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
            switch provider {
            case .off:
                throw LibrarySyncError.providerNotConfigured

            case .folder:
                let folder = try resolveFolderURL()
                // Held for the store's whole lifetime, which is this pass.
                let hasScope = folder.startAccessingSecurityScopedResource()
                defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
                try await sync(
                    library: library,
                    store: LampSyncDirectoryStore(root: folder),
                    source: LampSyncFileRecords.folderSource(folder),
                    preferenceSource: "folder:\(folder.standardizedFileURL.path)",
                    workspace: workspace
                )

            case .webDAV:
                guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
                    throw LibrarySyncError.invalidWebDAVURL
                }
                let storedPassword = SyncSecretStore.password ?? ""
                let credentials = username.isEmpty && storedPassword.isEmpty
                    ? nil : LampWebDAVCredentials(username: username, password: storedPassword)
                try await sync(
                    library: library,
                    store: LampWebDAVClient(baseURL: url, credentials: credentials),
                    source: LampSyncFileRecords.webDAVSource(url),
                    preferenceSource: "webdav:\(url.absoluteString)",
                    workspace: workspace
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
        guard importedRevision == nil || LampSyncConditionalWrite.namesSameRevision(
            snapshot.revision, importedRevision
        ) else {
            throw LibrarySyncError.libraryMovedOn
        }
        return snapshot.archive
    }

    /// Syncs a library that has moved to the per-file layout, or says that it
    /// has not.
    ///
    /// A library still in the old shape is no longer synced the old way. It
    /// is reported and offered the move instead, because carrying two sync
    /// designs is what made the differences between them hard to see, and
    /// because a library half in each is the one state nobody can reason
    /// about.
    private func sync(
        library: LampLibrary,
        store: any LampSyncRemoteStore,
        source: String,
        preferenceSource: String,
        workspace: URL
    ) async throws {
        if case .perFile = try await LampSyncLibraryLayout.of(store) {
            moveOffer = nil
            importedArchiveRevision = nil
            try await runBundlePass(
                library: library,
                store: store,
                source: source,
                preferenceSource: preferenceSource,
                workspace: workspace
            )
            return
        }

        // Still the old shape. Classify it once rather than on every pass:
        // deciding whose library it is means reading the archive, which is
        // the whole of it.
        if moveOffer == nil {
            statusMessage = "Reading the library…"
            let archive = try await archiveToMove(from: store, importedRevision: nil)
            moveOffer = LampSyncSettingsStore.earlierLibrary(ofArchive: archive) == .phone
                ? .join : .migrate
            importedArchiveRevision = .some(
                (try? await store.revision(path: LampSyncFolderLayout.bundlePath)) ?? nil
            )
        }
        throw LibrarySyncError.notMovedYet
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
        // Copied out before the pass, which holds `records` exclusively while
        // it runs. Inverted for the pass: a tombstone names a module path and
        // deleting the set behind it needs the set's own ID.
        let highlightModuleIDs = records.highlightModuleIDs(in: source)
        // Built from the sets that *exist*, not from the whole mapping.
        //
        // `forget(path:)` clears a file's record and leaves the set mapping
        // alone, so a set deleted here leaves its entry behind — and the
        // phone names a new set on the same translation `<translation>-
        // highlights` again, so the same module ID comes back pointing at a
        // different set. Inverting the whole mapping then resolves that module
        // ID to whichever entry Dictionary happened to yield first, which is
        // unordered and seeded per process: the same library would delete the
        // right set on one run and silently delete nothing on the next.
        let setIDsByModule = LampSyncHighlightModules.setIDsByModule(
            highlightModuleIDs,
            existingSetIDs: try await library.highlightSets().map(\.id)
        )
        let passLibrary = LampSyncMacPassLibrary(
            library: library, workspace: staging, fileManager: fileManager, learned: learned,
            highlightSetIDsByModule: setIDsByModule
        ) { path in
            guard let file = try await store.read(path: path) else {
                throw LibrarySyncError.incompleteRemoteImport([path])
            }
            return file.data
        }

        // What `receiving` prepared against. A contribution is computed from
        // the bundle as read — the preference merge in particular — so
        // applying it to a newer one would publish a decision made about
        // something else, and quietly drop whatever the other device wrote.
        var preparedFrom: LampSyncSettingsBundle?

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
            mergingVersion: { bundle, version in try bundle.merge(version: version.bundle) },
            receiving: { snapshot in
                let bundle = snapshot.bundle
                manifest = bundle.manifest
                preparedFrom = bundle
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
                guard bundle == preparedFrom else {
                    // Another device wrote between the read and this write.
                    // The pass takes it from the top rather than publishing a
                    // merge decided against a bundle that has moved on.
                    throw LampSyncBundlePass.PrepareAgain()
                }
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
        // The manifest carries these now, so this Mac need not.
        if !outcome.tombstoned.isEmpty {
            var removed = LampSyncRemovedModules.load(
                fromLibraryAt: library.rootURL, fileManager: fileManager
            )
            removed.forget(outcome.tombstoned)
            try removed.save(toLibraryAt: library.rootURL, fileManager: fileManager)
        }
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

        // An editable collection is merged *into* the library rather than
        // kept as a file, so a member of one of these kinds may leave no file
        // at its path — and a member with no local copy is downloaded, every
        // pass, for ever. The content is in the library; it simply is not a
        // file. Only for paths this Mac has actually installed, which is what
        // makes it true rather than convenient: core ignores a claim with no
        // recorded install behind it.
        //
        // Two ways a path lands here. A highlight set with nothing in it
        // exports to nothing — the bug this started as. And a notes or
        // writings module that is not this Mac's own: `install` merges every
        // module of those kinds into this Mac's collection, so an imported
        // one leaves nothing of its own behind. Only highlights were covered
        // at first, which left the second as the same loop waiting for
        // somebody to publish a second notes module.
        let produced = Set(candidates.map(\.path))
        for member in manifest.members
        where member.kind.map(LampSyncMacPassLibrary.mergedIntoTheLibrary.contains) == true
            && !produced.contains(member.path) {
            result.gathered.heldWithoutAFile.insert(member.path)
        }

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

        // What this Mac has deleted, so the manifest can carry it. Without
        // this nothing deleted here is ever tombstoned: the file stays a
        // member, this Mac stops producing it, and the next pass downloads it
        // back — a deck deleted here would be removed by its own ledger and
        // fetched again on every pass, for ever.
        let deckLedger = try LampPresentationDeckSync.deletions(
            in: library.rootURL, fileManager: fileManager
        )
        for (deckID, deletedAt) in deckLedger.deletedAt {
            guard let path = try? LampSyncFolderLayout.deckPath(deckID: deckID) else { continue }
            result.gathered.deletedLocally[path] = Int64(deletedAt.timeIntervalSince1970 * 1_000)
        }
        // Modules removed here. Nothing else records them: a note, a writing
        // and a highlight set each leave a trace in the personal ledger as
        // they go, and a deck in its own, but removing a module leaves none.
        for (path, removedAt) in LampSyncRemovedModules.load(
            fromLibraryAt: library.rootURL, fileManager: fileManager
        ).removedAt {
            result.gathered.deletedLocally[path] = removedAt
        }
        // A highlight set's deletion is recorded per item; the file that
        // carried it is the module this source published it under.
        let personal = try await library.personalDeletionLedger()
        for (setID, entry) in personal.entries[.highlightSet] ?? [:] {
            guard let deletedAt = entry.deletedAt,
                  let moduleID = moduleIDs[setID],
                  let path = try? LampSyncFolderLayout.modulePath(
                      kind: .highlights, moduleID: moduleID
                  )
            else { continue }
            result.gathered.deletedLocally[path] = deletedAt
        }

        // When this Mac last saved each thing it publishes, so that content
        // edited here after another device deleted it survives rather than
        // being deleted. The ledger records a presence for every item as it
        // is written, so the latest of those is the collection's last change.
        result.gathered.savedAt = LampSyncSavedAt.paths(
            notesLastSaved: LampSyncSavedAt.lastSaved(.note, in: personal),
            writingsLastSaved: writings.compactMap(\.lastModified).max(),
            highlightSets: sets.map { ($0.id, $0.lastModified) },
            highlightModuleIDs: moduleIDs,
            decks: decks.candidates.compactMap { candidate in
                guard let modified = try? candidate.url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { return nil }
                return (candidate.path, modified)
            }
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
        // Deleting something of theirs is the last thing a pass should do
        // quietly. Without this a pass that removed a highlight set reads
        // exactly like one that did nothing — which is also what made the
        // first paired test of it inconclusive.
        if !outcome.deletedLocally.isEmpty {
            parts.append(listed(outcome.deletedLocally.sorted(), "deleted here"))
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
    /// The keychain refused to hold the WebDAV password.
    case passwordNotStored(OSStatus)
    case missingRemoteRevision(String)
    case archiveUnreadable
    case libraryMovedOn
    case notMovedYet
    case weakBundleETag(String)

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured: "Choose a sync provider first."
        case .passwordNotStored(let status):
            // Named rather than numbered where macOS has a name for it: the
            // common causes are a locked login keychain or a denied prompt,
            // and both have messages a person can act on.
            """
            Your password could not be saved to the keychain\
            \(SecCopyErrorMessageString(status, nil).map { " (\($0))" } ?? " (error \(status))").
            Sync is otherwise set up; unlock your login keychain and enter it again.
            """
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
        case .notMovedYet:
            "This library is still in the older layout, so it was not synced. Move it to the new one from Sync settings, after updating Lamp Bible on your other devices."
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
        // Not `providerNotConfigured`, which told someone who had just chosen a
        // provider and typed their password to go and choose a provider.
        guard status == errSecSuccess else {
            throw LibrarySyncError.passwordNotStored(status)
        }
    }
}
