import Foundation

public struct LampAgentMCPConfiguration: Equatable, Sendable {
    public let helperExecutableURL: URL
    public let libraryRootURL: URL
    public let bundledModulesArchiveURL: URL?
    public let policyURL: URL
    /// The agent workspace this server serves, when it serves one.
    ///
    /// It is what lets `writing_changes` answer: the history of the writing
    /// lives in the workspace, and a server told nothing about one has nothing
    /// to report. A reader chat has no writing, so it passes none.
    public let workspaceURL: URL?
    /// The folder whose installed skills `read_skill` serves, when it is not
    /// the workspace.
    ///
    /// A reader chat's skills are installed in its own folder, and it has no
    /// writing workspace to name, so it names this instead. Started with
    /// neither, `read_skill` has nothing to read: every reader chat was in
    /// that position until this was passed, told by its instructions to call
    /// a tool that could only refuse.
    public let skillsURL: URL?
    /// The reader chat this server answers in, when it answers in one.
    ///
    /// What lets `start_writing` bring the conversation along: the agent
    /// asking is the one in that chat, and it has no way to name the chat
    /// itself, nor should it be trusted to.
    public let readerChatID: UUID?
    /// Which provider the reader chat's helper answers for. A chat can hold a
    /// conversation with each provider, and a writing started from one must
    /// take the conversation that asked for it, not whichever the chat has
    /// moved on to by the time Lamp makes the writing.
    public let readerChatProviderID: String?

    public init(
        helperExecutableURL: URL,
        libraryRootURL: URL,
        bundledModulesArchiveURL: URL? = nil,
        policyURL: URL,
        workspaceURL: URL? = nil,
        skillsURL: URL? = nil,
        readerChatID: UUID? = nil,
        readerChatProviderID: String? = nil
    ) {
        self.helperExecutableURL = helperExecutableURL
        self.libraryRootURL = libraryRootURL
        self.bundledModulesArchiveURL = bundledModulesArchiveURL
        self.policyURL = policyURL
        self.workspaceURL = workspaceURL
        self.skillsURL = skillsURL
        self.readerChatID = readerChatID
        self.readerChatProviderID = readerChatProviderID
    }

    /// This configuration as one provider's helper is started with it: the
    /// same, telling a reader chat's helper whose conversation it serves.
    public func answering(provider providerID: String) -> LampAgentMCPConfiguration {
        guard readerChatID != nil else { return self }
        return LampAgentMCPConfiguration(
            helperExecutableURL: helperExecutableURL,
            libraryRootURL: libraryRootURL,
            bundledModulesArchiveURL: bundledModulesArchiveURL,
            policyURL: policyURL,
            workspaceURL: workspaceURL,
            skillsURL: skillsURL,
            readerChatID: readerChatID,
            readerChatProviderID: providerID
        )
    }

    public var arguments: [String] {
        var result = ["--library-root", libraryRootURL.path]
        if let bundledModulesArchiveURL {
            result += ["--bundled-modules-archive", bundledModulesArchiveURL.path]
        }
        result += ["--policy", policyURL.path]
        if let workspaceURL {
            result += ["--workspace", workspaceURL.path]
        }
        if let skillsURL {
            result += ["--skills", skillsURL.path]
        }
        if let readerChatID {
            result += ["--reader-chat", readerChatID.uuidString]
            if let readerChatProviderID {
                result += ["--reader-chat-provider", readerChatProviderID]
            }
        }
        return result
    }

    public func writeProviderConfigurations(to workspace: URL, readOnly: Bool = false) throws {
        let fileManager = FileManager.default
        let codexDirectory = workspace.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        // Each file is read by one provider only, so each names that one.
        try answering(provider: AgentChatWireProvider.codex.rawValue).codexTOML.write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try answering(provider: AgentChatWireProvider.claude.rawValue).claudeJSON.write(
            to: workspace.appendingPathComponent(".mcp.json"),
            atomically: true,
            encoding: .utf8
        )
        let openCode = answering(provider: AgentChatWireProvider.openCode.rawValue)
        try (readOnly ? openCode.readOnlyOpenCodeJSON : openCode.openCodeJSON).write(
            to: workspace.appendingPathComponent("opencode.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    public var codexTOML: String {
        let encodedArguments = arguments.map(Self.quoted).joined(separator: ", ")
        return """
        # Generated by Lamp Bible. Recreated when this agent workspace opens.
        [mcp_servers.lamp]
        command = \(Self.quoted(helperExecutableURL.path))
        args = [\(encodedArguments)]
        required = true
        startup_timeout_sec = 15
        tool_timeout_sec = 60
        default_tools_approval_mode = "auto"
        """ + "\n"
    }

    public var codexCommandLineOverrides: [String] {
        [
            // Replace the server table so a reader session cannot inherit unrelated
            // writable MCP tools from the user's global coding configuration.
            "-c", "mcp_servers={lamp={command=\(Self.quoted(helperExecutableURL.path)),args=[\(arguments.map(Self.quoted).joined(separator: ", "))],required=true,default_tools_approval_mode=\"auto\"}}",
        ]
    }

    public var claudeJSON: String {
        Self.prettyJSON([
            "mcpServers": [
                "lamp": [
                    "type": "stdio",
                    "command": helperExecutableURL.path,
                    "args": arguments,
                ] as [String: Any],
            ],
        ])
    }

    public var openCodeJSON: String {
        Self.prettyJSON(openCodeConfiguration)
    }

    public var readOnlyOpenCodeJSON: String {
        var configuration = openCodeConfiguration
        configuration["agent"] = [
            "lamp-reader": [
                "description": "Discuss scripture using read-only Lamp module tools",
                "mode": "primary",
                "prompt": ReaderChatContext.instructions,
                "permission": ["*": "deny", "lamp_*": "allow"],
            ] as [String: Any],
        ]
        return Self.prettyJSON(configuration)
    }

    private var openCodeConfiguration: [String: Any] {
        [
            "$schema": "https://opencode.ai/config.json",
            "mcp": [
                "lamp": [
                    "type": "local",
                    "command": [helperExecutableURL.path] + arguments,
                    "enabled": true,
                ] as [String: Any],
            ],
        ]
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
