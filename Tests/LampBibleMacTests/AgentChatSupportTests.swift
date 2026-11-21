import Foundation
import Testing
@testable import LampBibleMacSupport

struct AgentChatSupportTests {
    @Test func parsesCodexSessionAndFinalMessage() {
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"thread.started","thread_id":"codex-session"}"#,
                provider: .codex
            ) == [.sessionStarted("codex-session")]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"item.completed","item":{"type":"agent_message","text":"Updated the draft."}}"#,
                provider: .codex
            ) == [.finalText("Updated the draft.")]
        )
    }

    @Test func parsesClaudeStreamingAndResultEvents() {
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"system","subtype":"init","session_id":"claude-session"}"#,
                provider: .claude
            ) == [.sessionStarted("claude-session")]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hello"}}}"#,
                provider: .claude
            ) == [.textFragment("Hello")]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"result","session_id":"claude-session","is_error":false,"result":"Hello there"}"#,
                provider: .claude
            ) == [.sessionStarted("claude-session"), .finalText("Hello there")]
        )
    }

    /// How a Claude run reports what it is doing, so a pane can show its steps
    /// rather than a spinner. These lines are the shapes a real
    /// `claude -p --output-format stream-json --include-partial-messages` run
    /// emits; a tool call's input arrives whole in the finished assistant
    /// message, which is before the call runs.
    @Test func parsesClaudeProgressEvents() {
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"mcp__lamp__read_passage","input":{}}}}"#,
                provider: .claude
            ) == [.activity(.toolStarted(name: "mcp__lamp__read_passage"))]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__lamp__read_passage","input":{"reference":"Psalm 22:1","translation_ids":["KJVs","LXX","Brenton"],"include_annotations":true}}]}}"#,
                provider: .claude
            ) == [.activity(.tool(
                name: "mcp__lamp__read_passage",
                summary: "Psalm 22:1 · KJVs, LXX, Brenton"
            ))]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"1\tIn the beginning"}]}}"#,
                provider: .claude
            ) == [.activity(.toolFinished)]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
                provider: .claude
            ) == [.activity(.writing)]
        )
    }

    /// Thinking is reported as happening, never as text. The blocks arrive
    /// with `thinking` empty and only a signature, so the estimate is all
    /// there is to say about them — a parser that offered the text would be
    /// offering an empty string.
    @Test func reportsThinkingWithoutClaimingToKnowIt() {
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}}"#,
                provider: .claude
            ) == [.activity(.thinking(estimatedTokens: nil))]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":50}}}"#,
                provider: .claude
            ) == [.activity(.thinking(estimatedTokens: 50))]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":120,"session_id":"s"}"#,
                provider: .claude
            ) == [.sessionStarted("s"), .activity(.thinking(estimatedTokens: 120))]
        )
    }

    /// Thinking deltas carry an estimate only sometimes, and a line that took
    /// each one at face value would flicker between a count and none while a
    /// single thinking block ran.
    @Test func keepsAthinkingEstimateThroughDeltasThatOmitIt() {
        let counted = AgentChatActivity.thinking(estimatedTokens: 50)
        #expect(counted.succeeded(by: .thinking(estimatedTokens: nil)) == counted)
        #expect(
            counted.succeeded(by: .thinking(estimatedTokens: 219))
                == .thinking(estimatedTokens: 219)
        )
        #expect(counted.succeeded(by: .writing) == .writing)
        // Nothing is kept across a different kind of step, or from no count.
        #expect(
            AgentChatActivity.writing.succeeded(by: .thinking(estimatedTokens: nil))
                == .thinking(estimatedTokens: nil)
        )
        #expect(
            AgentChatActivity.thinking(estimatedTokens: nil)
                .succeeded(by: .thinking(estimatedTokens: nil)) == .thinking(estimatedTokens: nil)
        )
    }

    @Test func namesAtoolAsApersonReadsIt() {
        #expect(
            AgentChatToolDescription.label(for: "mcp__lamp__read_commentary") == "read_commentary"
        )
        #expect(AgentChatToolDescription.label(for: "Read") == "Read")
        #expect(AgentChatToolDescription.label(for: "mcp__") == "mcp__")
    }

    /// A progress line says where a call is looking and never what it carries.
    /// A tool input can hold a whole draft, and a line under the header is not
    /// the place to put one.
    @Test func summarisesOnlyWhereAcallIsLooking() {
        #expect(AgentChatToolDescription.summary(of: [
            "reference": "John 1:1-2", "translation_ids": ["KJVs", "BSBs"],
        ]) == "John 1:1-2 · KJVs, BSBs")
        #expect(AgentChatToolDescription.summary(of: ["keys": ["H430", "H1254"]]) == "H430, H1254")
        #expect(AgentChatToolDescription.summary(of: ["day": 12]) == "12")
        #expect(AgentChatToolDescription.summary(of: [
            "file_path": "/tmp/draft.md",
            "content": "a whole draft, which no progress line should show",
        ]) == "/tmp/draft.md")
        // A long path keeps its end: the file's name is what identifies it.
        #expect(AgentChatToolDescription.summary(of: [
            "file_path": "/private/tmp/claude-501/-Users-someone-Documents-Personal-Repos-"
                + "lamp-bible-macos/a-session-id/scratchpad/streamtest/fact.txt",
        ]) == "…/streamtest/fact.txt")
        #expect(AgentChatToolDescription.summary(of: ["content": "only content"]) == nil)
        #expect(AgentChatToolDescription.summary(of: [:]) == nil)
        #expect(AgentChatToolDescription.summary(of: nil) == nil)
        #expect(AgentChatToolDescription.summary(of: [
            "module_ids": ["a", "b", "c", "d", "e", "f"],
        ]) == "a, b, c, d, …")

        // A query of several lines is one line, cut to a length that fits.
        let shown = AgentChatToolDescription.summary(of: [
            "query": "first line\nthen " + String(repeating: "word ", count: 40),
        ])
        #expect(shown?.count == 72)
        #expect(shown?.contains("\n") == false)
        #expect(shown?.hasSuffix("…") == true)
    }

    /// A line arrives in however many pieces the pipe gives it, and a
    /// multi-byte character can be split between two of them: decoding a
    /// chunk on its own would cut a JSON line in half and mangle a Greek word.
    @Test func readsWholeLinesOutOfChunksThatSplitThem() {
        var reader = AgentChatLineReader()
        #expect(reader.lines(from: Data("{\"a\":1}\n{\"b\"".utf8)) == [#"{"a":1}"#])
        #expect(reader.lines(from: Data(":2}\n".utf8)) == [#"{"b":2}"#])
        #expect(reader.lines(from: Data()) == [])
        #expect(reader.flush() == nil)

        let greek = Array("Ὁ Θεός".utf8)
        var halved = AgentChatLineReader()
        #expect(halved.lines(from: Data(greek[0..<2])) == [])
        #expect(halved.lines(from: Data(greek[2...]) + Data("\n".utf8)) == ["Ὁ Θεός"])

        // A last line with no newline on the end of it is still a line.
        var unfinished = AgentChatLineReader()
        #expect(unfinished.lines(from: Data("tail".utf8)) == [])
        #expect(unfinished.flush() == "tail")
        #expect(unfinished.flush() == nil)

        // Blank lines and carriage returns are not lines.
        var blanks = AgentChatLineReader()
        #expect(blanks.lines(from: Data("\n\r\n{\"c\":3}\r\n".utf8)) == [#"{"c":3}"#])
    }

    /// What a run was doing is shown while it runs and read as nothing when it
    /// is over: the reply is still the text the run finished with, and the
    /// progress events in between change neither it nor the session.
    @Test func asummaryIgnoresWhatTheRunWasDoing() {
        let output = [
            #"{"type":"system","subtype":"init","session_id":"s1"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}}"#,
            #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"mcp__lamp__read_passage","input":{}}}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"John 1:1 "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"says this."}}}"#,
            #"{"type":"result","session_id":"s1","is_error":false,"result":"John 1:1 says this."}"#,
        ].joined(separator: "\n")

        let summary = AgentChatRunSummary.summarize(output: output, provider: .claude)
        #expect(summary.sessionID == "s1")
        #expect(summary.response == "John 1:1 says this.")
        #expect(summary.failure == nil)
    }

    @Test func parsesOpenCodeTextAndNestedErrors() {
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"text","sessionID":"ses_123","part":{"type":"text","text":"Done."}}"#,
                provider: .openCode
            ) == [.sessionStarted("ses_123"), .textFragment("Done.")]
        )
        #expect(
            AgentChatWireParser.parse(
                #"{"type":"error","error":{"data":{"message":"No provider configured"}}}"#,
                provider: .openCode
            ) == [.failure("No provider configured")]
        )
    }

    @Test func ignoresNonJSONProgressOutput() {
        #expect(AgentChatWireParser.parse("Working…", provider: .codex).isEmpty)
    }

    @Test(arguments: [
        "Not logged in · Please run /login",
        "{\"type\":\"error\",\"message\":\"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header\"}",
        "Do you trust the files in this folder?",
        "0 credentials found. Run `opencode auth login`.",
    ])
    func recognizesOutputThatOnlyAnInteractiveSessionCanAnswer(output: String) {
        #expect(AgentChatSetupRequirement.isIndicated(in: output))
    }

    @Test(arguments: [
        "The model returned an empty response.",
        "rate limit exceeded; try again in 30 seconds",
        "Error: ENOENT: no such file or directory, open 'draft.md'",
    ])
    func leavesOrdinaryFailuresAlone(output: String) {
        #expect(!AgentChatSetupRequirement.isIndicated(in: output))
    }

    // MARK: - Reading a failure for a setup problem

    /// Said outright: the phrase is there, so the pane can name it.
    @Test func wordingThatNamesAPromptIsCalledASetupProblem() {
        let verdict = AgentChatSetupRequirement.verdict(
            output: "Not logged in · Please run /login",
            failure: "claude exited with status 1.",
            sessionID: nil,
            exitCode: 1
        )
        #expect(verdict == .indicated)
    }

    /// The case this exists for: a provider reworded its prompt, so nothing
    /// matches, but the run still died before it started a session.
    @Test func aFailureWithNoSessionIsTreatedAsAPossibleSetupProblem() {
        let verdict = AgentChatSetupRequirement.verdict(
            output: "codex: unrecognised first-run state",
            failure: "codex exited with status 2.",
            sessionID: nil,
            exitCode: 2
        )
        #expect(verdict == .possible)
    }

    /// A provider that started a session was past its prompts, so whatever
    /// went wrong afterwards is not something signing in would fix.
    @Test func aFailureAfterTheSessionStartedIsNotASetupProblem() {
        let verdict = AgentChatSetupRequirement.verdict(
            output: "{\"type\":\"error\",\"message\":\"rate limit exceeded\"}",
            failure: "rate limit exceeded",
            sessionID: "d149f2cc",
            exitCode: 1
        )
        #expect(verdict == .none)
    }

    @Test func aRunThatEndedCleanlyIsNotASetupProblem() {
        let verdict = AgentChatSetupRequirement.verdict(
            output: "", failure: "finished without returning a message.",
            sessionID: nil, exitCode: 0
        )
        #expect(verdict == .none)
    }

    // MARK: - Reading a credential listing

    /// What `opencode auth list` actually prints, box drawing and all.
    private static let openCodeListing = """
        \u{001B}[0m
        ┌  Credentials \u{001B}[90m~/.local/share/opencode/auth.json
        │
        ●  OpenCode Go \u{001B}[90mapi
        │
        └  1 credentials
        """

    @Test func aListingWithCredentialsReadsAsConnected() {
        #expect(AgentProviderCredentialListing.reportedCount(in: Self.openCodeListing) == 1)
        #expect(AgentProviderCredentialListing.describesCredentials(
            output: Self.openCodeListing, exitCode: 0
        ))
    }

    /// The bug this replaced: "10 credentials" contains "0 credential", so
    /// someone with ten providers configured was told to connect.
    @Test(arguments: [10, 20, 100])
    func manyCredentialsStillReadAsConnected(count: Int) {
        let listing = "┌  Credentials\n│\n└  \(count) credentials"
        #expect(AgentProviderCredentialListing.reportedCount(in: listing) == count)
        #expect(AgentProviderCredentialListing.describesCredentials(
            output: listing, exitCode: 0
        ))
    }

    @Test(arguments: ["└  0 credentials", "No credentials found."])
    func anEmptyListingReadsAsNotConnected(listing: String) {
        #expect(AgentProviderCredentialListing.reportedCount(in: listing) == 0)
        #expect(!AgentProviderCredentialListing.describesCredentials(
            output: listing, exitCode: 0
        ))
    }

    /// A listing that says nothing about credentials falls back to the exit
    /// status, which is how every other provider is judged.
    @Test func aListingThatSaysNothingFallsBackToTheExitStatus() {
        #expect(AgentProviderCredentialListing.reportedCount(in: "opencode 1.2.3") == nil)
        #expect(AgentProviderCredentialListing.describesCredentials(
            output: "opencode 1.2.3", exitCode: 0
        ))
        #expect(!AgentProviderCredentialListing.describesCredentials(
            output: "command failed", exitCode: 1
        ))
    }
}

/// What a run says about the account it ran on, and what Lamp does with it.
struct AgentChatAccountTests {
    @Test func claudeSaysWhetherASubscriptionOrAKeyPays() {
        let subscription = #"{"type":"system","subtype":"init","apiKeySource":"none","session_id":"s"}"#
        let key = #"{"type":"system","subtype":"init","apiKeySource":"ANTHROPIC_API_KEY","session_id":"s"}"#
        #expect(AgentChatWireParser.parse(subscription, provider: .claude)
            .contains(.billing(AgentChatBilling(source: "none"))))
        #expect(AgentChatBilling(source: "none").isAPIKey == false)
        #expect(AgentChatBilling(source: "oauth").isAPIKey == false)
        #expect(AgentChatWireParser.parse(key, provider: .claude)
            .contains(.billing(AgentChatBilling(source: "ANTHROPIC_API_KEY"))))
        #expect(AgentChatBilling(source: "ANTHROPIC_API_KEY").isAPIKey)
        #expect(AgentChatBilling(source: "/login managed key").isAPIKey)
    }

    @Test func codexSaysItInItsLoginStatus() {
        #expect(AgentChatBilling.codex(loginStatus: "Logged in using ChatGPT")?.isAPIKey == false)
        #expect(AgentChatBilling.codex(loginStatus: "Logged in using an API key - sk-ab***")?.isAPIKey == true)
        #expect(AgentChatBilling.codex(loginStatus: "Not logged in") == nil)
    }

    // As Claude Code 2.1.327 sent it, undocumented fields and all: only the
    // documented ones are read.
    private let warning = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1795492800,"rateLimitType":"seven_day","utilization":0.75,"overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"surpassedThreshold":0.75,"unifiedWindows":{"seven_day":{"utilization":0.75,"resetsAt":1795492800,"status":"allowed_warning","surpassedThreshold":0.75}},"overageEnabled":true},"uuid":"282fada3-ca8b-48ff-a6a3-233cfa75295a","session_id":"fe6b53c0-6a3a-491e-9c16-6c3e09fb618a"}"#

    @Test func aUsageLimitIsReadFromItsDocumentedFields() throws {
        let events = AgentChatWireParser.parse(warning, provider: .claude)
        let limit = try #require(events.compactMap { event -> AgentChatUsageLimit? in
            if case .usageLimit(let limit) = event { return limit }
            return nil
        }.first)
        #expect(limit.status == .allowedWarning)
        #expect(limit.utilization == 0.75)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1795492800))
        #expect(limit.needsCredits == false)
        // The session id it carries still starts the session.
        #expect(events.contains(.sessionStarted("fe6b53c0-6a3a-491e-9c16-6c3e09fb618a")))
    }

    @Test func aRejectionIsSaidPlainlyWithItsReset() {
        let now = Date(timeIntervalSince1970: 1795400000)
        let rejected = AgentChatUsageLimit(
            status: .rejected, resetsAt: now.addingTimeInterval(3600), utilization: 1, needsCredits: false
        )
        let text = AgentChatUsageLimitText.reached(rejected, provider: "Claude", now: now)
        #expect(text.hasPrefix("Claude\u{2019}s usage limit is reached. It resets at "))
        #expect(text.hasSuffix("Lamp stopped the reply rather than leave it waiting."))
        let credits = AgentChatUsageLimit(status: .rejected, resetsAt: nil, utilization: nil, needsCredits: true)
        #expect(AgentChatUsageLimitText.reached(credits, provider: "Claude").contains("usage credits"))
    }

    @Test func onlyAWarningIsWarnedOf() {
        let base = AgentChatUsageLimit(status: .allowed, resetsAt: nil, utilization: 0.2, needsCredits: false)
        #expect(AgentChatUsageLimitText.warning(base, provider: "Claude") == nil)
        let near = AgentChatUsageLimit(status: .allowedWarning, resetsAt: nil, utilization: 0.75, needsCredits: false)
        #expect(AgentChatUsageLimitText.warning(near, provider: "Claude") == "You\u{2019}ve used 75% of a Claude usage limit.")
    }

    @Test func aFailureSaysWhyWhereTheResultDoes() {
        let overloaded = #"{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":529,"result":"API Error: Overloaded"}"#
        #expect(AgentChatWireParser.parse(overloaded, provider: .claude).contains(
            .failure("Claude is overloaded right now. Try again in a minute. API Error: Overloaded")
        ))
        let tooLong = #"{"type":"result","is_error":true,"terminal_reason":"prompt_too_long","errors":["Prompt is too long"]}"#
        #expect(AgentChatWireParser.parse(tooLong, provider: .claude).contains(
            .failure("This conversation has grown too long for the model. Start a new chat to carry on. Prompt is too long")
        ))
        // Anything else is left in the provider's words.
        let other = #"{"type":"result","is_error":true,"result":"Something else"}"#
        #expect(AgentChatWireParser.parse(other, provider: .claude).contains(.failure("Something else")))
    }

    @Test func secretsAreTakenOutOfAFailureBeforeItIsKept() {
        let text = AgentChatSecrets.redacted(
            "401 for Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def with sk-ant-api03-AAAABBBBCCCCDDDD and api_key=hunter2hunter2"
        )
        #expect(!text.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(!text.contains("AAAABBBBCCCCDDDD"))
        #expect(!text.contains("hunter2hunter2"))
        #expect(text.contains("Bearer [redacted]"))
        #expect(text.contains("api_key=[redacted]"))
        // Prose that only mentions a token is left alone.
        #expect(AgentChatSecrets.redacted("Your token expired.") == "Your token expired.")
        let failed = AgentChatRunDisposition.of(
            output: "", exitCode: 1, launchError: "bad key sk-proj-ZZZZYYYYXXXXWWWW",
            wasStopped: false, provider: .codex, providerName: "Codex"
        )
        #expect(failed == .failed("bad key sk-[redacted]"))
    }

    @Test func aClaudeSessionsOwnVariablesAreNotHandedDown() {
        let cleaned = AgentProcessEnvironment.cleaned([
            "CLAUDECODE": "1",
            "CLAUDE_CODE_SESSION_ID": "abc",
            "CLAUDE_CODE_MESSAGING_TOKEN": "t",
            "CLAUDE_CONFIG_DIR": "/Users/x/.claude-work",
            "LAMP_CAPTURE_DIR": "/tmp/capture",
            "PATH": "/usr/bin",
        ])
        #expect(cleaned == [
            "CLAUDE_CONFIG_DIR": "/Users/x/.claude-work",
            "LAMP_CAPTURE_DIR": "/tmp/capture",
            "PATH": "/usr/bin",
        ])
    }

    @Test func aStopReachesWhatTheRunStarted() throws {
        // A shell that starts a child which outlives it unless killed.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 60 & wait"]
        try shell.run()
        defer { if shell.isRunning { shell.terminate() } }
        var children: [AgentProcessTree.Member] = []
        for _ in 0..<50 where children.isEmpty {
            children = AgentProcessTree.descendants(of: shell.processIdentifier)
            if children.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        let child = try #require(children.first)
        AgentProcessTree.kill([child])
        var gone = false
        for _ in 0..<50 where !gone {
            gone = Darwin.kill(child.pid, 0) != 0
            if !gone { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(gone)
    }
}
