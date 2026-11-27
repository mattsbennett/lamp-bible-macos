import Foundation
import LampBibleMacSupport
import LampCore
import Testing

/// A request on the Mac's card, as a paired device is shown it and answers
/// it (`decisions/0040`).
struct LampAgentRemoteApprovalHostingTests {
    private func input(_ fields: [String: String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func aCommandIsShownWithItsFolderAndTheAgentsReason() {
        let codex = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: "codex-0", toolName: AgentCodexRun.commandToolName,
            toolInputJSON: input(["command": "blender -b -P build.py", "cwd": "/w", "reason": "It needs the GPU"])
        ), provider: "codex")
        #expect(codex.kind == LampAgentRemoteApproval.command && codex.canAllow)
        #expect(codex.command == "blender -b -P build.py" && codex.folder == "/w" && codex.agentReason == "It needs the GPU")
        #expect(codex.title == "Run a command outside its sandbox" && codex.note?.contains("Outside its sandbox") == true)

        let agy = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: UUID().uuidString, toolName: AgentACPRun.commandToolName, toolInputJSON: input(["command": "ls", "cwd": "/w"])
        ), provider: "antigravity")
        #expect(agy.canAllow && agy.command == "ls" && agy.folder == "/w")

        let claude = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: UUID().uuidString, toolName: "Bash", toolInputJSON: input(["command": "npm test", "description": "Run the tests"])
        ), provider: "claude")
        // With no folder named, Deny-only: a relative path would be read
        // from a folder the phone doesn't show.
        #expect(!claude.canAllow && claude.command == "npm test" && claude.agentReason == "Run the tests")
    }

    /// What a device can't show whole, and every tool call but a command,
    /// it may only deny.
    @Test func whatCantBeShownWholeIsDenyOnly() {
        let hidden = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: "codex-1", toolName: AgentCodexRun.commandToolName, toolInputJSON: input(["command": "echo safe\u{202E}fr- mr"])
        ), provider: "codex")
        #expect(!hidden.canAllow)
        let long = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: "codex-2", toolName: AgentCodexRun.commandToolName,
            toolInputJSON: input(["command": String(repeating: "x", count: LampAgentRemoteApproval.largestAllowedCommand + 1)])
        ), provider: "codex")
        #expect(!long.canAllow)
        let write = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: UUID().uuidString, toolName: "Write", toolInputJSON: input(["file_path": "/w/a.md", "content": "Hello"])
        ), provider: "claude")
        #expect(write.kind == LampAgentRemoteApproval.tool && !write.canAllow && write.command?.contains("/w/a.md") == true)
        let noCommand = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: "codex-3", toolName: AgentCodexRun.commandToolName, toolInputJSON: "{}"
        ), provider: "codex")
        #expect(!noCommand.canAllow)
    }

    /// A device answers from the snapshot it was sent; the host judges it
    /// against its own state. The same id in the next turn, asking something
    /// else, is not what was answered.
    @Test func anAnswerMadeFromTheSnapshotIsTakenOnlyInItsTurn() throws {
        let question = AgentChatTranscript.Message(role: .user, text: "Render it", date: Date(timeIntervalSince1970: 1))
        let request = AgentToolApprovalRequest(
            id: "codex-0", toolName: AgentCodexRun.commandToolName, toolInputJSON: input(["command": "blender -b", "cwd": "/w"])
        )
        let host = LampAgentRemoteHosting.state(
            messages: [question], arriving: "", activity: nil, isRunning: true, failure: nil,
            approvals: [request], provider: "codex"
        )
        let summary = LampAgentRemoteChatSummary(
            id: "writing:w", title: "W", kind: LampAgentRemoteChatSummary.writing, provider: "codex", providerName: "Codex", acceptsMessages: true
        )
        // The device's copy, as sent and decoded.
        let sent = try JSONEncoder().encode(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: host))
        let device = LampAgentRemoteChatView(try JSONDecoder().decode(LampAgentRemoteChatSnapshot.self, from: sent))
        let shown = try #require(device.approvals.first)
        let answer = LampAgentRemoteMessage.answerApproval(shown, in: device.id, turnID: device.turnID, decision: LampAgentRemoteApprovalAnswer.allowOnce)
        func judged(_ state: LampAgentRemoteChatState) -> LampAgentRemoteApprovalAnswer.Outcome {
            LampAgentRemoteApprovalAnswer.decide(
                decision: answer.decision, approvalID: answer.approvalID, digest: answer.approvalDigest,
                shownTurn: answer.turnID, chatID: "writing:w", currentTurn: state.runningTurn, waiting: state.approvals
            )
        }
        #expect(judged(host) == .allowOnce)

        // The next turn's first request has the same id.
        let next = AgentToolApprovalRequest(
            id: "codex-0", toolName: AgentCodexRun.commandToolName, toolInputJSON: input(["command": "rm -rf ~/Documents", "cwd": "/w"])
        )
        let later = LampAgentRemoteHosting.state(
            messages: [question, .init(role: .assistant, text: "Done", date: Date(timeIntervalSince1970: 2)),
                       .init(role: .user, text: "Tidy up", date: Date(timeIntervalSince1970: 3))],
            arriving: "", activity: nil, isRunning: true, failure: nil, approvals: [next], provider: "codex"
        )
        #expect(judged(later) == .gone)
        // Answered on the Mac first: no longer waiting.
        let answered = LampAgentRemoteHosting.state(
            messages: [question], arriving: "", activity: nil, isRunning: true, failure: nil, approvals: [], provider: "codex"
        )
        #expect(judged(answered) == .gone)
    }

    /// Claude's hook says where a command runs beside its input, and
    /// Antigravity gives its own account of one: both reach the phone, the
    /// account as the agent's words.
    @Test func claudesFolderAndAntigravitysAccountReachThePhone() throws {
        let payload = #"{"tool_name":"Bash","tool_input":{"command":"ls ../notes"},"cwd":"/Users/x/Writing/talk"}"#
        let request = try #require(AgentToolApprovalRequest(id: "h1", hookPayload: Data(payload.utf8)))
        let claude = LampAgentRemoteHosting.approval(request, provider: "claude")
        #expect(claude.folder == "/Users/x/Writing/talk" && claude.canAllow)

        let params: [String: Any] = ["toolCall": [
            "kind": "execute",
            "rawInput": ["CommandLine": "sw_vers -productVersion", "toolSummary": "Check macOS product version"],
        ] as [String: Any], "options": [
            ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
            ["optionId": "deny", "name": "Deny", "kind": "reject_once"],
        ]]
        let asked = try #require(AgentACPRun.commandRequest(permission: params, readOnly: false, id: "agy-1"))
        let agy = LampAgentRemoteHosting.approval(asked, provider: "antigravity")
        #expect(agy.command == "sw_vers -productVersion" && agy.agentReason == "Check macOS product version")
        #expect(AgentToolApprovalSummary.of(asked).detail?.contains("Antigravity says: Check macOS product version") == true)
        // A folder that doesn't read as itself makes it Deny-only.
        let hidden = LampAgentRemoteHosting.approval(AgentToolApprovalRequest(
            id: "codex-4", toolName: AgentCodexRun.commandToolName, toolInputJSON: input(["command": "ls", "cwd": "/w/\u{202E}x"])
        ), provider: "codex")
        #expect(!hidden.canAllow)
    }
}
