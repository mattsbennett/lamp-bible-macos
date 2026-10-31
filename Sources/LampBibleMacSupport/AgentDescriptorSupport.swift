import Foundation

/// Where Lamp keeps its library and what an agent may see of it, written down
/// so that `lamp-mcp` can find both without being told.
///
/// An outside app's MCP configuration names the helper and nothing else. Paths
/// written into such a config go stale — the library moves, the access
/// settings change — and the app whose config it is has no way to notice. This
/// is the one place that does change: Lamp rewrites it whenever the
/// agent-access settings are applied, and the helper reads it at startup.
///
/// It grants nothing. Anything running as this user could already read the
/// library files directly; what the descriptor removes is the lookup, not a
/// barrier. `allowsExternalApps` is a setting Lamp's own helper honours, not
/// an enforcement boundary.
public struct LampAgentDescriptor: Codable, Equatable, Sendable {
    /// Raised when a field changes meaning. A helper that meets a descriptor
    /// from a newer Lamp says so rather than guessing at it, because guessing
    /// here means serving the wrong library or the wrong policy.
    public static let currentVersion = 1

    public var version: Int
    public var libraryRootPath: String
    public var policyPath: String
    public var bundledModulesArchivePath: String?
    /// Whether apps other than Lamp may use the library through the helper.
    /// Off until the user turns it on.
    public var allowsExternalApps: Bool
    /// Whether those apps may *change* a writing, as against reading one.
    /// Its own switch, and its own default of off: reading a library and
    /// rewriting someone's prose are not the same risk, and turning on the
    /// first must not quietly grant the second.
    public var allowsExternalWriting: Bool
    /// Whether those apps may add a reading plan. Its own switch for the same
    /// reason, and a narrow one: a plan is a module Lamp makes from a
    /// description, so this grants adding something new and nothing else —
    /// never changing or removing what is already in the library.
    public var allowsExternalReadingPlans: Bool

    public init(
        version: Int = currentVersion,
        libraryRootPath: String,
        policyPath: String,
        bundledModulesArchivePath: String? = nil,
        allowsExternalApps: Bool = false,
        allowsExternalWriting: Bool = false,
        allowsExternalReadingPlans: Bool = false
    ) {
        self.version = version
        self.libraryRootPath = libraryRootPath
        self.policyPath = policyPath
        self.bundledModulesArchivePath = bundledModulesArchivePath
        self.allowsExternalApps = allowsExternalApps
        self.allowsExternalWriting = allowsExternalWriting
        self.allowsExternalReadingPlans = allowsExternalReadingPlans
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        libraryRootPath = try container.decode(String.self, forKey: .libraryRootPath)
        policyPath = try container.decode(String.self, forKey: .policyPath)
        bundledModulesArchivePath = try container.decodeIfPresent(
            String.self, forKey: .bundledModulesArchivePath
        )
        // Absent means off. A descriptor written before this field existed
        // must not read as permission nobody gave.
        allowsExternalApps = try container.decodeIfPresent(
            Bool.self, forKey: .allowsExternalApps
        ) ?? false
        allowsExternalWriting = try container.decodeIfPresent(
            Bool.self, forKey: .allowsExternalWriting
        ) ?? false
        allowsExternalReadingPlans = try container.decodeIfPresent(
            Bool.self, forKey: .allowsExternalReadingPlans
        ) ?? false
    }

    public var libraryRootURL: URL {
        URL(fileURLWithPath: libraryRootPath, isDirectory: true)
    }

    public var policyURL: URL {
        URL(fileURLWithPath: policyPath)
    }

    public var bundledModulesArchiveURL: URL? {
        bundledModulesArchivePath.map { URL(fileURLWithPath: $0) }
    }
}

public enum LampAgentDescriptorStore {
    public static let filename = "agent-descriptor.json"

    public enum StoreError: Error, LocalizedError, Equatable {
        case missing(URL)
        case unreadable(URL)
        case unsupportedVersion(Int)
        case externalAppsNotAllowed

        public var errorDescription: String? {
            switch self {
            case .missing(let url):
                return """
                No Lamp descriptor at \(url.path). Open Lamp, then Settings › \
                Agent Access, to write one.
                """
            case .unreadable(let url):
                return "The Lamp descriptor at \(url.path) could not be read."
            case .unsupportedVersion(let version):
                return """
                The Lamp descriptor is version \(version), which this helper \
                does not understand. The app and its helper are from different \
                versions of Lamp.
                """
            case .externalAppsNotAllowed:
                return """
                Lamp is not set up for use from other apps. Turn on "Allow \
                other apps to read my library" in Lamp's Settings, under Agent \
                Access.
                """
            }
        }
    }

    /// `~/Library/Application Support/Lamp Bible`, as the slide studio's
    /// drafts use.
    public static func directoryURL(inApplicationSupport root: URL) -> URL {
        root.appendingPathComponent("Lamp Bible", isDirectory: true)
    }

    public static func url(inApplicationSupport root: URL) -> URL {
        directoryURL(inApplicationSupport: root).appendingPathComponent(filename)
    }

    /// This user's Application Support, which is where both the app and a
    /// helper launched by another app look. Nil only if the system has no
    /// such directory, in which case there is nowhere agreed to look.
    public static func defaultApplicationSupportURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    @discardableResult
    public static func write(
        _ descriptor: LampAgentDescriptor,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = directoryURL(inApplicationSupport: root)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(descriptor)
        data.append(0x0A)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public static func read(
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws -> LampAgentDescriptor {
        let source = url(inApplicationSupport: root)
        guard fileManager.fileExists(atPath: source.path) else {
            throw StoreError.missing(source)
        }
        guard let data = try? Data(contentsOf: source),
              let descriptor = try? JSONDecoder().decode(LampAgentDescriptor.self, from: data)
        else {
            throw StoreError.unreadable(source)
        }
        guard descriptor.version <= LampAgentDescriptor.currentVersion else {
            throw StoreError.unsupportedVersion(descriptor.version)
        }
        return descriptor
    }

    /// The descriptor to serve an outside app from, or the reason not to.
    ///
    /// Separate from `read` because refusing an app the user has not allowed
    /// is not the same as failing to find the library, and the two want
    /// different things said to whoever is reading the helper's stderr.
    public static func readForExternalUse(
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws -> LampAgentDescriptor {
        let descriptor = try read(inApplicationSupport: root, fileManager: fileManager)
        guard descriptor.allowsExternalApps else { throw StoreError.externalAppsNotAllowed }
        return descriptor
    }
}
