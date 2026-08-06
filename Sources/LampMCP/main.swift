import Foundation
import LampCore
#if canImport(LampMCPServer)
import LampMCPServer
#endif

#if canImport(Darwin)
import Darwin
#endif

@main
struct LampMCPCommand {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let policy = try options.policyURL.map(loadPolicy) ?? LampAgentAccessPolicy()
            let library = LampAgentLibrary(
                libraryRootURL: options.libraryRootURL,
                bundledModulesArchiveURL: options.bundledModulesArchiveURL,
                policy: policy
            )
            if options.healthCheck {
                let modules = try await library.listModules()
                let result = HealthCheckResult(
                    status: "ok",
                    moduleCount: modules.count,
                    moduleKinds: Array(Set(modules.map { $0.kind.rawValue })).sorted()
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(result))
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }
            try await LampMCPServerFactory.runStdio(
                library: library,
                policyURL: options.policyURL
            )
        } catch {
            FileHandle.standardError.write(Data("lamp-mcp: \(error.localizedDescription)\n".utf8))
            exit(64)
        }
    }

    private static func loadPolicy(from url: URL) throws -> LampAgentAccessPolicy {
        try JSONDecoder().decode(LampAgentAccessPolicy.self, from: Data(contentsOf: url))
    }
}

private struct HealthCheckResult: Codable {
    let status: String
    let moduleCount: Int
    let moduleKinds: [String]
}

private struct Options {
    let libraryRootURL: URL
    let bundledModulesArchiveURL: URL?
    let policyURL: URL?
    let healthCheck: Bool

    init(arguments: [String]) throws {
        var libraryRootURL: URL?
        var bundledModulesArchiveURL: URL?
        var policyURL: URL?
        var healthCheck = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--library-root":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                libraryRootURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--bundled-modules-archive":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                bundledModulesArchiveURL = URL(fileURLWithPath: arguments[index])
            case "--policy":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                policyURL = URL(fileURLWithPath: arguments[index])
            case "--health-check":
                healthCheck = true
            case "--help", "-h":
                throw OptionError.help
            default:
                throw OptionError.unknown(argument)
            }
            index += 1
        }
        guard let libraryRootURL else { throw OptionError.missingLibraryRoot }
        self.libraryRootURL = libraryRootURL
        self.bundledModulesArchiveURL = bundledModulesArchiveURL
        self.policyURL = policyURL
        self.healthCheck = healthCheck
    }
}

private enum OptionError: Error, LocalizedError {
    case help
    case missingLibraryRoot
    case missingValue(String)
    case unknown(String)

    var errorDescription: String? {
        let usage = "Usage: lamp-mcp --library-root PATH [--bundled-modules-archive PATH] [--policy PATH] [--health-check]"
        switch self {
        case .help: return usage
        case .missingLibraryRoot: return "Missing --library-root. \(usage)"
        case .missingValue(let option): return "Missing value for \(option). \(usage)"
        case .unknown(let option): return "Unknown option \(option). \(usage)"
        }
    }
}
