import Foundation
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

// Payloads below are verbatim from each CLI, captured through the same hooks
// Lamp installs; only file paths are shortened.
private enum CapturedPayloads {
    static let claudeSessionStart = #"{"session_id":"c371b62b-8ed7-488e-a5fb-2a8cfc51ff58","transcript_path":"/x.jsonl","cwd":"/w","hook_event_name":"SessionStart","source":"startup"}"#
    static let claudePrompt = #"{"session_id":"c371b62b-8ed7-488e-a5fb-2a8cfc51ff58","transcript_path":"/x.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Reply with the word ok."}"#
    static let claudeStop = #"{"session_id":"c371b62b-8ed7-488e-a5fb-2a8cfc51ff58","transcript_path":"/x.jsonl","cwd":"/w","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok\n\nBANANA"}"#
    static let codexSessionStart = #"{"session_id":"01a104ef-93b4-7301-acf6-e8e3866cc204","transcript_path":"/x.jsonl","cwd":"/w","hook_event_name":"SessionStart","model":"gpt-6-luna","permission_mode":"bypassPermissions","source":"startup"}"#
    static let codexPrompt = #"{"session_id":"01a104ef-93b4-7301-acf6-e8e3866cc204","turn_id":"01a104ef-93f9-7c63-b2e4-4d8549fa7ab5","transcript_path":"/x.jsonl","cwd":"/w","hook_event_name":"UserPromptSubmit","model":"gpt-6-luna","permission_mode":"bypassPermissions","prompt":"Reply with only the word ok."}"#
    static let codexStop = #"{"session_id":"01a104ef-93b4-7301-acf6-e8e3866cc204","turn_id":"01a104ef-93f9-7c63-b2e4-4d8549fa7ab5","transcript_path":"/x.jsonl","cwd":"/w","hook_event_name":"Stop","model":"gpt-6-luna","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"ok"}"#
    static let openCodeLoaded = #"{"lamp":"lamp-opencode-capture","version":1,"event":"loaded"}"#
    static let openCodeMessages = #"{"lamp":"lamp-opencode-capture","version":1,"event":"messages","sessionID":"ses_efb29047dffesLpW3PAYQDAppR","messages":[{"id":"msg_104d6fc40001w2C62x36eUKNYh","role":"user","text":"Reply with the word ok.","created":1791082560576},{"id":"msg_104d6fc4c001OxLtfkRYVKjMyc","role":"assistant","text":"ok\n\nBANANA","created":1791082560588}]}"#
}

struct AgentTerminalCaptureParserTests {
    private let recorded = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ json: String, _ provider: AgentChatWireProvider) -> [AgentTerminalCaptureEvent]? {
        AgentTerminalCaptureParser.parse(Data(json.utf8), provider: provider, eventKey: "claude.ab12", recordedAt: recorded)
    }

    @Test func claudeHooksBecomeSessionAndMessages() throws {
        let start = try #require(parse(CapturedPayloads.claudeSessionStart, .claude))
        #expect(start == [.sessionStarted(sessionID: "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58", isFreshConversation: false)])

        guard case .messages(let session, let prompt)? = parse(CapturedPayloads.claudePrompt, .claude)?.first else {
            Issue.record("prompt not parsed"); return
        }
        #expect(session == "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58")
        #expect(prompt.map(\.role) == [.user])
        #expect(prompt.first?.text == "Reply with the word ok.")

        guard case .messages(_, let reply)? = parse(CapturedPayloads.claudeStop, .claude)?.first else {
            Issue.record("reply not parsed"); return
        }
        #expect(reply.map(\.role) == [.assistant])
        #expect(reply.first?.text == "ok\n\nBANANA")
    }

    @Test func clearingInsideClaudeStartsTheConversationOver() {
        let cleared = CapturedPayloads.claudeSessionStart.replacingOccurrences(of: "\"startup\"", with: "\"clear\"")
        #expect(parse(cleared, .claude) == [.sessionStarted(sessionID: "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58", isFreshConversation: true)])
    }

    @Test func codexHooksMatchClaudes() throws {
        let session = "01a104ef-93b4-7301-acf6-e8e3866cc204"
        #expect(parse(CapturedPayloads.codexSessionStart, .codex) == [.sessionStarted(sessionID: session, isFreshConversation: false)])

        guard case .messages(_, let prompt)? = parse(CapturedPayloads.codexPrompt, .codex)?.first,
              case .messages(_, let reply)? = parse(CapturedPayloads.codexStop, .codex)?.first
        else { Issue.record("turn not parsed"); return }
        #expect(prompt.map(\.text) == ["Reply with only the word ok."])
        #expect(reply.map(\.text) == ["ok"])
        // Keyed by Codex's turn, so they stay distinct and stable wherever read.
        #expect(prompt[0].id != reply[0].id)
        let elsewhere = AgentTerminalCaptureParser.parse(Data(CapturedPayloads.codexStop.utf8), provider: .codex, eventKey: "codex.zz99", recordedAt: recorded)
        guard case .messages(_, let sameReply)? = elsewhere?.first else { Issue.record("reply not parsed"); return }
        #expect(sameReply[0].id == reply[0].id)
    }

    @Test func launchNoticesAreReadForAnyProvider() {
        let notice = AgentTerminalLaunchPlanner.noticeJSON("Recap skipped.")
        #expect(parse(notice, .openCode) == [.launchNotice("Recap skipped.")])
        #expect(parse(notice, .claude) == [.launchNotice("Recap skipped.")])
    }

    @Test func openCodeUsesLampsOwnFormat() throws {
        #expect(parse(CapturedPayloads.openCodeLoaded, .openCode) == [.integrationLoaded])
        guard case .messages(let session, let messages)? = parse(CapturedPayloads.openCodeMessages, .openCode)?.first else {
            Issue.record("messages not parsed"); return
        }
        #expect(session == "ses_efb29047dffesLpW3PAYQDAppR")
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages[0].date == Date(timeIntervalSince1970: 1_791_082_560.576))
    }

    @Test func rereadingTheSamePayloadGivesTheSameMessages() {
        // Absorbing relies on this to make reading a file twice harmless.
        #expect(parse(CapturedPayloads.codexStop, .codex) == parse(CapturedPayloads.codexStop, .codex))
        #expect(parse(CapturedPayloads.claudeStop, .claude) == parse(CapturedPayloads.claudeStop, .claude))
    }

    @Test func fieldsAddedByAFutureReleaseChangeNothing() {
        let extended = CapturedPayloads.codexStop.replacingOccurrences(
            of: "\"model\"",
            with: "\"some_new_field\":{\"nested\":[1,2]},\"model\""
        )
        #expect(parse(extended, .codex) == parse(CapturedPayloads.codexStop, .codex))
    }

    @Test func payloadsMissingTheirDocumentedFieldsAreUnreadable() {
        #expect(parse(#"{"hook_event_name":"Stop"}"#, .claude) == nil)
        #expect(parse(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#, .codex) == nil)
        #expect(parse("not json", .claude) == nil)
        #expect(parse(#"{"lamp":"something-else","event":"loaded"}"#, .openCode) == nil)
    }

    @Test func eventsLampDoesNotUseAreIgnoredRatherThanUnreadable() {
        let other = CapturedPayloads.claudeStop.replacingOccurrences(of: "\"Stop\"", with: "\"PreCompact\"")
        #expect(parse(other, .claude) == [])
    }
}

struct AgentTerminalAbsorbTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ id: String, _ role: AgentChatTranscript.Role, _ text: String, _ offset: TimeInterval) -> AgentChatTranscript.Message {
        AgentChatTranscript.Message(id: LampStableIdentifier.uuid([id]), role: role, text: text, date: base.addingTimeInterval(offset))
    }

    @Test func capturedTurnsJoinTheConversationAndTakeItsSession() {
        let chat = AgentChatTranscript(
            conversationID: UUID(),
            sessionID: "chat-session",
            sessionInstallID: "mac-a",
            messages: [message("chat", .user, "From Chat", 0)]
        )

        let result = chat.absorbing(
            capturedMessages: [message("t1", .user, "From Terminal", 10), message("t2", .assistant, "Reply", 11)],
            fromSession: "terminal-session",
            installID: "mac-a"
        )

        #expect(result.messages.map(\.text) == ["From Chat", "From Terminal", "Reply"])
        #expect(result.resumableSessionID(forInstall: "mac-a") == "terminal-session")
    }

    @Test func absorbingTheSameTurnsTwiceChangesNothing() {
        let turns = [message("t1", .user, "Hi", 1), message("t2", .assistant, "Hello", 2)]
        let once = AgentChatTranscript().absorbing(capturedMessages: turns, fromSession: "s", installID: "mac-a")
        let twice = once.absorbing(capturedMessages: turns, fromSession: "s", installID: "mac-a")
        #expect(twice == once)
    }

    @Test func aRevisedMessageReplacesItsEarlierText() {
        let first = AgentChatTranscript().absorbing(capturedMessages: [message("t1", .assistant, "Draft", 1)], fromSession: "s", installID: "mac-a")
        let revised = first.absorbing(capturedMessages: [message("t1", .assistant, "Final", 1)], fromSession: "s", installID: "mac-a")
        #expect(revised.messages.map(\.text) == ["Final"])
    }

    @Test func nothingCapturedLeavesTheTranscriptAlone() {
        let transcript = AgentChatTranscript(sessionID: "keep", sessionInstallID: "mac-a")
        #expect(transcript.absorbing(capturedMessages: [], fromSession: "other", installID: "mac-b") == transcript)
    }
}

struct AgentTerminalIngestTests {
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    /// Writes captured payloads with ascending creation times, as hooks would.
    private func capture(_ payloads: [(String, String)], in workspace: URL) throws {
        let directory = AgentTerminalCaptureStore.captureDirectory(in: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, (prefix, json)) in payloads.enumerated() {
            let url = directory.appendingPathComponent("\(prefix).\(UUID().uuidString.prefix(8)).json")
            try Data(json.utf8).write(to: url)
            let date = start.addingTimeInterval(Double(index))
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
    }

    @Test func aClaudeSessionLandsInTheTranscriptInOrder() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentTerminalCaptureStore.saveLaunchRecord(
            AgentTerminalLaunchRecord(providerID: "claude", launchedAt: Date(), sessionID: "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58"),
            in: workspace
        )
        try capture([
            ("claude", CapturedPayloads.claudeSessionStart),
            ("claude", CapturedPayloads.claudePrompt),
            ("claude", CapturedPayloads.claudeStop),
        ], in: workspace)

        let result = try AgentTerminalCaptureStore.ingest(workspace: workspace, installID: "mac-a")

        #expect(result.integrationReported)
        #expect(result.absorbedMessageCount == 2)
        let transcript = AgentChatTranscriptStore.load(providerID: "claude", in: workspace)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.resumableSessionID(forInstall: "mac-a") == "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58")
        // Read and folded in, so not read again.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: AgentTerminalCaptureStore.captureDirectory(in: workspace).path)
        #expect(remaining.isEmpty)
    }

    @Test func aFreshCodexLaunchAdoptsTheSessionItReports() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Codex chooses its own session ID, so a new launch starts without one.
        try AgentTerminalCaptureStore.saveLaunchRecord(
            AgentTerminalLaunchRecord(providerID: "codex", launchedAt: Date()),
            in: workspace
        )
        try capture([
            ("codex", CapturedPayloads.codexSessionStart),
            ("codex", CapturedPayloads.codexPrompt),
            ("codex", CapturedPayloads.codexStop),
        ], in: workspace)

        try AgentTerminalCaptureStore.ingest(workspace: workspace, installID: "mac-a")

        let transcript = AgentChatTranscriptStore.load(providerID: "codex", in: workspace)
        #expect(transcript.messages.map(\.text) == ["Reply with only the word ok.", "ok"])
        #expect(transcript.resumableSessionID(forInstall: "mac-a") == "01a104ef-93b4-7301-acf6-e8e3866cc204")
        #expect(AgentTerminalCaptureStore.loadLaunchRecord(in: workspace)?.sessionID == "01a104ef-93b4-7301-acf6-e8e3866cc204")
    }

    @Test func clearingStartsANewConversationForTheNewSession() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentTerminalCaptureStore.saveLaunchRecord(
            AgentTerminalLaunchRecord(providerID: "claude", launchedAt: Date(), sessionID: "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58"),
            in: workspace
        )
        let cleared = #"{"session_id":"d0000000-0000-4000-8000-000000000000","hook_event_name":"SessionStart","source":"clear"}"#
        let afterClear = CapturedPayloads.claudePrompt
            .replacingOccurrences(of: "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58", with: "d0000000-0000-4000-8000-000000000000")
            .replacingOccurrences(of: "Reply with the word ok.", with: "Fresh start")
        try capture([("claude", CapturedPayloads.claudePrompt), ("claude", cleared), ("claude", afterClear)], in: workspace)

        try AgentTerminalCaptureStore.ingest(workspace: workspace, installID: "mac-a")

        let transcript = AgentChatTranscriptStore.load(providerID: "claude", in: workspace)
        #expect(transcript.messages.map(\.text) == ["Fresh start"])
        #expect(transcript.sessionID == "d0000000-0000-4000-8000-000000000000")
    }

    @Test func launchNoticesAreReported() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentTerminalCaptureStore.saveLaunchRecord(
            AgentTerminalLaunchRecord(providerID: "openCode", launchedAt: Date()),
            in: workspace
        )
        try capture([("opencode", AgentTerminalLaunchPlanner.noticeJSON("Left alone."))], in: workspace)

        let result = try AgentTerminalCaptureStore.ingest(workspace: workspace, installID: "mac-a")
        #expect(result.notices == ["Left alone."])
    }

    @Test func onlyTheLaunchedProvidersCapturesAreRead() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentTerminalCaptureStore.saveLaunchRecord(
            AgentTerminalLaunchRecord(providerID: "openCode", launchedAt: Date()),
            in: workspace
        )
        try capture([("opencode", CapturedPayloads.openCodeLoaded), ("opencode", CapturedPayloads.openCodeMessages)], in: workspace)

        let result = try AgentTerminalCaptureStore.ingest(workspace: workspace, installID: "mac-a")

        #expect(result.integrationReported)
        #expect(AgentChatTranscriptStore.load(providerID: "openCode", in: workspace).messages.count == 2)
        #expect(AgentChatTranscriptStore.load(providerID: "claude", in: workspace).messages.isEmpty)
    }

    @Test func unreadableCapturesAreCountedNotFatal() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentTerminalCaptureStore.saveLaunchRecord(
            AgentTerminalLaunchRecord(providerID: "claude", launchedAt: Date(), sessionID: "c371b62b-8ed7-488e-a5fb-2a8cfc51ff58"),
            in: workspace
        )
        try capture([("claude", "{ truncated"), ("claude", CapturedPayloads.claudePrompt)], in: workspace)

        let result = try AgentTerminalCaptureStore.ingest(workspace: workspace, installID: "mac-a")

        #expect(result.unreadableFileCount == 1)
        #expect(result.absorbedMessageCount == 1)
    }

    @Test func withoutALaunchRecordNothingIsRead() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try capture([("claude", CapturedPayloads.claudePrompt)], in: workspace)

        let result = try AgentTerminalCaptureStore.ingest(workspace: workspace, installID: "mac-a")
        #expect(result == AgentTerminalIngestResult())
    }
}

struct AgentTerminalLaunchPlannerTests {
    private let workspace = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Lamp Bible/Library/AgentWorkspaces/Devotionals/talk-123")

    private func request(
        _ provider: AgentChatWireProvider,
        resume: String? = nil,
        new: String? = nil,
        recap: String? = nil
    ) -> AgentTerminalLaunchPlanner.Request {
        AgentTerminalLaunchPlanner.Request(
            provider: provider,
            executable: provider == .openCode ? "opencode" : (provider == .claude ? "claude" : "codex"),
            resumeSessionID: resume,
            newSessionID: new,
            recapFile: recap == nil ? nil : workspace.appendingPathComponent(".lamp/terminal/earlier-conversation.md"),
            recapText: recap,
            captureDirectory: workspace.appendingPathComponent(".lamp/terminal/captured"),
            claudeSettingsFile: workspace.appendingPathComponent(".lamp/terminal/claude-settings.json"),
            openCodeConfigDirectory: URL(fileURLWithPath: "/Users/someone/Library/Application Support/Lamp Bible/AgentIntegrations/OpenCode")
        )
    }

    @Test func claudeResumesTheConversationsSession() {
        let plan = AgentTerminalLaunchPlanner.plan(request(.claude, resume: "abc"))
        #expect(plan.arguments == ["--settings", workspace.path + "/.lamp/terminal/claude-settings.json", "--resume", "abc"])
    }

    @Test func aNewClaudeSessionGetsLampsIDAndTheRecap() {
        let plan = AgentTerminalLaunchPlanner.plan(request(.claude, new: "new-id", recap: "Earlier…"))
        #expect(plan.arguments.contains("--session-id"))
        #expect(plan.arguments.contains("new-id"))
        #expect(plan.arguments.contains("--append-system-prompt-file"))
    }

    @Test func codexResumeTakesItsHooksBeforeTheSubcommand() {
        let plan = AgentTerminalLaunchPlanner.plan(request(.codex, resume: "thread-1"))
        #expect(Array(plan.arguments.suffix(2)) == ["resume", "thread-1"])
        #expect(plan.arguments.filter { $0.hasPrefix("hooks.") }.count == 3)
        #expect(!plan.arguments.contains { $0.hasPrefix("developer_instructions=") })
        #expect(!plan.arguments.contains { $0.hasPrefix("notify") })
    }

    @Test func codexHookDefinitionsAreTheSameForEveryWorkspace() {
        // Codex asks the user to trust a hook by its exact definition, so these
        // must not vary between launches.
        let one = AgentTerminalLaunchPlanner.plan(request(.codex)).arguments
        let other = AgentTerminalLaunchPlanner.plan(AgentTerminalLaunchPlanner.Request(
            provider: .codex, executable: "codex", resumeSessionID: nil, newSessionID: nil,
            recapFile: nil, recapText: nil,
            captureDirectory: URL(fileURLWithPath: "/elsewhere/captured"),
            claudeSettingsFile: URL(fileURLWithPath: "/elsewhere/claude-settings.json"),
            openCodeConfigDirectory: URL(fileURLWithPath: "/elsewhere/opencode")
        )).arguments
        #expect(one == other)
        #expect(!one.joined().contains("/"+"elsewhere"))
    }

    @Test func codexHookDefinitionsAreUnchanged() {
        // Pinned: changing this makes every user trust Lamp's hooks again in
        // Codex. Change it only deliberately, and update this alongside.
        #expect(AgentTerminalLaunchPlanner.codexHookOverrides().last == #"hooks.Stop=[{hooks=[{type="command",command="d=\"${LAMP_CAPTURE_DIR:-}\"; [ -n \"$d\" ] || exit 0; mkdir -p \"$d\" && t=$(mktemp \"$d/.codex.XXXXXXXX\") && cat > \"$t\" && mv \"$t\" \"$d/codex.${t##*.}.json\"; exit 0"}]}]"#)
    }

    @Test func aNewCodexSessionGetsTheRecapAsInstructions() {
        let plan = AgentTerminalLaunchPlanner.plan(request(.codex, recap: "Earlier \"quoted\"\nline"))
        #expect(plan.arguments.contains(#"developer_instructions="Earlier \"quoted\"\nline""#))
    }

    @Test func openCodeSettingsNeverOverrideTheUsers() {
        let plan = AgentTerminalLaunchPlanner.plan(request(.openCode, resume: "ses_1", recap: nil))
        #expect(plan.arguments == ["--session", "ses_1"])
        #expect(plan.guardedEnvironment.map(\.name) == ["OPENCODE_CONFIG_DIR"])
        #expect(plan.environment["LAMP_CAPTURE_DIR"] != nil)

        let fresh = AgentTerminalLaunchPlanner.plan(request(.openCode, recap: "Earlier…"))
        #expect(fresh.guardedEnvironment.first { $0.name == "OPENCODE_CONFIG_CONTENT" }?.value.contains("earlier-conversation.md") == true)
    }

    @Test func theLaunchScriptIsValidShell() throws {
        let plan = AgentTerminalLaunchPlanner.plan(request(.codex, recap: "It's \"tricky\" — $HOME `x`\nsecond line"))
        let script = AgentTerminalLaunchPlanner.shellScript(for: plan)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-launch-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let check = try run("/bin/sh", ["-n", file.path])
        #expect(check.status == 0)
    }

    @Test func aVariableTheUserSetIsLeftAloneAndReported() throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp capture \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: capture) }
        var plan = AgentTerminalLaunchPlanner.plan(request(.openCode, recap: "Earlier…"))
        plan.environment["LAMP_CAPTURE_DIR"] = capture.path
        // Stands in for the CLI: reports what it was given.
        plan.executable = "/bin/sh"
        plan.arguments = ["-c", "printf '%s|%s' \"$OPENCODE_CONFIG_DIR\" \"${OPENCODE_CONFIG_CONTENT:+recap}\""]
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-launch-\(UUID().uuidString).sh")
        try AgentTerminalLaunchPlanner.shellScript(for: plan).write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try run("/bin/sh", [script.path], environment: ["OPENCODE_CONFIG_DIR": "/users/own"])

        // After the clear-screen sequence the script prints for a clean start.
        #expect(result.text == "\u{1B}[H\u{1B}[2J\u{1B}[3J/users/own|recap")
        let files = try FileManager.default.contentsOfDirectory(at: capture, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let events = try AgentTerminalCaptureParser.parse(Data(contentsOf: files[0]), provider: .openCode, eventKey: "x", recordedAt: Date())
        #expect(events?.first == .launchNotice(plan.guardedEnvironment[0].noticeIfAlreadySet))
    }
}

struct AgentTerminalShellTests {
    @Test func quotingSurvivesARealShell() throws {
        let awkward = "It's a \"path\" with $HOME, `ticks`, \\backslash and spaces"
        let output = try run("/bin/sh", ["-c", "printf '%s' " + AgentTerminalLaunchPlanner.shellQuote(awkward)])
        #expect(output.text == awkward)
    }

    @Test func theClaudeHookWritesItsPayloadCompletely() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp capture \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try JSONSerialization.jsonObject(
            with: AgentTerminalLaunchPlanner.claudeSettings()
        ) as? [String: Any]
        let hooks = settings?["hooks"] as? [String: [[String: [[String: String]]]]]
        #expect(hooks?.keys.sorted() == ["SessionStart", "Stop", "UserPromptSubmit"])
        let command = try #require(hooks?["Stop"]?.first?["hooks"]?.first?["command"])

        let result = try run("/bin/sh", ["-c", command], stdin: CapturedPayloads.claudeStop, environment: ["LAMP_CAPTURE_DIR": directory.path])

        #expect(result.status == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        #expect(files.first?.hasPrefix("claude.") == true && files.first?.hasSuffix(".json") == true)
        #expect(try String(contentsOf: directory.appendingPathComponent(files[0]), encoding: .utf8) == CapturedPayloads.claudeStop)
    }

    @Test func outsideLampsLaunchesTheHookDoesNothing() throws {
        let command = AgentTerminalLaunchPlanner.captureCommand(prefix: "codex")
        let result = try run("/bin/sh", ["-c", command], stdin: CapturedPayloads.codexStop, environment: ["LAMP_CAPTURE_DIR": ""])
        #expect(result.status == 0)
        #expect(result.text.isEmpty)
    }

    @Test func aCaptureThatCannotBeWrittenNeverFailsTheSession() throws {
        let command = AgentTerminalLaunchPlanner.captureCommand(prefix: "claude")
        let result = try run("/bin/sh", ["-c", command], stdin: "{}", environment: ["LAMP_CAPTURE_DIR": "/dev/null/impossible"])
        #expect(result.status == 0)
    }

    @Test func tomlStringsEscapeWhatTomlRequires() {
        #expect(AgentTerminalLaunchPlanner.tomlString("a\"b\\c\nd\te") == #""a\"b\\c\nd\te""#)
        #expect(AgentTerminalLaunchPlanner.tomlString("bell\u{07}") == #""bell\u0007""#)
    }
}

struct AgentChatSessionInstructionsTests {
    @Test func thereAreNoInstructionsWithoutAnEarlierConversation() {
        #expect(AgentChatContinuation.sessionInstructions(continuing: []) == nil)
    }

    @Test func instructionsCarryTheConversationWithoutANewMessage() throws {
        let earlier = [AgentChatTranscript.Message(role: .user, text: "Tighten the opening", date: Date())]
        let instructions = try #require(AgentChatContinuation.sessionInstructions(continuing: earlier))
        #expect(instructions.contains("User: Tighten the opening"))
        #expect(instructions.hasSuffix("The user's next message continues this conversation."))
    }
}

private func run(
    _ executable: String,
    _ arguments: [String],
    stdin: String? = nil,
    environment: [String: String] = [:]
) throws -> (status: Int32, text: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
        .filter { !$0.key.hasPrefix("OPENCODE_") && $0.key != "LAMP_CAPTURE_DIR" }
        .merging(environment) { $1 }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    if let stdin {
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
    } else {
        try process.run()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

struct AgentTerminalLauncherTests {
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func prepare(_ providerID: String, in workspace: URL) throws -> (AgentTerminalLauncher.Prepared, String) {
        let prepared = try AgentTerminalLauncher.prepare(
            providerID: providerID,
            executable: providerID.lowercased(),
            workspace: workspace,
            installID: "mac-a",
            openCodeConfigDirectory: workspace.appendingPathComponent("opencode-config")
        )
        let script = try String(
            contentsOf: AgentTerminalCaptureStore.terminalDirectory(in: workspace).appendingPathComponent("launch.sh"),
            encoding: .utf8
        )
        return (prepared, script)
    }

    @Test func aNewConversationStartsAClaudeSessionLampHasNamed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let (prepared, script) = try prepare("claude", in: workspace)

        #expect(prepared.resumedSessionID == nil)
        #expect(!prepared.carriesRecap)
        let named = try #require(AgentTerminalCaptureStore.loadLaunchRecord(in: workspace)?.sessionID)
        #expect(script.contains("'--session-id' '\(named)'"))
        #expect(prepared.command.hasPrefix("exec /bin/sh '"))
    }

    @Test func aSessionThisMacHoldsIsResumed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(sessionID: "thread-1", sessionInstallID: "mac-a", messages: [
                .init(role: .user, text: "Hi", date: Date()),
            ]),
            providerID: "codex",
            in: workspace
        )

        let (prepared, script) = try prepare("codex", in: workspace)

        #expect(prepared.resumedSessionID == "thread-1")
        #expect(!prepared.carriesRecap)
        #expect(script.contains("'resume' 'thread-1'"))
    }

    @Test func anotherMacsSessionIsCarriedOnFromARecap() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(sessionID: "elsewhere", sessionInstallID: "mac-b", messages: [
                .init(role: .user, text: "The secret word is MANGO.", date: Date()),
            ]),
            providerID: "openCode",
            in: workspace
        )

        let (prepared, script) = try prepare("openCode", in: workspace)

        #expect(prepared.resumedSessionID == nil)
        #expect(prepared.carriesRecap)
        let recap = try String(
            contentsOf: AgentTerminalCaptureStore.terminalDirectory(in: workspace).appendingPathComponent("earlier-conversation.md"),
            encoding: .utf8
        )
        #expect(recap.contains("MANGO"))
        #expect(script.contains("OPENCODE_CONFIG_CONTENT="))
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("opencode-config/plugins/lamp-capture.js").path
        ))
    }
}

struct AgentTerminalResumeFailureTests {
    @Test func aQuickFailedExitBeforeAnyTurnMeansTheSessionIsGone() {
        // Measured: each CLI exits with status 1 within two seconds.
        #expect(AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 1, runningFor: 1.8, capturedMessages: 0))
    }

    @Test func otherEndingsKeepTheSession() {
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 0, runningFor: 1, capturedMessages: 0))
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 1, runningFor: 60, capturedMessages: 0))
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 1, runningFor: 5, capturedMessages: 2))
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 127, runningFor: 1, capturedMessages: 0))
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: nil, runningFor: 1, capturedMessages: 0))
        // Closed by Lamp switching modes, or by the user: SIGHUP, SIGTERM, SIGKILL.
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 129, runningFor: 1, capturedMessages: 0))
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 143, runningFor: 1, capturedMessages: 0))
        #expect(!AgentTerminalResumeFailure.indicatesMissingSession(exitStatus: 137, runningFor: 1, capturedMessages: 0))
    }

    @Test func forgettingASessionKeepsTheConversation() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-forget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(sessionID: "gone", sessionInstallID: "mac-a", messages: [.init(role: .user, text: "Hi", date: Date())]),
            providerID: "claude", in: workspace
        )

        #expect(!(try AgentTerminalCaptureStore.forgetSession("other", providerID: "claude", in: workspace)))
        #expect(try AgentTerminalCaptureStore.forgetSession("gone", providerID: "claude", in: workspace))

        let transcript = AgentChatTranscriptStore.load(providerID: "claude", in: workspace)
        #expect(transcript.sessionID == nil)
        #expect(transcript.messages.count == 1)
        // So the next launch carries the conversation on from a recap.
        #expect(AgentChatContinuation.sessionInstructions(continuing: transcript.messages) != nil)
    }

    @Test func rawWaitStatusesBecomeShellExitStatuses() {
        #expect(TerminalWaitStatus.exitStatus(0) == 0)
        #expect(TerminalWaitStatus.exitStatus(256) == 1)
        #expect(TerminalWaitStatus.exitStatus(127 << 8) == 127)
        #expect(TerminalWaitStatus.exitStatus(9) == 137)
        // And against a real process, spawned and reaped as SwiftTerm does.
        var pid: pid_t = 0
        let words: [String] = ["/bin/sh", "-c", "exit 3"]
        let arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, arguments, nil) == 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(TerminalWaitStatus.exitStatus(status) == 3)
    }
}

struct AgentTerminalIntegrationMemoryTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "lamp-integration-memory-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func nothingIsKnownUntilTheIntegrationRuns() throws {
        try withDefaults { defaults in
            for memory in AgentTerminalIntegrationMemory.allCases {
                #expect(!memory.hasRun(in: defaults))
                memory.recordRun(in: defaults)
                #expect(memory.hasRun(in: defaults))
            }
        }
    }

    @Test func eachIntegrationIsRememberedSeparately() throws {
        try withDefaults { defaults in
            AgentTerminalIntegrationMemory.codexHooks.recordRun(in: defaults)
            #expect(!AgentTerminalIntegrationMemory.openCodePlugin.hasRun(in: defaults))
        }
        #expect(AgentTerminalIntegrationMemory.codexHooks.fingerprint != AgentTerminalIntegrationMemory.openCodePlugin.fingerprint)
    }

    @Test func aChangedIntegrationIsUnknownAgain() throws {
        try withDefaults { defaults in
            for memory in AgentTerminalIntegrationMemory.allCases {
                // What an earlier Lamp, with a different integration, would have stored.
                defaults.set(String(repeating: "0", count: 64), forKey: memory.defaultsKey)
                #expect(!memory.hasRun(in: defaults))
            }
        }
    }

    @Test func forgettingBringsTheGuidanceBack() throws {
        try withDefaults { defaults in
            AgentTerminalIntegrationMemory.openCodePlugin.recordRun(in: defaults)
            AgentTerminalIntegrationMemory.openCodePlugin.forget(in: defaults)
            #expect(!AgentTerminalIntegrationMemory.openCodePlugin.hasRun(in: defaults))
        }
    }

    @Test func onlyCLIsWithAFirstRunStepAreRemembered() {
        #expect(AgentTerminalIntegrationMemory.forProvider(.codex) == .codexHooks)
        #expect(AgentTerminalIntegrationMemory.forProvider(.openCode) == .openCodePlugin)
        #expect(AgentTerminalIntegrationMemory.forProvider(.claude) == nil)
    }

    @Test func theMemoryStaysOnThisMac() {
        // What it stands for is per machine, so it must never be a synced setting.
        for memory in AgentTerminalIntegrationMemory.allCases {
            #expect(!LampPortableSettingsCodec.syncedKeys.contains(memory.defaultsKey))
        }
    }

    @Test func thePluginIsWrittenAfreshOnlyWhenItIsMissingOrChanged() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let integrations = workspace.appendingPathComponent("integrations", isDirectory: true)
        func launch() throws -> Bool {
            try AgentTerminalLauncher.prepare(
                providerID: "openCode", executable: "opencode", workspace: workspace,
                installID: "mac-a", openCodeConfigDirectory: integrations
            ).integrationWrittenAfresh
        }

        #expect(try launch())
        #expect(!(try launch()))
        // An older Lamp's plugin.
        let plugin = integrations.appendingPathComponent("plugins/\(AgentTerminalOpenCodePlugin.filename)")
        try "// older".write(to: plugin, atomically: true, encoding: .utf8)
        #expect(try launch())
        // The folder cleared away.
        try FileManager.default.removeItem(at: integrations)
        #expect(try launch())
        // Other CLIs write nothing that needs installing.
        #expect(!(try AgentTerminalLauncher.prepare(
            providerID: "codex", executable: "codex", workspace: workspace,
            installID: "mac-a", openCodeConfigDirectory: integrations
        ).integrationWrittenAfresh))
    }
}
