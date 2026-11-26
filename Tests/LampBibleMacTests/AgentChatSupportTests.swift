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
        // Made up, and put together here rather than written out, so a
        // secret scanner reading the repository has nothing to match.
        let bearer = "not" + "-a-real-" + "token-0000"
        let key = "sk-" + "fake" + String(repeating: "0", count: 16)
        let password = "not" + "-a-" + "password"
        let text = AgentChatSecrets.redacted(
            "401 for Authorization: Bearer \(bearer) with \(key) and api_key=\(password)"
        )
        #expect(!text.contains(bearer))
        #expect(!text.contains(key))
        #expect(!text.contains(password))
        #expect(text.contains("Bearer [redacted]"))
        #expect(text.contains("sk-[redacted]"))
        #expect(text.contains("api_key=[redacted]"))
        // Prose that only mentions a token is left alone.
        #expect(AgentChatSecrets.redacted("Your token expired.") == "Your token expired.")
        let failed = AgentChatRunDisposition.of(
            output: "", exitCode: 1, launchError: "bad key \(key)",
            wasStopped: false, provider: .codex, providerName: "Codex"
        )
        #expect(failed == .failed("bad key sk-[redacted]"))
    }

    // As Claude Code 2.1.327 answered `claude -p /usage`, trimmed.
    private let claudeUsage = """
    You are currently using your subscription to power your Claude Code usage

    Current week (all models): 76% used · resets Nov 23 at 9pm (America/Vancouver)
    Current week (Fable): 16% used · resets Nov 23 at 9pm (America/Vancouver)

    What's contributing to your usage?
    Last 24h · 2103 requests · 11 sessions
      92%  Start fresh when you switch tasks · run /clear
    """

    @Test func claudesUsageLinesAreShownAsWritten() {
        #expect(AgentUsageReading.claude(usageOutput: claudeUsage)?.lines == [
            "Current week (all models): 76% used · resets Nov 23 at 9pm (America/Vancouver)",
            "Current week (Fable): 16% used · resets Nov 23 at 9pm (America/Vancouver)",
        ])
        // An answer in some other shape shows nothing rather than a guess.
        #expect(AgentUsageReading.claude(usageOutput: "Usage is unavailable right now.") == nil)
    }

    @Test func codexsWindowsAreReadFieldByField() throws {
        // The shape codex-cli 0.170.0's app-server answered with.
        let json = #"{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","primary":{"usedPercent":54,"windowDurationMins":10080,"resetsAt":1795619830},"secondary":{"usedPercent":12.4,"windowDurationMins":300,"resetsAt":1795500000},"credits":{"hasCredits":false},"spendControlReached":false,"planType":"prolite"}}"#
        let result = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let lines = try #require(AgentUsageReading.codex(
            rateLimitsResult: result, now: Date(timeIntervalSince1970: 1795400000)
        )?.lines)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("Weekly limit: 54% used · resets "))
        #expect(lines[1].hasPrefix("5-hour limit: 12% used · resets "))
        // A schema that has moved on shows nothing.
        #expect(AgentUsageReading.codex(rateLimitsResult: ["limits": [:]]) == nil)
        #expect(AgentUsageReading.codex(rateLimitsResult: ["rateLimits": ["primary": ["used": 5]]]) == nil)
    }

    @Test func openCodeGosWindowsAreReadWhereTheRouteAnswers() throws {
        // The shape of OpenCode's UsageLimits.Info (packages/schema, Oct 2026).
        let json = #"{"location":{"directory":"/tmp"},"data":{"workspace":{"id":"w","usageURL":"https://opencode.ai"},"go":{"rolling":{"percent":30,"limited":false,"resetsAt":1795500000000},"weekly":{"percent":61.6,"limited":false,"resetsAt":1795600000000},"monthly":{"percent":100,"limited":true,"resetsAt":1797000000000}},"budgets":[]}}"#
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let lines = try #require(AgentUsageReading.openCode(
            limitsResponse: object, now: Date(timeIntervalSince1970: 1795400000)
        )?.lines)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("5-hour limit: 30% used · resets "))
        #expect(lines[1].hasPrefix("Weekly limit: 62% used · resets "))
        #expect(lines[2].hasPrefix("Monthly limit: 100% used, reached · resets "))
        // Not signed in to a Console workspace, or no Go plan: nothing.
        #expect(AgentUsageReading.openCode(limitsResponse: ["location": [:], "data": NSNull()]) == nil)
        #expect(AgentUsageReading.openCode(limitsResponse: ["data": ["budgets": []]]) == nil)
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

}

/// Antigravity over `agy acp`, from messages agy 1.5.14 sent.
struct AgentACPTests {
    private let workspace = URL(fileURLWithPath: "/tmp/lamp-acp-workspace", isDirectory: true)
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func itsLaunchIsTheACPServerAndNothingElse() {
        #expect(AgentChatLaunchArguments.make(
            provider: .antigravity, prompt: "hi", sessionID: "s", proposedSessionID: nil
        ) == ["acp"])
        #expect(AgentChatModelChoice.arguments(for: "gemini-3.8-flash", provider: .antigravity) == [])
        #expect(AgentChatEffortChoice.arguments(for: "high", provider: .antigravity) == [])
    }

    @Test func aReplyIsReadFromTheSessionsUpdates() {
        let chunk = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Jesus wept."}}}}"#
        #expect(AgentChatWireParser.parse(chunk, provider: .antigravity) == [.textFragment("Jesus wept.")])
        let tool = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","name":"mcp_lamp_read_passage","status":"in_progress","kind":"other","title":"Run mcp_lamp_read_passage","rawInput":{"reference":"John 11:35","toolSummary":"Read John 11:35 in KJVs"}}}}"#
        #expect(AgentChatWireParser.parse(tool, provider: .antigravity)
            == [.activity(.tool(name: "mcp_lamp_read_passage", summary: "Read John 11:35 in KJVs"))])
        #expect(AgentChatToolDescription.label(for: "mcp_lamp_read_passage") == "read_passage")
        let opened = #"{"jsonrpc":"2.0","result":{"sessionId":"3b0eea46-e7e7-4475-8692-a9cca85f6d07","models":{}},"id":2}"#
        #expect(AgentChatWireParser.parse(opened, provider: .antigravity)
            == [.sessionStarted("3b0eea46-e7e7-4475-8692-a9cca85f6d07")])
        // A permission request is the run's to answer, not part of the reply.
        let asked = #"{"jsonrpc":"2.0","method":"session/request_permission","params":{"sessionId":"s"},"id":"1"}"#
        #expect(AgentChatWireParser.parse(asked, provider: .antigravity) == [])
    }

    @Test func aRunsReplyAndSessionAreReadFromItsWholeOutput() {
        let output = [
            #"{"jsonrpc":"2.0","result":{"protocolVersion":1},"id":1}"#,
            #"{"jsonrpc":"2.0","result":{"sessionId":"abc"},"id":2}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello, "}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"friend."}}}}"#,
            #"{"jsonrpc":"2.0","result":{"stopReason":"end_turn"},"id":3}"#,
        ].joined(separator: "\n")
        let summary = AgentChatRunSummary.summarize(output: output, provider: .antigravity)
        #expect(summary.sessionID == "abc")
        #expect(summary.response == "Hello, friend.")
    }

    @Test func signingInAndALostSessionAreRecognised() {
        let unsigned = #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Authentication required"},"id":2}"#
        #expect(AgentChatWireParser.parse(unsigned, provider: .antigravity) == [.failure("Authentication required")])
        #expect(AgentChatSetupRequirement.verdict(
            output: unsigned, failure: "Authentication required", sessionID: nil, exitCode: 1
        ) == .indicated)
        let lost = #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Failed to read session 0000; retry, or load it with session/load"},"id":2}"#
        #expect(AgentChatResumeFailure.indicatesMissingSession(in: lost))
        let refused = #"{"jsonrpc":"2.0","result":{"stopReason":"refusal"},"id":3}"#
        #expect(AgentChatWireParser.parse(refused, provider: .antigravity).count == 1)
        // A turn cut short is not a finished one.
        for reason in ["max_tokens", "max_turn_requests", "cancelled"] {
            let cut = #"{"jsonrpc":"2.0","result":{"stopReason":"\#(reason)"},"id":3}"#
            #expect(AgentChatWireParser.parse(cut, provider: .antigravity).count == 1, "\(reason)")
        }
        let finished = #"{"jsonrpc":"2.0","result":{"stopReason":"end_turn"},"id":3}"#
        #expect(AgentChatWireParser.parse(finished, provider: .antigravity).isEmpty)
    }

    @Test func aSessionIsResumedNeverLoadedAndGivenNoSecondFolder() {
        let fresh = AgentACPRun.open(sessionID: nil, workspace: workspace, mcpServers: [])
        #expect(fresh.method == "session/new")
        let again = AgentACPRun.open(sessionID: "abc", workspace: workspace, mcpServers: [])
        #expect(again.method == "session/resume")
        #expect(again.params["sessionId"] as? String == "abc")
        #expect(again.params["additionalDirectories"] == nil)
        let configuration = AgentACPRun.configuration(sessionID: "abc", model: "gemini-3.8-flash", effort: " ")
        // The asking mode first, whatever the reader's own agentMode says.
        #expect(configuration.map(\.method) == ["session/set_mode", "session/set_config_option"])
        #expect(configuration[0].params["modeId"] as? String == "default")
        #expect(configuration[1].params["configId"] as? String == "model")
    }

    /// Shaped as `agy acp` 1.5.14 answered `session/new` and
    /// `session/set_config_option` on 2026-11-22.
    @Test func theCatalogueNamesModelsAndKnowsEachOnesLevels() throws {
        let opened = try #require(JSONSerialization.jsonObject(with: Data(#"""
        {"sessionId":"s","configOptions":[
          {"id":"model","type":"select","currentValue":"gemini-4-neon","options":[
            {"value":"gemini-4-neon","name":"Gemini 4 Neon"},
            {"value":"gemini-4-argon","name":"Gemini 4 Argon"},
            {"value":"gpt-oss-120b-medium","name":"GPT-OSS 120B (Medium)"},
            {"value":" ","name":"blank"}]},
          {"id":"thought_level","type":"select","currentValue":"high","options":[
            {"value":"low","name":"Low"},{"value":"high","name":"High"},{"value":"xhigh","name":"Extra"}]}]}
        """#.utf8)) as? [String: Any])
        let models = try #require(AgentACPCatalogue.option("model", in: opened))
        #expect(models.current == "gemini-4-neon")
        #expect(models.choices.map(\.value) == ["gemini-4-neon", "gemini-4-argon", "gpt-oss-120b-medium"])
        // A model with no thinking level reports no option for it at all.
        let noLevels: [String: Any] = ["configOptions": [["id": "model", "currentValue": "gpt-oss-120b-medium", "options": []]]]
        #expect(AgentACPCatalogue.option("thought_level", in: noLevels) == nil)

        let neonLevels = try #require(AgentACPCatalogue.option("thought_level", in: opened)).choices
        let catalogue = AgentACPCatalogue(
            models: models.choices,
            defaultModel: models.current,
            levels: ["gemini-4-neon": neonLevels, "gpt-oss-120b-medium": []]
        )
        #expect(catalogue.modelName("gemini-4-argon") == "Gemini 4 Argon")
        #expect(catalogue.modelName("typed-by-hand") == "typed-by-hand")
        // No model chosen means the reader's default, whose levels these are.
        #expect(catalogue.levels(for: nil)?.map(\.value) == ["low", "high", "xhigh"])
        #expect(catalogue.levelName("xhigh", model: " ") == "Extra")
        #expect(catalogue.levels(for: "gpt-oss-120b-medium")?.isEmpty == true)
        // A model never read is unknown, not one without levels.
        #expect(catalogue.levels(for: "gemini-4-argon") == nil)
    }

    /// The server Lamp made for the writing, never one named in the
    /// workspace's `.mcp.json`, which the agent can rewrite.
    @Test func aWritingsLampServerIsTheOneLampMade() throws {
        let made = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp"),
            libraryRootURL: URL(fileURLWithPath: "/lib"),
            policyURL: URL(fileURLWithPath: "/policy.json"),
            workspaceURL: URL(fileURLWithPath: "/lib/AgentWorkspaces/Writing/talk")
        )
        let servers = AgentACPRun.mcpServers(mode: .writing, writingServer: made)
        #expect(servers.count == 1)
        #expect(servers.first?["name"] as? String == "lamp")
        #expect(servers.first?["command"] as? String == "/Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp")
        #expect((servers.first?["args"] as? [String])?.contains("/lib/AgentWorkspaces/Writing/talk") == true)
        #expect(AgentACPRun.mcpServers(mode: .writing, writingServer: nil).isEmpty)
    }

    private func request(_ call: [String: Any]) -> [String: Any] {
        ["toolCall": call, "options": [
            ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
            ["optionId": "always", "name": "Always", "kind": "allow_always"],
            ["optionId": "deny", "name": "Deny", "kind": "reject_once"],
        ]]
    }

    @Test func onlyLampsToolsAndOwnReadsAreAllowedInAReaderChat() {
        func decide(_ call: [String: Any], readOnly: Bool = true) -> String? {
            AgentACPRun.decide(
                permission: request(call), readOnly: readOnly, workspace: workspace, home: home, sessionID: "s"
            )
        }
        #expect(decide(["toolCallId": "c", "name": "mcp_lamp_read_passage", "kind": "other"]) == "allow")
        // Another server that flattens to the same prefix is not Lamp's.
        #expect(decide(["toolCallId": "c", "name": "mcp_lamp_admin_delete_record", "kind": "other"]) == "deny")
        // Its own long result, saved in its folder and read back.
        #expect(decide(["toolCallId": "c", "name": "view_file", "kind": "read",
                        "locations": [["path": "/Users/someone/.gemini/antigravity-cli/brain/s/.system_generated/steps/2/output.txt"]]]) == "allow")
        #expect(decide(["toolCallId": "c", "name": "view_file", "kind": "read",
                        "locations": [["path": "/Users/someone/.ssh/id_ed25519"]]]) == "deny")
        // Another session's folder is not this one's.
        #expect(decide(["toolCallId": "c", "name": "view_file", "kind": "read",
                        "locations": [["path": "/Users/someone/.gemini/antigravity-cli/brain/other/notes.md"]]]) == "deny")
        #expect(decide(["toolCallId": "c", "name": "run_command", "kind": "execute"]) == "deny")
        #expect(decide(["toolCallId": "c", "name": "write_file", "kind": "edit",
                        "locations": [["path": "/tmp/lamp-acp-workspace/draft.md"]]]) == "deny")
        // A question nobody is there to answer.
        #expect(decide(["toolCallId": "interaction_1", "name": "ask", "kind": "other"]) == "deny")
        // A writing's agent edits its own workspace and nothing outside it.
        #expect(decide(["toolCallId": "c", "name": "write_file", "kind": "edit",
                        "locations": [["path": "/tmp/lamp-acp-workspace/draft.md"]]], readOnly: false) == "allow")
        #expect(decide(["toolCallId": "c", "name": "write_file", "kind": "edit",
                        "locations": [["path": "/tmp/lamp-acp-workspace/../elsewhere.md"]]], readOnly: false) == "deny")
        #expect(decide(["toolCallId": "c", "name": "run_command", "kind": "execute"], readOnly: false) == "deny")
    }
}

struct AgentACPContainmentTests {
    @Test func aFileMadeThroughALinkOutOfTheWorkspaceIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-confine-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("dangling"),
            withDestinationURL: root.appendingPathComponent("nowhere/file.md")
        )
        let path = workspace.path
        #expect(AgentACPRun.confined(path + "/draft.md", to: workspace))
        #expect(AgentACPRun.confined(path + "/new/folder/note.md", to: workspace))
        // Not there yet, and through a link that leads out.
        #expect(!AgentACPRun.confined(path + "/link/new.md", to: workspace))
        #expect(!AgentACPRun.confined(path + "/link/../escape.md", to: workspace))
        #expect(!AgentACPRun.confined(path + "/../outside/x.md", to: workspace))
        #expect(!AgentACPRun.confined(path + "/dangling", to: workspace))
        #expect(!AgentACPRun.confined("relative/draft.md", to: workspace))
    }

    @Test func aReaderChatIsRefusedWhereTheReadersOwnSettingsActUnasked() {
        func refusal(_ json: String) -> String? { AgentACPRun.readerRefusal(settings: Data(json.utf8)) }
        #expect(refusal(#"{"model":"gemini-4-neon"}"#) == nil)
        #expect(refusal(#"{"permissions":{"allow":["read_file(src/)","view_file(*)"]}}"#) == nil)
        #expect(refusal(#"{"toolPermission":"always-proceed"}"#) != nil)
        #expect(refusal(#"{"permissions":{"allow":["command(git)"]}}"#) != nil)
        #expect(refusal(#"{"permissions":{"allow":["write_file(src/)"]}}"#) != nil)
        #expect(AgentACPRun.readerRefusal(settings: nil) == nil)
    }

    @Test func credentialsAreRedactedAndDiagnosticsKept() {
        let key = "AIza" + String(repeating: "x", count: 20)
        for leaked in ["GEMINI_API_KEY=\(key)", "client_secret=\(key)", #"password="first part second part""#] {
            let text = AgentChatSecrets.redacted("failed: \(leaked) end")
            #expect(text.contains("[redacted]"), "\(leaked)")
            #expect(!text.contains(key))
            #expect(!text.contains("second part"))
        }
        #expect(AgentChatSecrets.redacted("Unexpected token: undefined") == "Unexpected token: undefined")
        #expect(AgentChatSecrets.redacted("Your token expired.") == "Your token expired.")
        #expect(AgentChatSecrets.redacted("token: 9f8e7d6c5b4a3f2e1d0c") == "token: [redacted]")
        // Codex's second-round probes.
        #expect(!AgentChatSecrets.redacted("{'password': 'first part second part'}").contains("second part"))
        #expect(!AgentChatSecrets.redacted(#"password="first \" second secret suffix""#).contains("suffix"))
        #expect(AgentChatSecrets.redacted("token=abcdefghijklmnopqrstuvwx") == "token=[redacted]")
        for kept in ["sort_key=created_at", "primary_key=user_id", "Unexpected token: 123"] {
            #expect(AgentChatSecrets.redacted(kept) == kept)
        }
    }

    @Test func redactionStaysFastOnInputThatAlmostMatches() {
        for input in [String(repeating: "a-", count: 8000), String(repeating: "a:", count: 8000)] {
            let started = Date()
            _ = AgentChatSecrets.redacted(input)
            #expect(Date().timeIntervalSince(started) < 0.5)
        }
    }

    @Test func camelCaseCredentialsAreRedacted() {
        for leaked in ["accessToken=abcdefghijklmnopqrstuvwx", "refreshToken=abc123secret",
                       "authToken=abc123secret", "bearerToken=abc123secret", "apiKey: abc123secretvalue"] {
            #expect(AgentChatSecrets.redacted(leaked).hasSuffix("[redacted]"), "\(leaked)")
        }
    }

    @Test func anAskRuleOverEveryCommandKeepsAReaderChatSafe() {
        let safe = #"{"permissions":{"allow":["command(git)"],"ask":["command(*)"]}}"#
        #expect(AgentACPRun.readerRefusal(settings: Data(safe.utf8)) == nil)
        let unsafe = #"{"permissions":{"allow":["command(git)"],"ask":["command(rm)"]}}"#
        #expect(AgentACPRun.readerRefusal(settings: Data(unsafe.utf8)) != nil)
        let denied = #"{"permissions":{"allow":["command(git)"],"deny":["command(git)"]}}"#
        #expect(AgentACPRun.readerRefusal(settings: Data(denied.utf8)) == nil)
    }

    @Test func onlyLampsOwnServerCountsAsReadOnly() {
        #expect(AgentACPRun.isReadOnlyRule("mcp(lamp)"))
        #expect(AgentACPRun.isReadOnlyRule("mcp(lamp/read_passage)"))
        #expect(!AgentACPRun.isReadOnlyRule("mcp(lamp-admin/delete_record)"))
        #expect(AgentACPRun.isReadOnlyRule("read_file(src/)"))
        #expect(!AgentACPRun.isReadOnlyRule("write_file(src/)"))
        #expect(!AgentACPRun.isReadOnlyRule("command(git)"))
        #expect(!AgentACPRun.isReadOnlyRule("readme_writer(x)"))
    }

    @Test func theRootAndImpossiblePathsAreJudgedRight() {
        #expect(AgentACPRun.confined("/tmp", to: URL(fileURLWithPath: "/")))
        // A file cannot be made inside a file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("acp-file-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!AgentACPRun.confined(file.path + "/new.md", to: FileManager.default.temporaryDirectory))
    }

}

/// Asking about another Lamp chat, from Lamp's own transcripts.
struct LampAgentChatHistoryTests {
    private struct Library {
        let root: URL
        let readerChat: UUID
        let otherReaderChat: UUID
    }

    private func library() throws -> Library {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-history-\(UUID().uuidString)", isDirectory: true)
        let readerChat = UUID()
        let otherReaderChat = UUID()
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        func transcript(_ lines: [(AgentChatTranscript.Role, String)], from: Date) -> AgentChatTranscript {
            var transcript = AgentChatTranscript()
            transcript.messages = lines.enumerated().map { index, line in
                .init(role: line.0, text: line.1, date: from.addingTimeInterval(Double(index) * 60))
            }
            return transcript
        }
        try AgentChatTranscriptStore.save(
            transcript([(.user, "What does hesed mean in Ruth 1?"), (.assistant, "Loyal, covenant love.")], from: start),
            providerID: "claude",
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, chatID: readerChat)
        )
        try AgentChatTranscriptStore.save(
            transcript((0..<50).map { ($0 % 2 == 0 ? .user : .assistant, "message \($0)") }, from: start.addingTimeInterval(3600)),
            providerID: "codex",
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, chatID: otherReaderChat)
        )
        let writing = LampWritingWorkspace.url(libraryRootURL: root, writingID: "w1")
        try FileManager.default.createDirectory(at: writing, withIntermediateDirectories: true)
        try "# Patience in James\n\nText.".write(
            to: writing.appendingPathComponent(LampWritingWorkspace.draftFilename), atomically: true, encoding: .utf8
        )
        try "w1".write(
            to: writing.appendingPathComponent(LampWritingWorkspace.identifierFilename), atomically: true, encoding: .utf8
        )
        try AgentChatTranscriptStore.save(
            transcript([(.user, "Tighten the opening."), (.assistant, "Done.")], from: start.addingTimeInterval(7200)),
            providerID: "antigravity",
            in: writing
        )
        return Library(root: root, readerChat: readerChat, otherReaderChat: otherReaderChat)
    }

    @Test func everyChatIsListedNewestFirstWithThisOneMarked() throws {
        let fixture = try library()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chats = LampAgentChatHistory.list(libraryRootURL: fixture.root, thisReaderChat: fixture.readerChat)
        #expect(chats.map(\.chatID) == [
            "writing:w1", "reader:\(fixture.otherReaderChat.uuidString)", "reader:\(fixture.readerChat.uuidString)",
        ])
        #expect(chats[0].title == "Patience in James")
        #expect(chats[0].providers == ["antigravity"])
        #expect(chats[2].title == "What does hesed mean in Ruth 1?")
        #expect(chats[2].isThisChat)
        #expect(!chats[1].isThisChat)
        #expect(LampAgentChatHistory.list(libraryRootURL: fixture.root, kind: "writing").count == 1)
    }

    @Test func aChatIsReadAsItsMostRecentMessagesOrFromAnOffset() throws {
        let fixture = try library()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = "reader:\(fixture.otherReaderChat.uuidString)"
        let recent = try LampAgentChatHistory.read(chatID: id, libraryRootURL: fixture.root, limit: 10)
        #expect(recent.totalMessages == 50)
        #expect(recent.offset == 40)
        #expect(recent.messages.first?.text == "message 40")
        #expect(recent.provider == "codex")
        let earlier = try LampAgentChatHistory.read(chatID: id, libraryRootURL: fixture.root, offset: 0, limit: 2)
        #expect(earlier.messages.map(\.text) == ["message 0", "message 1"])
        #expect(throws: LampAgentChatHistory.Failure.noSuchProvider("claude")) {
            try LampAgentChatHistory.read(chatID: id, provider: "claude", libraryRootURL: fixture.root)
        }
    }

    @Test func aClearedChatDoesNotHideAnOlderOne() throws {
        let fixture = try library()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // The newest file of all, and nothing in it.
        let cleared = UUID()
        try AgentChatTranscriptStore.save(
            AgentChatTranscript(), providerID: "claude",
            in: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: fixture.root, chatID: cleared)
        )
        let newest = LampAgentChatHistory.list(libraryRootURL: fixture.root, limit: 1)
        #expect(newest.count == 1)
        #expect(newest.first?.chatID != "reader:\(cleared.uuidString)")
    }

    @Test func aWritingIsTitledByItsBriefBeforeItsDraft() throws {
        let fixture = try library()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = LampWritingWorkspace.url(libraryRootURL: fixture.root, writingID: "w1")
        try "# Devotional brief\n\n- Title: Patience, the Long Way\n- Subtitle: None\n".write(
            to: workspace.appendingPathComponent(LampWritingWorkspace.contextFilename), atomically: true, encoding: .utf8
        )
        let chats = LampAgentChatHistory.list(libraryRootURL: fixture.root, kind: "writing")
        #expect(chats.first?.title == "Patience, the Long Way")
        #expect(try LampAgentChatHistory.read(chatID: "writing:w1", libraryRootURL: fixture.root).title
            == "Patience, the Long Way")
    }

    @Test func aChatIDNamesOnlyAChatNeverAFolder() throws {
        let fixture = try library()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for id in ["writing:../../etc", "writing:nope", "reader:not-a-uuid", "../w1", "reader:\(UUID().uuidString)"] {
            #expect(throws: LampAgentChatHistory.Failure.unknownChat(id)) {
                try LampAgentChatHistory.read(chatID: id, libraryRootURL: fixture.root)
            }
        }
    }
}

/// CLIs launched in a process group of their own.
struct AgentSpawnedProcessTests {
    private func run(_ script: String, in directory: URL? = nil, environment: [String: String]? = nil,
                     input: String? = nil) throws -> (status: Int32, output: String) {
        let process = AgentSpawnedProcess()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin
        try process.run()
        if let stdin, let input {
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func itRunsWhereAndWithWhatItIsGiven() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let result = try run(#"pwd -P; echo "$LAMP_TEST"; cat; exit 3"#, in: directory,
                             environment: ["LAMP_TEST": "given", "PATH": "/usr/bin:/bin"], input: "typed")
        #expect(result.status == 3)
        #expect(result.output.contains(directory.path))
        #expect(result.output.contains("given"))
        #expect(result.output.contains("typed"))
    }

    @Test func lampsOwnFilesAreNotHandedDown() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spawn-fd-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let result = try run("[ -e /dev/fd/\(handle.fileDescriptor) ] && echo leaked || echo closed")
        #expect(result.output.contains("closed"))
    }

    @Test func aChildThatIgnoresStopIsStillKilledAfterItsParentHasGone() throws {
        let process = AgentSpawnedProcess()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The parent exits at once; its child ignores SIGTERM and holds the
        // output open, so the output never ends on its own.
        process.arguments = ["-c", #"(trap "" TERM; echo ready; sleep 30) & exit 0"#]
        process.standardOutput = output
        try process.run()
        // Only once the child is ignoring the ask: stopped any sooner, on a
        // busy machine, it dies before the trap is set.
        #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
        process.waitUntilExit()
        #expect(!process.isRunning)
        process.terminate()
        let ended = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = output.fileHandleForReading.readDataToEndOfFile()
            ended.signal()
        }
        #expect(ended.wait(timeout: .now() + 0.5) == .timedOut)
        // Its number is still the group's until release, so this is safe.
        process.signalGroup(SIGKILL)
        #expect(ended.wait(timeout: .now() + 5) == .success)
        let group = process.processIdentifier
        process.release()
        // Released, the number may be anyone's: nothing more is sent.
        process.signalGroup(SIGKILL)
        #expect(killpg(group, 0) != 0)
    }

    @Test func aStopReachesTheWholeGroupEvenAnOrphan() throws {
        let process = AgentSpawnedProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A child left behind by a parent that has exited, and one still
        // under the shell.
        process.arguments = ["-c", "(sleep 60 &); sleep 60 & wait"]
        try process.run()
        let group = process.processIdentifier
        Thread.sleep(forTimeInterval: 0.3)
        #expect(killpg(group, 0) == 0)
        process.terminate()
        #expect(process.waitUntilExit(within: 5))
        var gone = false
        for _ in 0..<100 where !gone {
            gone = killpg(group, 0) != 0
            if !gone { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(gone)
    }
}

/// What a run started that left its group: Claude Code's Bash commands and
/// Codex's command runner start sessions of their own.
struct AgentRunMembersTests {
    /// Starts `script` under /bin/sh in a group of its own, returning the
    /// process and the first line it prints.
    private func start(_ script: String) throws -> (AgentSpawnedProcess, String) {
        let process = AgentSpawnedProcess()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = output
        try process.run()
        var line = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([0x0A]) { break }
            line += byte
        }
        return (process, String(decoding: line, as: UTF8.self))
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func anOrphanInASessionOfItsOwnIsStillEnded() throws {
        // A command that starts its own session, as a tool runner does,
        // left behind when the shell that started it exits.
        let (process, printed) = try start(
            #"/usr/bin/python3 -c 'import os, time; os.setsid(); time.sleep(30)' & echo $!; sleep 1; exit 0"#
        )
        let orphan = try #require(pid_t(printed))
        let members = AgentRunMembers(rootPID: process.processIdentifier)
        members.sample()
        #expect(members.count >= 1)
        process.waitUntilExit()
        process.signalGroup(SIGKILL)
        // The group kill does not reach it: it is in a session of its own.
        #expect(isAlive(orphan))
        members.endAll()
        var gone = false
        for _ in 0..<100 where !gone {
            gone = !isAlive(orphan)
            if !gone { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(gone)
        process.release()
    }

    @Test func onlyOpenCodesBackgroundServiceIsSpared() {
        let service = ["opencode", "serve", "--service"]
        // As OpenCode 2 starts it: its own group, its own program.
        #expect(AgentRunMembers.isSpared(name: "opencode", pid: 500, group: 500, arguments: service))
        // The same inside the run's group is part of the run.
        #expect(!AgentRunMembers.isSpared(name: "opencode", pid: 500, group: 400, arguments: service))
        // A detached `opencode run` a tool started is the run's work.
        #expect(!AgentRunMembers.isSpared(name: "opencode", pid: 500, group: 500,
                                          arguments: ["opencode", "run", "edit the draft"]))
        #expect(!AgentRunMembers.isSpared(name: "opencode", pid: 500, group: 500,
                                          arguments: ["opencode", "serve"]))
        #expect(!AgentRunMembers.isSpared(name: "codex", pid: 500, group: 500, arguments: service))
        #expect(!AgentRunMembers.isSpared(name: "python3", pid: 500, group: 500, arguments: []))
    }

    @Test func argumentsAreReadFromTheKernel() throws {
        let process = AgentSpawnedProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.signalGroup(SIGKILL); process.waitUntilExit(); process.release() }
        #expect(AgentRunMembers.arguments(of: process.processIdentifier) == ["/bin/sleep", "30"])
    }
}
