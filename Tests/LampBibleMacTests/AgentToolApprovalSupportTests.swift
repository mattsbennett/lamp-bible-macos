import Foundation
import Testing
@testable import LampBibleMacSupport

struct AgentToolApprovalSupportTests {
    private func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func json(_ data: Data) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    @Test func aRequestReadsOnlyTheDocumentedFields() throws {
        let request = try #require(AgentToolApprovalRequest(id: "a", hookPayload: payload([
            "session_id": "s",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": "ls -la", "description": "List files"],
            "permission_suggestions": [],
            "some_future_field": true,
        ])))
        #expect(request.toolName == "Bash")
        #expect(request.toolInputJSON == #"{"command":"ls -la","description":"List files"}"#)
        #expect(AgentToolApprovalRequest(id: "b", hookPayload: payload(["tool_input": [:]])) == nil)
        #expect(AgentToolApprovalRequest(id: "c", hookPayload: Data("not json".utf8)) == nil)
    }

    @Test func decisionsTakeTheDocumentedShape() {
        #expect(json(AgentToolApprovalAnswer.allow.hookOutput) == [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow"],
            ],
        ])
        let deny = json(AgentToolApprovalAnswer.deny.hookOutput)
        let decision = (deny?["hookSpecificOutput"] as? NSDictionary)?["decision"] as? NSDictionary
        #expect(decision?["behavior"] as? String == "deny")
        #expect((decision?["message"] as? String)?.isEmpty == false)
    }

    @Test func theSettingsAddOneHookForEveryTool() throws {
        let channel = AgentToolApprovalChannel(directory: URL(fileURLWithPath: "/tmp/lamp approvals/run"))
        let settings = try #require(json(Data(ClaudePermissionHook.settingsJSON(for: channel).utf8)))
        let groups = try #require((settings["hooks"] as? NSDictionary)?["PermissionRequest"] as? [NSDictionary])
        #expect(groups.count == 1)
        // No matcher: every tool that needs permission is asked about.
        #expect(groups[0]["matcher"] == nil)
        let hook = try #require((groups[0]["hooks"] as? [NSDictionary])?.first)
        #expect(hook["type"] as? String == "command")
        #expect(hook["timeout"] as? Int == 600)
        #expect((hook["command"] as? String)?.contains("'/tmp/lamp approvals/run'") == true)
    }

    @Test func answeredRequestsAreNoLongerPending() throws {
        let channel = try AgentToolApprovalChannel.makeForRun()
        defer { channel.close() }
        try payload(["tool_name": "WebFetch", "tool_input": ["url": "https://example.com"]])
            .write(to: channel.directory.appendingPathComponent("request-one.json"))
        try Data("{".utf8).write(to: channel.directory.appendingPathComponent(".request.half"))
        #expect(channel.pendingRequests().map(\.id) == ["one"])
        try channel.answer("one", with: .deny)
        #expect(channel.pendingRequests().isEmpty)
    }

    @Test func alwaysAllowOffersClaudeCodesOwnRuleForThisWritingAlone() throws {
        let suggested = try #require(AgentToolApprovalRequest(id: "a", hookPayload: payload([
            "tool_name": "Bash",
            "tool_input": ["command": "npm run build"],
            "permission_suggestions": [
                ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
                [
                    "type": "addRules",
                    "rules": [["toolName": "Bash", "ruleContent": "npm run *"]],
                    "behavior": "allow",
                    "destination": "session",
                ],
            ],
        ]))?.alwaysAllowRule)
        #expect(suggested.ruleText == "Bash(npm run *)")
        #expect(suggested.description == "running any command that starts with “npm run”")
        let entry = try #require(json(Data(suggested.entryJSON.utf8)))
        // Each message is its own run, so a session rule would end with it.
        #expect(entry["destination"] as? String == "localSettings")
        #expect(entry["type"] as? String == "addRules")

        let output = json(AgentToolApprovalAnswer.alwaysAllow(suggested).hookOutput)
        let decision = (output?["hookSpecificOutput"] as? NSDictionary)?["decision"] as? NSDictionary
        #expect(decision?["behavior"] as? String == "allow")
        #expect((decision?["updatedPermissions"] as? [NSDictionary])?.first == entry)
    }

    @Test func withoutASuggestionOnlyANarrowRuleIsOffered() {
        func rule(_ tool: String, _ input: [String: Any]) -> String? {
            AgentToolApprovalRequest(id: "x", hookPayload: payload(["tool_name": tool, "tool_input": input]))?
                .alwaysAllowRule?.ruleText
        }
        #expect(rule("Bash", ["command": "sw_vers -productVersion"]) == "Bash(sw_vers -productVersion)")
        #expect(rule("Bash", ["command": "echo a\necho b"]) == nil)
        // In a rule a `*` is a wildcard, so the exact command can't be saved.
        #expect(rule("Bash", ["command": "rm *.tmp"]) == nil)
        #expect(rule("WebFetch", ["url": "https://www.esv.org/John+3/"]) == "WebFetch(domain:www.esv.org)")
        #expect(rule("WebSearch", ["query": "grace"]) == "WebSearch")
        #expect(rule("mcp__notes__save", [:]) == "mcp__notes__save")
        // A rule for every write would be far broader than the one asked about.
        #expect(rule("Write", ["file_path": "/tmp/a.md", "content": "x"]) == nil)
    }

    @Test func aSuggestionTooBroadToSayPlainlyIsNotOffered() throws {
        func offered(_ suggestion: [String: Any], command: String = "git status") -> AgentToolAlwaysAllowRule? {
            AgentToolApprovalRequest(id: "x", hookPayload: payload([
                "tool_name": "Bash",
                "tool_input": ["command": command],
                "permission_suggestions": [suggestion],
            ]))?.alwaysAllowRule
        }
        func addRules(_ rules: [[String: Any]]) -> [String: Any] {
            ["type": "addRules", "rules": rules, "behavior": "allow", "destination": "localSettings"]
        }
        // Every command, which would read as the single word "Bash": the
        // exact command is offered instead.
        let everything = try #require(offered(addRules([["toolName": "Bash"]])))
        #expect(everything.ruleText == "Bash(git status)")
        #expect(everything.description == "running “git status”")
        // A wildcard before the end isn't a prefix and isn't offered.
        #expect(offered(addRules([["toolName": "Bash", "ruleContent": "* --version"]]))?.ruleText == "Bash(git status)")
        #expect(offered(addRules([["toolName": "Edit", "ruleContent": "/**"]]))?.ruleText == "Bash(git status)")

        // Several narrow rules are each said.
        let two = try #require(offered(addRules([
            ["toolName": "Bash", "ruleContent": "git status:*"],
            ["toolName": "WebFetch", "ruleContent": "domain:github.com"],
        ])))
        #expect(two.description
            == "running any command that starts with “git status” and fetching pages from github.com")

        #expect(AgentToolAlwaysAllowRule.plainDescription(of: ["toolName": "mcp__lamp__read_passage"])
            == "using read_passage from lamp")
        #expect(AgentToolAlwaysAllowRule.plainDescription(of: ["toolName": "mcp__lamp__*"]) == nil)
        #expect(AgentToolAlwaysAllowRule.plainDescription(of: ["toolName": "Write"]) == nil)
    }

    @Test func aStaleOrUnreadableRequestIsNeverShown() throws {
        let channel = try AgentToolApprovalChannel.makeForRun()
        defer { channel.close() }
        let stale = channel.directory.appendingPathComponent("request-stale.json")
        try payload(["tool_name": "Bash", "tool_input": ["command": "ls"]]).write(to: stale)
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-700)],
            ofItemAtPath: stale.path
        )
        try Data("garbled".utf8).write(to: channel.directory.appendingPathComponent("request-garbled.json"))

        #expect(channel.pendingRequests().isEmpty)
        // The unreadable one was refused at once rather than left to time out.
        let refusal = try Data(contentsOf: channel.directory.appendingPathComponent("answer-garbled.json"))
        #expect(refusal == AgentToolApprovalAnswer.deny.hookOutput)
        // A request its hook has taken back can't be answered.
        #expect(throws: AgentToolApprovalChannel.AnswerError.self) {
            try channel.answer("gone", with: .allow)
        }
    }

    @Test func fileCardsShowWhatWouldBeWritten() {
        func detail(_ tool: String, _ input: [String: Any]) -> String? {
            AgentToolApprovalRequest(id: "x", hookPayload: payload(["tool_name": tool, "tool_input": input]))
                .map(AgentToolApprovalSummary.of)?.detail
        }
        #expect(detail("Write", ["file_path": "/w/notes.md", "content": "Grace upon grace."])
            == "/w/notes.md\n\nGrace upon grace.")
        #expect(detail("Edit", ["file_path": "/w/notes.md", "old_string": "law", "new_string": "grace"])
            == "/w/notes.md\n\nReplace:\nlaw\n\nWith:\ngrace")
        let long = String(repeating: "a", count: 900)
        #expect(detail("Write", ["file_path": "/w/x", "content": long])?.hasSuffix("…") == true)
    }

    @Test func theHookTakesItsRequestBackWhenTheWaitEnds() async throws {
        let channel = try AgentToolApprovalChannel.makeForRun()
        defer { channel.close() }
        let started = Date()
        let hook = try runHook(channel, payload: payload(["tool_name": "Bash", "tool_input": ["command": "ls"]]), waitSeconds: 1)
        try await waitForExit(hook.process)
        // Measured on the clock: a second, give or take the poll.
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(hook.output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: channel.directory.path)
        #expect(!left.contains { $0.hasPrefix("request-") })
    }

    /// The hook as Claude Code runs it: payload on standard input, decision on
    /// standard output.
    private func runHook(
        _ channel: AgentToolApprovalChannel,
        payload: Data,
        waitSeconds: Int = ClaudePermissionHook.waitSeconds
    ) throws -> (process: Process, output: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ClaudePermissionHook.command(for: channel, waitSeconds: waitSeconds)]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()
        return (process, output)
    }

    private func waitForRequest(in channel: AgentToolApprovalChannel) async throws -> AgentToolApprovalRequest {
        for _ in 0..<100 {
            if let request = channel.pendingRequests().first { return request }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    private func waitForExit(_ process: Process) async throws {
        for _ in 0..<100 where process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!process.isRunning, "The hook should have finished")
    }

    @Test func theHookPrintsTheDecisionLampWrites() async throws {
        let channel = try AgentToolApprovalChannel.makeForRun()
        defer { channel.close() }
        let hook = try runHook(channel, payload: payload([
            "tool_name": "Bash",
            "tool_input": ["command": "echo 'hi'"],
        ]))
        let request = try await waitForRequest(in: channel)
        #expect(AgentToolApprovalSummary.of(request) == .init(title: "Run a command", detail: "echo 'hi'"))

        try channel.answer(request.id, with: .allow)
        try await waitForExit(hook.process)
        #expect(hook.process.terminationStatus == 0)
        #expect(hook.output.fileHandleForReading.readDataToEndOfFile() == AgentToolApprovalAnswer.allow.hookOutput)
    }

    @Test func theHookGivesNoDecisionOnceLampStopsListening() async throws {
        let channel = try AgentToolApprovalChannel.makeForRun()
        let hook = try runHook(channel, payload: payload(["tool_name": "WebSearch", "tool_input": ["query": "x"]]))
        _ = try await waitForRequest(in: channel)

        channel.close()
        try await waitForExit(hook.process)
        #expect(hook.process.terminationStatus == 0)
        #expect(hook.output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test func summariesNameWhatDecidesIt() {
        func summary(_ tool: String, _ input: String) -> AgentToolApprovalSummary {
            .of(AgentToolApprovalRequest(id: "x", toolName: tool, toolInputJSON: input))
        }
        #expect(summary("WebFetch", #"{"url":"https://example.com","prompt":"p"}"#)
            == .init(title: "Fetch a web page", detail: "https://example.com"))
        #expect(summary("mcp__my_server__look_up", #"{"term":"grace"}"#)
            == .init(title: "Use look_up from my_server", detail: #"{"term":"grace"}"#))
        #expect(summary("Bash", "{}") == .init(title: "Run a command", detail: nil))
        #expect(summary("Unheard", #"{"a":1}"#) == .init(title: "Use Unheard", detail: #"{"a":1}"#))
    }
}
