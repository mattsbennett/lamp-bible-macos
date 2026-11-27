import Foundation
import Testing
@testable import LampBibleMacSupport

/// Before the Terminal opens, Lamp puts to the person whatever a provider
/// would read from the writing that Lamp can't vouch for (`decisions/0032`):
/// an allow-list, failing closed, the answer held to the bytes shown.
struct AgentTerminalLaunchCheckTests {
    private func workspace() throws -> (URL, LampAgentMCPConfiguration, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/tmp/library"),
            policyURL: URL(fileURLWithPath: "/tmp/policy.json"),
            workspaceURL: root
        )
        try server.restoreProviderConfigurations(in: root)
        // A bundled skill as Lamp ships it, installed as Lamp installs it.
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try write("---\nname: build-lamp-deck\ndescription: Decks.\n---\nBuild a deck.\n", "bundle/build-lamp-deck/SKILL.md", in: root)
        try write("Reference.\n", "bundle/build-lamp-deck/references/deck-format.md", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("build-lamp-deck"), to: root.appendingPathComponent(".claude/skills/build-lamp-deck"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".agents/skills"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("build-lamp-deck"), to: root.appendingPathComponent(".agents/skills/build-lamp-deck"))
        return (root, server, bundle)
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func findings(_ root: URL, _ server: LampAgentMCPConfiguration, _ bundle: URL, baseline: [String]? = []) -> [AgentTerminalLaunchCheck.Finding] {
        AgentTerminalLaunchCheck.findings(in: root, lampServer: server, bundledSkills: bundle, baseline: baseline)
    }

    @Test func aWritingAsLampAndClaudeLeaveItRaisesNothing() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // A plain custom skill, as Lamp writes one.
        try write("---\nname: my-notes\ndescription: \"Notes.\"\n---\n\nTake notes.\n", ".claude/skills/my-notes/SKILL.md", in: root)
        // As Claude writes it: servers approved, a style, a rule from a session.
        try write(#"{"enabledMcpjsonServers":["lamp"],"enableAllProjectMcpServers":true,"outputStyle":"Explanatory","permissions":{"allow":["Bash(sw_vers)"],"deny":["Bash(rm *)"]}}"#,
                  ".claude/settings.local.json", in: root)
        #expect(findings(root, server, bundle, baseline: ["allow Bash(sw_vers)"]).map(\.path) == [], "\(findings(root, server, bundle, baseline: ["allow Bash(sw_vers)"]))")
    }

    @Test func whatLampDidNotPutThereIsFoundWithWhatItHolds() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch /tmp/x"}]}]}}"#, ".claude/settings.json", in: root)
        try write(#"{"futureKey":{"run":"make"},"permissions":{"allow":["Bash"],"defaultMode":"bypassPermissions","additionalDirectories":["/"]}}"#,
                  ".claude/settings.local.json", in: root)
        for path in ["opencode.jsonc", ".opencode/opencode.json", ".opencode/plugin/x.js", ".opencode/tool/x.ts",
                     ".claude/agents/x.md", ".claude/commands/x.md", ".codex/hooks.json", ".agents/mcp_config.json", ".MCP.JSON.bak"] {
            try write("x", path, in: root)
        }
        // Lamp's own files, changed.
        try write(#"{"mcpServers":{"planted":{"command":"/bin/sh"}}}"#, ".mcp.json", in: root)
        // A built-in skill with one line changed, or a key added.
        try write("---\nname: build-lamp-deck\ndescription: Decks.\n  hooks:\n---\nBuild a deck.\n", ".claude/skills/build-lamp-deck/SKILL.md", in: root)
        try write("---\nname: my-notes\ndescription: \"Notes.\"\nallowed-tools: Bash\n---\n\nTake notes.\n", ".agents/skills/my-notes/SKILL.md", in: root)
        let found = findings(root, server, bundle)
        let paths = Set(found.map(\.path))
        for path in [".claude/settings.json", ".claude/settings.local.json", "opencode.jsonc", ".opencode/opencode.json",
                     ".opencode/plugin/x.js", ".opencode/tool/x.ts", ".claude/agents/x.md", ".claude/commands/x.md",
                     ".codex/hooks.json", ".agents/mcp_config.json", ".mcp.json",
                     ".claude/skills/build-lamp-deck/SKILL.md", ".agents/skills/my-notes/SKILL.md"] {
            #expect(paths.contains(path), "\(path)")
        }
        let local = found.filter { $0.path == ".claude/settings.local.json" }.map(\.detail)
        // An unknown setting, with its value: the test that it is an allow-list.
        #expect(local.contains(#"the setting futureKey: {"run":"make"}"#))
        #expect(local.contains("the permission setting defaultMode: bypassPermissions"))
        #expect(local.contains("added outside a Terminal session: allow Bash"))
        #expect(local.contains("added outside a Terminal session: folder /"))
        // A small file is shown whole.
        #expect(found.first { $0.path == ".claude/settings.json" }?.detail.contains("touch /tmp/x") == true)
        // Only the folders a provider reads.
        #expect(!paths.contains(".MCP.JSON.bak"))
    }

    @Test func aLinkIsFoundAndNeverFollowed() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".claude/settings.json").path, withDestinationPath: "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".OpenCode").path, withDestinationPath: "/tmp")
        let found = findings(root, server, bundle)
        #expect(found.contains { $0.path == ".claude/settings.json" && $0.detail == "a link to /etc/hosts" })
        #expect(found.contains { $0.path == ".OpenCode" && $0.detail == "a link to /tmp" })
        #expect(!found.contains { $0.detail.contains("localhost") })
    }

    @Test func anAnswerHoldsForExactlyTheBytesShown() throws {
        let (root, server, bundle) = try workspace()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("checks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: state) }
        try write(#"{"env":{"A":"1"}}"#, ".claude/settings.json", in: root)
        let first = findings(root, server, bundle)
        #expect(!AgentTerminalLaunchCheck.isApproved(first, for: root, in: state))
        try AgentTerminalLaunchCheck.approve(first, for: root, in: state)
        #expect(AgentTerminalLaunchCheck.isApproved(findings(root, server, bundle), for: root, in: state))
        // One byte changed, as it would be behind the prompt: asked again.
        try write(#"{"env":{"A":"2"}}"#, ".claude/settings.json", in: root)
        #expect(!AgentTerminalLaunchCheck.isApproved(findings(root, server, bundle), for: root, in: state))
        // Taken away, nothing is left to ask about.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude/settings.json"))
        #expect(AgentTerminalLaunchCheck.isApproved(findings(root, server, bundle), for: root, in: state))
    }

    @Test func rulesClaudeSavedInASessionAreItsOwn() throws {
        let (root, server, bundle) = try workspace()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("checks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: state) }
        try write(#"{"permissions":{"allow":["Bash(npm test)"]}}"#, ".claude/settings.local.json", in: root)
        #expect(AgentTerminalLaunchCheck.baseline(for: root, in: state) == nil)
        // As a session ends, what it saved is the writing's own.
        try AgentTerminalLaunchCheck.recordBaseline(in: root, file: state)
        #expect(findings(root, server, bundle, baseline: AgentTerminalLaunchCheck.baseline(for: root, in: state)).isEmpty)
        // One added after it, by anyone else, is found.
        try write(#"{"permissions":{"allow":["Bash(npm test)","Bash"]}}"#, ".claude/settings.local.json", in: root)
        #expect(findings(root, server, bundle, baseline: AgentTerminalLaunchCheck.baseline(for: root, in: state)).map(\.detail)
            == ["added outside a Terminal session: allow Bash"])
    }

    @Test func lampsFilesAreRestoredOnlyInsideTheWorkspace() throws {
        let (root, server, _) = try workspace()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".codex"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".codex"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try server.restoreProviderConfigurations(in: root) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("config.toml").path))
        // A file that isn't one is not written over either.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".codex"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".mcp.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mcp.json"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try server.restoreProviderConfigurations(in: root) }
    }

    /// A linked skills folder is never written through, and a linked local
    /// settings file gives no rules to trust.
    @Test func linkedFoldersAreNeitherRefreshedThroughNorTrusted() throws {
        let (root, _, _) = try workspace()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("checks-\(UUID().uuidString).json")
        defer { for made in [root, outside, state] { try? FileManager.default.removeItem(at: made) } }
        #expect(AgentTerminalLaunchCheck.skillFoldersArePlain(in: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".agents/skills"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".agents/skills"), withDestinationURL: outside)
        #expect(!AgentTerminalLaunchCheck.skillFoldersArePlain(in: root))

        try write(#"{"permissions":{"allow":["Bash"]}}"#, "planted.json", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".claude/settings.local.json"), withDestinationURL: outside.appendingPathComponent("planted.json")
        )
        try AgentTerminalLaunchCheck.recordBaseline(in: root, file: state)
        #expect(AgentTerminalLaunchCheck.baseline(for: root, in: state) == [])
    }

    /// What couldn't be looked at is marked so, and no answer covers it.
    @Test func aScanThatCouldNotFinishIsMarkedIncomplete() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let shut = root.appendingPathComponent(".opencode/shut", isDirectory: true)
        try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shut.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shut.path) }
        let found = AgentTerminalLaunchCheck.findings(in: root, lampServer: server, bundledSkills: bundle, baseline: [])
        #expect(found.contains { $0.path == ".opencode/shut" && $0.isIncomplete })
    }
}
