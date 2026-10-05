import Foundation
import LampCore
import MCP
@testable import LampMCPServer
import Testing

struct LampMCPServerTests {
    @Test func advertisesOnlyReadOnlyToolsWithValidObjectSchemas() {
        #expect(LampMCPToolCatalog.tools.count == 15)
        #expect(Set(LampMCPToolCatalog.tools.map(\.name)).count == 15)
        #expect(LampMCPToolCatalog.tools.allSatisfy { $0.annotations.readOnlyHint == true })
        #expect(LampMCPToolCatalog.tools.allSatisfy {
            $0.inputSchema.objectValue?["type"]?.stringValue == "object"
        })
    }

    @Test func dispatchesAListCallWithStructuredContent() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture)
        )
        let response = try await handler.call(name: "list_modules", arguments: nil)
        #expect(response.isError == false)
        #expect(response.structuredContent == .array([]))
        guard case .text(let text, _, _) = response.content.first else {
            Issue.record("Expected a text representation")
            return
        }
        #expect(text == "[\n\n]")
    }

    @Test func rejectsUnknownToolsAndMissingArguments() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture)
        )
        await #expect(throws: LampMCPToolError.unknownTool("missing")) {
            try await handler.call(name: "missing", arguments: nil)
        }
        await #expect(throws: LampMCPToolError.missingArgument("reference")) {
            try await handler.call(name: "read_passage", arguments: [:])
        }
    }

    @Test func reloadsAccessPolicyBeforeEveryToolCall() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let policyURL = fixture.appendingPathComponent("policy.json")
        try JSONEncoder().encode(LampAgentAccessPolicy())
            .write(to: policyURL, options: .atomic)
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture.appendingPathComponent("Library")),
            policyURL: policyURL
        )

        _ = try await handler.call(name: "list_modules", arguments: nil)
        try JSONEncoder().encode(LampAgentAccessPolicy.disabled)
            .write(to: policyURL, options: .atomic)

        await #expect(throws: LampAgentError.disabled) {
            try await handler.call(name: "list_modules", arguments: nil)
        }
    }
}

struct LampMCPClientCompatibilityTests {
    // Verbatim from Codex 0.156.1.
    private let codexInitialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.156.1"}}}"#

    @Test func codexsHandshakeDecodes() throws {
        let original = Data(codexInitialize.utf8)
        // The failure being worked around: the SDK can't decode it as sent.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Request<Initialize>.self, from: original)
        }

        let compatible = LampMCPServerFactory.compatibleClientMessage(original)
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: compatible)
        #expect(request.params.clientInfo.name == "codex-mcp-client")
        #expect(request.params.protocolVersion == "2025-06-18")
        #expect(request.params.capabilities.elicitation != nil)
    }

    @Test func everyOtherMessagePassesThroughUnchanged() {
        let messages = [
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#,
            "not json",
        ]
        for message in messages {
            let data = Data(message.utf8)
            #expect(LampMCPServerFactory.compatibleClientMessage(data) == data)
        }
    }
}
