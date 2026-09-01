import CryptoKit
import Foundation

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
}

/// Stores workspace context as content-addressed, read-only files. Every unique
/// byte sequence is kept once per Lamp library; workspace paths are hard links
/// to that shared object so filenames and directory layout remain user-facing.
public enum WorkspaceContextFileStore {
    private static let agentWorkspacesDirectory = "AgentWorkspaces"
    private static let devotionalWorkspacesDirectory = "Devotionals"
    private static let contextDirectoryName = "context"
    private static let objectDirectoryName = ".ContextObjects"

    /// Adds a file or directory to a workspace's context. An identical top-level
    /// file already in that workspace is reused instead of adding another alias.
    @discardableResult
    public static func addContextItem(
        from sourceURL: URL,
        to workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
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
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Removes a direct child of a workspace's context and prunes shared objects
    /// after their final workspace link disappears.
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

        let digests = try regularFileDigests(including: item, fileManager: fileManager)
        try fileManager.removeItem(at: item)
        try pruneObjects(
            withDigests: digests,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
    }

    /// Replaces standalone context files (for example, files restored from sync)
    /// with links to the library-wide content-addressed object store.
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
        let devotionalRoot = libraryRootURL.standardizedFileURL
            .appendingPathComponent(agentWorkspacesDirectory, isDirectory: true)
            .appendingPathComponent(devotionalWorkspacesDirectory, isDirectory: true)
            .standardizedFileURL
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

    private static func addDirectoryContents(
        from source: URL,
        to destination: URL,
        libraryRootURL: URL,
        fileManager: FileManager
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: []
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else { throw unsafeContextItemError() }
            let childDestination = destination.appendingPathComponent(child.lastPathComponent)
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: childDestination,
                    withIntermediateDirectories: false
                )
                try addDirectoryContents(
                    from: child,
                    to: childDestination,
                    libraryRootURL: libraryRootURL,
                    fileManager: fileManager
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
                throw unsafeContextItemError()
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
