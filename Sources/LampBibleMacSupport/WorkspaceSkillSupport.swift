import CryptoKit
import Foundation

public struct WorkspaceSkillDefinition: Equatable, Identifiable, Sendable {
    public let name: String
    public let description: String
    public let instructions: String
    public let directoryURL: URL

    public init(name: String, description: String, instructions: String, directoryURL: URL) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.directoryURL = directoryURL
    }

    public var id: String { name }
}

public struct WorkspaceSkillSelection: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let names: [String]

    public init(names: some Sequence<String>) {
        formatVersion = 1
        self.names = Array(Set(names)).sorted()
    }
}

/// Owns the library-wide custom-skill catalog and materializes each workspace's
/// selected skills into the provider-specific directories expected by agents.
public enum WorkspaceSkillStore {
    public static let selectionFilename = "enabled-skills.json"

    private static let catalogDirectoryName = "AgentSkills"

    /// The skills that ship with Lamp, by the folder name each has under
    /// `Resources/AgentSkills`, and what each one asks of the surface it is
    /// installed on.
    ///
    /// Written down once because five different rules read it — a built-in is
    /// kept out of the custom catalog, refused by every editing path, left out
    /// of the sync export, installed into a writing's workspace, and installed
    /// into a reader chat — and a skill added to the resources but not here
    /// becomes editable and syncable, which is how a reader's copy silently
    /// diverges from the one their build ships.
    ///
    /// `writesFiles` keeps a skill out of a read-only surface. A reader chat
    /// cannot write anything, and a skill whose steps end in a file is worse
    /// there than no skill at all: the agent follows it and fails at the last
    /// step, having spent the reader's time.
    ///
    /// `installsInWorkspace` is a separate question, because writing a file is
    /// not the same as belonging to a writing. `import-lamp-writing` builds its
    /// bundle outside the library and brings in writings that do not exist yet,
    /// so no one writing's workspace is its home — it was installed into every
    /// one of them, which is the last place anybody would look for it. It is
    /// read from the bundled catalog instead, wherever `read_skill` is offered
    /// alongside the import tools.
    public static let bundledSkills: [
        (name: String, writesFiles: Bool, installsInWorkspace: Bool)
    ] = [
        ("build-lamp-deck", true, true),
        ("import-lamp-writing", true, false),
        ("original-languages", false, true),
        ("sola-scriptura", false, true),
    ]

    public static var bundledSkillNames: Set<String> { Set(bundledSkills.map(\.name)) }

    /// The bundled skills a writing's own workspace carries.
    public static var workspaceBundledSkillNames: Set<String> {
        Set(bundledSkills.lazy.filter(\.installsInWorkspace).map(\.name))
    }

    /// The bundled skills a read-only surface can carry out in full.
    public static var readOnlyBundledSkillNames: Set<String> {
        Set(bundledSkills.lazy.filter { !$0.writesFiles }.map(\.name))
    }

    private static var builtInSkillNames: Set<String> { bundledSkillNames }

    /// Brings a workspace's copy of each named bundled skill up to the one this
    /// build ships, into every provider directory, and takes out the bundled
    /// skills this surface is not given. Returns what it wrote.
    ///
    /// Replacing rather than only installing when absent: a workspace used to
    /// keep whatever it was given on the day it was created, so an agent months
    /// later was reading instructions for an older renderer with no way to tell.
    /// These skills are Lamp's to own, so replacing one loses nothing of the
    /// reader's. A skill already identical is left alone, since copying it
    /// would change its modification date for nothing.
    @discardableResult
    /// Outside `WritingWorkspaceFiles`, deliberately: this installs bundled
    /// skills into whatever skills directories it is given, and the reader's
    /// chat workspaces — which are not a writing's — are its other caller.
    /// The writing-workspace paths that reach it (`migrateWorkspaceSkills`,
    /// `synchronizeWorkspace`) are on the owner themselves, so the work is
    /// serialised where it touches a writing.
    public static func installBundledSkills(
        named names: Set<String>,
        from catalog: URL?,
        intoSkillDirectoriesOf workspace: URL,
        fileManager: FileManager = .default
    ) throws -> [String] {
        guard let catalog else { return [] }
        // `names` is the whole set this surface is to have, so a bundled skill
        // left out of it is taken away rather than left behind. Without this a
        // skill dropped from a surface — `import-lamp-writing`, when it stopped
        // belonging to one writing's workspace — would sit in every workspace
        // that ever had it, frozen at the build that put it there, and be
        // preferred by `read_skill` over the bundle it was moved to. Only
        // bundled names are removed: a custom skill cannot carry one.
        for name in bundledSkillNames.subtracting(names).sorted() {
            for root in [codexSkillsDirectory(in: workspace), claudeSkillsDirectory(in: workspace)] {
                // Confined the same way the custom-skill sweep is: a provider
                // directory that is a link leads the delete out of the
                // workspace, and this one runs on a reader chat's folder too.
                guard isSafeDirectory(root, fileManager: fileManager) else { continue }
                let stale = root.appendingPathComponent(name, isDirectory: true)
                guard isSafeDirectory(stale, fileManager: fileManager) else { continue }
                try fileManager.removeItem(at: stale)
            }
        }
        var installed: [String] = []
        for name in names.sorted() {
            let source = catalog.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            var wrote = false
            for root in [codexSkillsDirectory(in: workspace), claudeSkillsDirectory(in: workspace)] {
                let destination = root.appendingPathComponent(name, isDirectory: true)
                if fileManager.fileExists(atPath: destination.path) {
                    guard try treeDigest(of: source, fileManager: fileManager)
                        != treeDigest(of: destination, fileManager: fileManager) else { continue }
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                wrote = true
            }
            if wrote { installed.append(name) }
        }
        return installed
    }

    /// Identifies a skill folder by its relative paths and the contents of each
    /// file, so a changed reference file counts as a change even though
    /// `SKILL.md` did not move. Modification dates are no use here: copying
    /// sets its own.
    ///
    /// Each file is hashed rather than measured. Keyed on byte counts, as this
    /// was until 2026-11-04, an edit that happened to preserve a file's length
    /// — a corrected word, a reworded line, a typo — was no change at all, and
    /// the workspace went on serving an agent the copy it already had while the
    /// install reported that nothing needed doing.
    static func treeDigest(of directory: URL, fileManager: FileManager = .default) throws -> String {
        let root = directory.standardizedFileURL.path
        var entries: [String] = []
        let files = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = files?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            entries.append("\(relative):\(hexDigest(of: try Data(contentsOf: url)))")
        }
        return hexDigest(of: Data(entries.sorted().joined(separator: "\n").utf8))
    }

    private static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func catalogDirectory(in libraryRootURL: URL) -> URL {
        libraryRootURL.standardizedFileURL
            .appendingPathComponent(catalogDirectoryName, isDirectory: true)
    }

    public static func selectionURL(in workspaceURL: URL) -> URL {
        workspaceURL.standardizedFileURL
            .appendingPathComponent(".lamp", isDirectory: true)
            .appendingPathComponent(selectionFilename)
    }

    public static func isValidSkillName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.range(
            of: "^[a-z0-9]+(?:-[a-z0-9]+)*$",
            options: .regularExpression
        ) != nil
    }

    @WritingWorkspaceFiles
    public static func catalogSkills(
        in libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> [WorkspaceSkillDefinition] {
        let root = catalogDirectory(in: libraryRootURL)
        guard isSafeDirectory(root, fileManager: fileManager) else { return [] }
        return try childSkillDirectories(in: root, fileManager: fileManager)
            .filter { !builtInSkillNames.contains($0.lastPathComponent) }
            .compactMap { directory in
                try definition(in: directory)
            }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @WritingWorkspaceFiles
    public static func enabledSkillNames(
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> Set<String> {
        _ = try validatedWorkspace(
            workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager,
            createIfNeeded: false
        )
        let manifest = selectionURL(in: workspaceURL)
        guard fileManager.fileExists(atPath: manifest.path) else { return [] }
        let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw unsafeSkillStorageError()
        }
        let selection = try JSONDecoder().decode(
            WorkspaceSkillSelection.self,
            from: Data(contentsOf: manifest)
        )
        guard selection.formatVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "The workspace skill selection uses an unsupported format.",
            ])
        }
        return Set(selection.names.filter(isValidSkillName))
    }

    /// Migrates custom skills from the former workspace-owned layout on first
    /// use. Conflicting definitions are retained under a unique skill name.
    @WritingWorkspaceFiles
    public static func migrateWorkspaceSkills(
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let workspace = try validatedWorkspace(
            workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager,
            createIfNeeded: true
        )
        let manifest = selectionURL(in: workspace)
        guard !fileManager.fileExists(atPath: manifest.path) else {
            try synchronizeWorkspace(
                workspace,
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
            return
        }

        var enabled: Set<String> = []
        let legacyRoot = codexSkillsDirectory(in: workspace)
        if isSafeDirectory(legacyRoot, fileManager: fileManager) {
            for source in try childSkillDirectories(in: legacyRoot, fileManager: fileManager)
            where !builtInSkillNames.contains(source.lastPathComponent) {
                let importedName = try importLegacySkill(
                    from: source,
                    libraryRootURL: libraryRootURL,
                    fileManager: fileManager
                )
                enabled.insert(importedName)
            }
        }
        try writeSelection(enabled, in: workspace, fileManager: fileManager)
        try synchronizeWorkspace(
            workspace,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
    }

    @WritingWorkspaceFiles
    public static func migrateAllWorkspaces(
        in libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = devotionalWorkspacesDirectory(in: libraryRootURL)
        guard isSafeDirectory(root, fileManager: fileManager) else { return }
        for workspace in try safeChildDirectories(in: root, fileManager: fileManager) {
            try migrateWorkspaceSkills(
                in: workspace,
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
        }
    }

    @discardableResult
    @WritingWorkspaceFiles
    public static func saveSkill(
        name: String,
        description: String,
        instructions: String,
        in libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> WorkspaceSkillDefinition {
        guard isValidSkillName(name) else { throw invalidSkillNameError() }
        guard !builtInSkillNames.contains(name) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Built-in skills can be viewed but not changed.",
            ])
        }
        let catalog = catalogDirectory(in: libraryRootURL)
        try ensureSafeDirectory(catalog, fileManager: fileManager)
        let directory = catalog.appendingPathComponent(name, isDirectory: true)
        try ensureSafeDirectory(directory, fileManager: fileManager)
        let document = skillDocument(
            name: name,
            description: description,
            instructions: instructions
        )
        try document.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try synchronizeAllEnabledWorkspaces(
            in: libraryRootURL,
            fileManager: fileManager
        )
        return try definition(in: directory) ?? WorkspaceSkillDefinition(
            name: name,
            description: description,
            instructions: instructions,
            directoryURL: directory
        )
    }

    @WritingWorkspaceFiles
    public static func enableSkill(
        named name: String,
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard isValidSkillName(name), !builtInSkillNames.contains(name) else {
            throw invalidSkillNameError()
        }
        let source = catalogDirectory(in: libraryRootURL)
            .appendingPathComponent(name, isDirectory: true)
        guard try definition(in: source) != nil else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The skill “\(name)” is not in this Lamp library.",
            ])
        }
        var enabled = try enabledSkillNames(
            in: workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        enabled.insert(name)
        try writeSelection(enabled, in: workspaceURL, fileManager: fileManager)
        try synchronizeWorkspace(
            workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
    }

    @WritingWorkspaceFiles
    public static func disableSkill(
        named name: String,
        in workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard isValidSkillName(name), !builtInSkillNames.contains(name) else { return }
        var enabled = try enabledSkillNames(
            in: workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        enabled.remove(name)
        try writeSelection(enabled, in: workspaceURL, fileManager: fileManager)
        try synchronizeWorkspace(
            workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
    }

    @WritingWorkspaceFiles
    public static func synchronizeWorkspace(
        _ workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let workspace = try validatedWorkspace(
            workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager,
            createIfNeeded: true
        )
        let enabled = try enabledSkillNames(
            in: workspace,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        let catalog = catalogDirectory(in: libraryRootURL)

        for providerRoot in [
            codexSkillsDirectory(in: workspace),
            claudeSkillsDirectory(in: workspace),
        ] {
            try ensureSafeDirectory(providerRoot, fileManager: fileManager)
            for installed in try safeChildDirectories(in: providerRoot, fileManager: fileManager) {
                let name = installed.lastPathComponent
                if builtInSkillNames.contains(name) {
                    // A built-in is not the reader's to enable or disable, so
                    // the rule below does not apply to it. One that no longer
                    // belongs in a writing's workspace is still taken out:
                    // `import-lamp-writing` left here by an older build would
                    // otherwise be read by an agent in place of the catalog's,
                    // for as long as this workspace is never prepared again.
                    if !workspaceBundledSkillNames.contains(name) {
                        try fileManager.removeItem(at: installed)
                    }
                    continue
                }
                let canonical = catalog.appendingPathComponent(name, isDirectory: true)
                let hasCanonicalDefinition = try definition(in: canonical) != nil
                if !enabled.contains(name) || !hasCanonicalDefinition {
                    try fileManager.removeItem(at: installed)
                }
            }

            for name in enabled.sorted() {
                let source = catalog.appendingPathComponent(name, isDirectory: true)
                guard try definition(in: source) != nil else { continue }
                let destination = providerRoot.appendingPathComponent(name, isDirectory: true)
                try replaceDirectory(
                    at: destination,
                    with: source,
                    fileManager: fileManager
                )
            }
        }
    }

    @WritingWorkspaceFiles
    public static func synchronizeAllEnabledWorkspaces(
        in libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = devotionalWorkspacesDirectory(in: libraryRootURL)
        guard isSafeDirectory(root, fileManager: fileManager) else { return }
        for workspace in try safeChildDirectories(in: root, fileManager: fileManager)
        where fileManager.fileExists(atPath: selectionURL(in: workspace).path) {
            try synchronizeWorkspace(
                workspace,
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
        }
    }

    @WritingWorkspaceFiles
    public static func applySelectionData(
        _ data: Data,
        to workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        _ = try validatedWorkspace(
            workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager,
            createIfNeeded: true
        )
        let selection = try JSONDecoder().decode(WorkspaceSkillSelection.self, from: data)
        guard selection.formatVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let names = Set(selection.names.filter {
            isValidSkillName($0) && !builtInSkillNames.contains($0)
        })
        try writeSelection(names, in: workspaceURL, fileManager: fileManager)
        try synchronizeWorkspace(
            workspaceURL,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
    }

    @discardableResult
    @WritingWorkspaceFiles
    public static func importLegacySkill(
        from sourceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let originalName = sourceURL.lastPathComponent
        guard isValidSkillName(originalName),
              !builtInSkillNames.contains(originalName),
              try definition(in: sourceURL) != nil else {
            throw invalidSkillNameError()
        }

        let catalog = catalogDirectory(in: libraryRootURL)
        try ensureSafeDirectory(catalog, fileManager: fileManager)
        var destination = catalog.appendingPathComponent(originalName, isDirectory: true)
        var importedName = originalName
        if fileManager.fileExists(atPath: destination.path) {
            if try directoriesMatch(sourceURL, destination, fileManager: fileManager) {
                return originalName
            }
            importedName = availableConflictName(
                for: originalName,
                in: catalog,
                fileManager: fileManager
            )
            destination = catalog.appendingPathComponent(importedName, isDirectory: true)
        }

        try safeCopyDirectory(from: sourceURL, to: destination, fileManager: fileManager)
        if importedName != originalName {
            try rewriteSkillName(importedName, in: destination)
        }
        return importedName
    }

    private static func writeSelection(
        _ names: Set<String>,
        in workspaceURL: URL,
        fileManager: FileManager
    ) throws {
        let parent = selectionURL(in: workspaceURL).deletingLastPathComponent()
        try ensureSafeDirectory(parent, fileManager: fileManager)
        let selection = WorkspaceSkillSelection(names: names.filter {
            isValidSkillName($0) && !builtInSkillNames.contains($0)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(selection).write(to: selectionURL(in: workspaceURL), options: .atomic)
    }

    private static func definition(in directory: URL) throws -> WorkspaceSkillDefinition? {
        guard isValidSkillName(directory.lastPathComponent) else { return nil }
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
        let documentURL = directory.appendingPathComponent("SKILL.md")
        let documentValues = try? documentURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard documentValues?.isRegularFile == true,
              documentValues?.isSymbolicLink != true,
              let document = try? String(contentsOf: documentURL, encoding: .utf8) else { return nil }
        return parseSkill(
            named: directory.lastPathComponent,
            document: document,
            directoryURL: directory
        )
    }

    private static func parseSkill(
        named name: String,
        document: String,
        directoryURL: URL
    ) -> WorkspaceSkillDefinition {
        let parts = document.components(separatedBy: "---")
        guard parts.count >= 3 else {
            return WorkspaceSkillDefinition(
                name: name,
                description: "",
                instructions: document,
                directoryURL: directoryURL
            )
        }
        let frontmatter = parts[1]
        let descriptionLine = frontmatter.split(separator: "\n").first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("description:")
        }
        let rawDescription = descriptionLine.map(String.init)?
            .split(separator: ":", maxSplits: 1)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let description: String
        if let data = rawDescription.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            description = decoded
        } else {
            description = rawDescription
        }
        return WorkspaceSkillDefinition(
            name: name,
            description: description,
            instructions: parts.dropFirst(2).joined(separator: "---")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            directoryURL: directoryURL
        )
    }

    private static func skillDocument(
        name: String,
        description: String,
        instructions: String
    ) -> String {
        """
        ---
        name: \(name)
        description: \(yamlQuoted(description))
        ---

        \(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        """ + "\n"
    }

    private static func yamlQuoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    private static func rewriteSkillName(_ name: String, in directory: URL) throws {
        let documentURL = directory.appendingPathComponent("SKILL.md")
        var lines = try String(contentsOf: documentURL, encoding: .utf8)
            .components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else { return }
        if let index = lines[1..<end].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:")
        }) {
            lines[index] = "name: \(name)"
        } else {
            lines.insert("name: \(name)", at: 1)
        }
        try lines.joined(separator: "\n").write(
            to: documentURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func availableConflictName(
        for original: String,
        in catalog: URL,
        fileManager: FileManager
    ) -> String {
        var index = 2
        while true {
            let suffix = "-\(index)"
            let stem = String(original.prefix(64 - suffix.count))
            let candidate = stem + suffix
            if !fileManager.fileExists(
                atPath: catalog.appendingPathComponent(candidate, isDirectory: true).path
            ) {
                return candidate
            }
            index += 1
        }
    }

    private static func directoriesMatch(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager
    ) throws -> Bool {
        try directoryContents(lhs, fileManager: fileManager)
            == directoryContents(rhs, fileManager: fileManager)
    }

    private static func directoryContents(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> [String: Data] {
        guard isSafeDirectory(directory, fileManager: fileManager),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
              ) else { throw unsafeSkillStorageError() }
        let prefix = directory.standardizedFileURL.path + "/"
        var contents: [String: Data] = [:]
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw unsafeSkillStorageError() }
            guard values.isRegularFile == true else { continue }
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw unsafeSkillStorageError() }
            contents[String(path.dropFirst(prefix.count))] = try Data(contentsOf: item)
        }
        return contents
    }

    private static func replaceDirectory(
        at destination: URL,
        with source: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path),
           try directoriesMatch(source, destination, fileManager: fileManager) {
            return
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".lamp-skill-\(UUID().uuidString)", isDirectory: true)
        try safeCopyDirectory(from: source, to: temporary, fileManager: fileManager)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func safeCopyDirectory(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        guard isSafeDirectory(source, fileManager: fileManager),
              !fileManager.fileExists(atPath: destination.path) else {
            throw unsafeSkillStorageError()
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try copyDirectoryContents(
                from: source,
                to: destination,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private static func copyDirectoryContents(
        from source: URL,
        to destination: URL,
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
            guard values.isSymbolicLink != true else { throw unsafeSkillStorageError() }
            let childDestination = destination.appendingPathComponent(child.lastPathComponent)
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: childDestination,
                    withIntermediateDirectories: false
                )
                try copyDirectoryContents(
                    from: child,
                    to: childDestination,
                    fileManager: fileManager
                )
            } else if values.isRegularFile == true {
                try fileManager.copyItem(at: child, to: childDestination)
            } else {
                throw unsafeSkillStorageError()
            }
        }
    }

    private static func childSkillDirectories(
        in directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try safeChildDirectories(in: directory, fileManager: fileManager).filter {
            isValidSkillName($0.lastPathComponent)
        }
    }

    private static func safeChildDirectories(
        in directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private static func validatedWorkspace(
        _ workspaceURL: URL,
        libraryRootURL: URL,
        fileManager: FileManager,
        createIfNeeded: Bool
    ) throws -> URL {
        let root = devotionalWorkspacesDirectory(in: libraryRootURL)
        let workspace = workspaceURL.standardizedFileURL
        guard workspace.deletingLastPathComponent() == root,
              !workspace.lastPathComponent.isEmpty,
              workspace.lastPathComponent != ".",
              workspace.lastPathComponent != ".." else {
            throw unsafeSkillStorageError()
        }
        if fileManager.fileExists(atPath: workspace.path) {
            guard isSafeDirectory(workspace, fileManager: fileManager) else {
                throw unsafeSkillStorageError()
            }
        } else if createIfNeeded {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        }
        return workspace
    }

    private static func devotionalWorkspacesDirectory(in libraryRootURL: URL) -> URL {
        LampWritingWorkspace.root(libraryRootURL: libraryRootURL.standardizedFileURL).standardizedFileURL
    }

    /// Where each provider looks for a workspace's skills. The copy Codex
    /// reads is the canonical one; Claude's is a mirror of it.
    public static func codexSkillsDirectory(in workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    public static func claudeSkillsDirectory(in workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private static func ensureSafeDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  isSafeDirectory(directory, fileManager: fileManager) else {
                throw unsafeSkillStorageError()
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func isSafeDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink != true
    }

    private static func invalidSkillNameError() -> CocoaError {
        CocoaError(.validationMissingMandatoryProperty, userInfo: [
            NSLocalizedDescriptionKey: "Use lowercase letters, numbers, and single hyphens for the skill name.",
        ])
    }

    private static func unsafeSkillStorageError() -> CocoaError {
        CocoaError(.fileWriteNoPermission, userInfo: [
            NSLocalizedDescriptionKey: "Workspace skills must use safe files and directories inside the Lamp library.",
        ])
    }
}
