import Foundation
import LampBibleMacSupport
import LampCore
import MCP
@testable import LampMCPServer
import Testing

struct LampMCPServerTests {
    @Test func advertisesOnlyReadOnlyToolsWithValidObjectSchemas() {
        let all = LampMCPToolCatalog.tools(workspace: true)
        #expect(LampMCPToolCatalog.tools.count == 15)
        #expect(LampMCPToolCatalog.deckTools.count == 3)
        #expect(all.count == 19)
        #expect(Set(all.map(\.name)).count == all.count)
        #expect(all.allSatisfy { $0.annotations.readOnlyHint == true })
        #expect(all.allSatisfy {
            $0.inputSchema.objectValue?["type"]?.stringValue == "object"
        })
    }

    /// A session with no workspace has no writing history, and a tool that can
    /// only answer "there is no workspace" is worse than no tool.
    @Test func offersTheWritingHistoryOnlyToASessionWithAWorkspace() {
        #expect(!LampMCPToolCatalog.tools(workspace: false).contains { $0.name == "writing_changes" })
        #expect(LampMCPToolCatalog.tools(workspace: true).contains { $0.name == "writing_changes" })
    }

    @Test func refusesTheWritingHistoryWithoutAWorkspace() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(library: LampAgentLibrary(libraryRootURL: fixture))
        await #expect(throws: LampMCPToolError.noWorkspace) {
            try await handler.call(name: "writing_changes", arguments: nil)
        }
    }

    @Test func readsTheWritingHistoryOfTheWorkspaceItWasGiven() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        let workspace = fixture.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit,
            before: "So on capacity there has been no meaningful change.",
            after: "But on this question of capacity, there has been no meaningful change.",
            in: workspace
        )

        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture),
            workspaceURL: workspace
        )
        let response = try await handler.call(name: "writing_changes", arguments: nil)
        #expect(response.isError == false)
        guard case .text(let text, _, _) = response.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("\"source\" : \"editor\""))
        #expect(text.contains("+But on this question of capacity"))
        #expect(text.contains("-So on capacity there has been no meaningful change."))

        // A time has to come back in the form `since` takes. It used to be
        // seconds from Apple's 2001 epoch in the structured copy and ISO 8601
        // in the text, so neither could be handed back without knowing which
        // was which.
        #expect(text.contains("\"at\" : \"20"))
        let structured = try #require(response.structuredContent)
        let changes = try #require(structured.objectValue?["results"]?.arrayValue)
        let at = try #require(changes.first?.objectValue?["at"]?.stringValue)
        guard case .time = LampWritingChanges.since(at) else {
            Issue.record("`at` should read back as a time: \(at)")
            return
        }
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
        // MCP requires an object here. A bare array makes Claude Code reject
        // the call as a schema violation, which disabled every Lamp tool.
        #expect(response.structuredContent == .object(["results": .array([])]))
        guard case .text(let text, _, _) = response.content.first else {
            Issue.record("Expected a text representation")
            return
        }
        #expect(text == "[\n\n]")
    }

    @Test(arguments: [
        ("list_modules", [String: Value]()),
        ("list_reading_plans", [:]),
        ("list_books", [:]),
        ("search_library", ["query": .string("grace")]),
        ("list_quiz_modules", [:]),
    ])
    func namesEveryStructuredResultAsAnObject(tool: String, arguments: [String: Value]) async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture)
        )
        let response = try await handler.call(name: tool, arguments: arguments)
        #expect(response.structuredContent?.objectValue != nil, "\(tool) must answer with an object")
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
