import Foundation
import Testing
@testable import LampBibleMacSupport

struct AgentRevisionSupportTests {
    @Test func revisionsAreDurableOrderedAndReversible() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            providerName: "Codex",
            before: "Original",
            after: "Agent draft",
            in: workspace,
            createdAt: firstDate
        )
        try DevotionalAgentRevisionStore.record(
            kind: .restoration,
            before: "Agent draft",
            after: "Original",
            in: workspace,
            createdAt: secondDate
        )

        let revisions = try DevotionalAgentRevisionStore.revisions(in: workspace)
        #expect(revisions.map(\.createdAt) == [secondDate, firstDate])
        #expect(revisions[1].beforeMarkdown == "Original")
        #expect(revisions[1].afterMarkdown == "Agent draft")
        #expect(revisions[1].providerName == "Codex")
    }

    @Test func identicalLatestRevisionIsDeduplicated() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let first = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            before: "Before",
            after: "After",
            in: workspace
        )
        let duplicate = try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            before: "Before",
            after: "After",
            in: workspace
        )

        #expect(first != nil)
        #expect(duplicate == nil)
        #expect(try DevotionalAgentRevisionStore.revisions(in: workspace).count == 1)
    }

    @Test func revisionsAreScopedToEachMarkdownDocument() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try DevotionalAgentRevisionStore.record(
            kind: .agentEdit,
            before: "Before",
            after: "After",
            in: workspace
        )
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit,
            documentPath: "outline.md",
            before: "Before",
            after: "After",
            in: workspace
        )

        let draftRevisions = try DevotionalAgentRevisionStore.revisions(in: workspace)
        let outlineRevisions = try DevotionalAgentRevisionStore.revisions(
            in: workspace,
            documentPath: "outline.md"
        )
        #expect(draftRevisions.count == 1)
        #expect(draftRevisions.first?.resolvedDocumentPath == "draft.md")
        #expect(outlineRevisions.count == 1)
        #expect(outlineRevisions.first?.kind == .userEdit)
        #expect(outlineRevisions.first?.resolvedDocumentPath == "outline.md")
    }

    @Test func legacyRevisionWithoutDocumentPathBelongsToDraft() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let revisionsDirectory = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisionsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let identifier = UUID()
        let legacyJSON = """
        {
          "afterMarkdown" : "After",
          "beforeMarkdown" : "Before",
          "createdAt" : 100000,
          "id" : "\(identifier.uuidString)",
          "kind" : "agentEdit"
        }
        """
        try Data(legacyJSON.utf8).write(to: revisionsDirectory.appendingPathComponent("legacy.json"))

        let draftRevisions = try DevotionalAgentRevisionStore.revisions(in: workspace)
        #expect(draftRevisions.count == 1)
        #expect(draftRevisions.first?.documentPath == nil)
        #expect(draftRevisions.first?.resolvedDocumentPath == "draft.md")
        #expect(try DevotionalAgentRevisionStore.revisions(
            in: workspace,
            documentPath: "outline.md"
        ).isEmpty)
    }

    @Test func synchronizedDraftRoundTrips() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(try DevotionalAgentRevisionStore.lastSyncedDraft(in: workspace) == nil)
        try DevotionalAgentRevisionStore.markSynced("Current draft", in: workspace)
        #expect(try DevotionalAgentRevisionStore.lastSyncedDraft(in: workspace) == "Current draft")
    }
}
