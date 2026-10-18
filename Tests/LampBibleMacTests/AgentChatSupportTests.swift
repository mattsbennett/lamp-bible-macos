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
