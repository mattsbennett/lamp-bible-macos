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
