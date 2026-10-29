import Foundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
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
            if let deckURL = options.buildDeckURL {
                try await buildDeck(deckURL, options: options)
                return
            }
            if let deckURL = options.renderDeckURL {
                try await renderDeck(deckURL, options: options)
                return
            }
            // An outside app's config names this helper and nothing more, so
            // what it was not told it reads from the descriptor Lamp keeps.
            // Anything given explicitly still wins: a workspace config that
            // names its own library is not second-guessed.
            let resolved = try options.usesDescriptor ? descriptor() : nil
            // Every mode but `--render-deck` serves a library, and `Options`
            // has already refused the combination that lacks one.
            guard let libraryRootURL = options.libraryRootURL ?? resolved?.libraryRootURL else {
                throw OptionError.missingLibraryRoot
            }
            let policyURL = options.policyURL ?? resolved?.policyURL
            let policy = try policyURL.map(loadPolicy) ?? LampAgentAccessPolicy()
            let library = LampAgentLibrary(
                libraryRootURL: libraryRootURL,
                bundledModulesArchiveURL: options.bundledModulesArchiveURL
                    ?? resolved?.bundledModulesArchiveURL,
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
                libraryRootURL: libraryRootURL,
                policy: policy,
                policyURL: policyURL,
                workspaceURL: options.workspaceURL
            )
        } catch {
            FileHandle.standardError.write(Data("lamp-mcp: \(error.localizedDescription)\n".utf8))
            exit(64)
        }
    }

    /// What Lamp wrote down about its library, for a helper started without
    /// being told where anything is.
    ///
    /// The external switch is checked here rather than by the caller, because
    /// a helper reached this way is being used from outside Lamp whichever
    /// app did the reaching.
    private static func descriptor() throws -> LampAgentDescriptor {
        guard let applicationSupport =
            LampAgentDescriptorStore.defaultApplicationSupportURL() else {
            throw OptionError.missingLibraryRoot
        }
        return try LampAgentDescriptorStore.readForExternalUse(
            inApplicationSupport: applicationSupport
        )
    }

    /// Derives what a deck can derive — its speaker notes and any missing
    /// identifiers — and says what it could not.
    private static func buildDeck(_ deckURL: URL, options: Options) async throws {
        // A chart's values come from a library, so they are filled in only
        // when one was named. Without `--library` the report says so rather
        // than leaving a chart quietly empty.
        let charts = options.libraryRootURL.map { root -> LampDeckChartWorker in
            let library = LampLibrary(rootURL: root)
            return { deck in await library.workingOutCharts(in: deck) }
        }
        let built = try await LampDeckTools.buildFile(
            deckURL: deckURL,
            manuscriptURL: options.manuscriptURL,
            charts: charts
        )
        FileHandle.standardOutput.write(built.json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        // A broken anchor is the one failure worth a non-zero status: it means
        // a slide's notes are no longer the manuscript's.
        if !built.resolved { exit(1) }
    }

    /// Draws a deck's slides to PNGs and prints what the drawing showed.
    @MainActor
    private static func renderDeck(_ deckURL: URL, options: Options) async throws {
        let json = try await LampDeckTools.renderFile(
            deckURL: deckURL,
            outputDirectory: options.outputURL
                ?? deckURL.deletingLastPathComponent()
                    .appendingPathComponent("presentation-preview", isDirectory: true),
            overviewURL: options.overviewURL,
            libraryRoot: options.libraryRootURL,
            manuscriptURL: options.manuscriptURL,
            slideNumbers: options.slideNumbers,
            width: options.renderWidth
        )
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// The access policy, or a refusal that names the file.
    ///
    /// `JSONDecoder`'s own description of a missing key is "The data couldn't
    /// be read because it is missing", which says neither what data nor where
    /// it was. That was tolerable while every caller passed `--policy` itself
    /// and knew the path; a helper started from the descriptor does not, and
    /// nor does the person reading its stderr in another app's log.
    private static func loadPolicy(from url: URL) throws -> LampAgentAccessPolicy {
        guard let data = try? Data(contentsOf: url) else {
            throw OptionError.unreadablePolicy(url, "it could not be opened")
        }
        do {
            return try JSONDecoder().decode(LampAgentAccessPolicy.self, from: data)
        } catch {
            throw OptionError.unreadablePolicy(url, error.localizedDescription)
        }
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
    let buildDeckURL: URL?
    let manuscriptURL: URL?
    let outputURL: URL?
    let overviewURL: URL?
    let slideNumbers: [Int]?
    let renderWidth: Double
    let workspaceURL: URL?
    /// Whether to fill in what wasn't given from the descriptor Lamp writes.
    /// Set by `--external`, and by being started with no arguments at all:
    /// that is what an outside app's config looks like, since a config cannot
    /// hold paths that stay true.
    let usesDescriptor: Bool

    init(arguments: [String]) throws {
        var libraryRootURL: URL?
        var bundledModulesArchiveURL: URL?
        var policyURL: URL?
        var healthCheck = false
        var renderDeckURL: URL?
        var buildDeckURL: URL?
        var manuscriptURL: URL?
        var outputURL: URL?
        var overviewURL: URL?
        var slideNumbers: [Int]?
        var renderWidth = 1_600.0
        var workspaceURL: URL?
        var usesDescriptor = arguments.isEmpty
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
            case "--external":
                usesDescriptor = true
            case "--render-deck":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                renderDeckURL = URL(fileURLWithPath: arguments[index])
            case "--build-deck":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                buildDeckURL = URL(fileURLWithPath: arguments[index])
            case "--manuscript":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                manuscriptURL = URL(fileURLWithPath: arguments[index])
            case "--output":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                outputURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--overview":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                overviewURL = URL(fileURLWithPath: arguments[index])
            case "--workspace":
                index += 1
                guard arguments.indices.contains(index) else { throw OptionError.missingValue(argument) }
                workspaceURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
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
        // no library; every other mode serves one, named here or in the
        // descriptor.
        if renderDeckURL == nil && buildDeckURL == nil && libraryRootURL == nil && !usesDescriptor {
            throw OptionError.missingLibraryRoot
        }
        self.libraryRootURL = libraryRootURL
        self.bundledModulesArchiveURL = bundledModulesArchiveURL
        self.policyURL = policyURL
        self.healthCheck = healthCheck
        self.renderDeckURL = renderDeckURL
        self.buildDeckURL = buildDeckURL
        self.manuscriptURL = manuscriptURL
        self.outputURL = outputURL
        self.overviewURL = overviewURL
        self.slideNumbers = slideNumbers
        self.renderWidth = renderWidth
        self.workspaceURL = workspaceURL
        self.usesDescriptor = usesDescriptor
    }
}

private enum OptionError: Error, LocalizedError {
    case help
    case missingLibraryRoot
    case missingValue(String)
    case invalidValue(String, String)
    case unknown(String)
    case unreadablePolicy(URL, String)

    var errorDescription: String? {
        let usage = """
        Usage: lamp-mcp [--external]
               lamp-mcp --library-root PATH [--bundled-modules-archive PATH] [--policy PATH] [--workspace DIR] [--health-check]
               lamp-mcp --render-deck PATH [--output DIR] [--overview FILE] [--slides 1,3,5] [--width 1600] [--library-root PATH] [--manuscript PATH]
               lamp-mcp --build-deck PATH --manuscript PATH
        """
        switch self {
        case .help: return usage
        case .missingLibraryRoot: return "Missing --library-root. \(usage)"
        case .missingValue(let option): return "Missing value for \(option). \(usage)"
        case .invalidValue(let option, let detail): return "Invalid value for \(option). \(detail)"
        case .unknown(let option): return "Unknown option \(option). \(usage)"
        case .unreadablePolicy(let url, let detail):
            return """
            The access policy at \(url.path) could not be read: \(detail) \
            Re-apply the agent access settings in Lamp to write it again.
            """
        }
    }
}
