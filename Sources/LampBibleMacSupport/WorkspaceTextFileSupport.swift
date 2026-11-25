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
        // leave every file inside it on the other Mac.
        // Including the sources under here that are *not* on disk: the walk
        // above enumerates files, and an offloaded one has none. Removing a
        // folder has to take its offloaded descendants too, or they stay on
        // the server for ever with nothing left here to name them
        // (`decisions/0019`).
        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        let relative = item.standardizedFileURL.path
            .dropFirst(contextDirectory.standardizedFileURL.path.count + 1)
        let offloadedDescendants = ledger.offloadedContextPaths()
            .filter { $0 == relative || $0.hasPrefix(relative + "/") }
            .map(WorkspaceFileLedger.contextKey)
        let allKeys = Set(keys).union(offloadedDescendants)
        guard !allKeys.isEmpty else { return }
        for key in allKeys { ledger.recordDeletion(of: key) }
        try ledger.save(in: workspaceURL)

        // And queued for the *server*, which is new: until a source became a
        // deletable kind its removal travelled only inside the workspace
        // tree, so every device dropped its copy and the store kept the bytes
        // for ever. This is what lets the store shrink
        // (`lamp-bible-core/Documentation/decisions/0019`).
        let folder = workspaceURL.lastPathComponent
        let members = allKeys.compactMap { key -> String? in
            let relative = String(key.dropFirst(WorkspaceFileLedger.contextKey("").count))
            return try? LampWritingWorkspaceLayout.contextPath(
                folder: folder, relativePath: relative
            )
        }
        guard !members.isEmpty else { return }
        var removed = LampSyncRemovedModules.load(
            fromLibraryAt: libraryRootURL, fileManager: fileManager
        )
        let now = WorkspaceFileLedger.milliseconds(Date())
        for member in members { removed.record(member, at: now) }
        try removed.save(toLibraryAt: libraryRootURL, fileManager: fileManager)
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
    /// The pane's own control. It runs the same checks as the unattended
    /// sweep, through the same function — including the look at the server.
    ///
    /// A press has no pass behind it, so it takes the last pass's listing and
    /// the server that listing came from. Without one it refuses: trusting
    /// the record alone would delete the last copy of a source somebody
    /// removed from the sync folder by hand, and the record would be just as
    /// confident (`decisions/0021`). A reader standing there watching is not
    /// a substitute for knowing.
    @WritingWorkspaceFiles
    public static func offloadSource(
        relativePath: String,
        in workspaceURL: URL,
        libraryRootURL: URL,
        source: String,
        seen: [String: String],
        fileManager: FileManager = .default
    ) async throws {
        guard (try? LampWritingWorkspaceLayout.contextPath(
            folder: workspaceURL.lastPathComponent, relativePath: relativePath
        )) != nil else { throw OffloadError.notAsource(relativePath) }
        let result = try await offloadSources(
            [relativePath], in: workspaceURL, libraryRootURL: libraryRootURL,
            source: source, seen: seen, fileManager: fileManager
        )
        guard result.offloaded.isEmpty else { return }
        switch result.skipped[relativePath] {
        case .changedSinceUpload: throw OffloadError.changedSinceUpload(relativePath)
        case .notOnTheServer, .notSeenOnTheServer:
            throw OffloadError.notOnTheServer(relativePath)
        default: throw OffloadError.notAsource(relativePath)
        }
    }

    /// Removes a source this Mac may not be holding.
    ///
    /// `removeContextItem` is the act for a file on disk, and it requires
    /// one: it returns early when nothing is there, and it takes only an
    /// entry directly under the context directory. An offloaded row is
    /// neither — no local bytes, and possibly a nested path — so Remove on it
    /// did nothing at all, silently.
    ///
    /// The deletion still has to be written down and queued for the server,
    /// because that is what makes it a deletion rather than an absence
    /// (`decisions/0018`, `0019`).
    @WritingWorkspaceFiles
    public static func removeOffloadedSource(
        relativePath: String,
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let folder = workspaceURL.lastPathComponent
        guard let member = try? LampWritingWorkspaceLayout.contextPath(
            folder: folder, relativePath: relativePath
        ) else { throw OffloadError.notAsource(relativePath) }
        let key = WorkspaceFileLedger.contextKey(relativePath)

        // `recordDeletion` clears the offload note itself: a path being
        // tombstoned must not also be one the gather withholds, or the pane
        // would keep offering Download for something the server is being told
        // to drop.
        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        ledger.recordDeletion(of: key)
        try ledger.save(in: workspaceURL)

        var removed = LampSyncRemovedModules.load(
            fromLibraryAt: libraryRootURL, fileManager: fileManager
        )
        removed.record(member, at: WorkspaceFileLedger.milliseconds(Date()))
        try removed.save(toLibraryAt: libraryRootURL, fileManager: fileManager)

        // Tolerant of a copy being here after all: the reader may have
        // fetched it back between the list being drawn and the button being
        // pressed, and the deletion means the same thing either way.
        //
        // Only ever a regular file, and only one inside this workspace's
        // context directory. `removeSyncedContextFile` deletes recursively,
        // so without this a folder that had taken the place of an offloaded
        // file — the shallow listing still offers the old row — would be
        // erased whole, with everything unrelated inside it.
        guard let contextDirectory = try? validatedContextDirectory(
            in: workspaceURL, libraryRootURL: libraryRootURL, fileManager: fileManager
        ) else { return }
        let file = contextDirectory.appendingPathComponent(relativePath)
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().path
                .hasPrefix(contextDirectory.resolvingSymlinksInPath().path + "/")
        else { return }
        try? removeSyncedContextFile(
            at: file, libraryRootURL: libraryRootURL, fileManager: fileManager
        )
    }

    /// Asks for an offloaded source back. The next pass fetches it.
    @WritingWorkspaceFiles
    public static func fetchSource(
        relativePath: String,
        in workspaceURL: URL
    ) throws {
        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        // The ask is recorded, and outlives the attempt: a pass that cannot
        // reach the server leaves the row saying "Coming back" with something
        // to press again, rather than no row at all.
        ledger.clearOffload(of: WorkspaceFileLedger.contextKey(relativePath))
        try ledger.save(in: workspaceURL)
    }

    /// Why one source was left where it was.
    public enum Skipped: String, Sendable {
        /// No confirmed revision for this source — the server has not taken it.
        case notOnTheServer
        /// The pass's own listing of the folder did not show this source at
        /// the revision recorded for it. A record is a memory of an upload;
        /// the listing is what the server says now.
        case notSeenOnTheServer
        /// The bytes here are not the bytes that were uploaded. The next pass
        /// takes the new ones up, and the sweep after that may offload it.
        case changedSinceUpload
        /// Not a regular file under this workspace's context directory.
        case notAsource
        /// The file would not go. Nothing is recorded, so it is offered again.
        case couldNotRemove
        /// Somebody opened the writing while the batch was working.
        case nowHeld
    }

    /// Puts a batch of sources back on the server in one go.
    ///
    /// For the unattended sweep. The pane's single-file `offloadSource` keeps
    /// its own path; this one loads the records once for the whole batch and
    /// saves the ledger once, and it is stricter in two ways the sweep needs:
    ///
    /// - it checks the **current** source only. `mayOffload` accepts a
    ///   confirmed revision from any source this Mac has ever synced with, so
    ///   after a change of server it would offload a file the new one never
    ///   took.
    /// - it checks the bytes on disk are the bytes that went up. A confirmed
    ///   revision says an upload completed, not that nothing has happened
    ///   since. Sources are read-only hard links and nothing here writes one
    ///   in place, so this should never fire — but the sweep runs with nobody
    ///   watching, and the check costs one hash of a file that is about to be
    ///   deleted anyway.
    ///
    /// Each offload is noted before any file goes, keeping `decisions/0020`'s
    /// order for the batch as a whole: a crash part way leaves sources marked
    /// offloaded that are still here, which costs nothing, rather than files
    /// gone and unrecorded, which the gather would read as never-seen.
    @discardableResult
    @WritingWorkspaceFiles
    public static func offloadSources(
        _ relativePaths: [String],
        in workspaceURL: URL,
        libraryRootURL: URL,
        source: String,
        seen: [String: String]?,
        fileManager: FileManager = .default,
        while shouldContinue: (@Sendable () async -> Bool)? = nil
    ) async throws -> (offloaded: [String], skipped: [String: Skipped]) {
        guard !relativePaths.isEmpty else { return ([], [:]) }
        let contextDirectory = try validatedContextDirectory(
            in: workspaceURL, libraryRootURL: libraryRootURL, fileManager: fileManager
        )
        let folder = workspaceURL.lastPathComponent
        let records = LampSyncFileRecords.load(
            fromLibraryAt: libraryRootURL, fileManager: fileManager
        )
        let root = contextDirectory.resolvingSymlinksInPath().path + "/"

        var ready: [(relativePath: String, file: URL, identity: LampFileIdentity)] = []
        var skipped: [String: Skipped] = [:]
        for relativePath in relativePaths {
            guard let path = try? LampWritingWorkspaceLayout.contextPath(
                folder: folder, relativePath: relativePath
            ) else { skipped[relativePath] = .notAsource; continue }
            guard let installed = records.record(path, in: source)?.installedRevision else {
                skipped[relativePath] = .notOnTheServer
                continue
            }
            if let seen {
                // The pass lists each context folder on its way past
                // (`revisionsOfUnlistedMembers`), and that listing is the only
                // thing here that has seen the server. A record keeps
                // `installedRevision` for ever: nothing refreshes it, and a
                // source deleted from the folder by hand leaves an unchanged
                // local copy that the plan answers `.none` for. Offloading on
                // the record alone would then delete the last copy.
                guard let listed = seen[path],
                      LampSyncConditionalWrite.namesSameRevision(listed, installed)
                else { skipped[relativePath] = .notSeenOnTheServer; continue }
            }
            let file = contextDirectory.appendingPathComponent(relativePath)
            guard let values = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ]), values.isRegularFile == true, values.isSymbolicLink != true,
                  file.resolvingSymlinksInPath().path.hasPrefix(root)
            else { skipped[relativePath] = .notAsource; continue }
            // Taken either side of the read, so the identity carried forward
            // is the identity of the bytes that were hashed. Stat, hash,
            // stat: anything that replaced the file during the read changes
            // the second one, and the pair would otherwise bind this file's
            // verified digest to a replacement's identity — which the check
            // before the unlink would then wave through.
            guard let before = try? LampFileIdentity(url: file),
                  let digest = try? LampSyncContentRevision.digest(forFileAt: file),
                  let identity = try? LampFileIdentity(url: file),
                  Self.namesSameBytes(before, identity)
            else {
                skipped[relativePath] = .changedSinceUpload
                continue
            }
            guard !records.changedSinceUpload(path, in: source, digest: digest) else {
                skipped[relativePath] = .changedSinceUpload
                continue
            }
            ready.append((relativePath, file, identity))
        }
        guard !ready.isEmpty else { return ([], skipped) }

        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        for candidate in ready {
            ledger.recordOffload(of: WorkspaceFileLedger.contextKey(candidate.relativePath))
        }
        try ledger.save(in: workspaceURL)

        var offloaded: [String] = []
        var stubborn: [String] = []
        for candidate in ready {
            // Asked before each file, not once before the batch: hashing a
            // workspace's sources takes long enough for a reader to open the
            // writing in the middle of it, and the sources would then go from
            // under an open editor.
            if let shouldContinue, await !shouldContinue() {
                skipped[candidate.relativePath] = .nowHeld
                stubborn.append(candidate.relativePath)
                continue
            }
            // The file this batch verified, not merely the path it was at.
            // Every candidate is hashed before any is deleted, so a large
            // batch leaves a window in which Finder, a restore, or an agent
            // running in this very workspace can put different bytes at an
            // already-checked path — and those bytes were never on the
            // server.
            guard let now = try? LampFileIdentity(url: candidate.file),
                  Self.namesSameBytes(now, candidate.identity)
            else {
                skipped[candidate.relativePath] = .changedSinceUpload
                stubborn.append(candidate.relativePath)
                continue
            }
            do {
                try removeSyncedContextFile(
                    at: candidate.file, libraryRootURL: libraryRootURL,
                    fileManager: fileManager
                )
                offloaded.append(candidate.relativePath)
            } catch {
                // Reported rather than thrown: one stubborn file must not cost
                // the rest of the batch.
                //
                // Judged by whether the file is still here, not by the error.
                // `removeSyncedContextFile` unlinks first and prunes the
                // shared object after, so a pruning failure throws over a
                // source that has already gone — and clearing its note then
                // would leave an absent member unwithheld, which the plan
                // reads as a download. The offload succeeded; only the tidying
                // did not.
                if fileManager.fileExists(atPath: candidate.file.path) {
                    stubborn.append(candidate.relativePath)
                    skipped[candidate.relativePath] = .couldNotRemove
                } else {
                    offloaded.append(candidate.relativePath)
                }
            }
        }

        // A note left on a file that is still here would be a lie in the one
        // direction that shows: the gather would withhold a member this Mac
        // holds, and the pane would offer Download for a file already on disk.
        if !stubborn.isEmpty {
            var corrected = WorkspaceFileLedger.load(in: workspaceURL)
            for relativePath in stubborn {
                corrected.forgetOffload(of: WorkspaceFileLedger.contextKey(relativePath))
            }
            try? corrected.save(in: workspaceURL)
        }
        return (offloaded, skipped)
    }

    /// Whether two `stat`s of a path name the same bytes.
    ///
    /// Everything but the **change** time. A source is a hard link into the
    /// library's object store, so a workspace holding the same file twice
    /// holds two links to one inode — and unlinking either moves that inode's
    /// `ctime`, which would make the sibling look replaced and leave the
    /// shared bytes on disk for ever. Replacement still shows: a new file has
    /// a new inode, and a write in place moves the modification time.
    static func namesSameBytes(_ lhs: LampFileIdentity, _ rhs: LampFileIdentity) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modifiedSeconds == rhs.modifiedSeconds
            && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds
    }

    public enum OffloadError: LocalizedError, Equatable {
        case notOnTheServer(String)
        case notAsource(String)
        case changedSinceUpload(String)

        public var errorDescription: String? {
            switch self {
            case .notOnTheServer(let name):
                "“\(name)” has not finished syncing yet, so keeping it here is the only copy."
            case .notAsource(let name):
                "“\(name)” is not a file this writing holds as a source."
            case .changedSinceUpload(let name):
                "“\(name)” has changed since it was synced, so it goes up on the next sync first."
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
        var ledger = WorkspaceFileLedger.load(in: workspaceURL)
        let key = WorkspaceFileLedger.contextKey(relativePath)
        // Forgotten, not asked for. Another device deleting a source is not
        // this reader wanting it back, and an ask would leave the pane
        // showing "Coming back" for something that is never coming.
        ledger.forgetOffload(of: key)
        try ledger.save(in: workspaceURL)

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
        fileManager: FileManager
    ) -> URL {
        let proposed = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let source = URL(fileURLWithPath: name)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
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
