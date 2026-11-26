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

    /// Without this the server has no workspace, and `writing_changes` has no
    /// history to read — so an agent is back to keeping its own copies of the
    /// draft to compare.
    @Test func namesTheWorkspaceSoTheWritingHistoryCanBeRead() {
        let workspace = URL(fileURLWithPath: "/Users/Reader/Lamp Library/AgentWorkspaces/Writing/talk", isDirectory: true)
        let withWorkspace = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/tmp/library"),
            policyURL: URL(fileURLWithPath: "/tmp/policy.json"),
            workspaceURL: workspace
        )
        #expect(withWorkspace.arguments.contains("--workspace"))
        #expect(withWorkspace.arguments.contains(workspace.path))
        #expect(withWorkspace.codexTOML.contains(workspace.path))

        // A reader chat has no writing, so it names no workspace.
        let reader = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/tmp/library"),
            policyURL: URL(fileURLWithPath: "/tmp/policy.json")
        )
        #expect(!reader.arguments.contains("--workspace"))
    }

    /// Codex reads a project's own settings only in a folder the person
    /// trusted, and a writing workspace is not one, so a Codex writing chat
    /// is given Lamp's server on its command line, approved, since
    /// `codex exec` cannot ask; built from Lamp's configuration, never the
    /// workspace's files. The project file stays "auto", for the Codex
    /// terminal, which can ask.
    @Test func codexIsGivenLampsServerApprovedInEveryHeadlessChat() throws {
        let workspace = URL(fileURLWithPath: "/tmp/library/AgentWorkspaces/Writing/talk", isDirectory: true)
        let configuration = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/tmp/library"),
            policyURL: URL(fileURLWithPath: "/tmp/policy.json"),
            workspaceURL: workspace
        )
        #expect(configuration.codexTOML.contains(#"default_tools_approval_mode = "auto""#))

        let writing = AgentChatLaunchArguments.make(
            provider: .codex, prompt: "Write", sessionID: "thread-1", proposedSessionID: nil, writingServer: configuration
        )
        let override = try #require(writing.firstIndex(of: "-c").map { writing[$0 + 1] })
        #expect(override.hasPrefix(#"mcp_servers.lamp={command="/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp""#))
        #expect(override.contains(workspace.path))
        #expect(override.contains(#"default_tools_approval_mode="approve""#))
        // Before `resume`, which takes the flags after it as its own.
        let resume = try #require(writing.firstIndex(of: "resume"))
        #expect(writing.firstIndex(of: "-c")! < resume)
        // Without a server Lamp made, none is named.
        #expect(!AgentChatLaunchArguments.make(
            provider: .codex, prompt: "Write", sessionID: nil, proposedSessionID: nil
        ).contains("-c"))

        // A reader chat's own server, approved too, and no rules read.
        let reader = AgentChatLaunchArguments.make(
            provider: .codex, prompt: "Read", sessionID: nil, proposedSessionID: nil, mode: .reader(configuration)
        )
        #expect(reader.contains { $0.hasPrefix("mcp_servers={lamp=") && $0.contains(#"default_tools_approval_mode="approve""#) })
        #expect(reader.contains("--ignore-rules"))
        #expect(!writing.contains("--ignore-rules"))
        // Except on a Codex too old to take it, which would refuse the chat.
        #expect(!AgentChatLaunchArguments.make(
            provider: .codex, prompt: "Read", sessionID: nil, proposedSessionID: nil,
            mode: .reader(configuration), codexIgnoresRules: false
        ).contains("--ignore-rules"))
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
