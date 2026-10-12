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
            if let deckURL = options.renderDeckURL {
                try await renderDeck(deckURL, options: options)
                return
            }
            // Every mode but `--render-deck` serves a library, and `Options`
            // has already refused the combination that lacks one.
            guard let libraryRootURL = options.libraryRootURL else {
                throw OptionError.missingLibraryRoot
            }
            let policy = try options.policyURL.map(loadPolicy) ?? LampAgentAccessPolicy()
            let library = LampAgentLibrary(
                libraryRootURL: libraryRootURL,
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

    /// Draws a deck's slides to PNGs and prints what the drawing showed.
    @MainActor
    private static func renderDeck(_ deckURL: URL, options: Options) async throws {
        let report = try await LampDeckPreview.render(
            deckURL: deckURL,
            outputDirectory: options.outputURL
                ?? deckURL.deletingLastPathComponent()
                    .appendingPathComponent("presentation-preview", isDirectory: true),
            libraryRoot: options.libraryRootURL,
            slideNumbers: options.slideNumbers,
            width: options.renderWidth
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
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
    let libraryRootURL: URL?
    let bundledModulesArchiveURL: URL?
    let policyURL: URL?
    let healthCheck: Bool
    let renderDeckURL: URL?
    let outputURL: URL?
    let slideNumbers: [Int]?
    let renderWidth: Double

    init(arguments: [String]) throws {
        var libraryRootURL: URL?
        var bundledModulesArchiveURL: URL?
        var policyURL: URL?
        var healthCheck = false
        var renderDeckURL: URL?
        var outputURL: URL?
        var slideNumbers: [Int]?
        var renderWidth = 1_600.0
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
            case "--render-deck":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                renderDeckURL = URL(fileURLWithPath: arguments[index])
            case "--output":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                outputURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--slides":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                let parsed = arguments[index]
                    .split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !parsed.isEmpty else {
                    throw OptionError.invalidValue(argument, "Use slide numbers such as 1,3,5.")
                }
                slideNumbers = parsed
            case "--width":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                guard let parsed = Double(arguments[index]), parsed >= 320, parsed <= 4_096 else {
                    throw OptionError.invalidValue(argument, "Use a width between 320 and 4096.")
                }
                renderWidth = parsed
            case "--help", "-h":
                throw OptionError.help
            default:
                throw OptionError.unknown(argument)
            }
            index += 1
        }
        // Rendering a deck reads the deck and the images beside it, so it needs
        // no library; every other mode serves one.
        if renderDeckURL == nil && libraryRootURL == nil {
            throw OptionError.missingLibraryRoot
        }
        self.libraryRootURL = libraryRootURL
        self.bundledModulesArchiveURL = bundledModulesArchiveURL
        self.policyURL = policyURL
        self.healthCheck = healthCheck
        self.renderDeckURL = renderDeckURL
        self.outputURL = outputURL
        self.slideNumbers = slideNumbers
        self.renderWidth = renderWidth
    }
}

private enum OptionError: Error, LocalizedError {
    case help
    case missingLibraryRoot
    case missingValue(String)
    case invalidValue(String, String)
    case unknown(String)

    var errorDescription: String? {
        let usage = """
        Usage: lamp-mcp --library-root PATH [--bundled-modules-archive PATH] [--policy PATH] [--health-check]
               lamp-mcp --render-deck PATH [--output DIR] [--slides 1,3,5] [--width 1600] [--library-root PATH]
        """
        switch self {
        case .help: return usage
        case .missingLibraryRoot: return "Missing --library-root. \(usage)"
        case .missingValue(let option): return "Missing value for \(option). \(usage)"
        case .invalidValue(let option, let detail): return "Invalid value for \(option). \(detail)"
        case .unknown(let option): return "Unknown option \(option). \(usage)"
        }
    }
}
