import Foundation
import Testing
@testable import LampBibleMac
@testable import LampBibleMacSupport

/// A Codex writing chat is given Lamp's server as Lamp makes it, from the
/// workspace's path, never from a file in the workspace, which the agent can
/// change: a server named there would be started outside the sandbox.
@MainActor
struct WritingChatServerTests {
    private let helper = URL(fileURLWithPath: "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp")

    @Test func aWritingsServerIsMadeFromWhereItsWorkspaceIs() throws {
        let workspace = URL(fileURLWithPath: "/Users/Reader/Lamp Bible/Library/AgentWorkspaces/Writing/talk-1a2b", isDirectory: true)
        let made = try #require(WritingChatTurns.mcpConfiguration(forWorkspace: workspace, helperExecutableURL: helper))
        #expect(made.helperExecutableURL == helper)
        #expect(made.libraryRootURL.path == "/Users/Reader/Lamp Bible/Library")
        #expect(made.policyURL.path == "/Users/Reader/Lamp Bible/AgentAccessPolicy.json")
        #expect(made.workspaceURL == workspace)
        #expect(made.arguments.contains(workspace.path))
    }

    @Test func aFolderThatIsNoWritingsWorkspaceGetsNoServer() {
        for path in ["/tmp/somewhere", "/tmp/library/AgentWorkspaces/Reader/chat", "/tmp/library/Writing/talk"] {
            #expect(WritingChatTurns.mcpConfiguration(forWorkspace: URL(fileURLWithPath: path), helperExecutableURL: helper) == nil)
        }
        // And none without the helper in the app.
        #expect(WritingChatTurns.mcpConfiguration(
            forWorkspace: URL(fileURLWithPath: "/tmp/library/AgentWorkspaces/Writing/talk"), helperExecutableURL: nil
        ) == nil)
    }

    @Test func aServerNamedInTheWorkspacesOwnFilesIsNotTheOneGiven() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Library/AgentWorkspaces/Writing/talk", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        // What an agent might write over Lamp's own file.
        try Data(#"{"mcpServers":{"lamp":{"command":"/tmp/not-lamp","args":["--anything"]}}}"#.utf8)
            .write(to: workspace.appendingPathComponent(".mcp.json"))
        let made = WritingChatTurns.mcpConfiguration(forWorkspace: workspace, helperExecutableURL: helper)
        let arguments = AgentChatLaunchArguments.make(
            provider: .codex, prompt: "Write", sessionID: nil, proposedSessionID: nil, writingServer: made
        )
        let override = try #require(arguments.firstIndex(of: "-c").map { arguments[$0 + 1] })
        #expect(override.contains(helper.path))
        #expect(!override.contains("/tmp/not-lamp"))
        #expect(!override.contains("--anything"))
    }
}
