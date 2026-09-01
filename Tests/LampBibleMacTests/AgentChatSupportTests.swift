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
}
