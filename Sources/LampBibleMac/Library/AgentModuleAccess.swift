import Foundation
import LampCore

enum AgentModuleAccessScope: String, CaseIterable, Identifiable {
    case enabledModules
    case allInstalledModules

    var id: Self { self }

    var title: String {
        switch self {
        case .enabledModules: "Enabled Modules"
        case .allInstalledModules: "All Installed Modules"
        }
    }
}

enum AgentModuleAccessPreferences {
    static func policy(
        isEnabled: Bool,
        scope: AgentModuleAccessScope,
        includesPersonalContent: Bool,
        modules: [LampInstalledModule],
        hiddenModuleIDs: Set<String>
    ) -> LampAgentAccessPolicy {
        var allowedModuleIDs: Set<String>?
        if scope == .enabledModules {
            allowedModuleIDs = Set(
                modules.lazy.filter { !hiddenModuleIDs.contains($0.id) }.map(\.id)
            )
            if includesPersonalContent {
                allowedModuleIDs?.formUnion([
                    "personal-devotionals", "personal-notes", "personal-highlights",
                ])
            }
        }
        return LampAgentAccessPolicy(
            isEnabled: isEnabled,
            allowedModuleIDs: allowedModuleIDs,
            includesPersonalContent: includesPersonalContent
        )
    }

    static var mcpHelperExecutableURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("lamp-mcp")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if let executable = Bundle.main.executableURL {
            let adjacent = executable.deletingLastPathComponent().appendingPathComponent("lamp-mcp")
            if FileManager.default.isExecutableFile(atPath: adjacent.path) { return adjacent }
        }
        return nil
    }

    static func accessPolicyURL(libraryRootURL: URL) -> URL {
        libraryRootURL.deletingLastPathComponent()
            .appendingPathComponent("AgentAccessPolicy.json")
    }

    @discardableResult
    static func writePolicy(
        _ policy: LampAgentAccessPolicy,
        libraryRootURL: URL
    ) throws -> URL {
        let destination = accessPolicyURL(libraryRootURL: libraryRootURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(policy)
        data.append(0x0A)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func healthCheck(
        policy: LampAgentAccessPolicy,
        libraryRootURL: URL,
        bundledModulesArchiveURL: URL?
    ) async -> String {
        guard let helper = mcpHelperExecutableURL else { return "Helper not installed" }
        do {
            let policyURL = try writePolicy(policy, libraryRootURL: libraryRootURL)
            return await Task.detached(priority: .userInitiated) {
                let process = Process()
                let output = Pipe()
                process.executableURL = helper
                process.arguments = ["--library-root", libraryRootURL.path]
                if let bundledModulesArchiveURL {
                    process.arguments? += ["--bundled-modules-archive", bundledModulesArchiveURL.path]
                }
                process.arguments? += ["--policy", policyURL.path, "--health-check"]
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        return String(decoding: data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let result = try JSONDecoder().decode(HealthCheck.self, from: data)
                    return "Ready — \(result.moduleCount) sources across \(result.moduleKinds.count) kinds"
                } catch {
                    return error.localizedDescription
                }
            }.value
        } catch {
            return error.localizedDescription
        }
    }

    private struct HealthCheck: Decodable {
        let moduleCount: Int
        let moduleKinds: [String]
    }
}
