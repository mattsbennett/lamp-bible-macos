import Foundation
@testable import LampBibleMacSupport
import Testing

struct ReaderChatSupportTests {
    private var configuration: LampAgentMCPConfiguration {
        LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/tmp/Lamp Library"),
            policyURL: URL(fileURLWithPath: "/tmp/Reader Chat/.lamp/module-policy.json")
        )
    }

    @Test func eachMessageCarriesItsOwnChapterAndTranslation() {
        let first = ReaderChatContext(reference: "John 1", translationID: "kjv", translationName: "King James Version")
        let second = ReaderChatContext(reference: "Romans 8", translationID: "web", translationName: "World English Bible")
        let capturedPrompt = first.prompt(for: "Explain this chapter")
        let nextPrompt = second.prompt(for: "Compare this with Psalm 23")

        #expect(capturedPrompt.contains("Chapter: John 1"))
        #expect(capturedPrompt.contains("Translation module ID: kjv"))
        #expect(!capturedPrompt.contains("Romans 8"))
        #expect(nextPrompt.contains("Chapter: Romans 8"))
        #expect(nextPrompt.contains("Translation module ID: web"))
        #expect(!nextPrompt.contains("John 1"))
        #expect(nextPrompt.hasSuffix("Compare this with Psalm 23"))
    }

    @Test(arguments: [false, true])
    func readerRestrictionsApplyToNewAndResumedSessions(resuming: Bool) {
        let session = resuming ? "existing-session" : nil
        func arguments(_ provider: AgentChatWireProvider) -> [String] {
            AgentChatLaunchArguments.make(
                provider: provider, prompt: "Explain John 1", sessionID: session,
                proposedSessionID: "proposed-session", mode: .reader(configuration)
            )
        }

        let codex = arguments(.codex)
        #expect(value(after: "--sandbox", in: codex) == "read-only")
        #expect(codex.contains("approval_policy=\"never\""))
        #expect(codex.contains(where: { $0.hasPrefix("mcp_servers={lamp={command=") }))
        #expect(!codex.contains("workspace-write"))
        #expect(codex.contains("resume") == resuming)

        let claude = arguments(.claude)
        #expect(value(after: "--permission-mode", in: claude) == "dontAsk")
        #expect(value(after: "--tools", in: claude) == "")
        #expect(value(after: "--allowedTools", in: claude) == "mcp__lamp__*")
        #expect(value(after: "--mcp-config", in: claude) == configuration.claudeJSON)
        #expect(claude.contains("--strict-mcp-config"))
        #expect(!claude.contains("acceptEdits"))
        #expect(value(after: resuming ? "--resume" : "--session-id", in: claude)
            == (resuming ? "existing-session" : "proposed-session"))

        let openCode = arguments(.openCode)
        #expect(value(after: "--agent", in: openCode) == "lamp-reader")
        #expect(openCode.contains("--pure"))
        #expect(openCode.contains("--session") == resuming)
    }

    @Test func writingRetainsEditingAndDefaultProviderTools() {
        let codex = AgentChatLaunchArguments.make(
            provider: .codex, prompt: "Write", sessionID: nil, proposedSessionID: nil
        )
        #expect(value(after: "--sandbox", in: codex) == "workspace-write")
        let claude = AgentChatLaunchArguments.make(
            provider: .claude, prompt: "Write", sessionID: nil, proposedSessionID: nil
        )
        #expect(value(after: "--permission-mode", in: claude) == "acceptEdits")
        #expect(!claude.contains("--tools"))
        let openCode = AgentChatLaunchArguments.make(
            provider: .openCode, prompt: "Write", sessionID: nil, proposedSessionID: nil
        )
        #expect(!openCode.contains("--agent"))
    }

    @Test func readerWorkspacePreservesHistoryAndRestrictsOpenCodeTools() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let windowID = UUID()
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, windowID: windowID)
        #expect(workspace == ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, windowID: windowID))
        #expect(workspace != ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, windowID: UUID()))
        #expect(workspace.path.contains("/AgentWorkspaces/Reader/"))
        try ReaderChatWorkspaceStore.prepare(workspace: workspace, configuration: configuration)
        let transcript = workspace.appendingPathComponent(".lamp/native-chat-codex.json")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("saved conversation".utf8)
        try original.write(to: transcript)
        try ReaderChatWorkspaceStore.prepare(workspace: workspace, configuration: configuration)
        #expect(try Data(contentsOf: transcript) == original)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("draft.md").path))

        let data = try Data(contentsOf: workspace.appendingPathComponent("opencode.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agents = try #require(object["agent"] as? [String: [String: Any]])
        let permissions = try #require(agents["lamp-reader"]?["permission"] as? [String: String])
        #expect(permissions == ["*": "deny", "lamp_*": "allow"])
        let instructions = try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(instructions.contains("read-only conversation"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
