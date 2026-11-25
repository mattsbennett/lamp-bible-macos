import CryptoKit
import Foundation
import LampModuleKit

/// The one owner of a writing workspace's files.
///
/// Preparing a workspace writes the policy, the helper's configuration, the
/// skills and the instructions; the assistant pane writes the context, the
/// brief and a skill beside them; and a sync pass takes a whole workspace in,
/// merging its documents and context and rewriting its skills selection. Those
/// are the same files, and one writing can be open in two panes while a phone's
/// turn is a third caller, so they need one owner or they tear each other's
/// work.
///
/// That owner is deliberately not the main actor. The work is files, not
/// drawing, and holding it on the thread that draws made every preparation a
/// run of frames the window could not paint. The serialisation is what matters,
/// not which actor provides it.
///
/// It lives here, in Support, because the sync pass writes live workspaces too
/// and cannot see into LampBibleMac. `WorkspaceFileOwnershipTests` holds every
/// writer to it, since in this project's Swift 5 mode an unannotated writer is
/// only a warning — and then runs on whoever called it.
@globalActor
public actor WritingWorkspaceFiles {
    public static let shared = WritingWorkspaceFiles()
}

/// A UTF-8 Markdown or text document stored directly inside an agent workspace.
public struct WorkspaceTextFileSnapshot: Equatable, Identifiable, Sendable {
    public let url: URL
    public let contents: String

    public init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }

    public var id: String { url.lastPathComponent }
}

/// Discovers and safely writes the user-facing text artifacts in an agent workspace.
/// Infrastructure, context, skills, and presentation files deliberately stay out of
/// the editor's document tabs.
public enum WorkspaceTextFileStore {
    public static let supportedExtensions: Set<String> = ["md", "markdown", "txt", "text"]
    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let reservedMarkdownStems: Set<String> = [
        "agents", "claude", "devotional_context", "draft",
    ]

    /// Whether the file is Markdown rather than plain text.
    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Normalizes a user-entered top-level Markdown filename. An omitted
    /// extension becomes `.md`; explicit non-Markdown extensions are rejected.
    public static func normalizedMarkdownFilename(_ proposedName: String) -> String? {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("."),
              !trimmed.hasSuffix("."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }

        let source = URL(fileURLWithPath: trimmed)
        let filename = source.pathExtension.isEmpty ? "\(trimmed).md" : trimmed
        let candidate = URL(fileURLWithPath: filename)
        guard candidate.lastPathComponent == filename,
              !candidate.deletingPathExtension().lastPathComponent.isEmpty,
              markdownExtensions.contains(candidate.pathExtension.lowercased()),
              !reservedMarkdownStems.contains(
                candidate.deletingPathExtension().lastPathComponent.lowercased()
              ),
              filename.utf8.count <= 240 else { return nil }
        return filename
    }

    @discardableResult
    public static func createMarkdownDocument(
        named proposedName: String,
        in workspaceURL: URL,
        initialContents: String = "",
        fileManager: FileManager = .default
    ) throws -> WorkspaceTextFileSnapshot {
        guard let filename = normalizedMarkdownFilename(proposedName) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "Use a top-level .md or .markdown filename that is not reserved by Lamp.",
            ])
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory) {
            let values = try workspaceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [
                    NSLocalizedDescriptionKey: "The writing workspace is not a safe directory.",
                ])
            }
        } else {
            try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        }

        let existingNames = try fileManager.contentsOfDirectory(atPath: workspaceURL.path)
        guard !existingNames.contains(where: { $0.caseInsensitiveCompare(filename) == .orderedSame }) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "A workspace file named \(filename) already exists.",
            ])
        }

        let destination = workspaceURL.appendingPathComponent(filename)
        try Data(initialContents.utf8).write(to: destination, options: .withoutOverwriting)
        return WorkspaceTextFileSnapshot(url: destination, contents: initialContents)
    }

    public static func snapshots(
        in workspaceURL: URL,
        excludingFilenames: Set<String> = []
    ) throws -> [WorkspaceTextFileSnapshot] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workspaceURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return [] }

        let excluded = Set(excludingFilenames.map { $0.lowercased() })
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  supportedExtensions.contains(url.pathExtension.lowercased()),
                  !excluded.contains(url.lastPathComponent.lowercased()),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            return WorkspaceTextFileSnapshot(url: url, contents: contents)
        }.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    public static func write(
        _ contents: String,
        to fileURL: URL,
        in workspaceURL: URL
    ) throws {
        let workspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let parent = fileURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard parent == workspace,
              supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Workspace documents must be Markdown or text files stored at the top level of the writing workspace.",
            ])
        }
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Opening a file by hand

    /// Where `url` sits inside the workspace, or nil if it sits outside it.
    ///
    /// Both sides are resolved first, so a path that leaves the workspace
    /// through a symbolic link or `..` is recognised as outside it however it
    /// is spelled.
    public static func relativePath(of url: URL, in workspaceURL: URL) -> String? {
        let workspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let workspaceComponents = workspace.pathComponents
        let fileComponents = file.pathComponents
        guard fileComponents.count > workspaceComponents.count,
              Array(fileComponents.prefix(workspaceComponents.count)) == workspaceComponents
        else { return nil }
        return fileComponents.dropFirst(workspaceComponents.count).joined(separator: "/")
    }

    /// Opens any readable text file inside the workspace, at any depth.
    ///
    /// The document tabs list only the writing's companions on purpose —
    /// infrastructure, context and skills would bury them — but anything in the
    /// workspace can be opened deliberately, which is what this is for. The
    /// limits that remain are the ones that protect the editor rather than tidy
    /// it: inside the workspace, a real file, and text rather than bytes.
    public static func openableSnapshot(
        at url: URL,
        in workspaceURL: URL
    ) throws -> WorkspaceTextFileSnapshot {
        guard relativePath(of: url, in: workspaceURL) != nil else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Only files inside this writing's workspace can be opened here.",
            ])
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) is not a file.",
            ])
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              !contents.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) is not a text file, so it can't be edited here.",
            ])
        }
        return WorkspaceTextFileSnapshot(url: url, contents: contents)
    }

    /// Saves a file opened that way, back where it came from.
    public static func writeOpened(
        _ contents: String,
        to fileURL: URL,
        in workspaceURL: URL
    ) throws {
        guard relativePath(of: fileURL, in: workspaceURL) != nil else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Only files inside this writing's workspace can be saved here.",
            ])
        }
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

/// A human label for a workspace file, so a tab beside "Main Prose" reads the
/// same way rather than as a raw filename.
public enum WorkspaceDocumentTitle {
    /// `outline.md` becomes "Outline", `deck-format.md` "Deck Format".
    ///
    /// A word that already carries a capital is left exactly as typed, so
    /// `README.md` and `DEVOTIONAL_CONTEXT.md` are not retitled into something
    /// their author did not write.
    public static func formatted(_ path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        // A dotfile's name is its identity — `.mcp.json` means something that
        // "Mcp" does not — so it is shown as written.
        guard !filename.hasPrefix(".") else { return filename }
        let stem = (filename as NSString).deletingPathExtension
        let source = stem.isEmpty ? filename : stem
        let words = source
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return filename }
        return words.map { word in
            word.contains(where: \.isUppercase) ? word : word.capitalized
        }.joined(separator: " ")
    }

    /// Titles for several files at once, keyed by the path each was given.
    ///
    /// Two files can format to one title — `deck/notes.md` and `notes.md`, or
    /// `outline.md` beside `outline.txt`. Where that happens the whole path is
    /// used for every file that collided, because a tab bar in which two tabs
    /// read alike is worse than one that reads less prettily.
    public static func titles(for paths: [String]) -> [String: String] {
        var byTitle: [String: [String]] = [:]
        for path in paths {
            byTitle[formatted(path), default: []].append(path)
        }
        var result: [String: String] = [:]
        for (title, paths) in byTitle {
            for path in paths {
                result[path] = paths.count == 1 ? title : path
            }
        }
        return result
    }
}

/// Stores workspace context as content-addressed, read-only files. Every unique
/// byte sequence is kept once per Lamp library; workspace paths are hard links
/// to that shared object so filenames and directory layout remain user-facing.
public enum WorkspaceContextFileStore {
    private static let agentWorkspacesDirectory = "AgentWorkspaces"
    private static let contextDirectoryName = "context"
    private static let objectDirectoryName = ".ContextObjects"

    /// Adds a file or directory to a workspace's context. An identical top-level
    /// file already in that workspace is reused instead of adding another alias.
    ///
    /// A folder is copied as far as it can be: entries that cannot become
    /// context — symbolic links, aliases to elsewhere, sockets, devices, and
    /// anything unreadable — are reported through `reportingSkipped` by their
    /// path relative to the folder rather than failing the whole add.
    @discardableResult
    @WritingWorkspaceFiles
    public static func addContextItem(
        from sourceURL: URL,
        to workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default,
        reportingSkipped: (String) -> Void = { _ in }
    ) throws -> URL? {
        let contextDirectory = try validatedContextDirectory(
            in: workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        let source = sourceURL.standardizedFileURL
        guard !isContained(source, in: contextDirectory) else { return nil }
        // Names a source still holds though it is not here: let go to the
        // server, or on its way back. The disk shows them free, and a new
        // attachment given one of them would be published over the server's
        // copy on the next pass — overwriting a source with something else,
        // and nobody asked. The top-level name is what is taken, so a new
        // folder cannot land among offloaded files either.
        //
        // Compared without case: on the case-insensitive volume a library
        // usually lives on, `history.pdf` and an offloaded `History.pdf` are
        // one path. Over-reserving on a case-sensitive volume costs a " 2".
        // From a ledger that read: one that would not cannot say which names
        // are taken, and guessing none could put a new file over an
        // offloaded source's only copy.
        guard let ledger = WorkspaceFileLedger.loadIfReadable(in: workspaceURL) else {
            throw WorkspaceFileLedger.UnreadableLedger()
        }
        let reserved = Set(
            ledger.contextActs()
                .filter { $0.value != .leaving }.keys.compactMap {
                    $0.split(separator: "/", maxSplits: 1).first.map {
                        String($0).precomposedStringWithCanonicalMapping.lowercased()
                    }
                }
        )

        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else { throw unsafeContextItemError() }

        if values.isRegularFile == true {
            let digest = try contentDigest(of: source)
            if let existing = try topLevelFile(
                withDigest: digest,
                in: contextDirectory,
                fileManager: fileManager
            ) {
                try materialize(
                    existing,
                    withDigest: digest,
                    at: existing,
                    libraryRootURL: libraryRootURL,
                    fileManager: fileManager
                )
                return existing
            }
            let destination = availableDestination(
                named: source.lastPathComponent,
                in: contextDirectory,
                reserving: reserved,
                fileManager: fileManager
            )
            try materialize(
                source,
                withDigest: digest,
                at: destination,
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
            return destination
        }

        guard values.isDirectory == true else { throw unsafeContextItemError() }
        let destination = availableDestination(
            named: source.lastPathComponent,
            in: contextDirectory,
            reserving: reserved,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try addDirectoryContents(
                from: source,
                to: destination,
                relativePath: "",
                libraryRootURL: libraryRootURL,
                fileManager: fileManager,
                reportingSkipped: reportingSkipped
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Removes a direct child of a workspace's context and prunes shared objects
    /// after their final workspace link disappears.
    @WritingWorkspaceFiles
    public static func removeContextItem(
        at itemURL: URL,
        from workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let contextDirectory = try validatedContextDirectory(
            in: workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        let item = itemURL.standardizedFileURL
        guard item.deletingLastPathComponent() == contextDirectory,
              fileManager.fileExists(atPath: item.path) else { return }
        // Resolved, not just string-compared. A nested directory that is a
        // symbolic link out of the workspace can satisfy a prefix check while
        // naming a file somewhere else entirely, and this removes what it
        // names (`decisions/0010`: a pass deals only in ordinary files).
        guard item.resolvingSymlinksInPath().path
            .hasPrefix(contextDirectory.resolvingSymlinksInPath().path + "/")
        else { return }

        // Every source about to go, by its published key, taken *before* the
        // removal while the files are still there to enumerate.
        let keys = publishedKeys(under: item, below: contextDirectory, fileManager: fileManager)
        // Whether it is a folder, asked of the disk before it goes. Asked
        // after, only a cached answer on the URL could say.
        var status = stat()
        let isFolder = lstat(item.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
        // And the ledger, read before anything is touched: one that will not
        // read cannot name the offloaded sources under a folder, and a save
        // over it would be refused only after the files were gone and their
        // removals queued.
        guard var ledger = WorkspaceFileLedger.loadIfReadable(in: workspaceURL) else {
            throw WorkspaceFileLedger.UnreadableLedger()
        }
        let relative = String(
            item.standardizedFileURL.path.dropFirst(contextDirectory.standardizedFileURL.path.count + 1)
        )
        // A folder holding a source with no copy here is not removed: that
        // would delete the only copy, on the server, which is the one thing
        // this feature never does on a click (`decisions/0022`). Download it
        // first. At the folder's own path too — a folder that has taken an
        // offloaded file's place hides it.
        if isFolder {
            let notHere = ledger.contextActs()
                .filter { $0.value != .leaving }
                .keys
                .filter { $0 == relative || $0.hasPrefix(relative + "/") }
                .filter { !LampWorkspaceSync.isHere($0, inContextOf: workspaceURL, fileManager: fileManager) }
            guard notHere.isEmpty else { throw OffloadError.waitsForDownload(relative) }
        }

        let digests = try regularFileDigests(including: item, fileManager: fileManager)
        try fileManager.removeItem(at: item)
        try pruneObjects(
            withDigests: digests,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )

        // **This is the act that means "delete it everywhere".** A source
        // that merely goes missing is not a deletion — the ledger used to
        // infer one from absence, which cannot tell the reader's removal from
        // a file this Mac offloaded or an agent tidying the workspace it runs
        // in (`lamp-bible-core/Documentation/decisions/0018`). So the removal
        // writes it down, and nothing else does.
        //
        // One entry per *file*, not one for the folder: the import checks
        // each source against its own key, so a folder's key alone would
        // leave every file inside it on the other Mac. Every one of them was
        // here — a folder holding anything that was not is refused above.
        let allKeys = Set(keys)
        guard !allKeys.isEmpty else { return }

        // Queued for the *server* first: until a source became a deletable
        // kind its removal travelled only inside the workspace tree, so every
        // device dropped its copy and the store kept the bytes for ever
        // (`lamp-bible-core/Documentation/decisions/0019`). And first, before
        // the acts are cleared below: the other way round, a crash between the
        // two would leave an offloaded child gone from the list with nothing
        // telling the server, and the lock on where sync points free to lift.
        let folder = workspaceURL.lastPathComponent
        let members = allKeys.compactMap { key -> String? in
            let relative = String(key.dropFirst(WorkspaceFileLedger.contextKey("").count))
            return try? LampWritingWorkspaceLayout.contextPath(
                folder: folder, relativePath: relative
            )
        }
        if !members.isEmpty {
            var removed = LampSyncRemovedModules.load(
                fromLibraryAt: libraryRootURL, fileManager: fileManager
            )
            let now = WorkspaceFileLedger.milliseconds(Date())
            for member in members { removed.record(member, at: now) }
            try removed.save(toLibraryAt: libraryRootURL, fileManager: fileManager)
        }

        for key in allKeys { ledger.recordDeletion(of: key) }
        try ledger.save(in: workspaceURL)
    }

    /// The published keys of every regular file at or under `item`.
    ///
    /// Relative to the context directory, which is what a member path and a
    /// ledger key are built from. A link is left out, as the digest walk
    /// leaves one out and for the reason `decisions/0010` gives.
    private static func publishedKeys(
        under item: URL, below contextDirectory: URL, fileManager: FileManager
    ) -> [String] {
        let prefix = contextDirectory.standardizedFileURL.path + "/"
        func key(_ url: URL) -> String? {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return nil }
            let relative = String(path.dropFirst(prefix.count))
            return relative.isEmpty ? nil : WorkspaceFileLedger.contextKey(relative)
        }
        let values = try? item.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        if values?.isSymbolicLink == true { return [] }
        if values?.isRegularFile == true { return key(item).map { [$0] } ?? [] }
        guard values?.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: item, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              )
        else { return [] }
        var keys: [String] = []
        for case let file as URL in enumerator {
            guard let child = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ]), child.isRegularFile == true, child.isSymbolicLink != true,
                  let k = key(file)
            else { continue }
            keys.append(k)
        }
        return keys
    }

    /// Drops a source's local copy, keeping the server's.
    ///
    /// The space back is the whole of it: a reader's sources are most of what
    /// a library holds, and on the measured one the six largest PDFs
    /// compressed **1.07×** — a PDF is already deflated, so archiving by
    /// compression reclaims about 7% where this reclaims all of it
    /// (`lamp-bible-core/Documentation/decisions/0018`).
    ///
    /// One source through `offloadSources`, its refusal as an error.
    @WritingWorkspaceFiles
    public static func offloadSource(
        relativePath: String,
        in workspaceURL: URL,
        libraryRootURL: URL,
        observation: ServerObservation,
        server: OffloadServer,
        fileManager: FileManager = .default,
        while shouldContinue: (@Sendable () async -> Bool)? = nil
    ) async throws {
        let result = try await offloadSources(
            [relativePath], in: workspaceURL, libraryRootURL: libraryRootURL,
            observation: observation, server: server, fileManager: fileManager,
            while: shouldContinue
        )
        guard result.offloaded.isEmpty else { return }
        switch result.skipped[relativePath] {
        case .changedSinceUpload: throw OffloadError.changedSinceUpload(relativePath)
        case .untrustedVolume: throw OffloadError.untrustedVolume(relativePath)
        case .wouldLoseWhatNoStoreKeeps: throw OffloadError.wouldLoseWhatNoStoreKeeps(relativePath)
        case .nowHeld: throw OffloadError.notOnTheServer(relativePath)
        case .notOnTheServer, .later: throw OffloadError.notOnTheServer(relativePath)
        case .serverCopyDiffers: throw OffloadError.serverCopyDiffers(relativePath)
        case .couldNotReadTheServer: throw OffloadError.couldNotReadTheServer(relativePath)
        default: throw OffloadError.notAsource(relativePath)
        }
    }

    /// Asks for a source to go back to the server after the next sync.
    ///
    /// Nothing is deleted here. Every offload happens in one place — right
    /// after a sync pass finishes, with that pass's fresh look at the server
    /// and nothing else running — because a button that deleted at any moment
    /// could overlap a pass, a change of server, or a refresh of the lock on
    /// one, and three review rounds kept finding those overlaps one at a time
    /// (owner's decision, `decisions/0021`).
    @WritingWorkspaceFiles
    public static func queueOffload(relativePath: String, in workspaceURL: URL) throws {
        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        let file = workspaceURL.appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent(relativePath)
        // Bound to the file it is about, or not made: a request with no file
        // to bind would go to whatever is put at the path next.
        guard LampWorkspaceSync.isHere(relativePath, inContextOf: workspaceURL),
              let identity = try? LampFileIdentity(regularFileAt: file)
        else { throw OffloadError.notAsource(relativePath) }
        ledger.noteLeaving(
            WorkspaceFileLedger.contextKey(relativePath),
            file: WorkspaceFileLedger.place(of: identity)
        )
        try ledger.save(in: workspaceURL)
    }

    /// Withdraws a request to offload, before the sync that would carry it out.
    @WritingWorkspaceFiles
    public static func cancelOffload(relativePath: String, in workspaceURL: URL) throws {
        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        let key = WorkspaceFileLedger.contextKey(relativePath)
        guard ledger.acts[key] == .leaving else { return }
        ledger.forgetAct(key)
        try ledger.save(in: workspaceURL)
    }

    /// Asks for an offloaded source back.
    ///
    /// Recorded as what the reader did, and that is all: the gather stops
    /// withholding it, so the next pass fetches it, and the pane draws it as
    /// on its way until it arrives. The ask outlives the attempt — a pass
    /// that cannot reach the server leaves something to press again.
    @WritingWorkspaceFiles
    public static func fetchSource(
        relativePath: String,
        in workspaceURL: URL
    ) throws {
        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        ledger.noteWanted(WorkspaceFileLedger.contextKey(relativePath))
        try ledger.save(in: workspaceURL)
    }

    /// Why one source was left where it was.
    public enum Skipped: String, Sendable {
        /// Not a member on the server, or never uploaded or downloaded by
        /// this Mac: nothing worth reading back yet.
        case notOnTheServer
        /// The server's copy, read just now, is not these bytes — or there is
        /// none. Download would not give these back.
        case serverCopyDiffers
        /// The server's copy could not be read. Nothing is known, so nothing
        /// goes.
        case couldNotReadTheServer
        /// This run has read as much from the server as it may; the rest
        /// wait for the next.
        case later
        /// Another member's path differs from this one only in case. Fetched
        /// back, the two land on one name wherever names fold, and the pass
        /// refuses such a pair — so neither could come back.
        case nameCollides
        /// The bytes here are not the bytes that were uploaded, or they
        /// changed between being checked and being deleted. The next pass
        /// takes the new ones up, and the sweep after that may offload them.
        case changedSinceUpload
        /// Not a plain file under this workspace's context directory.
        case notAsource
        /// The file would not go. Nothing is left recorded, so it is offered
        /// again.
        case couldNotRemove
        /// Somebody opened the writing while the batch was working.
        case nowHeld
        /// The reader withdrew the request while the batch was working.
        case withdrawn
        /// The library is on a volume whose file identities cannot be trusted
        /// to notice a change, so nothing there is offloaded.
        case untrustedVolume
        /// The file carries a resource fork or Finder tags, which no store
        /// keeps.
        case wouldLoseWhatNoStoreKeeps

        /// Whether trying again after another sync could change the answer.
        /// A request to offload a source that will never qualify is dropped,
        /// and said, rather than retried for ever.
        public var isLasting: Bool {
            switch self {
            case .notAsource, .untrustedVolume, .wouldLoseWhatNoStoreKeeps, .nameCollides: true
            case .notOnTheServer, .serverCopyDiffers, .couldNotReadTheServer, .later,
                 .changedSinceUpload, .couldNotRemove, .nowHeld, .withdrawn: false
            }
        }
    }

    /// Puts sources back on the server.
    ///
    /// The one function every offload goes through — the pane's button and
    /// the unattended sweep alike — so neither can be laxer than the other.
    ///
    /// **Checked, then acted on, one file at a time.** Every source is
    /// verified first:
    ///
    /// - a member of the server's manifest as the last pass left it, and
    ///   uploaded or downloaded by this Mac with these bytes — cheap, and only
    ///   to avoid reading back what cannot qualify;
    /// - read through one open, which gives the identity and the digest of
    ///   the same bytes (`VerifiedSource`).
    ///
    /// Then, per file, **the server's copy is read and hashed**, through the
    /// store the sync uses now, and the file goes only if it is these bytes
    /// (`decisions/0022`). That read is the proof; nothing remembered stands
    /// in for it. After it, the only suspension is asking whether the writing
    /// has been opened, and it comes **before** anything is noted. From noting
    /// the offload to unlinking the file nothing suspends, so no other work
    /// on this actor — a pass gathering this workspace — can see between
    /// them. The unlink takes only a `VerifiedSource`, and checks the path
    /// still holds those bytes immediately before it goes.
    @WritingWorkspaceFiles
    public static func offloadSources(
        _ relativePaths: [String],
        in workspaceURL: URL,
        libraryRootURL: URL,
        observation: ServerObservation,
        server: OffloadServer,
        onlyWhileRequested: Bool = false,
        readBudget: Int64 = readBackPerRun,
        fileManager: FileManager = .default,
        while shouldContinue: (@Sendable () async -> Bool)? = nil
    ) async throws -> (offloaded: [String], skipped: [String: Skipped], read: Int64) {
        // The server read from is the one the look was at, reached the same
        // way: otherwise the members say nothing about it.
        guard server.source == observation.source, server.account == observation.account else {
            return ([], Dictionary(relativePaths.map { ($0, Skipped.couldNotReadTheServer) },
                                   uniquingKeysWith: { first, _ in first }), 0)
        }
        guard !relativePaths.isEmpty else { return ([], [:], 0) }
        let contextDirectory = try validatedContextDirectory(
            in: workspaceURL, libraryRootURL: libraryRootURL, fileManager: fileManager
        )
        let folder = workspaceURL.lastPathComponent
        let records = LampSyncFileRecords.load(
            fromLibraryAt: libraryRootURL, fileManager: fileManager
        )

        var ready: [VerifiedSource] = []
        var skipped: [String: Skipped] = [:]
        // Members whose paths fold to the same name.
        let folded = Dictionary(grouping: observation.members) {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        }
        // Asked of the volume once, before any file is read. Off APFS nothing
        // would be offloaded anyway, and on a library kept on exFAT or a share
        // an hourly sweep would otherwise reread every eligible PDF just to
        // refuse it. The per-file answer, from the open descriptor, is still
        // what decides — this only saves reading what it would refuse.
        guard LampSyncIdentityTrust.trustsIdentity(ofVolumeAt: contextDirectory) else {
            for relativePath in relativePaths { skipped[relativePath] = .untrustedVolume }
            return ([], skipped, 0)
        }
        for relativePath in relativePaths {
            guard let path = try? LampWritingWorkspaceLayout.contextPath(
                folder: folder, relativePath: relativePath
            ) else { skipped[relativePath] = .notAsource; continue }
            guard (folded[path.precomposedStringWithCanonicalMapping.lowercased()]?.count ?? 0) <= 1 else {
                skipped[relativePath] = .nameCollides
                continue
            }
            // A member the listing showed with a revision: what Download
            // needs to plan the fetch back (`ServerObservation.listed`).
            guard observation.members.contains(path),
                  observation.listed.contains(path),
                  records.record(path, in: observation.source)?.uploadedDigest != nil
            else {
                skipped[relativePath] = .notOnTheServer
                continue
            }
            guard let verified = VerifiedSource.verify(
                relativePath: relativePath, inContext: contextDirectory
            ) else { skipped[relativePath] = .notAsource; continue }
            // Neither the digest nor any store carries a resource fork or the
            // reader's Finder tags, so the copy on the server is not all of
            // the file and no download could put them back. An attribute that
            // could not even be read counts the same.
            guard !verified.read.hasResourceFork, !verified.read.hasAttributesNoStoreKeeps else {
                skipped[relativePath] = .wouldLoseWhatNoStoreKeeps
                continue
            }
            // The last check before the unlink is of the identity alone, and
            // `decisions/0007` trusts an identity only on APFS: on exFAT, or a
            // share that mirrors the write time into the change time, a file
            // rewritten at the same size with its date put back would pass it.
            guard verified.read.identityIsTrusted else {
                skipped[relativePath] = .untrustedVolume
                continue
            }
            guard !records.changedSinceUpload(
                path, in: observation.source, digest: verified.digest
            ) else { skipped[relativePath] = .changedSinceUpload; continue }
            ready.append(verified)
        }

        var offloaded: [String] = []
        var read: Int64 = 0
        for verified in ready {
            if let shouldContinue, await !shouldContinue() {
                skipped[verified.relativePath] = .nowHeld
                continue
            }
            // The proof: the server's copy, read now, through the store the
            // sync uses, is these bytes. Bounded — the first sweep on a
            // library could otherwise read back all of it at once — and the
            // bound checked before the read, not after. One file larger than
            // the whole allowance may go only as a run's first read, or it
            // never would.
            let size = verified.read.identity.size
            guard read + size <= readBudget || (read == 0 && readBudget >= readBackPerRun) else {
                skipped[verified.relativePath] = .later
                continue
            }
            read += size
            guard let path = try? LampWritingWorkspaceLayout.contextPath(
                folder: folder, relativePath: verified.relativePath
            ) else { skipped[verified.relativePath] = .notAsource; continue }
            switch await serverCopy(
                of: path, from: server, matches: verified.digest, size: size, fileManager: fileManager
            ) {
            case .matches: break
            case .differs:
                skipped[verified.relativePath] = .serverCopyDiffers
                continue
            case .unreadable:
                skipped[verified.relativePath] = .couldNotReadTheServer
                continue
            }
            // The read suspended: whether the writing was opened, or sync
            // moved, meanwhile is asked again before anything is noted.
            if let shouldContinue, await !shouldContinue() {
                skipped[verified.relativePath] = .nowHeld
                continue
            }
            // Nothing suspends from here to the end of this iteration.
            let key = WorkspaceFileLedger.contextKey(verified.relativePath)
            var ledger = WorkspaceFileLedger.load(in: workspaceURL)
            // Still asked for, read with nothing suspending between this and
            // the note: Keep Here pressed after the batch began, while it was
            // reading the file, must still keep it.
            if onlyWhileRequested, ledger.acts[key] != .leaving {
                skipped[verified.relativePath] = .withdrawn
                continue
            }
            // And still about this file: the request goes with the file it
            // was made about, not with its name.
            let place = WorkspaceFileLedger.place(of: verified.read.identity)
            if onlyWhileRequested, let chosen = ledger.leavingFile[key], chosen != place {
                ledger.forgetAct(key)
                try ledger.save(in: workspaceURL)
                skipped[verified.relativePath] = .withdrawn
                continue
            }
            let baseline = ledger.noteOffloaded(key)
            // What left, so a copy coming back can be told from another one.
            ledger.offloadedDigest[key] = verified.digest
            // Its quarantine goes into the same save as the note, before the
            // file does: the mark is the one thing a download cannot bring
            // back by itself.
            if let mark = quarantineMark(of: verified.file) {
                ledger.quarantine[key] = mark
            }
            try ledger.save(in: workspaceURL)
            do {
                try unlink(verified, libraryRootURL: libraryRootURL, fileManager: fileManager)
                offloaded.append(verified.relativePath)
            } catch {
                // Judged by whether the file is still here, not by the error:
                // the unlink comes before pruning the shared object, so a
                // pruning failure throws over a source that has gone — and
                // forgetting the act then would leave an absent member
                // unwithheld, which the plan reads as a download.
                if LampWorkspaceSync.isHere(
                    verified.relativePath, inContextOf: workspaceURL, fileManager: fileManager
                ) {
                    ledger.forgetAct(key, restoring: baseline)
                    // A request the reader made survives a failed unlink,
                    // put back here, before anything else can run, rather
                    // than by the caller afterwards — when Keep Here may
                    // since have been pressed and would be undone.
                    if onlyWhileRequested { ledger.noteLeaving(key, file: place) }
                    try? ledger.save(in: workspaceURL)
                    skipped[verified.relativePath] =
                        error is UnlinkRefusal ? .changedSinceUpload : .couldNotRemove
                } else {
                    offloaded.append(verified.relativePath)
                }
            }
        }
        return (offloaded, skipped, read)
    }

    /// How much one run of offloads reads back from the server, shared by
    /// everything it offloads.
    public static let readBackPerRun: Int64 = 1 << 30

    private enum ServerCopy { case matches, differs, unreadable }

    /// Reads the server's copy of `path` into a scratch file and compares its
    /// digest. Not on this actor's time: nothing here touches a workspace.
    private nonisolated static func serverCopy(
        of path: String, from server: OffloadServer, matches digest: String, size: Int64,
        fileManager: FileManager
    ) async -> ServerCopy {
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-offload-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            let copy = scratch.appendingPathComponent("copy")
            guard try await server.fetch(path, size + 1, copy) else { return .differs }
            return try LampSyncContentRevision.digest(forFileAt: copy) == digest ? .matches : .differs
        } catch {
            return .unreadable
        }
    }

    /// A file's quarantine marker, or nil where it has none.
    private static func quarantineMark(of file: URL) -> String? {
        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(file.path, "com.apple.quarantine", &value, size, 0, XATTR_NOFOLLOW) == size
        else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    private struct UnlinkRefusal: Error {}

    /// Unlinks a verified source, then prunes the shared object if nothing
    /// else links to it.
    ///
    /// Takes only a `VerifiedSource`. The ordinary removal hashes a path and
    /// then deletes whatever is at it, which put a second read — of a source
    /// that may be 90 MB — after the check that said deleting was safe.
    /// Here the path is asked, without following a link, whether it is still
    /// the file that was read — the whole identity, change time included —
    /// and is unlinked straight after; `unlink(2)` will not remove a folder,
    /// whatever has been put there.
    ///
    /// The change time is what notices a file rewritten at the same size
    /// with its date put back (`decisions/0007`), and nothing else does.
    /// It also moves when a hard-linked twin of the source is unlinked, so
    /// a workspace holding the same file twice offloads one copy now and
    /// the other on the next sweep, read afresh. That costs a pass; ignoring
    /// the change time cost the guard `0007` exists for.
    ///
    /// What is left is the gap between that question and the unlink: no I/O,
    /// microseconds, and only another process of the same user in the
    /// workspace can use it — the bound `decisions/0010` already accepts.
    /// macOS cannot unlink by descriptor, so it is accepted rather than
    /// closed (`decisions/0021`).
    @WritingWorkspaceFiles
    static func unlink(
        _ verified: VerifiedSource,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard verified.isStillInside,
              let now = try? LampFileIdentity(regularFileAt: verified.file),
              now == verified.read.identity
        else { throw UnlinkRefusal() }
        let result = verified.file.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.unlink($0) } ?? -1
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try pruneObjects(
            withDigests: [verified.digest], libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
    }

    public enum OffloadError: LocalizedError, Equatable {
        case notOnTheServer(String)
        case notAsource(String)
        case changedSinceUpload(String)
        case untrustedVolume(String)
        case waitsForDownload(String)
        case serverCopyDiffers(String)
        case couldNotReadTheServer(String)
        case wouldLoseWhatNoStoreKeeps(String)

        public var errorDescription: String? {
            switch self {
            case .notOnTheServer(let name):
                "“\(name)” has not finished syncing yet, so keeping it here is the only copy."
            case .notAsource(let name):
                "“\(name)” is not a file this writing holds as a source."
            case .changedSinceUpload(let name):
                "“\(name)” has changed since it was synced, so it goes up on the next sync first."
            case .wouldLoseWhatNoStoreKeeps(let name):
                "“\(name)” has Finder tags or a resource fork, which the server can't keep, so Lamp keeps it here."
            case .waitsForDownload(let name):
                "“\(name)” holds sources that are only on the server. Download them first, then remove it."
            case .serverCopyDiffers(let name):
                "The server's copy of “\(name)” is not the one on this Mac, so Lamp keeps it here."
            case .couldNotReadTheServer(let name):
                "Lamp couldn't read the server's copy of “\(name)” to check it, so it stays on this Mac."
            case .untrustedVolume(let name):
                "“\(name)” is on a disk that can't reliably tell whether a file has changed, so Lamp keeps it here rather than risk deleting edits the server doesn't have."
            }
        }
    }

    /// Carries out a source deletion another device made: removes the file,
    /// prunes its shared object, and clears any note that this Mac had
    /// offloaded it.
    ///
    /// Tolerant of the file being absent. This Mac may have offloaded the
    /// source, or never fetched it — there is then nothing to remove, and
    /// the only thing that matters is that the offload note goes, or the
    /// gather would withhold a member that no longer exists.
    @WritingWorkspaceFiles
    public static func removeDeletedSource(
        relativePath: String,
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let key = WorkspaceFileLedger.contextKey(relativePath)
        // Forgotten, not asked for. Another device deleting a source is not
        // this reader wanting it back, and an ask would leave the pane
        // showing "Coming back" for something that is never coming. A ledger
        // that will not read is left alone, and the file still goes.
        if var ledger = WorkspaceFileLedger.loadIfReadable(in: workspaceURL) {
            ledger.forgetAct(key)
            try ledger.save(in: workspaceURL)
        }

        let contextDirectory = try validatedContextDirectory(
            in: workspaceURL, libraryRootURL: libraryRootURL, fileManager: fileManager
        )
        let file = contextDirectory.appendingPathComponent(relativePath)
        // A regular file, and only that. A tombstone names one source; if a
        // folder has since been put at that path, removing it would take
        // everything inside — and `removeSyncedContextFile` removes
        // recursively. A link is refused for `decisions/0010`'s reason.
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().path
                .hasPrefix(contextDirectory.resolvingSymlinksInPath().path + "/")
        else { return }
        try removeSyncedContextFile(
            at: file, libraryRootURL: libraryRootURL, fileManager: fileManager
        )
    }

    static func removeSyncedContextFile(
        at fileURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let digests = try regularFileDigests(including: fileURL, fileManager: fileManager)
        try fileManager.removeItem(at: fileURL)
        try pruneObjects(withDigests: digests, libraryRootURL: libraryRootURL, fileManager: fileManager)
    }

    /// Replaces standalone context files (for example, files restored from sync)
    /// with links to the library-wide content-addressed object store.
    @WritingWorkspaceFiles
    public static func consolidate(
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let contextDirectory = try validatedContextDirectory(
            in: workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: contextDirectory.path),
              let enumerator = fileManager.enumerator(
                at: contextDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
              ) else { return }

        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let digest = try contentDigest(of: file)
            try materialize(
                file,
                withDigest: digest,
                at: file,
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
        }
    }

    private static func validatedContextDirectory(
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let devotionalRoot = LampWritingWorkspace.root(
            libraryRootURL: libraryRootURL.standardizedFileURL, fileManager: fileManager
        ).standardizedFileURL
        let workspace = workspaceURL.standardizedFileURL
        guard workspace.deletingLastPathComponent() == devotionalRoot,
              !workspace.lastPathComponent.isEmpty,
              workspace.lastPathComponent != ".",
              workspace.lastPathComponent != ".." else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Context can only be stored in a Lamp devotional workspace.",
            ])
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory) {
            let values = try workspace.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw unsafeContextItemError()
            }
        } else {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        let context = workspace.appendingPathComponent(contextDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: context.path, isDirectory: &isDirectory) {
            let values = try context.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw unsafeContextItemError()
            }
        } else {
            try fileManager.createDirectory(at: context, withIntermediateDirectories: false)
        }
        return context.standardizedFileURL
    }

    /// Copies one level of a chosen folder. A folder picked from Finder routinely
    /// holds entries that must not become context — symbolic links, aliases,
    /// cloud placeholders, unreadable files — and dropping the whole folder over
    /// one of them is worse than adding the rest and saying what was left out.
    private static func addDirectoryContents(
        from source: URL,
        to destination: URL,
        relativePath: String,
        libraryRootURL: URL,
        fileManager: FileManager,
        reportingSkipped: (String) -> Void
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: []
        )
        for child in children {
            let childPath = relativePath.isEmpty
                ? child.lastPathComponent
                : relativePath + "/" + child.lastPathComponent
            guard let values = try? child.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]), values.isSymbolicLink != true else {
                reportingSkipped(childPath)
                continue
            }
            let childDestination = destination.appendingPathComponent(child.lastPathComponent)
            do {
                if values.isDirectory == true {
                    try fileManager.createDirectory(
                        at: childDestination,
                        withIntermediateDirectories: false
                    )
                    try addDirectoryContents(
                        from: child,
                        to: childDestination,
                        relativePath: childPath,
                        libraryRootURL: libraryRootURL,
                        fileManager: fileManager,
                        reportingSkipped: reportingSkipped
                    )
                } else if values.isRegularFile == true {
                    try materialize(
                        child,
                        withDigest: contentDigest(of: child),
                        at: childDestination,
                        libraryRootURL: libraryRootURL,
                        fileManager: fileManager
                    )
                } else {
                    reportingSkipped(childPath)
                }
            } catch {
                // An unreadable or unsupported entry loses only itself.
                try? fileManager.removeItem(at: childDestination)
                reportingSkipped(childPath)
            }
        }
    }

    private static func materialize(
        _ source: URL,
        withDigest digest: String,
        at destination: URL,
        libraryRootURL: URL,
        fileManager: FileManager
    ) throws {
        let object = try ensureObject(
            for: source,
            digest: digest,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        if source.standardizedFileURL == destination.standardizedFileURL,
           try isSameFile(source, object, fileManager: fileManager) {
            return
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".lamp-context-\(UUID().uuidString)")
        do {
            try fileManager.linkItem(at: object, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if source.standardizedFileURL != destination.standardizedFileURL,
               !fileManager.fileExists(atPath: destination.path) {
                // A different filesystem may not support hard links. Keep the
                // context usable, even though this individual path cannot share storage.
                try fileManager.copyItem(at: object, to: destination)
                try makeReadOnly(destination, fileManager: fileManager)
            } else if source.standardizedFileURL == destination.standardizedFileURL {
                // Consolidation is best-effort when a filesystem cannot hard-link.
                return
            } else {
                throw error
            }
        }
    }

    private static func ensureObject(
        for source: URL,
        digest: String,
        libraryRootURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let directory = objectDirectory(in: libraryRootURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = directory.appendingPathComponent(digest)
        if fileManager.fileExists(atPath: object.path) {
            guard try contentDigest(of: object) == digest else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "A shared context object failed its integrity check.",
                ])
            }
            try makeReadOnly(object, fileManager: fileManager)
            return object
        }

        let temporary = directory.appendingPathComponent(".\(digest)-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            guard try contentDigest(of: temporary) == digest else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try makeReadOnly(temporary, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: temporary, to: object)
            } catch where fileManager.fileExists(atPath: object.path) {
                try? fileManager.removeItem(at: temporary)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return object
    }

    private static func topLevelFile(
        withDigest digest: String,
        in contextDirectory: URL,
        fileManager: FileManager
    ) throws -> URL? {
        for candidate in try fileManager.contentsOfDirectory(
            at: contextDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) {
            let values = try candidate.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isRegularFile == true,
               values.isSymbolicLink != true,
               try contentDigest(of: candidate) == digest {
                return candidate
            }
        }
        return nil
    }

    private static func regularFileDigests(
        including item: URL,
        fileManager: FileManager
    ) throws -> Set<String> {
        let values = try item.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else { return [] }
        if values.isRegularFile == true { return [try contentDigest(of: item)] }
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: item,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ) else { return [] }
        var digests: Set<String> = []
        for case let file as URL in enumerator {
            let childValues = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if childValues.isSymbolicLink == true {
                enumerator.skipDescendants()
            } else if childValues.isRegularFile == true {
                digests.insert(try contentDigest(of: file))
            }
        }
        return digests
    }

    private static func pruneObjects(
        withDigests digests: Set<String>,
        libraryRootURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = objectDirectory(in: libraryRootURL)
        for digest in digests {
            let object = directory.appendingPathComponent(digest)
            guard fileManager.fileExists(atPath: object.path) else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: object.path)
            let referenceCount = (attributes[.referenceCount] as? NSNumber)?.intValue ?? 2
            if referenceCount <= 1 {
                try fileManager.removeItem(at: object)
            }
        }
    }

    private static func objectDirectory(in libraryRootURL: URL) -> URL {
        libraryRootURL.standardizedFileURL
            .appendingPathComponent(agentWorkspacesDirectory, isDirectory: true)
            .appendingPathComponent(objectDirectoryName, isDirectory: true)
    }

    private static func contentDigest(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSameFile(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let left = try fileManager.attributesOfItem(atPath: lhs.path)
        let right = try fileManager.attributesOfItem(atPath: rhs.path)
        return (left[.systemNumber] as? NSNumber) == (right[.systemNumber] as? NSNumber)
            && (left[.systemFileNumber] as? NSNumber) == (right[.systemFileNumber] as? NSNumber)
    }

    private static func makeReadOnly(_ file: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    }

    private static func availableDestination(
        named name: String,
        in directory: URL,
        reserving reserved: Set<String> = [],
        fileManager: FileManager
    ) -> URL {
        func isTaken(_ candidate: URL) -> Bool {
            fileManager.fileExists(atPath: candidate.path)
                || reserved.contains(
                    candidate.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                )
        }
        let proposed = directory.appendingPathComponent(name)
        guard isTaken(proposed) else { return proposed }
        let source = URL(fileURLWithPath: name)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !isTaken(candidate) { return candidate }
            index += 1
        }
    }

    private static func isContained(_ item: URL, in directory: URL) -> Bool {
        item == directory || item.path.hasPrefix(directory.path + "/")
    }

    private static func unsafeContextItemError() -> CocoaError {
        CocoaError(.fileWriteNoPermission, userInfo: [
            NSLocalizedDescriptionKey: "Context items must be regular files or directories without symbolic links.",
        ])
    }
}
