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
    private var hasAutomaticallySynced = false

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
        guard !hasAutomaticallySynced,
              defaults.bool(forKey: "sync.automatic"),
              provider != .off else { return }
        hasAutomaticallySynced = true
        await sync(library: library)
    }

    func sync(library: LampLibrary) async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        statusMessage = "Preparing sync…"
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("lamp-sync-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: workspace) }
            let incoming = workspace.appendingPathComponent("Incoming", isDirectory: true)
            let outgoing = workspace.appendingPathComponent("Outgoing", isDirectory: true)

            switch provider {
            case .off:
                throw LibrarySyncError.providerNotConfigured
            case .folder:
                let folder = try resolveFolderURL()
                let hasScope = folder.startAccessingSecurityScopedResource()
                defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
                if fileManager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) {
                    statusMessage = "Merging changes from \(folder.lastPathComponent)…"
                    try LampFolderSync.merge(from: folder, into: incoming)
                    _ = try await library.importPortableBackup(from: incoming)
                    importSettings(from: incoming)
                    try LampWorkspaceSync.importPortableWorkspaces(
                        from: incoming,
                        into: library.rootURL,
                        fileManager: fileManager
                    )
                }
                statusMessage = "Publishing library…"
                _ = try await library.exportPortableBackup(to: outgoing)
                exportSettings(to: outgoing)
                try LampWorkspaceSync.exportPortableWorkspaces(
                    from: library.rootURL,
                    to: outgoing,
                    fileManager: fileManager
                )
                try LampFolderSync.merge(from: outgoing, into: folder)
            case .webDAV:
                guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
                    throw LibrarySyncError.invalidWebDAVURL
                }
                let storedPassword = SyncSecretStore.password ?? ""
                let credentials = username.isEmpty && storedPassword.isEmpty
                    ? nil : LampWebDAVCredentials(username: username, password: storedPassword)
                let client = LampWebDAVClient(baseURL: url, credentials: credentials)
                var iOSImportSummary = IOSWebDAVImportSummary()
                statusMessage = "Downloading WebDAV library…"
                if let data = try await client.download(filename: "lamp-bible.lampsync") {
                    do {
                        let archive = try LampSyncArchive.decode(compressedData: data)
                        try archive.extract(to: incoming)
                        iOSImportSummary.failures.append(contentsOf:
                            normalizeArchivedDevotionalJSON(in: incoming)
                        )
                        do {
                            _ = try await library.importPortableBackup(from: incoming)
                        } catch {
                            // A stale or partially incompatible Mac archive must not
                            // prevent the canonical iOS folders from being scanned.
                            iOSImportSummary.failures.append(
                                "lamp-bible.lampsync (\(error.localizedDescription))"
                            )
                        }
                        importSettings(from: incoming)
                        do {
                            try LampWorkspaceSync.importPortableWorkspaces(
                                from: incoming,
                                into: library.rootURL,
                                fileManager: fileManager
                            )
                        } catch {
                            iOSImportSummary.failures.append(
                                "lamp-bible.lampsync workspaces (\(error.localizedDescription))"
                            )
                        }
                    } catch {
                        iOSImportSummary.failures.append(
                            "lamp-bible.lampsync (\(error.localizedDescription))"
                        )
                    }
                }
                statusMessage = "Importing iPhone and iPad library…"
                iOSImportSummary.merge(try await importIOSWebDAVContent(
                    using: client,
                    into: workspace,
                    library: library
                ))
                statusMessage = "Uploading WebDAV library…"
                _ = try await library.exportPortableBackup(to: outgoing)
                exportSettings(to: outgoing)
                try LampWorkspaceSync.exportPortableWorkspaces(
                    from: library.rootURL,
                    to: outgoing,
                    fileManager: fileManager
                )
                let archive = try LampSyncArchive.create(from: outgoing)
                try await client.upload(archive.compressedData(), filename: "lamp-bible.lampsync")
                statusMessage = "Publishing iPhone and iPad compatible library…"
                try await publishIOSWebDAVContent(
                    using: client,
                    from: workspace,
                    library: library
                )

                defaults.set(Date(), forKey: "sync.lastCompleted")
                let date = Date().formatted(date: .abbreviated, time: .shortened)
                if iOSImportSummary.downloadedCount > 0 {
                    statusMessage = "Synced \(date) — downloaded \(iOSImportSummary.downloadedCount) item\(iOSImportSummary.downloadedCount == 1 ? "" : "s")"
                } else {
                    statusMessage = "Synced \(date)"
                }
                if !iOSImportSummary.failures.isEmpty {
                    let examples = iOSImportSummary.failures.prefix(3).joined(separator: "; ")
                    errorMessage = "Sync completed, but \(iOSImportSummary.failures.count) WebDAV file\(iOSImportSummary.failures.count == 1 ? "" : "s") could not be imported: \(examples)"
                }
                isSyncing = false
                return
            }

            defaults.set(Date(), forKey: "sync.lastCompleted")
            statusMessage = "Synced \(Date().formatted(date: .abbreviated, time: .shortened))"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        isSyncing = false
    }

    private func importIOSWebDAVContent(
        using client: LampWebDAVClient,
        into workspace: URL,
        library: LampLibrary
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
                filenames = try await client.listFilenames(directory: source.rawValue)
            } catch {
                summary.failures.append(
                    "\(source.rawValue) (could not list folder: \(error.localizedDescription))"
                )
                continue
            }
            for filename in filenames where isPortableModule(filename) {
                do {
                    guard let data = try await client.download(
                        relativePath: "\(source.rawValue)/\(filename)"
                    ) else { continue }
                    let isJSON = filename.lowercased().hasSuffix(".json")

                    switch source {
                    case .notes, .highlights, .devotionals:
                        let remoteSetID = source == .highlights && !isJSON
                            ? try? LampWebDAVPersonalArchiveAdapter.highlightSetID(
                                in: data,
                                fileManager: fileManager
                            )
                            : nil
                        let documents: [LampWebDAVModuleJSONDocument]
                        if isJSON {
                            documents = try LampWebDAVModuleJSONAdapter.documents(
                                from: data,
                                kind: source.kind,
                                fallbackModuleID: remoteModuleStem(filename)
                            )
                        } else {
                            documents = []
                        }

                        if source == .devotionals {
                            if isJSON {
                                for document in documents {
                                    let localURL = importDirectory
                                        .appendingPathComponent(UUID().uuidString)
                                        .appendingPathExtension("json")
                                    try document.data.write(to: localURL, options: .atomic)
                                    summary.devotionals += try await library.importPersonalDevotional(
                                        from: localURL
                                    ).count
                                }
                            } else {
                                let localURL = importDirectory
                                    .appendingPathComponent(UUID().uuidString)
                                    .appendingPathExtension("lamp")
                                try compressedModuleData(data, filename: filename).write(
                                    to: localURL,
                                    options: .atomic
                                )
                                summary.devotionals += try await library.importPersonalDevotional(
                                    from: localURL
                                ).count
                            }
                        } else if isJSON {
                            for document in documents {
                                let localURL = importDirectory
                                    .appendingPathComponent(UUID().uuidString)
                                    .appendingPathExtension("json")
                                try document.data.write(to: localURL, options: .atomic)
                                let result = try await library.importPersonalStudyData(from: localURL)
                                summary.studyEntries += result.importedCount
                            }
                        } else {
                            let localURL = importDirectory
                                .appendingPathComponent(UUID().uuidString)
                                .appendingPathExtension("lamp")
                            try compressedModuleData(data, filename: filename).write(
                                to: localURL,
                                options: .atomic
                            )
                            let result = try await library.importPersonalStudyData(from: localURL)
                            summary.studyEntries += result.importedCount
                        }

                        if let remoteSetID {
                            highlightModuleIDsBySet[remoteSetID] = safeRemoteIdentifier(
                                remoteModuleStem(filename)
                            )
                        }

                    case .translations, .dictionaries, .commentaries, .books, .plans, .quizzes:
                        if isJSON {
                            let documents = try LampWebDAVModuleJSONAdapter.documents(
                                from: data,
                                kind: source.kind,
                                fallbackModuleID: remoteModuleStem(filename)
                            )
                            for document in documents {
                                let moduleURL = importDirectory
                                    .appendingPathComponent(document.moduleID)
                                    .appendingPathExtension("lamp")
                                _ = try LampModuleCompiler().compile(
                                    data: document.data,
                                    sourceFilename: filename,
                                    destinationURL: moduleURL
                                )
                                _ = try await library.install(from: moduleURL)
                                summary.modules += 1
                            }
                        } else {
                            let moduleURL = importDirectory
                                .appendingPathComponent(safeRemoteIdentifier(remoteModuleStem(filename)))
                                .appendingPathExtension("lamp")
                            try compressedModuleData(data, filename: filename).write(
                                to: moduleURL,
                                options: .atomic
                            )
                            _ = try await library.install(from: moduleURL)
                            summary.modules += 1
                        }
                    }
                } catch {
                    summary.failures.append(
                        "\(source.rawValue)/\(filename) (\(error.localizedDescription))"
                    )
                }
            }
        }

        defaults.set(highlightModuleIDsBySet, forKey: Self.iOSHighlightModuleIDsBySetKey)
        return summary
    }

    private func normalizeArchivedDevotionalJSON(in backupDirectory: URL) -> [String] {
        let directory = backupDirectory.appendingPathComponent("Devotionals", isDirectory: true)
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

    private func publishIOSWebDAVContent(
        using client: LampWebDAVClient,
        from workspace: URL,
        library: LampLibrary
    ) async throws {
        let exportDirectory = workspace.appendingPathComponent("iOS Exports", isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        for export in [
            (
                module: LampPersonalModule.notes,
                directory: "Notes",
                filename: "notes.lamp",
                iOSModuleID: "notes",
                archiveKind: LampWebDAVPersonalArchiveKind.notes
            ),
            (
                module: LampPersonalModule.writing,
                directory: "Devotionals",
                filename: "devotionals.lamp",
                iOSModuleID: "devotionals",
                archiveKind: LampWebDAVPersonalArchiveKind.devotionals
            ),
        ] {
            try await client.createDirectory(export.directory)
            let localURL = exportDirectory.appendingPathComponent(export.filename)
            try await library.exportPersonalModule(export.module, format: .lamp, to: localURL)
            let archive = try LampWebDAVPersonalArchiveAdapter.archive(
                Data(contentsOf: localURL, options: .mappedIfSafe),
                replacingModuleIDWith: export.iOSModuleID,
                kind: export.archiveKind,
                fileManager: fileManager
            )
            try await client.upload(
                archive,
                relativePath: "\(export.directory)/\(export.filename)"
            )
        }

        try await client.createDirectory("Highlights")
        var highlightModuleIDsBySet = defaults.dictionary(
            forKey: Self.iOSHighlightModuleIDsBySetKey
        ) as? [String: String] ?? [:]
        for set in try await library.highlightSets() {
            let moduleID = safeRemoteIdentifier(
                highlightModuleIDsBySet[set.id] ?? set.id
            )
            guard let document = try? await library.personalHighlightsDocument(
                translationID: set.translationID,
                moduleID: moduleID,
                name: set.name,
                setID: set.id
            ) else { continue }
            let localURL = exportDirectory.appendingPathComponent(document.suggestedModuleFilename)
            _ = try LampModuleCompiler().compile(
                data: document.jsonData,
                sourceFilename: document.suggestedJSONFilename,
                destinationURL: localURL
            )
            try await client.upload(
                Data(contentsOf: localURL, options: .mappedIfSafe),
                relativePath: "Highlights/\(document.suggestedModuleFilename)"
            )
            highlightModuleIDsBySet[set.id] = moduleID
        }
        defaults.set(highlightModuleIDsBySet, forKey: Self.iOSHighlightModuleIDsBySetKey)
    }

    private func isPortableModule(_ filename: String) -> Bool {
        let lowercased = filename.lowercased()
        return lowercased.hasSuffix(".lamp")
            || lowercased.hasSuffix(".db.zlib")
            || lowercased.hasSuffix(".db")
            || lowercased.hasSuffix(".json")
    }

    private func compressedModuleData(_ data: Data, filename: String) throws -> Data {
        guard filename.lowercased().hasSuffix(".db") else { return data }
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            throw LampSyncError.archiveConversionFailed
        }
        return compressed
    }

    private func remoteModuleStem(_ filename: String) -> String {
        if filename.lowercased().hasSuffix(".db.zlib") {
            return String(filename.dropLast(".db.zlib".count))
        }
        return URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
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

    private func exportSettings(to directory: URL) {
        var settings: [String: Any] = [:]
        for key in Self.syncedSettingKeys {
            if let value = defaults.object(forKey: key) { settings[key] = value }
        }
        guard PropertyListSerialization.propertyList(settings, isValidFor: .binary) else { return }
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: settings,
            format: .binary,
            options: 0
        ) {
            try? data.write(to: directory.appendingPathComponent("settings.plist"), options: .atomic)
        }
    }

    private func importSettings(from directory: URL) {
        let url = directory.appendingPathComponent("settings.plist")
        guard let data = try? Data(contentsOf: url),
              let settings = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = settings as? [String: Any] else { return }
        for key in Self.syncedSettingKeys {
            if let value = dictionary[key] { defaults.set(value, forKey: key) }
        }
    }

    private static let syncedSettingKeys = [
        "reader.fontSize", "reader.lineSpacing", "reader.typeface", "reader.defaultTranslationID",
        "reader.readAloud.voice", "reader.readAloud.rate", "reader.readAloud.followAlong",
        "reader.showStrongsHints", "reader.crossReferences.canonicalOrder",
        "commentary.fontSize", "commentary.lineSpacing", "commentary.typeface",
        "studyInspector.greekDictionaryModuleID", "studyInspector.hebrewDictionaryModuleID",
        "studyInspector.commentaryModuleID",
        "plans.wordsPerMinute", "plans.externalBibleApp", "plans.reminder.enabled",
        "plans.reminder.hour", "plans.reminder.minute", "devotional.fontSize",
        "quiz.defaultAgeGroup", "quiz.alwaysShowAnswers", "quiz.fontSize",
        "quiz.lineSpacing", "quiz.typeface", "modules.hiddenIDs",
        "writing.preview.placement", "writing.preview.width", "writing.preview.fontSize",
        "writing.preview.lineSpacing", "writing.preview.typeface",
        "writing.preview.followsEditorScrolling", "devotional.editor.fontSize",
        "devotional.lineSpacing", "devotional.typeface",
        "writing.sortOrder", "writing.groupBy",
        "books.fontSize", "books.lineSpacing", "books.typeface", "books.readerState",
    ]
}

private enum IOSWebDAVModuleDirectory: String, CaseIterable {
    case translations = "Translations"
    case dictionaries = "Dictionaries"
    case commentaries = "Commentaries"
    case books = "Books"
    case devotionals = "Devotionals"
    case notes = "Notes"
    case plans = "Plans"
    case highlights = "Highlights"
    case quizzes = "Quizzes"

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

private struct IOSWebDAVImportSummary {
    var studyEntries = 0
    var devotionals = 0
    var modules = 0
    var failures: [String] = []

    var personalItemCount: Int { studyEntries + devotionals }
    var downloadedCount: Int { personalItemCount + modules }

    mutating func merge(_ other: IOSWebDAVImportSummary) {
        studyEntries += other.studyEntries
        devotionals += other.devotionals
        modules += other.modules
        failures.append(contentsOf: other.failures)
    }
}

private enum LibrarySyncError: LocalizedError {
    case providerNotConfigured
    case folderNotConfigured
    case invalidWebDAVURL

    var errorDescription: String? {
        switch self {
        case .providerNotConfigured: "Choose a sync provider first."
        case .folderNotConfigured: "Choose an iCloud Drive or local folder for sync."
        case .invalidWebDAVURL: "Enter a valid HTTP or HTTPS WebDAV folder URL."
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
