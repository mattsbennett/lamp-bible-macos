import Foundation
import Testing
@testable import LampBibleMac
@testable import LampBibleMacSupport

/// An Antigravity writing chat puts a command to the person on Lamp's card
/// (`decisions/0039`), as Codex's and Claude's do; a reader chat never asks.
struct AgentACPCommandTests {
    /// The request `agy acp` 1.5.14 sent to run a command, recorded
    /// 2026-11-26; only the session's id is changed.
    static let recorded = #"""
    {"sessionId":"s1","toolCall":{"sessionUpdate":"tool_call","toolCallId":"call_8396344239046598981","name":"run_command","args":{"CommandLine":"sw_vers -productVersion","WaitMsBeforeAsync":5000,"toolSummary":"Check macOS product version"},"status":"pending","kind":"execute","title":"sw_vers -productVersion","rawInput":{"CommandLine":"sw_vers -productVersion","WaitMsBeforeAsync":5000,"toolSummary":"Check macOS product version"}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}
    """#

    private var params: [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(Self.recorded.utf8)) as! [String: Any]
    }

    @Test func theRecordedCommandComesToThePersonWhole() throws {
        let request = try #require(AgentACPRun.commandRequest(permission: params, readOnly: false, id: "agy-1"))
        #expect(request.alwaysAllowRule == nil)
        let shown = AgentToolApprovalSummary.of(request)
        #expect(shown.title == "Run a command")
        // The command whole, then the agent's own account of it, said to be
        // its.
        #expect(shown.detail == "sw_vers -productVersion\n\nAntigravity says: Check macOS product version")
        #expect(shown.note?.contains("Lamp does not sandbox Antigravity") == true)
        // A reader chat never asks: its rule rejects.
        #expect(AgentACPRun.commandRequest(permission: params, readOnly: true, id: "agy-1") == nil)
        #expect(AgentACPRun.decide(permission: params, readOnly: true, workspace: URL(fileURLWithPath: "/tmp"),
                                   home: URL(fileURLWithPath: "/tmp"), sessionID: "s1") == "deny")
    }

    @Test func allowIsOnceAndNeverAlways() throws {
        var offered = params
        offered["options"] = [
            ["optionId": "always", "name": "Always", "kind": "allow_always"],
            ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
            ["optionId": "deny", "name": "Deny", "kind": "reject_once"],
        ]
        #expect(AgentACPRun.outcome(for: .allow, permission: offered) as NSDictionary == ["outcome": "selected", "optionId": "allow"])
        #expect(AgentACPRun.outcome(for: .deny, permission: offered) as NSDictionary == ["outcome": "selected", "optionId": "deny"])
        // With no once-only allow, it is not asked at all.
        offered["options"] = [["optionId": "always", "name": "Always", "kind": "allow_always"], ["optionId": "deny", "name": "Deny", "kind": "reject_once"]]
        #expect(AgentACPRun.commandRequest(permission: offered, readOnly: false, id: "agy-1") == nil)
        // Nor one whose command is only described.
        var described = params
        var call = described["toolCall"] as! [String: Any]
        call["rawInput"] = ["toolSummary": "Check the version"]
        described["toolCall"] = call
        #expect(AgentACPRun.commandRequest(permission: described, readOnly: false, id: "agy-1") == nil)
    }
}

/// The runner against a fake `agy acp`: it answers Lamp's requests, asks to
/// run a command, and touches a marker only when Lamp allows it.
@Suite(.serialized)
struct AgentACPCommandRunnerTests {
    struct Fake {
        let folder: URL
        var script: URL { folder.appendingPathComponent("agy") }
        var log: URL { folder.appendingPathComponent("sent.log") }
        var marker: URL { folder.appendingPathComponent("ran") }
        var sent: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        var ran: Bool { FileManager.default.fileExists(atPath: marker.path) }
    }

    private func fake() throws -> Fake {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agy-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = Fake(folder: folder)
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let request = #"{"jsonrpc":"2.0","id":"1","method":"session/request_permission","params":"# + AgentACPCommandTests.recorded.trimmingCharacters(in: .whitespacesAndNewlines) + "}"
        let lines = [
            "#!/bin/sh",
            "log=\(quoted(fake.log.path)); marker=\(quoted(fake.marker.path))",
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'"#,
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}'"#,
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"jsonrpc":"2.0","id":3,"result":{}}'"#,
            #"read -r l; printf '%s\n' "$l" >> "$log""#,
            "echo \(quoted(request))",
            #"while read -r l; do printf '%s\n' "$l" >> "$log"; case "$l" in *'"outcome"'*) break;; esac; done"#,
            #"case "$l" in *'"allow"'*) touch "$marker";; esac"#,
            #"echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}}}'"#,
            #"echo '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'"#,
            #"while read -r l; do printf '%s\n' "$l" >> "$log"; done; exit 0"#,
        ]
        try lines.joined(separator: "\n").write(to: fake.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.script.path)
        return fake
    }

    private func run(
        _ fake: Fake, runner: AgentCLIProcessRunner = AgentCLIProcessRunner(), answerSeconds: Double = 30,
        onApprovals: (@Sendable (AgentCLIProcessRunner, [AgentToolApprovalRequest]) -> Void)? = nil
    ) async -> AgentCLIProcessResult {
        await runner.runACP(
            executableName: fake.script.path, workingDirectory: fake.folder, mode: .writing,
            sessionID: nil, model: nil, effort: nil, prompt: "Check the version", answerSeconds: answerSeconds,
            onApprovals: { onApprovals?(runner, $0) }
        )
    }

    @Test func allowedOnceItRuns() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = await run(fake) { runner, list in
            guard let request = list.first else { return }
            DispatchQueue.global().async { runner.answerApproval(request.id, with: .allow) }
        }
        #expect(result.exitCode == 0)
        #expect(fake.ran)
    }

    @Test func deniedItDoesNot() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        _ = await run(fake) { runner, list in
            guard let request = list.first else { return }
            DispatchQueue.global().async { runner.answerApproval(request.id, with: .deny) }
        }
        #expect(!fake.ran)
        #expect(fake.sent.contains(#""optionId":"deny""#))
    }

    @Test func unansweredItIsDeclinedInTime() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let shown = Locked<[Int]>([])
        _ = await run(fake, answerSeconds: 0.5) { _, list in shown.mutate { $0.append(list.count) } }
        #expect(!fake.ran)
        #expect(fake.sent.contains(#""optionId":"deny""#))
        #expect(shown.value.first == 1 && shown.value.last == 0)
    }

    @Test func stopWhileItWaitsCancelsItAndAllowsNothing() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        _ = await run(fake) { runner, list in
            guard let request = list.first else { return }
            DispatchQueue.global().async {
                runner.cancel()
                runner.answerApproval(request.id, with: .allow)
            }
        }
        #expect(!fake.ran)
        #expect(fake.sent.contains(#""outcome":"cancelled""#))
        #expect(!fake.sent.contains(#""optionId":"allow""#))
    }
}
