import Foundation
import LampBibleMacSupport
import Testing
@testable import LampBibleMac

/// Allow for This Chat remembers one command, byte for byte, in one folder,
/// for one conversation (`decisions/0044`).
struct AgentChatCommandGrantTests {
    private static let codexRequest = #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","command":"/bin/zsh -lc 'blender -b'","cwd":"/w","reason":"GPU"}}"#

    private func codexAsk(_ line: String = codexRequest) throws -> AgentToolApprovalRequest {
        let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        guard case .ask(let request) = AgentCodexRun.reply(
            to: message["method"] as! String, params: message["params"] as! [String: Any], id: "codex-0"
        ) else { throw CancellationError() }
        return request
    }

    @Test func aCodexRequestOffersItsCommandAsSentAndItsFolder() throws {
        let grant = try #require(try codexAsk().chatGrant)
        // What ran, wrapper and all, not the unwrapped command the card shows.
        #expect(grant.commandText == "/bin/zsh -lc 'blender -b'")
        #expect(grant.folderText == "/w")
        #expect(grant.tool == AgentCodexRun.commandToolName)
    }

    @Test func aRequestNamingNoFolderOffersNothing() throws {
        let line = #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","command":"make"}}"#
        #expect(try codexAsk(line).chatGrant == nil)
    }

    @Test func claudeIsOfferedNoGrant() throws {
        let payload = Data(#"{"tool_name":"Bash","tool_input":{"command":"make"},"cwd":"/w"}"#.utf8)
        let request = try #require(AgentToolApprovalRequest(id: "c", hookPayload: payload))
        #expect(request.chatGrant == nil)
    }

    @Test func onlyTheSameBytesInTheSameFolderMatch() {
        let tool = AgentCodexRun.commandToolName
        let grant = AgentChatCommandGrant(tool: tool, command: "say café", folder: "/w")
        #expect(grant == AgentChatCommandGrant(tool: tool, command: "say café", folder: "/w"))
        for other in [
            AgentChatCommandGrant(tool: tool, command: "say café ", folder: "/w"),
            AgentChatCommandGrant(tool: tool, command: "say café", folder: "/x"),
            AgentChatCommandGrant(tool: tool, command: "say café", folder: "/w/"),
            // The same to Swift's ==, not to the shell.
            AgentChatCommandGrant(tool: tool, command: "say cafe\u{301}", folder: "/w"),
            AgentChatCommandGrant(tool: AgentACPRun.commandToolName, command: "say café", folder: "/w"),
        ] {
            #expect(grant != other)
        }
        let wrapped = AgentChatCommandGrant(tool: tool, command: "/bin/zsh -lc 'make'", folder: "/w")
        #expect(wrapped != AgentChatCommandGrant(tool: tool, command: "/bin/bash -lc 'make'", folder: "/w"))
        #expect(wrapped != AgentChatCommandGrant(tool: tool, command: "make", folder: "/w"))
    }

    @Test func anAntigravityCommandOffersItsSessionFolderAndIsAllowedOnceNeverAlways() throws {
        let params: [String: Any] = [
            "toolCall": ["kind": "execute", "rawInput": ["CommandLine": "make all"]],
            "options": [
                ["kind": "allow_once", "optionId": "once"],
                ["kind": "allow_always", "optionId": "always"],
                ["kind": "reject_once", "optionId": "no"],
            ],
        ]
        let request = try #require(AgentACPRun.commandRequest(permission: params, readOnly: false, id: "a", sessionFolder: "/w"))
        #expect(request.chatGrant == AgentChatCommandGrant(tool: AgentACPRun.commandToolName, command: "make all", folder: "/w"))
        #expect((AgentACPRun.outcome(for: .allow, permission: params) as NSDictionary).isEqual(to: ["outcome": "selected", "optionId": "once"]))
    }

    @Test func grantsAreHeldByChatAndOnlyThere() {
        let store = AgentChatCommandGrants()
        let workspace = URL(fileURLWithPath: "/w")
        #expect(AgentChatCommandGrants.key(provider: "codex", workspace: workspace, conversation: nil) == nil)
        let one = AgentChatCommandGrants.key(provider: "codex", workspace: workspace, conversation: UUID())!
        let next = AgentChatCommandGrants.key(provider: "codex", workspace: workspace, conversation: UUID())!
        let elsewhere = AgentChatCommandGrants.key(provider: "antigravity", workspace: workspace, conversation: UUID())!
        let grant = AgentChatCommandGrant(tool: "codex.command", command: "make", folder: "/w")
        store.add(grant, for: one)
        store.add(grant, for: one)
        #expect(store.list(for: one) == [grant])
        #expect(store.contains(grant, for: one))
        #expect(!store.contains(grant, for: next))
        #expect(!store.contains(grant, for: elsewhere))
        store.remove(grant, for: one)
        #expect(!store.contains(grant, for: one))
        store.add(grant, for: one)
        store.removeAll(for: one)
        #expect(store.list(for: one).isEmpty)
    }
}

/// With the fake Codex: a command allowed for the chat is accepted unasked,
/// in the same turn and the next; any other still comes to the card.
struct AgentChatCommandGrantRunnerTests {
    private func fakeCodex(requests: [String]) throws -> (folder: URL, script: URL, log: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-grant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("codex"), log = folder.appendingPathComponent("sent.log")
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        var lines = [
            "#!/bin/sh",
            "log=\(quoted(log.path))",
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"id":1,"result":{}}'"#,
            #"read -r l; printf '%s\n' "$l" >> "$log""#,
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"id":2,"result":{"thread":{"id":"t1"}}}'"#,
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"id":3,"result":{"turn":{"id":"u1"}}}'"#,
            #"echo '{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"u1"}}}'"#,
        ]
        for request in requests {
            lines += [
                "echo \(quoted(request))",
                #"while read -r l; do printf '%s\n' "$l" >> "$log"; case "$l" in *'"decision"'*|*'"result"'*) break;; esac; done"#,
            ]
        }
        lines += [
            #"echo '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m1","text":"Done.","phase":"final_answer"}}}'"#,
            #"echo '{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"u1","status":"completed"}}}'"#,
            #"while read -r l; do printf '%s\n' "$l" >> "$log"; done; exit 0"#,
        ]
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (folder, script, log)
    }

    private func request(_ id: Int, cwd: String = "/w") -> String {
        #"{"method":"item/commandExecution/requestApproval","id":\#(id),"params":{"kind":"command","command":"/bin/zsh -lc 'blender -b'","cwd":"\#(cwd)"}}"#
    }

    @Test func anAllowedCommandIsAcceptedUnaskedAndAnotherIsAsked() async throws {
        let fake = try fakeCodex(requests: [request(0), request(1), request(2, cwd: "/elsewhere")])
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let key = "codex|\(fake.folder.path)|\(UUID().uuidString)"
        let grant = AgentChatCommandGrant(tool: AgentCodexRun.commandToolName, command: "/bin/zsh -lc 'blender -b'", folder: "/w")
        AgentChatCommandGrants.shared.add(grant, for: key)
        defer { AgentChatCommandGrants.shared.removeAll(for: key) }
        let runner = AgentCLIProcessRunner()
        runner.useChatGrants(key)
        let shown = Locked<[String]>([])
        let result = await runner.runCodexAppServer(
            executableName: fake.script.path, workingDirectory: fake.folder, writingServer: nil,
            threadID: nil, model: nil, effort: nil, prompt: "Render it", answerSeconds: 30,
            onApprovals: { list in
                guard let request = list.first else { return }
                shown.mutate { $0.append(request.folder ?? (request.toolInput["cwd"] as? String ?? "")) }
                DispatchQueue.global().async { runner.answerApproval(request.id, with: .deny) }
            }
        )
        #expect(result.exitCode == 0)
        // Only the one in another folder came to the card.
        #expect(shown.value == ["/elsewhere"])
        let sent = (try? String(contentsOf: fake.log, encoding: .utf8)) ?? ""
        #expect(sent.components(separatedBy: #""decision":"accept""#).count - 1 == 2)
        #expect(sent.contains(#""decision":"decline""#))
    }

    @Test func withoutTheGrantTheSameCommandIsAsked() async throws {
        let fake = try fakeCodex(requests: [request(0)])
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let runner = AgentCLIProcessRunner()
        runner.useChatGrants("codex|\(fake.folder.path)|\(UUID().uuidString)")
        let shown = Locked<Int>(0)
        _ = await runner.runCodexAppServer(
            executableName: fake.script.path, workingDirectory: fake.folder, writingServer: nil,
            threadID: nil, model: nil, effort: nil, prompt: "Render it", answerSeconds: 30,
            onApprovals: { list in
                guard let request = list.first else { return }
                shown.mutate { $0 += 1 }
                DispatchQueue.global().async { runner.answerApproval(request.id, with: .deny) }
            }
        )
        #expect(shown.value == 1)
    }
}
