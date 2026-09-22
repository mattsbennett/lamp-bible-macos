import Foundation
@testable import LampBibleMacSupport
import Testing

struct AgentMCPConfigurationSupportTests {
    @Test func generatesProviderConfigurationsWithSafePaths() throws {
        let configuration = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/Users/Reader/Lamp Library", isDirectory: true),
            bundledModulesArchiveURL: URL(fileURLWithPath: "/Applications/Lamp Bible.app/Contents/Resources/bundled_modules.db.zlib"),
            policyURL: URL(fileURLWithPath: "/Users/Reader/Lamp Bible/Agent Access.json")
        )

        #expect(configuration.codexTOML.contains(#"command = "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp""#))
        let claude = try #require(configuration.claudeJSON.data(using: .utf8))
        let claudeObject = try #require(
            JSONSerialization.jsonObject(with: claude) as? [String: Any]
        )
        let claudeServers = try #require(claudeObject["mcpServers"] as? [String: Any])
        let lamp = try #require(claudeServers["lamp"] as? [String: Any])
        #expect(lamp["command"] as? String == configuration.helperExecutableURL.path)
        #expect((lamp["args"] as? [String])?.contains(configuration.policyURL.path) == true)

        let openCode = try #require(configuration.openCodeJSON.data(using: .utf8))
        let openCodeObject = try #require(
            JSONSerialization.jsonObject(with: openCode) as? [String: Any]
        )
        #expect(openCodeObject["$schema"] as? String == "https://opencode.ai/config.json")
        let openCodeServers = try #require(openCodeObject["mcp"] as? [String: Any])
        let openCodeLamp = try #require(openCodeServers["lamp"] as? [String: Any])
        #expect(openCodeLamp["command"] as? [String] == [configuration.helperExecutableURL.path] + configuration.arguments)
        #expect(openCodeLamp["enabled"] as? Bool == true)
        #expect(openCodeObject["agent"] == nil)
    }

    @Test func writesAllThreeProjectLocalFiles() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-agent-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let configuration = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/tmp/library"),
            policyURL: URL(fileURLWithPath: "/tmp/policy.json")
        )
        try configuration.writeProviderConfigurations(to: workspace)
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".codex/config.toml").path))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".mcp.json").path))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("opencode.json").path))
    }
}
