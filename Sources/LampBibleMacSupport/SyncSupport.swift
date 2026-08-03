import Foundation

public struct LampSyncArchive: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let data: Data
        public let modifiedAt: Date

        public init(path: String, data: Data, modifiedAt: Date) {
            self.path = path
            self.data = data
            self.modifiedAt = modifiedAt
        }
    }

    public let formatVersion: Int
    public let entries: [Entry]

    public init(formatVersion: Int = 1, entries: [Entry]) {
        self.formatVersion = formatVersion
        self.entries = entries
    }

    public static func create(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> LampSyncArchive {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return LampSyncArchive(entries: []) }
        let prefix = directory.standardizedFileURL.path + "/"
        let entries = try enumerator.compactMap { item -> Entry? in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(prefix) else { throw LampSyncError.unsafeArchivePath }
            return Entry(
                path: String(standardizedPath.dropFirst(prefix.count)),
                data: try Data(contentsOf: url),
                modifiedAt: values.contentModificationDate ?? Date()
            )
        }
        return LampSyncArchive(entries: entries.sorted { $0.path < $1.path })
    }

    public func compressedData() throws -> Data {
        let data = try JSONEncoder().encode(self)
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    public static func decode(compressedData: Data) throws -> LampSyncArchive {
        let data = try (compressedData as NSData).decompressed(using: .zlib) as Data
        let archive = try JSONDecoder().decode(LampSyncArchive.self, from: data)
        guard archive.formatVersion == 1 else { throw LampSyncError.unsupportedArchiveVersion }
        return archive
    }

    public func extract(
        to directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.standardizedFileURL.path + "/"
        for entry in entries {
            guard !entry.path.hasPrefix("/"),
                  !entry.path.split(separator: "/").contains("..") else {
                throw LampSyncError.unsafeArchivePath
            }
            let destination = directory.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(root) else { throw LampSyncError.unsafeArchivePath }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: destination, options: .atomic)
            try fileManager.setAttributes(
                [.modificationDate: entry.modifiedAt],
                ofItemAtPath: destination.path
            )
        }
    }
}

public enum LampFolderSync {
    public static func merge(
        from source: URL,
        into destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let archive = try LampSyncArchive.create(from: source, fileManager: fileManager)
        try archive.extract(to: destination, fileManager: fileManager)
    }
}

public struct LampWebDAVCredentials: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct LampWebDAVClient: Sendable {
    public let baseURL: URL
    public let credentials: LampWebDAVCredentials?
    private let session: URLSession

    public init(
        baseURL: URL,
        credentials: LampWebDAVCredentials? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
    }

    public func download(filename: String) async throws -> Data? {
        let request = try makeRequest(method: "GET", filename: filename)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LampSyncError.invalidResponse }
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw LampSyncError.httpStatus(response.statusCode)
        }
        return data
    }

    public func upload(_ data: Data, filename: String) async throws {
        var request = try makeRequest(method: "PUT", filename: filename)
        request.httpBody = data
        request.setValue("application/x-lamp-bible-sync", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LampSyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw LampSyncError.httpStatus(response.statusCode)
        }
    }

    public func makeRequest(method: String, filename: String) throws -> URLRequest {
        guard !filename.contains("/"), !filename.contains("..") else {
            throw LampSyncError.unsafeArchivePath
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(filename))
        request.httpMethod = method
        request.timeoutInterval = 60
        if let credentials {
            let token = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

public enum LampSyncError: LocalizedError {
    case unsafeArchivePath
    case unsupportedArchiveVersion
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unsafeArchivePath: "The sync archive contains an unsafe file path."
        case .unsupportedArchiveVersion: "This Lamp Bible sync archive version is not supported."
        case .invalidResponse: "The sync server returned an invalid response."
        case .httpStatus(let status): "The sync server returned HTTP status \(status)."
        }
    }
}
