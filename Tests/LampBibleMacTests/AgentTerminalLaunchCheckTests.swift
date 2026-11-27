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

    private func findings(_ root: URL, _ server: LampAgentMCPConfiguration, _ bundle: URL) -> [AgentTerminalLaunchCheck.Finding] {
        AgentTerminalLaunchCheck.findings(in: root, lampServer: server, bundledSkills: bundle)
    }

    @Test func aWritingAsLampAndClaudeLeaveItRaisesNothing() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // A plain custom skill, as Lamp writes one.
        try write("---\nname: my-notes\ndescription: \"Notes.\"\n---\n\nTake notes.\n", ".claude/skills/my-notes/SKILL.md", in: root)
        // As Claude writes it: servers approved, a style, rules that only
        // restrict, which need no one's say.
        try write(#"{"enabledMcpjsonServers":["lamp"],"enableAllProjectMcpServers":true,"outputStyle":"Explanatory","permissions":{"deny":["Bash(rm *)"],"ask":["WebFetch"]}}"#,
                  ".claude/settings.local.json", in: root)
        #expect(findings(root, server, bundle).map(\.path) == [], "\(findings(root, server, bundle))")
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
        #expect(local.contains("a permission saved for Claude: allow Bash"))
        #expect(local.contains("a permission saved for Claude: folder /"))
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
        // Taken away, nothing is left to ask about, and its approval goes.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude/settings.json"))
        #expect(AgentTerminalLaunchCheck.isApproved(findings(root, server, bundle), for: root, in: state))
        AgentTerminalLaunchCheck.keepApprovals(onlyFor: findings(root, server, bundle), for: root, in: state)
        // Put back as it was approved, it is asked about again.
        try write(#"{"env":{"A":"2"}}"#, ".claude/settings.json", in: root)
        try AgentTerminalLaunchCheck.approve(findings(root, server, bundle), for: root, in: state)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude/settings.json"))
        AgentTerminalLaunchCheck.keepApprovals(onlyFor: findings(root, server, bundle), for: root, in: state)
        try write(#"{"env":{"A":"2"}}"#, ".claude/settings.json", in: root)
        #expect(!AgentTerminalLaunchCheck.isApproved(findings(root, server, bundle), for: root, in: state))
    }

    /// A rule that grants is the person's to keep, however it came: never
    /// trusted for when it appeared. Kept once, the same bytes don't ask
    /// again; several saved together come together.
    @Test func aSavedPermissionIsKeptByThePersonAlone() throws {
        let (root, server, bundle) = try workspace()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("checks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: state) }
        try write(#"{"permissions":{"allow":["Bash(npm test)","Bash(make)","WebSearch"]}}"#, ".claude/settings.local.json", in: root)
        let saved = findings(root, server, bundle)
        #expect(saved.map(\.detail) == [
            "a permission saved for Claude: allow Bash(npm test)",
            "a permission saved for Claude: allow Bash(make)",
            "a permission saved for Claude: allow WebSearch",
        ])
        try AgentTerminalLaunchCheck.approve(saved, for: root, in: state)
        #expect(AgentTerminalLaunchCheck.isApproved(findings(root, server, bundle), for: root, in: state))
        // One more, and only it is new.
        try write(#"{"permissions":{"allow":["Bash(npm test)","Bash(make)","WebSearch","Bash"]}}"#, ".claude/settings.local.json", in: root)
        let now = findings(root, server, bundle)
        #expect(!AgentTerminalLaunchCheck.isApproved(now, for: root, in: state))
        // Shown: only what is new, and as a permission.
        let shown = AgentTerminalLaunchCheck.unapproved(now, for: root, in: state)
        #expect(shown.map(\.detail) == ["a permission saved for Claude: allow Bash"])
        #expect(shown.allSatisfy { $0.isPermission })
        // Kept, the earlier ones stay kept.
        try AgentTerminalLaunchCheck.approve(shown, for: root, in: state)
        #expect(AgentTerminalLaunchCheck.isApproved(findings(root, server, bundle), for: root, in: state))
        // A file that merely says so is no permission.
        try write("a permission saved for Claude: allow Bash", ".claude/notes.txt", in: root)
        #expect(findings(root, server, bundle).first { $0.path == ".claude/notes.txt" }?.isPermission == false)
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
    /// settings file is a finding, never read.
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
        #expect(AgentTerminalLaunchCheck.findings(in: root, lampServer: nil, bundledSkills: nil)
            .contains { $0.path == ".claude/settings.local.json" && $0.detail.hasPrefix("a link to") })
    }

    /// What couldn't be looked at is marked so, and no answer covers it.
    @Test func aScanThatCouldNotFinishIsMarkedIncomplete() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let shut = root.appendingPathComponent(".opencode/shut", isDirectory: true)
        try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shut.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shut.path) }
        let found = AgentTerminalLaunchCheck.findings(in: root, lampServer: server, bundledSkills: bundle)
        #expect(found.contains { $0.path == ".opencode/shut" && $0.isIncomplete })
    }

    /// A string that reads as an object is not the object: an answer for
    /// one doesn't carry to the other.
    @Test func aSettingIsFingerprintedByItsTypedValue() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"futureKey":"{\"a\":1}"}"#, ".claude/settings.local.json", in: root)
        let asText = findings(root, server, bundle).first { $0.path == ".claude/settings.local.json" }
        try write(#"{"futureKey":{"a":1}}"#, ".claude/settings.local.json", in: root)
        let asObject = findings(root, server, bundle).first { $0.path == ".claude/settings.local.json" }
        #expect(asText != nil && asObject != nil)
        #expect(asText?.fingerprint != asObject?.fingerprint)
    }

    /// A plain skill whose description holds `---` is still Lamp's.
    @Test func aPlainSkillWithDashesInItsDescriptionIsLamps() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("---\nname: notes\ndescription: \"Before --- after\"\n---\n\nTake notes.\n", ".claude/skills/notes/SKILL.md", in: root)
        #expect(!findings(root, server, bundle).contains { $0.path.contains("notes") })
    }

    /// A skill folder named as Lamp never names one is not taken for Lamp's.
    @Test func aSkillWithANameLampWouldNotGiveIsNotLamps() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let odd = "notes\u{2028}x"
        try write("---\nname: \(odd)\ndescription: \"N\"\n---\n\nTake notes.\n", ".claude/skills/\(odd)/SKILL.md", in: root)
        #expect(findings(root, server, bundle).contains { $0.path.contains("SKILL.md") && $0.path.contains("notes") })
    }

    /// A Claude launch marks its start in Lamp's own folder, never the
    /// workspace's, and the mark is this launch's.
    @Test func aClaudeLaunchMarksItsStartInLampsFolder() throws {
        let marker = URL(fileURLWithPath: "/Users/Reader/Library/Application Support/Lamp Bible/Terminal Launches/abc/ready-1")
        let settings = try #require(try JSONSerialization.jsonObject(with: AgentTerminalLaunchPlanner.claudeSettings(readyMarker: marker)) as? [String: Any])
        let start = try #require(((settings["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(start.contains { ($0["command"] as? String)?.contains("touch '/Users/Reader/Library/Application Support/Lamp Bible/Terminal Launches/abc/ready-1'") == true })
        // Still capturing as before.
        #expect(start.count >= 2)
    }

    /// A pipe among the settings can't be looked at, so no answer covers it.
    @Test func aSpecialFileIsIncomplete() throws {
        let (root, server, bundle) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mkfifo(root.appendingPathComponent(".claude/settings.json").path, 0o644) == 0)
        #expect(findings(root, server, bundle).contains { $0.path == ".claude/settings.json" && $0.isIncomplete })
    }
}
