import Foundation
import Testing
@testable import LampBibleMacSupport

/// Stopping a provider CLI terminates it, and the CLIs exit 143 when
/// terminated. A stopped run therefore arrives looking exactly like a crash,
/// and used to be reported as one — "Claude exited with status 143" — for
/// something the user, or Lamp itself, had done.
struct AgentChatRunDispositionTests {
    /// The exact shape the chat pane saw: Lamp terminated the run, so the CLI
    /// exited 143 having streamed nothing.
    private let terminatedWithNothingSaid = ""

    @Test func aStoppedRunIsNotAFailure() {
        let disposition = AgentChatRunDisposition.of(
            output: terminatedWithNothingSaid,
            exitCode: 143,
            launchError: nil,
            wasStopped: true,
            provider: .claude,
            providerName: "Claude"
        )
        #expect(disposition == .stopped(partialReply: ""))
    }

    /// The bug verbatim. Whatever else changes, this number must never be put
    /// in front of the user as something the provider did.
    @Test func aStoppedRunNeverQuotesItsSignalExitStatus() {
        let disposition = AgentChatRunDisposition.of(
            output: terminatedWithNothingSaid,
            exitCode: 143,
            launchError: nil,
            wasStopped: true,
            provider: .claude,
            providerName: "Claude"
        )
        if case .failed(let message) = disposition {
            Issue.record("A stopped run was reported as a failure: \(message)")
        }
    }

    /// Stopping a long reply partway should keep what had already arrived.
    @Test func aStoppedRunKeepsWhatHadAlreadyArrived() {
        let streamed = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Here is the first half"}}}
        """
        let disposition = AgentChatRunDisposition.of(
            output: streamed,
            exitCode: 143,
            launchError: nil,
            wasStopped: true,
            provider: .claude,
            providerName: "Claude"
        )
        #expect(disposition == .stopped(partialReply: "Here is the first half"))
    }

    /// The same exit code, not stopped, is still a real failure: a CLI killed
    /// by something outside Lamp has nothing useful to say, and the status is
    /// the only thing left to report.
    @Test func thatSameExitCodeUnstoppedIsStillAFailure() {
        let disposition = AgentChatRunDisposition.of(
            output: "",
            exitCode: 143,
            launchError: nil,
            wasStopped: false,
            provider: .claude,
            providerName: "Claude"
        )
        #expect(disposition == .failed("Claude exited with status 143."))
    }

    @Test func aRunThatAnsweredIsAReply() {
        let streamed = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"result","subtype":"success","result":"All done."}
        """
        let disposition = AgentChatRunDisposition.of(
            output: streamed,
            exitCode: 0,
            launchError: nil,
            wasStopped: false,
            provider: .claude,
            providerName: "Claude"
        )
        #expect(disposition == .replied("All done."))
    }

    @Test func aLaunchErrorOutranksTheExitStatus() {
        let disposition = AgentChatRunDisposition.of(
            output: "",
            exitCode: -1,
            launchError: "claude is not installed.",
            wasStopped: false,
            provider: .claude,
            providerName: "Claude"
        )
        #expect(disposition == .failed("claude is not installed."))
    }

    @Test func aCleanRunThatSaidNothingIsSilentRatherThanFailed() {
        let disposition = AgentChatRunDisposition.of(
            output: "",
            exitCode: 0,
            launchError: nil,
            wasStopped: false,
            provider: .claude,
            providerName: "Claude"
        )
        #expect(disposition == .silent("Claude finished without returning a message."))
    }

    /// A CLI's own words beat a bare status when it printed any.
    @Test func printedOutputIsPreferredToTheExitStatus() {
        let disposition = AgentChatRunDisposition.of(
            output: "{\"type\":\"system\"}\nInvalid API key · Please run /login",
            exitCode: 1,
            launchError: nil,
            wasStopped: false,
            provider: .claude,
            providerName: "Claude"
        )
        #expect(disposition == .failed("Invalid API key · Please run /login"))
    }
}
