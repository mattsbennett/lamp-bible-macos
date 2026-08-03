import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
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

    var password: String {
        get { SyncSecretStore.password ?? "" }
        set { try? SyncSecretStore.setPassword(newValue) }
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
                }
                statusMessage = "Publishing library…"
                _ = try await library.exportPortableBackup(to: outgoing)
                exportSettings(to: outgoing)
                try LampFolderSync.merge(from: outgoing, into: folder)
            case .webDAV:
                guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
                    throw LibrarySyncError.invalidWebDAVURL
                }
                let credentials = username.isEmpty && password.isEmpty
                    ? nil : LampWebDAVCredentials(username: username, password: password)
                let client = LampWebDAVClient(baseURL: url, credentials: credentials)
                statusMessage = "Downloading WebDAV library…"
                if let data = try await client.download(filename: "lamp-bible.lampsync") {
                    let archive = try LampSyncArchive.decode(compressedData: data)
                    try archive.extract(to: incoming)
                    _ = try await library.importPortableBackup(from: incoming)
                    importSettings(from: incoming)
                }
                statusMessage = "Uploading WebDAV library…"
                _ = try await library.exportPortableBackup(to: outgoing)
                exportSettings(to: outgoing)
                let archive = try LampSyncArchive.create(from: outgoing)
                try await client.upload(archive.compressedData(), filename: "lamp-bible.lampsync")
            }

            defaults.set(Date(), forKey: "sync.lastCompleted")
            statusMessage = "Synced \(Date().formatted(date: .abbreviated, time: .shortened))"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        isSyncing = false
    }

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
        "reader.fontSize", "reader.lineSpacing", "reader.defaultTranslationID",
        "reader.readAloud.voice", "reader.readAloud.rate", "reader.readAloud.followAlong",
        "reader.showStrongsHints", "reader.crossReferences.canonicalOrder",
        "plans.wordsPerMinute", "plans.externalBibleApp", "plans.reminder.enabled",
        "plans.reminder.hour", "plans.reminder.minute", "devotional.fontSize",
        "quiz.defaultAgeGroup", "modules.hiddenIDs", "modules.order",
    ]
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
