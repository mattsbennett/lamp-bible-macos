import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import LampModuleKit
import Security
import os

extension Notification.Name {
    /// A sync pass brought back a reading position or a bookmark this Mac did
    /// not have. Sent only when the join actually changed something, so a
    /// reader is not reloaded by every pass.
    static let lampBookReadingStateChanged = Notification.Name("lampBookReadingStateChanged")
}

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

    /// Files this Mac holds that the server's listing did not find, by their
    /// path in the library, with why (`LampSyncFilePlan.missing`).
    ///
    /// A report, never an action. Absence is not a deletion: a server can
    /// answer a listing from a stale view, and iCloud refills a folder file
    /// by file while its manifest already names everything. So these are
    /// marked and the reader decides, and a module leaves the set as soon as
    /// a pass finds its file again.
    /// Kept by path rather than by module ID. `remoteModuleID(of:)` gives the
    /// ID the *server* knows a file by, which is not the one this Mac uses:
    /// a personal module's path holds the adapter's rewritten ID, and a
    /// highlight module's the per-set ID this Mac mints. Keyed on those, a
    /// mark could land on a module that happens to share an ID with another's
    /// remote name — telling a reader their intact module is gone. A caller
    /// asks for the path it would publish a module to, and gets an answer
    /// about that module or none.
    @Published private(set) var missingFiles: [String: LampSyncFilePlan.Missing] = [:]

    /// Whether the last pass reached the library at all.
    ///
    /// The third state, and the one that keeps the mark honest: a pass that
    /// threw has no outcome, so nothing can be said about what is on the
    /// server. The set from the last pass that did reach it stays, because a
    /// module missing an hour ago is still worth showing — but it is
    /// described as unchecked rather than as gone.
    @Published private(set) var reachedLibrary = true

    /// Where each book was left and what is bookmarked in it: this Mac's own
    /// record rather than the library's, and the one part of a pass that a
    /// reader writes to while the pass is running.
    private let readingState = LampBookReadingStateStore()

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

    /// Sources this Mac holds only on the server, as member paths — what the
    /// Settings notice counts. Kept current after every pass, and whenever a
    /// pane offloads, downloads or removes a source.
    @Published private(set) var sourcesOnlyOnTheServer: [String] = []

    /// The server this Mac's offloads went to, while any are outstanding.
    ///
    /// The lock on where sync points (owner's decision, `decisions/0021`) is
    /// *this*, not the list above. It is written before the first unlink, so
    /// it holds from the moment a copy is about to go rather than from the
    /// next time the list is read; and it names the server, rather than
    /// inferring one from records that are only memories of past uploads.
    /// It is released when nothing is only on the server and no removal of a
    /// source is still queued for it — a removal sent after a switch would go
    /// to the wrong server.
    ///
    /// And it names the account as well as the server (`OffloadLock`): a pass
    /// at the same address as anyone else is refused before it starts.
    private var offloadLock: OffloadLock? {
        get {
            if let data = defaults.data(forKey: Self.offloadLockKey),
               let lock = try? JSONDecoder().decode(OffloadLock.self, from: data) {
                return lock
            }
            // Written by a build that kept the address alone.
            return defaults.string(forKey: "sync.offloadsHeldBy")
                .map { OffloadLock(source: $0, account: nil) }
        }
        set {
            defaults.removeObject(forKey: "sync.offloadsHeldBy")
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.offloadLockKey)
            } else {
                defaults.removeObject(forKey: Self.offloadLockKey)
            }
            objectWillChange.send()
        }
    }

    private static let offloadLockKey = "sync.offloadLock"

    /// The server sync is locked to, by its address.
    private var offloadsHeldBy: String? { offloadLock?.source }

    /// Whether where sync points is locked to one server.
    var destinationIsLocked: Bool { offloadLock != nil }

    /// Engages the lock before an offload deletes anything.
    private func willOffload(to source: String, as account: String) {
        if offloadLock == nil { offloadLock = OffloadLock(source: source, account: account) }
    }

    func refreshSourcesOnlyOnTheServer(library: LampLibrary) async {
        let root = library.rootURL
        // Unreadable leaves things as they were: not a reason to lift a lock.
        guard let read = await LampWorkspaceSync.sourcesOnlyOnTheServer(inLibraryAt: root) else {
            Self.log.error("Could not read which sources are only on the server; the lock stays as it is")
            return
        }
        sourcesOnlyOnTheServer = read
        let removalsQueued = LampSyncRemovedModules.load(fromLibraryAt: root, fileManager: fileManager)
            .removedAt.keys.contains(where: LampWorkspaceSync.namesAsource)
        if sourcesOnlyOnTheServer.isEmpty, !removalsQueued, !isOffloading {
            if offloadLock != nil { offloadLock = nil }
        } else if offloadLock == nil, !sourcesOnlyOnTheServer.isEmpty, let current = currentSource {
            // Held but never written down — from a build before this. The
            // server sync talks to now is the one they can only have gone to;
            // the account is filled in by the next pass there.
            offloadLock = OffloadLock(source: current, account: nil)
        }
    }

    /// Asks for every offloaded source back and starts a pass: the way out of
    /// the lock.
    func downloadEverySourceOnTheServer(library: LampLibrary) async {
        await LampWorkspaceSync.askForEverySourceOnTheServer(inLibraryAt: library.rootURL)
        await refreshSourcesOnlyOnTheServer(library: library)
        _ = await syncAsked(library: library)
    }

    /// Asks for the sync after which a requested offload is carried out. A
    /// source not yet on the server goes up in that sync, and the offload
    /// after it reads it back.
    func syncForOffload(library: LampLibrary, workspace: URL) async {
        offloadRefusals[workspace.standardizedFileURL.path] = nil
        _ = await syncAsked(library: library)
    }

    /// Why a requested offload could not happen, by the workspace that asked
    /// (its standardized path), for that writing's pane alone.
    @Published private(set) var offloadRefusals: [String: String] = [:]

    /// A pass the reader asked for by pressing something — Download, Try
    /// Again, Download All. Not subject to the automatic-sync setting, which
    /// governs passes Lamp starts by itself: a press is not one of those.
    func syncAsked(library: LampLibrary) async -> Bool {
        guard provider != .off else { return false }
        return await sync(library: library)
    }

    /// Whether sync may be pointed at `destination` now. Refusals say why.
    private func mayPointSync(at destination: String?) -> Bool {
        let allowed = LampWorkspaceSync.mayPointSync(at: destination, heldBy: offloadsHeldBy)
        if !allowed { sayWhyTheDestinationIsLocked() }
        return allowed
    }

    private func sayWhyTheDestinationIsLocked() {
        let count = sourcesOnlyOnTheServer.count
        errorMessage = count == 0
            ? """
              A source removal is still waiting to reach the current sync \
              server. Let it sync before changing where Lamp syncs.
              """
            : """
              \(count == 1 ? "A source is" : "\(count) sources are") only on the \
              current sync server. Download \(count == 1 ? "it" : "them") before \
              changing where Lamp syncs, or \(count == 1 ? "it" : "they") would be \
              left behind.
              """
    }

    /// The server a provider would sync with, from what is remembered for it.
    private func source(for provider: Provider) -> String? {
        switch provider {
        case .webDAV: URL(string: endpoint).map(LampSyncFileRecords.webDAVSource)
        case .folder: (try? resolveFolderURL()).map(LampSyncFileRecords.folderSource)
        case .off: nil
        }
    }

    var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: "sync.provider") ?? "off") ?? .off }
        set {
            guard newValue == provider || mayPointSync(at: source(for: newValue)) else {
                objectWillChange.send()
                return
            }
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
        set {
            guard newValue == endpoint
                || mayPointSync(at: URL(string: newValue).map(LampSyncFileRecords.webDAVSource))
            else { objectWillChange.send(); return }
            defaults.set(newValue, forKey: "sync.webdav.endpoint")
        }
    }

    var username: String {
        get { defaults.string(forKey: "sync.webdav.username") ?? "" }
        set {
            // Another account on the same address can be another set of
            // files, and the sources were offloaded to this one's.
            guard newValue == username || !destinationIsLocked else {
                sayWhyTheDestinationIsLocked()
                objectWillChange.send()
                return
            }
            defaults.set(newValue, forKey: "sync.webdav.username")
        }
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
        // Forgetting the way to the server is forgetting the way to the only
        // copy of anything offloaded to it.
        guard !destinationIsLocked else {
            sayWhyTheDestinationIsLocked()
            return
        }
        provider = .off
        defaults.removeObject(forKey: "sync.webdav.endpoint")
        defaults.removeObject(forKey: "sync.webdav.username")
        defaults.removeObject(forKey: "sync.folderBookmark")
        try? SyncSecretStore.setPassword("")
        errorMessage = nil
        objectWillChange.send()
    }

    func updateWebDAVPassword(_ password: String) -> Bool {
        // A first password with no username turns anonymous requests into
        // signed-in ones, and clearing the last one turns them back: another
        // account, as far as the offloads are concerned. A new password for
        // the same account is not.
        let current = SyncSecretStore.password ?? ""
        guard SyncAccount.identity(username: username, password: password)
                == SyncAccount.identity(username: username, password: current)
                || !destinationIsLocked
        else {
            sayWhyTheDestinationIsLocked()
            return false
        }
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
        guard mayPointSync(at: LampSyncFileRecords.folderSource(url)) else { return }
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

    /// Syncs once per launch, if sync is on, and says whether this call ran a
    /// pass — finished or not, since a pass that failed partway may still
    /// have brought something in. A window that waited on another's pass,
    /// or found it done, ran none.
    @discardableResult
    func syncAutomaticallyIfNeeded(library: LampLibrary) async -> Bool {
        guard !isSyncing,
              defaults.bool(forKey: "sync.automatic"),
              provider != .off else { return false }
        var ranPass = false
        do {
            try await automaticSync.run {
                ranPass = true
                guard await self.sync(library: library) else {
                    throw AutomaticSyncError.failed
                }
            }
        } catch {
            // Keep the gate open; sync(library:) reports operational errors.
        }
        return ranPass
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
        lastPublishedWork = await localWork(library: library)
        // Another pass is running. `runSyncPass` would refuse this one and
        // answer false, which reads exactly like a pass that failed — and the
        // lines below would then throw away the observation the running pass
        // has just written. Ask for a pass after it instead. Checked with no
        // suspension before the call, so it is the same answer the guard
        // inside will give.
        //
        // Nor while the offloads after the last pass are being carried out:
        // they act on that pass's look at the server, and a new pass starting
        // under them could see a source gone that they are about to delete.
        guard !isSyncing, !passGate else {
            LampSyncRequest.wantAPass()
            return false
        }
        // Taken with no suspension since the check above, and held through
        // the pass, the promotion of its look at the server, reconciliation
        // and the offloads: `runSyncPass` clears `isSyncing` before its last
        // await, and a second pass starting in that gap would gather a newer
        // view while this one deleted on the older.
        passGate = true
        let finished = await passAndItsAftermath(library: library)
        passGate = false
        // An ask made while this pass ran — a Download pressed after the
        // gather had already looked — is answered now, whether or not this
        // pass finished: a poll that only the reader window runs may not be
        // running. Once, so a failing server is not asked again for ever.
        if LampSyncRequest.takePending() {
            return await sync(library: library)
        }
        return finished
    }

    /// Held from the start of a pass until its offloads are done. While it
    /// is, no other pass or move starts.
    private var passGate = false
    /// The account the running pass's store was built with.
    private var accountOfThisPass = ""

    private func passAndItsAftermath(library: LampLibrary) async -> Bool {
        let finished = await runSyncPass(library: library)
        // Both forgotten on purpose: the next probe takes a fresh mark to
        // measure from, once the server has had time to settle.
        lastSeenBundleRevision = nil
        lastPassFinishedAt = Date()
        lastObservation = finished ? pendingObservation : nil
        pendingObservation = nil
        if finished {
            await reconcileOffloadsWithTheServer(library: library)
            await carryOutOffloads(library: library)
            await sayWhatCameBack(library: library)
        }
        await refreshSourcesOnlyOnTheServer(library: library)
        return finished
    }

    /// Whether a pass is running, from its start to the end of its offloads —
    /// what a caller waiting for a pass to finish has to wait on. `isSyncing`
    /// clears before the offloads, and a sync asked for then is queued rather
    /// than run, so waiting on it alone returns before the pass it queued.
    var isPassRunning: Bool { isSyncing || passGate }

    /// Whether the offloads after a pass are being carried out. While they
    /// are, no pass starts and the lock on where sync points is not released.
    @Published private(set) var isOffloading = false

    /// Carries out every offload, right after a pass has finished and before
    /// another can start: what the reader asked for, then what the
    /// inactivity setting picks.
    ///
    /// **The one place a source is deleted to save space** (owner's decision,
    /// `decisions/0021`). The Offload button used to delete at once, at any
    /// moment, and so could overlap a pass, a change of server, or a refresh
    /// of the lock on one — three review rounds found those overlaps one at a
    /// time. Here there is one moment: the look at the server is the one this
    /// pass has just taken, no other pass is running, and the lock is
    /// written down before anything goes and not released until after.
    ///
    /// Each offload reads the server's copy back through a store made the
    /// way the pass's was — same address, same credentials, same folder
    /// access — and goes only where it is the local bytes (`decisions/0022`).
    private func carryOutOffloads(library: LampLibrary) async {
        guard let observation = offloadObservation() else { return }
        isOffloading = true
        defer { isOffloading = false }
        do {
            try await withConnection { connection in
                // The connection is made again from the settings; it must be
                // the one the look was at.
                guard connection.source == observation.source,
                      connection.account == observation.account else { return }
                let store = UncheckedStore(store: connection.store)
                let server = OffloadServer(
                    source: connection.source, account: connection.account,
                    fetch: { path, destination in
                        try await store.store.read(path: path, into: destination) != nil
                    }
                )
                await offloadRequestedSources(library: library, observation: observation, server: server)
                await offloadInactiveSources(library: library, observation: observation, server: server)
            }
        } catch {
            Self.log.error("Offloads skipped: the server could not be reached as the pass reached it: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What came back from the server not as it left, said once.
    private func sayWhatCameBack(library: LampLibrary) async {
        let notices = await LampWorkspaceSync.takeReturnNotices(inLibraryAt: library.rootURL)
        if let first = notices.changed.first {
            errorMessage = notices.changed.count == 1
                ? "“\(first)” came back from the server changed: it isn't the copy that left this Mac."
                : "\(notices.changed.count) sources came back from the server changed: they aren't the copies that left this Mac."
        } else if let first = notices.unmarked.first {
            errorMessage = notices.unmarked.count == 1
                ? "“\(first)” came back without its “downloaded from the internet” mark, which macOS wouldn't let Lamp put back."
                : "\(notices.unmarked.count) sources came back without their “downloaded from the internet” mark, which macOS wouldn't let Lamp put back."
        }
    }

    /// The sources the reader asked to go back to the server.
    ///
    /// Asked for, so none of the sweep's own reasons to wait — the setting,
    /// the hour between sweeps, the writing's dates, an open editor — apply:
    /// the reader is the one at that editor, pressing the button. Every
    /// safety check does. A request that could succeed later stays; one that
    /// never can is dropped and said.
    private func offloadRequestedSources(
        library: LampLibrary, observation: ServerObservation, server: OffloadServer
    ) async {
        let root = library.rootURL
        var offloaded = 0
        for (workspace, requested) in await LampWorkspaceSync.requestedOffloads(inLibraryAt: root) {
            willOffload(to: server.source, as: server.account)
            var refused: [String] = []
            var differs: [String] = []
            do {
                let result = try await WorkspaceContextFileStore.offloadSources(
                    requested, in: workspace, libraryRootURL: root, observation: observation,
                    server: server, onlyWhileRequested: true,
                    while: { @Sendable [weak self] in
                        await MainActor.run {
                            guard let self else { return false }
                            return self.offloadObservation() == observation
                                && !KeptAgentChats.isBusy(in: workspace)
                        }
                    }
                )
                offloaded += result.offloaded.count
                for (path, reason) in result.skipped {
                    if reason == .withdrawn {
                        // Keep Here won; there is nothing to put back.
                        continue
                    }
                    if reason == .serverCopyDiffers || reason == .couldNotReadTheServer {
                        differs.append(path)
                    }
                    if reason.isLasting {
                        try? await WorkspaceContextFileStore.cancelOffload(
                            relativePath: path, in: workspace
                        )
                        refused.append(path)
                    }
                    // Anything else is left as it is: untouched, or put back by
                    // the batch itself before it let go. Re-queueing here,
                    // afterwards, would undo a Keep Here pressed meanwhile.
                    Self.log.info("A requested offload was left: \(reason.rawValue, privacy: .public)")
                }
            } catch {
                Self.log.error("A requested offload failed: \(error.localizedDescription, privacy: .public)")
            }
            // Said in the pane that asked — this workspace's — and in Sync
            // settings.
            let key = workspace.standardizedFileURL.path
            if !refused.isEmpty {
                let message = refused.count == 1
                    ? "“\(refused[0])” can't go back to the server, so it stays on this Mac."
                    : "\(refused.count) sources can't go back to the server, so they stay on this Mac."
                errorMessage = message
                offloadRefusals[key] = message
            } else if !differs.isEmpty {
                // The request stays, for a pass whose read of the server
                // matches; the pane says why nothing has happened yet.
                offloadRefusals[key] = differs.count == 1
                    ? "“\(differs[0])” is waiting: the server's copy didn't match this Mac's when Lamp checked, so it stays here for now."
                    : "\(differs.count) sources are waiting: the server's copies didn't match this Mac's when Lamp checked, so they stay here for now."
            } else {
                offloadRefusals[key] = nil
            }
        }
        if offloaded > 0 {
            statusMessage = offloaded == 1
                ? "1 source put back on the server."
                : "\(offloaded) sources put back on the server."
        }
    }

    /// What the last **finished** pass saw of the server. Nil until one has,
    /// and nil again after one that did not finish: what runs after a pass
    /// must act on a look the server answered, not on the one before last.
    private var lastObservation: ServerObservation?
    /// What the pass now running saw at its gather, promoted to
    /// `lastObservation` only if the pass finishes.
    private var pendingObservation: ServerObservation?

    /// When this Mac last looked for sources to put back on the server.
    private var lastOffloadSweepAt = Date.distantPast
    /// The work is small — one query, a stat or two per workspace, one records
    /// load — but a pass can run every few seconds and there is no reason to
    /// ask that often about a clock measured in months.
    private static let offloadSweepInterval: TimeInterval = 60 * 60

    /// The source this library syncs with, named as the records name it, or
    /// nil where sync is off or not configured.
    private var currentSource: String? {
        switch provider {
        case .webDAV:
            guard let url = URL(string: endpoint) else { return nil }
            return LampSyncFileRecords.webDAVSource(url)
        case .folder:
            guard let folder = try? resolveFolderURL() else { return nil }
            return LampSyncFileRecords.folderSource(folder)
        case .off:
            return nil
        }
    }

    /// What the last finished pass saw, if it was looking at the server this
    /// Mac is configured for **now**, and recently enough to answer for a
    /// button press.
    ///
    /// Turning sync off, or changing folders, makes the last look worthless
    /// however recent it is: Offload would delete against one server while
    /// Download fetched from another.
    func offloadObservation(now: Date = Date()) -> ServerObservation? {
        guard let source = currentSource,
              let observation = lastObservation,
              observation.answers(
                  for: source,
                  account: provider == .webDAV
                      ? (try? SyncSecretStore.readPassword())
                          .map { SyncAccount.identity(username: username, password: $0) } ?? "\u{0}unreadable"
                      : "",
                  now: now
              )
        else { return nil }
        return observation
    }

    /// Forgets this Mac's offloads of sources the server no longer holds.
    ///
    /// Another device's removal of a source neither Mac is holding reaches
    /// here as a manifest that no longer counts it a member. Nothing else
    /// notices: there is no local file for the plan to delete, so the note
    /// would survive and the pane would keep offering Download for something
    /// that is gone.
    private func reconcileOffloadsWithTheServer(library: LampLibrary) async {
        // Unread is not empty: a pass that never got a manifest must not look
        // like a server that has dropped every source.
        guard let members = lastObservation?.members else { return }
        guard let observed = lastObservation?.source,
              LampWorkspaceSync.mayReconcileOffloads(withManifestOf: observed, heldBy: offloadsHeldBy)
        else { return }
        let forgotten = await LampWorkspaceSync.forgetActsNoLongerOnTheServer(
            inLibraryAt: library.rootURL, members: members
        )
        if !forgotten.isEmpty {
            Self.log.info("Forgot \(forgotten.count, privacy: .public) offload(s) the server no longer holds")
        }
    }

    /// Puts the sources of writings left alone for long enough back on the
    /// server, keeping the server's copy (`decisions/0020`, `0021`).
    ///
    /// **After a finished pass, not at launch.** Offloading deletes the only
    /// local copy, so it may only touch a file the server is known to hold —
    /// and a confirmed revision is what a pass's bundle update has just
    /// produced. A launch sweep would run against whatever the records said
    /// when the app last quit, and the launch pass would then make the same
    /// work available a second later anyway. With sync off there is no pass,
    /// so no sweep, which is right: there is nowhere for the sources to go.
    @discardableResult
    private func offloadInactiveSources(
        library: LampLibrary, observation: ServerObservation, server: OffloadServer
    ) async -> Int {
        let after = WorkspaceSourceOffload.After.chosen()
        guard after.days != nil else { return 0 }
        let now = Date()
        guard now.timeIntervalSince(lastOffloadSweepAt) > Self.offloadSweepInterval
        else { return 0 }
        lastOffloadSweepAt = now

        let libraryRoot = library.rootURL
        let writings: [(id: String, modified: Date)]
        do {
            writings = try await library.personalDevotionalModificationDates()
        } catch {
            Self.log.error("Offload sweep could not read the writings: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        // Read on this actor, where the editors register themselves.
        let held = OpenWritingEditors.writingIDs
        let workspaces = await WorkspaceSourceOffload.workspaces(
            inLibraryAt: libraryRoot, writings: writings, observation: observation, now: now
        )
        let candidates = WorkspaceSourceOffload.offloadable(
            from: workspaces, after: after, heldBy: held, now: now
        )
        guard !candidates.isEmpty else { return 0 }

        // By folder, which each candidate carries, and never by id: two ids
        // differing only in Unicode form are one key to Swift and two folders
        // on disk, and re-deriving the folder from the id would send one
        // writing's candidates into the other's workspace.
        var byFolder: [String: (writingID: String, folder: URL, paths: [String])] = [:]
        for candidate in candidates {
            guard let folder = candidate.folder else { continue }
            byFolder[folder.path, default: (candidate.writingID, folder, [])].paths
                .append(candidate.relativePath)
        }
        var offloaded = 0
        for (_, group) in byFolder.sorted(by: { $0.key < $1.key }) {
            let writingID = group.writingID
            let relativePaths = group.paths
            let workspaceURL = group.folder
            // Asked again, per workspace, rather than trusted from before the
            // scan. The scan and the batches before this one are awaits, and
            // a reader who opened this writing during them would lose its
            // sources from under an open editor.
            guard !OpenWritingEditors.writingIDs.contains(writingID),
                  !KeptAgentChats.isBusy(in: workspaceURL)
            else { continue }
            willOffload(to: server.source, as: server.account)
            do {
                let result = try await WorkspaceContextFileStore.offloadSources(
                    relativePaths, in: workspaceURL,
                    libraryRootURL: libraryRoot, observation: observation, server: server,
                    // Asked again before each file goes, not once before the
                    // batch: hashing a workspace's sources takes long enough
                    // for a reader to open the writing in the middle of it.
                    // And whether this is still the server the look was at:
                    // sync turned off or moved part way through a sweep would
                    // otherwise go on deleting copies Download can no longer
                    // reach.
                    while: { @Sendable [weak self] in
                        await MainActor.run {
                            guard let self else { return false }
                            // An agent turn on this writing — started from
                            // the phone, say, with no editor open — is using
                            // its sources too.
                            return !OpenWritingEditors.writingIDs.contains(writingID)
                                && !KeptAgentChats.isBusy(in: workspaceURL)
                                && self.offloadObservation() == observation
                        }
                    }
                )
                offloaded += result.offloaded.count
                for reason in Set(result.skipped.values) {
                    let count = result.skipped.values.filter { $0 == reason }.count
                    Self.log.info("Offload sweep left \(count, privacy: .public) source(s): \(reason.rawValue, privacy: .public)")
                }
            } catch {
                Self.log.error("Offload sweep failed for a workspace: \(error.localizedDescription, privacy: .public)")
            }
        }
        if offloaded > 0 {
            Self.log.info("Offload sweep put \(offloaded, privacy: .public) source(s) back on the server")
            statusMessage = offloaded == 1
                ? "1 source put back on the server."
                : "\(offloaded) sources put back on the server."
        }
        return offloaded
    }

    /// Everything this Mac has to publish, as one thing that can be compared
    /// with the same answer taken later.
    ///
    /// Three parts, because the answer comes from three places and no one of
    /// them covers the others. Compared as a whole, and only for difference:
    /// see `LampSyncLocalWork` for why none of these numbers may be ordered
    /// against another.
    private struct LocalWork: Equatable {
        /// Notes, writings, highlights, plans followed, readings ticked — the
        /// ledgers answer for all of them at once.
        let personal: Int64
        /// Modules installed and removed, decks, workspaces, skills: files,
        /// which no ledger records.
        let files: [String: Int64]
        /// The preferences that travel, as they stand here now.
        let settings: NSDictionary

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.personal == rhs.personal
                && lhs.files == rhs.files
                && lhs.settings.isEqual(rhs.settings)
        }
    }

    /// What this Mac had to publish when the last pass started, so work done
    /// since can be told from what that pass already carried.
    private var lastPublishedWork: LocalWork?

    /// Asked every few seconds, so each part is cheap: two indexed aggregates
    /// and a small blob for the ledgers, a handful of stats and a walk of the
    /// decks and workspaces for the files, and a read of thirty-odd defaults
    /// for the preferences. Nothing is opened, read or hashed.
    private func localWork(library: LampLibrary) async -> LocalWork? {
        guard let personal = try? await library.personalChangeStamp() else { return nil }
        let libraryRoot = library.rootURL
        let fileManager = self.fileManager
        // Off the main thread, which this controller otherwise holds.
        let files = await Task.detached {
            LampSyncLocalWork.marks(inLibraryAt: libraryRoot, fileManager: fileManager)
        }.value
        var settings: [String: Any] = [:]
        for key in LampPortableSettingsCodec.syncedKeys {
            if let value = defaults.object(forKey: key) { settings[key] = value }
        }
        return LocalWork(personal: personal, files: files, settings: settings as NSDictionary)
    }

    /// Publishes this Mac's work when it has any, without being asked.
    ///
    /// Sync ran at launch and when the Sync button was pressed, and nothing
    /// else — so a reading ticked here sat on this Mac until someone went
    /// looking for that button, while the phone had published the same kind of
    /// change within seconds.
    ///
    /// Everything this Mac publishes is asked about, not only the study
    /// content the ledgers record: a plan deleted, a module installed, a deck
    /// saved, a workspace document written and a setting changed are all work
    /// somebody else should see, and each of them used to wait for the
    /// button. `LocalWork` is the whole question.
    ///
    /// Asked often and does nothing nearly every time: the question is a few
    /// aggregates, a few stats and a read of some defaults, and a pass
    /// follows only when the answer has moved. That keeps the status line
    /// still, and keeps a pass from running while a burst of edits is still
    /// arriving.
    ///
    /// A pass that takes another device's work in moves this answer too, so
    /// one quiet pass follows it and finds nothing to send. That was already
    /// so of an arriving note, and the cost of recording the answer *before*
    /// a pass rather than after: an edit made while the pass ran would
    /// otherwise be taken as something that pass had already carried, and
    /// wait for the next change to be noticed at all.
    func syncLocalWorkIfAppeared(library: LampLibrary) async {
        guard !isSyncing,
              defaults.bool(forKey: "sync.automatic"),
              provider != .off
        else { return }
        // Somebody asked for a pass that this Mac's own work would not start:
        // fetching an offloaded source writes only bookkeeping, which `marks`
        // deliberately does not read.
        if LampSyncRequest.takePending() {
            _ = await sync(library: library)
            return
        }
        guard let work = await localWork(library: library) else { return }
        // Nothing recorded means no pass has run in this session, which is
        // the case when sync was switched on after launch. Publishing then is
        // right: the launch pass, which would otherwise have covered what is
        // already here, never happened. A pass that did run records this
        // before it starts, so this is not the ordinary path.
        guard let last = lastPublishedWork, work == last else {
            _ = await sync(library: library)
            return
        }
    }


    /// The bundle's revision when this Mac last looked, or nil when it has
    /// not looked since its own write.
    private var lastSeenBundleRevision: String??
    /// When the last pass finished, so a probe is not made while the server
    /// may still be answering with what it held before the write.
    private var lastPassFinishedAt = Date.distantPast
    /// When the listed folders were last compared with this Mac's records.
    private var listingProbedAt = Date.distantPast
    /// The listing a probe last started a pass for. A file this Mac does not
    /// take — or a record a pass leaves as it was — would otherwise read as
    /// work on every probe, and start a pass every two minutes for ever.
    private var listingActedOn: [String: String]?
    /// Every pass's start, finish and failure, kept by the system log rather
    /// than printed: a pass that never finishes left no trace otherwise.
    private static let log = Logger(subsystem: "com.neus.Lamp-Bible.macOS", category: "sync")


    /// The digests this session has taken, for the library it is open on.
    ///
    /// One cache per library root, made the first time a pass asks and kept
    /// for as long as the app runs — and **nil** where the filesystem under
    /// the library does not maintain an identity a digest can be kept
    /// against, which is every pass on a NAS, an SMB share or a memory card.
    /// There the pass reads every file, as it always did. See
    /// `lamp-bible-core/Documentation/decisions/0007` for why the answer
    /// depends on the filesystem at all.
    private var heldDigestCache: (root: URL, device: Int64?, cache: LampSyncDigestCache?)?

    private func digestCache(forLibraryAt root: URL) -> LampSyncDigestCache? {
        // Scoped to the volume that was actually asked about, and asked
        // about once: the trust is a filesystem's, and a library can have
        // another volume mounted inside it — an external disk holding a
        // workspace's context, say — whose files nothing has vouched for.
        //
        // No device, no cache. A library on a filesystem whose identities
        // mean nothing, or one that cannot be read at this moment, is hashed
        // every pass, which is what `0001` required.
        let device = LampSyncIdentityTrust.trustedDevice(ofVolumeAt: root)
        // Kept only while it still describes the volume in front of us. An
        // external library can come back at the same path on a different
        // device, and a cache made for the old one can answer for nothing —
        // so it would rehash everything, every pass, until the app restarted.
        if let held = heldDigestCache, held.root == root, held.device == device {
            return held.cache
        }
        if device == nil {
            Self.log.notice("Library volume keeps no identity to trust; hashing every pass")
        }
        let cache = device.map { LampSyncDigestCache(trustedDevice: $0) }
        heldDigestCache = (root, device, cache)
        return cache
    }

    /// Opens the configured remote, for something smaller than a pass.
    private func withRemoteStore<T>(
        _ body: (any LampSyncRemoteStore) async throws -> T
    ) async throws -> T {
        try await withRemoteStore { store, _ in try await body(store) }
    }

    /// The configured remote, with the source its file records are kept
    /// under (`LampSyncFileRecords`).
    private func withRemoteStore<T>(
        _ body: (any LampSyncRemoteStore, String) async throws -> T
    ) async throws -> T {
        try await withConnection { try await body($0.store, $0.source) }
    }

    /// A way to the configured server: the store, the source its records are
    /// kept under, and who it is reached as (`SyncAccount.identity`).
    private struct Connection {
        let store: any LampSyncRemoteStore
        let source: String
        let account: String
    }

    /// Makes the one connection everything uses — a pass, a probe, an
    /// offload's read-back — so they cannot reach the server in different
    /// ways. A folder's access is held for the body.
    ///
    /// A password that is stored and cannot be read is an error, never no
    /// password: going anonymous instead reached a different library on a
    /// server that serves one to anonymous requests.
    private func withConnection<T>(_ body: (Connection) async throws -> T) async throws -> T {
        switch provider {
        case .off:
            throw LibrarySyncError.providerNotConfigured
        case .folder:
            let folder = try resolveFolderURL()
            let hasScope = folder.startAccessingSecurityScopedResource()
            defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
            return try await body(Connection(
                store: LampSyncDirectoryStore(root: folder),
                source: LampSyncFileRecords.folderSource(folder),
                account: ""
            ))
        case .webDAV:
            guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
                throw LibrarySyncError.invalidWebDAVURL
            }
            let storedPassword = try SyncSecretStore.readPassword()
            let account = SyncAccount.identity(username: username, password: storedPassword)
            let credentials = account.isEmpty
                ? nil : LampWebDAVCredentials(username: username, password: storedPassword)
            return try await body(Connection(
                store: LampWebDAVClient(baseURL: url, credentials: credentials),
                source: LampSyncFileRecords.webDAVSource(url),
                account: account
            ))
        }
    }

    /// The store, carried into the offload's read-back closure. Used from one
    /// task at a time, as every store here is.
    private struct UncheckedStore: @unchecked Sendable {
        let store: any LampSyncRemoteStore
    }

    /// Whether the module and deck folders hold anything this Mac has not
    /// taken: a file replaced or dropped in by hand on the server, or taken
    /// away, which touches no bundle and so no bundle probe sees. One
    /// Depth:1 listing a folder and no file read, every two minutes.
    /// What a folder probe found: the listing, and whether it is worth a pass.
    private struct FolderProbe: Sendable {
        let listing: [String: String]
        let hasWork: Bool
    }

    private func listedFoldersHaveWork(library: LampLibrary) async -> Bool {
        guard Date().timeIntervalSince(listingProbedAt) >= 120 else { return false }
        listingProbedAt = Date()
        let root = library.rootURL
        let reportedMissing = missingFiles
        // A struct rather than an optional listing, because `try?` flattens a
        // nested optional: a probe that threw and a probe that found nothing
        // worth a pass would both arrive as nil, and the first must say the
        // library was not reached while the second must not.
        let probe = try? await withRemoteStore { store, source -> FolderProbe in
            let recorded = LampSyncFileRecords.load(fromLibraryAt: root).listedRevisions(in: source)
            let listing = try await LampSyncFilePlan.listing(in: store, recorded: recorded)
            // A marked file has to be looked at again even where nothing else
            // moved. One that comes back can come back at exactly the
            // revision this Mac recorded — which no comparison of revisions
            // sees — and one whose folder could not be listed has never been
            // answered at all. Either way the mark would stand for ever.
            let worthAnotherPass = reportedMissing.contains { path, why in
                why == .folderNotListed || listing[path] != nil
            }
            let moved = !LampSyncFilePlan.remoteChanges(listing: listing, recorded: recorded).isEmpty
            return FolderProbe(listing: listing, hasWork: moved || worthAnotherPass)
        }
        guard let probe else {
            // A probe that throws has not reached the library. Marks from an
            // earlier pass must stop being stated as fact: the reader is
            // offered Delete only where Lamp has actually looked.
            reachedLibrary = false
            return false
        }
        guard probe.hasWork, probe.listing != listingActedOn else { return false }
        listingActedOn = probe.listing
        Self.log.notice("Listed folders changed outside a pass; syncing")
        return true
    }

    /// Takes in another device's work while this one is open.
    ///
    /// The companion to `syncLocalWorkIfAppeared`: that publishes what is made
    /// here, this collects what was made elsewhere. It costs one request with
    /// no body, and a pass follows only when the bundle has moved.
    ///
    /// Nothing is compared for a while after this Mac's own pass. A server can
    /// answer with the revision it held before the write for a short time,
    /// which reads as somebody else's change and would start a pass answering
    /// our own.
    /// Returns whether a pass ran, so a caller only reloads when there is
    /// something new to show.
    @discardableResult
    func syncRemoteChangesIfAny(library: LampLibrary) async -> Bool {
        guard !isSyncing,
              defaults.bool(forKey: "sync.automatic"),
              provider != .off,
              Date().timeIntervalSince(lastPassFinishedAt) > 15
        else { return false }
        let revision = try? await withRemoteStore { store in
            try await store.revision(path: LampSyncFolderLayout.bundlePath)
        }
        guard let revision else {
            // The cheapest check there is, and it could not be made: say so,
            // rather than leaving a mark claiming a file is gone from a
            // library nothing can reach.
            reachedLibrary = false
            return false
        }
        guard let seen = lastSeenBundleRevision else {
            // First look since a pass. Take it as the mark to measure from
            // rather than syncing: a pass has just reconciled with this.
            lastSeenBundleRevision = revision
            return false
        }
        guard !LampSyncConditionalWrite.namesSameRevision(revision, seen ?? "") else {
            // The bundle has not moved, but a module file can still have.
            guard await listedFoldersHaveWork(library: library) else { return false }
            return await sync(library: library)
        }
        return await sync(library: library)
    }

    /// Refuses a pass that would reach the server holding the offloads any
    /// other way than they were put there: before it reads a manifest, which
    /// from another library would settle them as gone and lift the lock. A
    /// lock from before the account was kept takes this pass's.
    private func admitPass(at source: String, as account: String) throws {
        guard var lock = offloadLock else { return }
        guard lock.admits(source: source, account: account) else {
            throw LibrarySyncError.offloadsHeldElsewhere
        }
        if lock.account == nil {
            lock.account = account
            offloadLock = lock
        }
    }

    private func runSyncPass(library: LampLibrary) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        // A folder has no account; a WebDAV pass sets its own below.
        accountOfThisPass = ""
        Self.log.notice("Sync pass started (\(self.provider.rawValue, privacy: .public))")
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
                try admitPass(at: LampSyncFileRecords.folderSource(folder), as: "")
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
                // Unreadable is not none: see `withConnection`.
                let storedPassword = try SyncSecretStore.readPassword()
                // The account this store is built with, read once, here — and
                // what the pass's look at the server is labelled with.
                let account = SyncAccount.identity(username: username, password: storedPassword)
                try admitPass(at: LampSyncFileRecords.webDAVSource(url), as: account)
                accountOfThisPass = account
                let credentials = account.isEmpty
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
            Self.log.error("Sync pass failed: \(String(describing: error), privacy: .public)")
            reachedLibrary = false
            errorMessage = LampSyncErrorText.sentence(for: error)
            statusMessage = nil
            isSyncing = false
            await refreshConflicts(library: library)
            return false
        }
        isSyncing = false
        Self.log.notice("Sync pass finished")
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
        guard let offer = moveOffer, let imported = importedArchiveRevision,
              !isSyncing, !passGate
        else { return false }
        // A move runs its own pass, not through `sync(library:)`, so the
        // offloads that come after a pass do not run after it. Any the reader
        // has asked for get a pass of their own once the move is done.
        defer {
            Task { [weak self] in
                guard let self,
                      await !LampWorkspaceSync.requestedOffloads(inLibraryAt: library.rootURL).isEmpty
                else { return }
                _ = await self.sync(library: library)
            }
        }
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
        // When each deletion the pass was handed was made, for forgetting
        // only those, not one made again while it ran.
        var carriedDeletions: [String: Int64] = [:]

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

        let outcome: LampSyncBundlePass.Outcome
        do {
        outcome = try await reportingWeakRevision {
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
                carriedDeletions = gathered.gathered.deletedLocally
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
        } catch {
            // Kept even so: a pass that stopped after writing files leaves
            // their revisions in `records`, unrecorded in the manifest, and
            // the next pass records them. Lost, a copy this Mac sent and then
            // deleted reads as one someone else put back, and comes back.
            try? records.save(toLibraryAt: library.rootURL, fileManager: fileManager)
            throw error
        }

        // A highlight set's module ID lives only in the module on the server,
        // so a set stays unpublished until a pass has read one.
        for (setID, moduleID) in learned.highlightModuleIDsBySet {
            records.setHighlightModuleID(moduleID, forSet: setID, in: source)
        }
        try records.save(toLibraryAt: library.rootURL, fileManager: fileManager)
        // The manifest carries these now, so this Mac need not. `tombstoned`
        // is what the manifest took, not what the plan asked for, which
        // matters here more than anywhere: this Mac's deletions come from the
        // deck ledger and the personal ledger, which keep their records for
        // ever, so it asks for the same tombstones on every pass. Keyed on
        // the ask, and writing regardless, this dated a file
        // `LampSyncLocalWork` reads — so the Mac saw work to publish every
        // time it published, and synced every six seconds for as long as it
        // was open. `forget` writes only where the record moved as well.
        // `settled` too: deletions the manifest already carried, from a pass
        // that stopped before forgetting them, with a copy written since put
        // back. Kept, each would plan its path as deleted here for good.
        try LampSyncRemovedModules.forget(
            outcome.tombstoned + outcome.settled, carried: carriedDeletions,
            inLibraryAt: library.rootURL, fileManager: fileManager
        )
        if let plannedSettings {
            try settings.remember(plannedSettings)
            reportDisputedPreferences(plannedSettings.merge)
        }
        // What the other device knew about where its books were left. Taken
        // from the bundle as written rather than by reading it back, and
        // joined rather than replacing, so a book read on both since the last
        // pass keeps the later of the two positions and the union of the
        // bookmarks.
        // Membership as the pass leaves the server, not as it found it. An
        // update that retried against another device's deletion finishes
        // with that deletion in, and reconciling against the opening manifest
        // would leave its source drawn as "On the server". The listing stays
        // the gather's: revisions are what was seen, not what was written.
        if let written = outcome.written?.bundle, let opened = pendingObservation {
            pendingObservation = opened.with(members: Set(written.manifest.members.map(\.path)))
        }
        if let written = outcome.written?.bundle,
           let incoming = LampSyncBundleLedgers.bookReading(in: written),
           readingState.merge(incoming) {
            // A bookmark set or cleared elsewhere has to appear in a book
            // that is open now; a position is read when a book next opens.
            NotificationCenter.default.post(name: .lampBookReadingStateChanged, object: nil)
        }
        defaults.set(Date(), forKey: "sync.lastCompleted")
        missingFiles = outcome.missing
        reachedLibrary = true
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
        // The media the manifest already names. Disk discovery may only
        // answer for one of these: a file at a path nobody names would be
        // uploaded, and a writing deleted before its first sync leaves its
        // pictures on disk — publishing those would send the reader
        // something they deleted.
        let mediaMembers = Set(
            manifest.members.lazy
                .filter { $0.kind?.isMedia == true }
                .map(\.path)
        )
        let media = LampSyncLocalFiles.devotionalMedia(
            for: writings,
            remoteModuleID: LampSyncMacPassLibrary.remoteWritingModuleID,
            inLibraryAt: library.rootURL,
            members: mediaMembers,
            fileManager: fileManager
        )
        candidates += media.candidates

        // A note's pictures, for the notes that have any.
        let notesWithMedia = try await library.personalNotesWithMedia()
        let notePictures = LampSyncLocalFiles.noteMedia(
            for: notesWithMedia,
            remoteModuleID: LampSyncMacPassLibrary.remoteNotesModuleID,
            inLibraryAt: library.rootURL,
            members: mediaMembers,
            fileManager: fileManager
        )
        candidates += notePictures.candidates
        result.gaps += LampSyncLocalFiles.unresolved(
            notePictures.missing, candidates: notePictures.candidates, manifest: manifest
        )

        // A notes module's pictures, which are not inside its .lamp either.
        let notesModulePictures = LampSyncLocalFiles.noteModuleMedia(
            for: try await library.noteModuleMediaFilenames(),
            inLibraryAt: library.rootURL,
            fileManager: fileManager
        )
        candidates += notesModulePictures.candidates
        // Said rather than swallowed, as a writing's are: a picture a note
        // refers to and the library does not hold is published as a
        // reference to bytes that were never sent, and the other device has
        // no way to find out.
        result.gaps += LampSyncLocalFiles.unresolved(
            notesModulePictures.missing,
            candidates: notesModulePictures.candidates, manifest: manifest
        )

        // A book's pictures, for the books in the library and any the
        // manifest already names — the gate that keeps a picture belonging to
        // something else from going up as a book's.
        // Every module this Mac knows of another kind, not just those with a
        // file to publish: one whose file has gone is still read from its
        // database, and still keeps pictures under its ID.
        let otherModules = try await library.installedModules()
            .filter { $0.kind != .book }.map(\.id)
        let pictures = LampSyncLocalFiles.bookMedia(
            books: Set(modules.filter { $0.module.kind == .book }.map(\.module.id)),
            otherModules: Set(otherModules),
            remotePaths: manifest.members.map(\.path),
            inLibraryAt: library.rootURL,
            fileManager: fileManager
        )
        candidates += pictures.candidates
        result.gaps += pictures.unplaceable

        let decks = LampSyncLocalFiles.decks(
            inLibraryAt: library.rootURL, fileManager: fileManager
        )
        candidates += decks.candidates
        result.gaps += decks.unplaceable

        // Each writing's review marks. A deleted writing's go with it
        // everywhere, and are swept first, so a file removed here is not
        // also offered for upload.
        let personalLedger = try await library.personalDeletionLedger()
        let reviewDeletions = try LampWritingReviewStore(rootURL: library.rootURL).deletions(
            deleted: LampWritingReviewStore.deletedWritings(in: personalLedger),
            held: Set(writings.map(\.id)),
            members: Dictionary(manifest.members.map { ($0.path, $0.presentSince ?? 0) }, uniquingKeysWith: max),
            now: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        candidates += LampSyncLocalFiles.writingReviews(inLibraryAt: library.rootURL, fileManager: fileManager)
        // And its documents, the outline and notes beside it, swept before
        // the workspaces are gathered below for the same reason.
        let documentDeletions = try LampWritingDocumentStore(
            rootURL: LampWritingWorkspace.root(libraryRootURL: library.rootURL, fileManager: fileManager)
        ).deletions(
            deleted: LampWritingReviewStore.deletedWritings(in: personalLedger),
            held: Set(writings.map(\.id)),
            members: Dictionary(manifest.members.map { ($0.path, $0.presentSince ?? 0) }, uniquingKeysWith: max),
            now: Int64(Date().timeIntervalSince1970 * 1_000)
        )

        // Off the main thread, which this controller otherwise holds. Hashing
        // every file is most of a pass's own work, a second and a half on a
        // full library, and a launch sync doing it here froze the splash half
        // faded over the reader until it was done.
        //
        // The first pass of a session reads every file. After that the bytes
        // — modules and media — are answered from what this session already
        // read, where the library's filesystem keeps an identity worth
        // trusting (`lamp-bible-core/Documentation/decisions/0007`).
        let gatheredSoFar = candidates
        let libraryRoot = library.rootURL
        let fileManager = self.fileManager
        let digests = digestCache(forLibraryAt: libraryRoot)
        let described = try await Task.detached {
            let workspaces = try await LampSyncLocalFiles.workspaceFiles(
                inLibraryAt: libraryRoot,
                stagingIn: exports,
                fileManager: fileManager
            )
            return LampSyncLocalFiles.describe(
                gatheredSoFar + workspaces, fileManager: fileManager, digests: digests
            )
        }.value
        result.gathered.local = described.files
        // A revision this Mac compacted away leaves no file at its path, and
        // a member with no local copy is downloaded — then written back by
        // the merge and deleted again by the compaction that follows it, on
        // every pass, for ever. The history is held; it is in the revision
        // that replaced it. (`lamp-bible-core/Documentation/decisions/0016`.)
        //
        // After the locals, not beside the other claim above, because this
        // one asks what the gather actually produced for every workspace,
        // which is not known until the workspaces have been described.
        //
        // Except the ids an untagged merge here still needs a file for: a
        // demotion wants every id the merge replaced, so claiming one would
        // leave a turn's changes under no turn's name for good.
        // The sources this Mac has **offloaded**: still on the server,
        // dropped here to free space. The pass takes no part in them —
        // nothing fetched, nothing deleted, nothing recorded — so they come
        // down again when something asks.
        //
        // Read from each workspace's ledger, not from what is missing. The
        // first version of this withheld every absent source, which cannot
        // tell a file this Mac offloaded from one it has never seen: a new
        // Mac withheld the whole library's sources and had no way to fetch
        // one. Absence is not a fact about intent, and this is the fourth
        // place tonight that has had to be said
        // (`lamp-bible-core/Documentation/decisions/0016`, `0017`, `0018`).
        let offloaded = await LampWorkspaceSync.offloadedSources(
            inLibraryAt: library.rootURL, fileManager: fileManager
        )
        if !offloaded.isEmpty {
            let members = Set(manifest.members.lazy.map(\.path))
            result.gathered.withheld.formUnion(offloaded.intersection(members))
        }

        result.gathered.heldWithoutAFile.formUnion(
            await LampWorkspaceSync.revisionMembersHeldWithoutAFile(
                members: manifest.members.map(\.path),
                heldAsFiles: Set(described.files.map(\.path)),
                inLibraryAt: library.rootURL,
                fileManager: fileManager
            )
        )
        // Said to the pass rather than only to the person: a path left out of
        // the locals reads as one this Mac does not hold, so the plan used to
        // fetch the server's copy and install it over the file it could not
        // read (`lamp-bible-core/Documentation/decisions/0013`).
        //
        // And *only* to the pass, which reports a line per refused path —
        // adding them to `gaps` as well put each unreadable file in the
        // status line twice, and two of them crowded out whatever else had
        // gone wrong in the pass.
        for gap in described.unreadable { result.gathered.refused[gap.path] = gap.reason }
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
        // A writing's documents deleted here are written down the same way.
        // One that is here again, restored or brought back by a newer write
        // elsewhere, is no longer deleted, and is forgotten. The pass dates
        // one still gone past the server's write of the copy this Mac last
        // had (core's `queuedDeletionTime`), so neither a slow clock here nor
        // an upload sent while it was deleted brings it back.
        let heldDocuments = Set((try? LampWritingDocumentStore(
            rootURL: LampWritingWorkspace.root(libraryRootURL: library.rootURL, fileManager: fileManager)
        ).held().keys).map(Array.init) ?? [])
        let removals = LampSyncRemovedModules.load(fromLibraryAt: library.rootURL, fileManager: fileManager).removedAt
        // Sources too, now that one can be deleted. A reader who removes a
        // source and attaches another at the same name before the next pass
        // would otherwise have the queued deletion win: the path tombstoned,
        // the server's copy reaped, and a later pass deleting the
        // replacement here. A file that is present again is not deleted.
        let heldSources = Set(described.files.lazy.map(\.path).filter(LampWorkspaceSync.namesAsource))
        let restored = removals.keys.filter { heldDocuments.contains($0) || heldSources.contains($0) }
        if !restored.isEmpty {
            try LampSyncRemovedModules.forget(restored, inLibraryAt: library.rootURL, fileManager: fileManager)
        }
        // A document deleted on its own, rather than with its writing.
        // Its marks go with it: a record left behind is fetched from the
        // server for ever, and a later document of the same name would
        // wear another file's marks.
        let reviewStore = LampWritingReviewStore(rootURL: library.rootURL)
        var reviewRemovals: [String: Int64?] = [:]
        let manifestTimes = Dictionary(
            manifest.members.map { ($0.path, $0.presentSince ?? 0) }, uniquingKeysWith: max
        )
        for (path, removedAt) in removals where !heldDocuments.contains(path) {
            result.gathered.deletedLocally[path] = removedAt
        }
        // What becomes of each document's review record, decided by
        // core (`LampWritingDocumentReview.fate`) and by nothing here.
        // The Mac answered this three times and was wrong three times,
        // each costing a live document every mark on it: a tombstone
        // dated now beat another device's later save; dated from the
        // document's own deletion it still beat a record older than
        // both; and sweeping a record whose document was merely absent
        // swept the records of documents whose own upload had failed.
        // The rule is modelled (`Verification/SyncMerge.lean`:
        // `reviewFate`) and the phone calls the same one.
        // Every record here, and every record a deletion is already
        // queued for. A record removed by an earlier gather is not in
        // the folder any more, so looking only at the files there could
        // never take its deletion back — and a document that came back
        // after a failed pass would lose its marks on the server.
        var toWeigh = ((try? reviewStore.reviewed()) ?? []).map {
            (writingID: $0.writingID, documentKey: $0.documentKey)
        }
        let queued = Set(removals.keys).union(result.gathered.deletedLocally.keys)
        for path in queued {
            guard let target = LampSyncFolderLayout.reviewTarget(ofPath: path),
                  target.documentKey != nil,
                  !toWeigh.contains(where: {
                      $0.writingID == target.writingID && $0.documentKey == target.documentKey
                  })
            else { continue }
            toWeigh.append((target.writingID, target.documentKey))
        }
        for kept in toWeigh {
            guard let key = kept.documentKey,
                  let reviewPath = try? LampSyncFolderLayout.writingReviewPath(
                      writingID: kept.writingID, documentKey: key
                  ),
                  let name = LampWritingDocumentReview.place(
                      of: reviewPath,
                      record: (try? reviewStore.review(
                          writingID: kept.writingID, documentKey: key
                      )) ?? nil
                  )?.document,
                  let documentPath = try? LampWritingWorkspaceLayout.documentPath(
                      folder: LampWritingWorkspaceLayout.directoryName(for: kept.writingID),
                      name: name
                  )
            else { continue }
            let entry = manifest.entry(at: documentPath)
            switch LampWritingDocumentReview.fate(
                held: heldDocuments.contains(documentPath),
                // The revision the deletion was of, which the manifest
                // keeps: without it a deletion is weighed by time alone
                // and the one distinction that settles it is lost.
                deletedHere: removals[documentPath].map {
                    (at: $0, revision: entry?.deletedRevision)
                },
                document: entry.map { (revision: $0.revision, isMember: $0.isMember) },
                // The document's time, not the record's. A record may
                // not have been touched for months while the document
                // was saved yesterday, and it is the document's save
                // that overtakes a deletion of the document.
                documentWritten: entry?.presentSince,
                asked: result.gathered.deletedLocally[reviewPath],
                now: Int64(Date().timeIntervalSince1970 * 1_000)
            ) {
            case .deleted(let at):
                try? reviewStore.remove(writingID: kept.writingID, documentKey: key)
                let dated = manifestTimes[reviewPath].map { max(at, $0 + 1) } ?? at
                result.gathered.deletedLocally[reviewPath] = dated
                // Written down beside the documents' own removals, so a
                // pass that fails does not lose the only thing that
                // would sweep again.
                reviewRemovals[reviewPath] = dated
            case .cancelled:
                result.gathered.deletedLocally.removeValue(forKey: reviewPath)
                // `updateValue`, not the subscript: assigning nil
                // through the subscript of a dictionary of optionals
                // takes the entry out instead of storing a nil, so the
                // cancellations below found nothing to forget.
                reviewRemovals.updateValue(nil, forKey: reviewPath)
            case .none:
                break
            }
        }
        if !reviewRemovals.isEmpty {
            var records = LampSyncRemovedModules.load(
                fromLibraryAt: library.rootURL, fileManager: fileManager
            )
            for (path, removedAt) in reviewRemovals {
                guard let removedAt else { continue }
                records.record(path, at: removedAt)
            }
            try? records.save(toLibraryAt: library.rootURL, fileManager: fileManager)
            let cancelled = reviewRemovals.filter { $0.value == nil }.map(\.key)
            if !cancelled.isEmpty {
                try? LampSyncRemovedModules.forget(
                    cancelled, inLibraryAt: library.rootURL, fileManager: fileManager
                )
            }
        }
        // A highlight set's deletion is recorded per item; the file that
        // carried it is the module this source published it under.
        let personal = personalLedger
        result.gathered.deletedLocally.merge(reviewDeletions) { max($0, $1) }
        result.gathered.deletedLocally.merge(documentDeletions) { max($0, $1) }
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
        // Sources carry when they were attached here, so a replacement put
        // at a path another Mac deleted supersedes that deletion rather than
        // being taken for the copy it deleted.
        let sourceTimes = await LampWorkspaceSync.sourceAttachmentTimes(
            inLibraryAt: library.rootURL, fileManager: fileManager
        )
        result.gathered.savedAt = LampSyncSavedAt.paths(
            notesLastSaved: LampSyncSavedAt.lastSaved(.note, in: personal),
            writingsLastSaved: writings.compactMap(\.lastModified).max(),
            highlightSets: sets.map { ($0.id, $0.lastModified) },
            highlightModuleIDs: moduleIDs,
            decks: decks.candidates.compactMap { candidate in
                guard let modified = LampFileModification.date(of: candidate.url) else { return nil }
                return (candidate.path, modified)
            }
        )
        result.gathered.savedAt.merge(sourceTimes) { _, source in source }

        // The paths no folder listing reaches: the manifest names them, and
        // their folders are listed for them — one request a folder rather
        // than one a file. See `revisionsOfUnlistedMembers`.
        // Withheld paths are not asked about either. A folder provider's
        // listing carries no revision, so the fallback asks the file itself —
        // which on iCloud materialises an evicted copy and hashes it. A pass
        // that will not install a source has no business pulling its bytes
        // into the sync folder to find out its revision.
        let withheld = result.gathered.withheld
        let unlisted = await LampSyncLocalFiles.revisionsOfUnlistedMembers(
            manifest.members
                .filter { !($0.kind?.isListed ?? true) && !withheld.contains($0.path) }
                .map(\.path),
            from: store
        )
        // Which server this pass looked at, as whom, and what its manifest
        // counts — for what runs after it. Labelled with the source and the
        // account this gather's store was built with, not whatever the
        // settings say by the time anyone reads it. Not proof of any file:
        // an offload reads the server's copy back (`decisions/0022`).
        pendingObservation = ServerObservation(
            source: source,
            account: accountOfThisPass,
            members: Set(manifest.members.map(\.path))
        )
        result.gathered.extraListing.merge(unlisted) { _, listed in listed }
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
        // Said in the log rather than the status line: it is a fault in the
        // app, not something the reader did or can mend, and it means this
        // pass fetched a file it had fetched before. The phone did it to
        // every reading plan for months without a word anywhere.
        // (`LampSyncUnclaimedInstalls`.)
        //
        // Through `Self.log` and not `print`, for the reason the logger's own
        // comment gives: an installed app launched from Finder has nowhere
        // for stdout to go, so these two reports — the only warning anything
        // gives for this fault — reached nobody. Two days of the unified log
        // held not one of them while a library was fetching 43 revision
        // members again on every pass.
        //
        // The count and the folders are public and the paths are not: a
        // member's path carries names the reader chose — a context file is
        // titled whatever the book is called — and the unified log is what a
        // sysdiagnose collects and a person sends on. The count is what says
        // whether this is happening and whether it stopped, which is all the
        // two-pass check needs.
        if !outcome.fetchedAgain.isEmpty {
            let count = outcome.fetchedAgain.count
            let folders = LampSyncDiagnostics.folders(named: outcome.fetchedAgain)
            let paths = outcome.fetchedAgain.sorted().joined(separator: ", ")
            Self.log.warning(
                """
                Fetched again, so something here holds these without saying so: \
                \(count, privacy: .public) under \(folders, privacy: .public) \
                — \(paths, privacy: .private)
                """
            )
        }
        // The same fault from the other end, and the end somebody notices:
        // a thing deleted on another device that this one will not delete,
        // because as far as the plan can tell it has nothing to delete.
        if !outcome.deletionsNotCarriedOut.isEmpty {
            let count = outcome.deletionsNotCarriedOut.count
            let folders = LampSyncDiagnostics.folders(named: outcome.deletionsNotCarriedOut)
            let paths = outcome.deletionsNotCarriedOut.sorted().joined(separator: ", ")
            Self.log.warning(
                """
                Deleted elsewhere but not here, so something here holds these \
                without saying so: \(count, privacy: .public) under \
                \(folders, privacy: .public) — \(paths, privacy: .private)
                """
            )
        }
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
    /// A password may be stored and could not be read.
    case passwordNotRead(OSStatus)
    /// Sources are only on the server, reached another way than this.
    case offloadsHeldElsewhere
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
        case .passwordNotRead(let status):
            """
            Your WebDAV password couldn't be read from the keychain\
            \(SecCopyErrorMessageString(status, nil).map { " (\($0))" } ?? " (error \(status))").
            Lamp didn't sync rather than connect without it. Unlock your login keychain and try again.
            """
        case .offloadsHeldElsewhere:
            """
            Some sources are only on the server, and Lamp is now set to reach it as \
            a different account from the one they were put there as, so it didn't \
            sync. Sign in as that account again, or download them first.
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

    /// The stored password, "" where none is stored, and an error where one
    /// may be stored but could not be read — a locked keychain, a denied
    /// prompt. `password` answers nil for both.
    static func readPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else { throw LibrarySyncError.passwordNotRead(status) }
        return password
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
