import Foundation

/// The canonical study instructions, shared by workspace installation and MCP.
/// Reference files stay on demand rather than being inlined into every prompt.
public enum LampBundledSkills {
    public static let studySkillNames: Set<String> = ["original-languages", "sola-scriptura"]

    public static var catalogURL: URL? {
        #if SWIFT_PACKAGE
        let resources = Bundle.module.resourceURL
        #else
        let resources = Bundle.main.resourceURL
        #endif
        return catalogURL(resourceURL: resources, executableURL: Bundle.main.executableURL)
    }

    /// Native app resources, an embedded Contents/Helpers executable, or a
    /// standalone helper with its catalog beside it. Never consult the cwd.
    static func catalogURL(resourceURL: URL?, executableURL: URL?) -> URL? {
        var candidates = resourceURL.map { [$0.appendingPathComponent("AgentSkills")] } ?? []
        if let executableDirectory = executableURL?.deletingLastPathComponent() {
            candidates += [
                executableDirectory.deletingLastPathComponent()
                    .appendingPathComponent("Resources/AgentSkills"),
                executableDirectory.appendingPathComponent("AgentSkills"),
            ]
        }
        return candidates.first {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    public static func read(
        name: String, file: String = "SKILL.md", catalogURL: URL? = LampBundledSkills.catalogURL
    ) throws -> String {
        guard studySkillNames.contains(name), let catalogURL else {
            throw SkillError.unavailable(name)
        }
        return try read(file: file, inside: catalogURL.appendingPathComponent(name))
    }

    /// Also used for installed workspace skills, keeping the confinement rule
    /// identical for bundled references and user-defined skills.
    public static func read(file: String, inside directory: URL) throws -> String {
        guard file.hasSuffix(".md"), !file.hasPrefix("/"),
              !file.split(separator: "/").contains("..") else {
            throw SkillError.invalidPath
        }
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL
        let target = directory.appendingPathComponent(file)
            .resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(folder.path + "/") else {
            throw SkillError.invalidPath
        }
        return try String(contentsOf: target, encoding: .utf8)
    }

    public enum SkillError: Error, LocalizedError {
        case unavailable(String)
        case invalidPath

        public var errorDescription: String? {
            switch self {
            case .unavailable(let name): "The bundled skill \(name) is unavailable."
            case .invalidPath: "A skill reference must be a Markdown path inside that skill."
            }
        }
    }
}
