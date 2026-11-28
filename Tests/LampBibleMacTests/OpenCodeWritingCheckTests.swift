import Foundation
import LampBibleMacSupport
import Testing
@testable import LampBibleMac

/// An OpenCode writing turn runs only on settings checked for it, as a
/// Terminal opens only on settings checked for it (`decisions/0043`).
@MainActor
@Suite(.serialized)
struct OpenCodeWritingCheckTests {
    /// `<library>/AgentWorkspaces/Writing/<writing>`, as Lamp lays it out.
    private func writing() throws -> (library: URL, workspace: URL) {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("oc-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        let workspace = library.appendingPathComponent("AgentWorkspaces/Writing/w", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (library, workspace)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func finding(_ path: String, incomplete: Bool = false) -> AgentTerminalLaunchCheck.Finding {
        .init(path: path, fingerprint: incomplete ? "incomplete" : "f", detail: "")
    }

    @Test func onlyWhatOpenCodeReadsIsAskedAbout() {
        for path in ["opencode.json", "OpenCode.JSONC", ".opencode/plugin/x.js", ".OPENCODE", ".claude/skills/x/SKILL.md", ".agents/skills", ".claude", ".agents"] {
            #expect(AgentTerminalLaunchCheck.openCodeReads(finding(path)), "\(path)")
        }
        for path in [".claude/settings.local.json", ".claude/settings", ".codex/config.toml", ".mcp.json", ".agents/mcp_config.json", ".claude/skillsx"] {
            #expect(!AgentTerminalLaunchCheck.openCodeReads(finding(path)), "\(path)")
        }
        #expect(AgentTerminalLaunchCheck.openCodeReads(finding(".claude", incomplete: true)))
    }

    /// OpenCode reads its settings in every folder above the one it runs in.
    @Test func settingsAboveTheWritingInsideTheLibraryAreFound() throws {
        let (library, workspace) = try writing()
        #expect(AgentTerminalLaunchCheck.openCodeAncestorFindings(of: workspace).isEmpty)
        try write("{\"mcp\":{}}", to: library.appendingPathComponent("opencode.jsonc"))
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("AgentWorkspaces/Writing/.opencode"), withIntermediateDirectories: true
        )
        let found = AgentTerminalLaunchCheck.openCodeAncestorFindings(of: workspace)
        #expect(Set(found.map(\.path)) == ["../.opencode", "../../../opencode.jsonc"])
        // A folder can't be vouched for; a file is shown whole.
        #expect(found.first { $0.path == "../.opencode" }?.isIncomplete == true)
        #expect(found.first { $0.path == "../../../opencode.jsonc" }?.detail == "{\"mcp\":{}}")
        // Above the library is the person's own.
        try write("{}", to: library.deletingLastPathComponent().appendingPathComponent("opencode.json"))
        #expect(AgentTerminalLaunchCheck.openCodeAncestorFindings(of: workspace).count == 2)
    }

    @Test func aPlantedSettingStopsTheTurn() async throws {
        let (_, workspace) = try writing()
        #expect(await WritingChatTurns.checkOpenCode(in: workspace) == .clear)
        try write("{\"plugin\":[\"./x.js\"]}", to: workspace.appendingPathComponent("opencode.jsonc"))
        try write("export default {}", to: workspace.appendingPathComponent(".opencode/plugin/x.js"))
        // Claude's settings are Claude's: not asked about here.
        try write("{\"permissions\":{\"allow\":[\"Bash(make)\"]}}", to: workspace.appendingPathComponent(".claude/settings.local.json"))
        guard case .refused(let words, let paths) = await WritingChatTurns.checkOpenCode(in: workspace) else {
            Issue.record("expected the turn stopped")
            return
        }
        #expect(paths.sorted() == [".opencode/plugin/x.js", "opencode.jsonc"])
        #expect(words.contains("opencode.jsonc") && words.contains("~/.config/opencode"))
    }

    /// Nothing of the writing's is approved for an OpenCode chat, a setting
    /// whose code is elsewhere (Codex's round 5) and an empty one alike.
    @Test func noSettingOfTheWritingsIsTakenForOpenCodeHoweverSmall() async throws {
        for body in [#"{"plugin":["/tmp/elsewhere/plugin.js"]}"#, "{}"] {
            let (_, workspace) = try writing()
            try write(body, to: workspace.appendingPathComponent("opencode.jsonc"))
            guard case .refused(_, let paths) = await WritingChatTurns.checkOpenCode(in: workspace) else {
                Issue.record("expected \(body) refused")
                continue
            }
            #expect(paths == ["opencode.jsonc"])
        }
    }

    /// A skill as plain as Lamp writes one passes; one carrying a script
    /// beside its words doesn't.
    @Test func aPlainSkillPassesAndOneWithAScriptDoesNot() async throws {
        let (library, workspace) = try writing()
        // As the writing's pane adds one: saved in the library, enabled here.
        try await DevotionalAgentWorkspaceStore.writeSkill(
            name: "notes", description: "Notes.", instructions: "Words.", to: workspace, libraryRootURL: library
        )
        #expect(await WritingChatTurns.checkOpenCode(in: workspace) == .clear)
        try write("echo hi", to: workspace.appendingPathComponent(".claude/skills/notes/run.sh"))
        guard case .refused(_, let paths) = await WritingChatTurns.checkOpenCode(in: workspace) else {
            Issue.record("expected the turn refused")
            return
        }
        #expect(paths.contains { $0.hasPrefix(".claude/skills/notes") })
    }

    /// Lamp's skills as Lamp installs them pass, a stale or retired copy
    /// brought up to date by the install a writing's preparation runs.
    @Test func lampsOwnSkillsPassOnceInstalled() async throws {
        let catalog = try #require(LampBundledSkills.catalogURL)
        let (_, workspace) = try writing()
        let names = WorkspaceSkillStore.bundledSkillNames
        let stale = workspace.appendingPathComponent(".claude/skills/\(names.sorted()[0])/SKILL.md")
        try write("an older Lamp's words", to: stale)
        try WorkspaceSkillStore.installBundledSkills(named: names, from: catalog, intoSkillDirectoriesOf: workspace)
        #expect(await WritingChatTurns.checkOpenCode(in: workspace) == .clear)
    }

    @Test func aLinkWhereTheSettingsShouldBeStopsTheTurn() async throws {
        let (library, workspace) = try writing()
        try write("{}", to: library.appendingPathComponent("elsewhere.json"))
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("opencode.json"), withDestinationURL: library.appendingPathComponent("elsewhere.json")
        )
        // Refused, not put to the person: what a link leads to can change
        // unasked, and OpenCode rereads it at every request.
        guard case .refused(let words, _) = await WritingChatTurns.checkOpenCode(in: workspace) else {
            Issue.record("expected the turn refused")
            return
        }
        #expect(words.contains("opencode.json"))
    }

    /// An OpenCode turn writes OpenCode's file alone: another provider's it
    /// can't write doesn't stop it.
    @Test func anOpenCodeTurnRestoresOnlyOpenCodesFile() throws {
        let (library, workspace) = try writing()
        let server = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/usr/bin/true"), libraryRootURL: library,
            policyURL: library.appendingPathComponent("policy.json"), workspaceURL: workspace
        )
        try server.restoreProviderConfigurations(in: workspace, only: [.openCode])
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("opencode.json").path))
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".mcp.json").path))
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".codex/config.toml").path))
    }

    /// A wait's notice has a name of its own, so taking it back leaves the
    /// chat's end notice alone.
    @Test func aWaitNoticeHasItsOwnName() {
        let context = AgentTurnNotificationContext(title: "Talk", route: .writing("w"))
        #expect(AgentTurnNotifications.waitIdentifier(context, provider: "codex") != context.route.notificationIdentifier)
        #expect(AgentTurnNotifications.waitIdentifier(context, provider: "codex") != AgentTurnNotifications.waitIdentifier(context, provider: "openCode"))
    }

    /// Clear once, for the next send only, and only if nothing began since.
    @Test func aCheckIsForTheNextTurnAlone() async throws {
        let (_, workspace) = try writing()
        #expect(!KeptAgentChats.takeOpenCodeCheck(in: workspace))
        #expect(await WritingChatTurns.checkOpenCode(in: workspace) == .clear)
        #expect(KeptAgentChats.takeOpenCodeCheck(in: workspace))
        #expect(!KeptAgentChats.takeOpenCodeCheck(in: workspace), "once only")
        #expect(await WritingChatTurns.checkOpenCode(in: workspace) == .clear)
        KeptAgentChats.noteTurnBegun(in: workspace)
        #expect(!KeptAgentChats.takeOpenCodeCheck(in: workspace), "a turn begun since")
    }

    /// The chat model is the last line: unchecked, an OpenCode writing turn
    /// doesn't start, whoever asked.
    @Test func anUncheckedOpenCodeWritingTurnSendsNothing() async throws {
        let (_, workspace) = try writing()
        let model = KeptAgentChats.model(provider: .openCode, workspace: workspace, mode: .writing)
        defer { KeptAgentChats.drop(model) }
        let taken = await model.send("Hello", contextualPrompt: "Hello", inConversation: model.conversationID)
        #expect(!taken)
        #expect(!model.isRunning)
        #expect(model.errorMessage?.contains("OpenCode wasn’t started") == true)
    }

    /// Only what OpenCode reads is walked, so a large folder of Claude's
    /// neither shows nor spends the scan's limit.
    @Test func aLargeClaudeFolderDoesNotStopAnOpenCodeTurn() async throws {
        let (_, workspace) = try writing()
        let worktrees = workspace.appendingPathComponent(".claude/worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        for index in 0..<5_100 { FileManager.default.createFile(atPath: worktrees.appendingPathComponent("f\(index)").path, contents: nil) }
        #expect(await WritingChatTurns.checkOpenCode(in: workspace) == .clear)
    }

    @Test func aClaudeFolderAboveTheWritingStopsTheTurn() async throws {
        let (library, workspace) = try writing()
        try write("x", to: library.appendingPathComponent("AgentWorkspaces/.claude/skills/x/SKILL.md"))
        guard case .refused(let words, _) = await WritingChatTurns.checkOpenCode(in: workspace) else {
            Issue.record("expected the turn refused")
            return
        }
        #expect(words.contains("../.claude"))
    }

    /// A Terminal of any provider running in the writing: OpenCode doesn't
    /// start beside it.
    @Test func anOpenCodeTurnDoesNotStartBesideAnyTerminal() async throws {
        let (_, workspace) = try writing()
        let launch = UUID()
        AgentTerminalHolds.shared.begin(launch, in: workspace, holdsChats: false)
        defer { AgentTerminalHolds.shared.dropIfNotStarted(launch) }
        #expect(!AgentTerminalHolds.shared.isHeld(in: workspace))
        guard case .refused = await WritingChatTurns.checkOpenCode(in: workspace) else {
            Issue.record("expected the turn refused")
            return
        }
    }

    /// Noted at the count from before the check began, so a turn begun
    /// while it ran makes it stale.
    @Test func aCheckIsStaleOnceATurnBeganWhileItRan() throws {
        let (_, workspace) = try writing()
        let before = KeptAgentChats.turnsBegun(in: workspace)
        KeptAgentChats.noteTurnBegun(in: workspace)
        KeptAgentChats.noteOpenCodeChecked(in: workspace, at: before)
        #expect(!KeptAgentChats.takeOpenCodeCheck(in: workspace))
    }

    /// Each check lets go only of answers for what it looked at.
    @Test func answersAreLetGoOnlyWithinTheScopeLookedAt() throws {
        let (_, workspace) = try writing()
        let file = workspace.deletingLastPathComponent().appendingPathComponent("approvals.json")
        let above = finding("../opencode.json"), own = finding("opencode.json"), claudes = finding(".claude/settings.local.json")
        try AgentTerminalLaunchCheck.approve([above, own, claudes], for: workspace, in: file)
        // The Terminal's check, which doesn't look above the writing.
        AgentTerminalLaunchCheck.keepApprovals(onlyFor: [claudes], for: workspace, in: file)
        #expect(AgentTerminalLaunchCheck.isApproved([above, claudes], for: workspace, in: file))
        #expect(!AgentTerminalLaunchCheck.isApproved([own], for: workspace, in: file))
        // OpenCode's, which doesn't look at Claude's settings.
        AgentTerminalLaunchCheck.keepApprovals(onlyFor: [], for: workspace, inScope: { path in
            path.hasPrefix("../") || AgentTerminalLaunchCheck.openCodeScope(path)
        }, in: file)
        #expect(AgentTerminalLaunchCheck.isApproved([claudes], for: workspace, in: file))
        #expect(!AgentTerminalLaunchCheck.isApproved([above], for: workspace, in: file))
    }

    /// A queue saved for a chat not yet loaded is held when a Claude
    /// Terminal begins, and the chat takes the hold as it loads.
    @Test func aChatNotYetLoadedTakesTheHoldAsItLoads() throws {
        let (_, workspace) = try writing()
        KeptAgentChats.holdQueues(in: workspace)
        let model = KeptAgentChats.model(provider: .codex, workspace: workspace, mode: .writing)
        defer { KeptAgentChats.drop(model) }
        #expect(model.queueHeld)
    }

    /// End ends the Terminal that holds the chats, not another provider's.
    @Test func endLeavesAnotherProvidersTerminal() throws {
        let (_, workspace) = try writing()
        let claude = UUID(), codex = UUID()
        AgentTerminalHolds.shared.begin(claude, in: workspace)
        AgentTerminalHolds.shared.begin(codex, in: workspace, holdsChats: false)
        defer { AgentTerminalHolds.shared.dropIfNotStarted(codex) }
        AgentTerminalHolds.shared.end(in: workspace)
        #expect(!AgentTerminalHolds.shared.isHeld(in: workspace))
        #expect(AgentTerminalHolds.shared.isPending(codex))
    }

    /// A conversation saved before conversations had ids can still be
    /// allowed for.
    @Test func aChatWithNoConversationIdStillHasAGrantKey() throws {
        let (_, workspace) = try writing()
        let model = KeptAgentChats.model(provider: .codex, workspace: workspace, mode: .writing)
        defer { KeptAgentChats.drop(model) }
        #expect(model.conversationID == nil)
        #expect(model.chatGrantKey != nil)
    }

    /// Above the writing, a file that can't be shown whole can't be approved.
    @Test func aLongFileAboveTheWritingStopsTheTurn() throws {
        let (library, workspace) = try writing()
        try write(String(repeating: "x", count: 5_000), to: library.appendingPathComponent("opencode.json"))
        let found = AgentTerminalLaunchCheck.openCodeAncestorFindings(of: workspace)
        #expect(found.count == 1 && found[0].isIncomplete)
    }

    /// The folders above where OpenCode runs, with a linked parent resolved.
    @Test func theFoldersAboveAreFoundThroughALinkedParent() throws {
        let (library, workspace) = try writing()
        let elsewhere = library.deletingLastPathComponent().appendingPathComponent("Elsewhere/Writing", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try write("{}", to: elsewhere.deletingLastPathComponent().appendingPathComponent("opencode.json"))
        let real = elsewhere.appendingPathComponent("w", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        // AgentWorkspaces/Writing a link to Elsewhere/Writing.
        let linked = library.appendingPathComponent("AgentWorkspaces/Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        let found = AgentTerminalLaunchCheck.openCodeAncestorFindings(of: linked.appendingPathComponent("w"))
        #expect(found.map(\.path).contains("../../opencode.json"))
        _ = workspace
    }

    /// A file in the writing the sheet could show only by its size stops the
    /// turn, rather than be approved unseen.
    @Test func aLongPluginInTheWritingStopsTheTurn() async throws {
        let (_, workspace) = try writing()
        try write(String(repeating: "x", count: 5_000), to: workspace.appendingPathComponent(".opencode/plugin/big.js"))
        guard case .refused(let words, _) = await WritingChatTurns.checkOpenCode(in: workspace) else {
            Issue.record("expected the turn refused")
            return
        }
        #expect(words.contains("big.js"))
    }

    /// Claude's own folder above the writing counts only for its skills.
    @Test func aClaudeFolderAboveWithNoSkillsIsLeftAlone() throws {
        let (library, workspace) = try writing()
        try write("{}", to: library.appendingPathComponent(".claude/settings.json"))
        #expect(AgentTerminalLaunchCheck.openCodeAncestorFindings(of: workspace).isEmpty)
        try FileManager.default.createDirectory(at: library.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        #expect(AgentTerminalLaunchCheck.openCodeAncestorFindings(of: workspace).map(\.path) == ["../../../.claude/skills"])
    }
}
