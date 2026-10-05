import Foundation
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Two Macs syncing one devotional's workspace through a real sync archive.
struct WorkspaceFileDeletionSyncTests {
    // In the past, as real modification times are.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let devotional = "talk-123"

    private struct Macs {
        let root: URL
        let a: URL
        let b: URL

        init(devotional: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-workspace-deletions-\(UUID().uuidString)", isDirectory: true)
            a = root.appendingPathComponent("Mac A", isDirectory: true)
            b = root.appendingPathComponent("Mac B", isDirectory: true)
            for library in [a, b] {
                try FileManager.default.createDirectory(
                    at: library.appendingPathComponent("AgentWorkspaces/Devotionals/\(devotional)"),
                    withIntermediateDirectories: true
                )
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func sync(from source: URL, to destination: URL) throws {
            let outgoing = root.appendingPathComponent("outgoing-\(UUID().uuidString)", isDirectory: true)
            try LampWorkspaceSync.exportPortableWorkspaces(from: source, to: outgoing, installID: "mac")
            let archive = try LampSyncArchive.decode(
                compressedData: LampSyncArchive.create(from: outgoing).compressedData()
            )
            let incoming = root.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
            try archive.extract(to: incoming)
            try LampWorkspaceSync.importPortableWorkspaces(from: incoming, into: destination)
        }
    }

    private func workspace(_ library: URL) -> URL {
        library.appendingPathComponent("AgentWorkspaces/Devotionals/\(devotional)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL, at offset: TimeInterval) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(offset)],
            ofItemAtPath: url.path
        )
    }

    private func documents(_ library: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace(library).path)
            .filter { $0.hasSuffix(".md") }
            .sorted()
    }

    private func contextFiles(_ library: URL) -> [String] {
        let context = workspace(library).appendingPathComponent("context").path
        let all = FileManager.default.enumerator(atPath: context)?.allObjects as? [String] ?? []
        return all.filter { !$0.hasPrefix(".") && $0.contains(".") }.sorted()
    }

    // MARK: - Documents

    @Test func aDocumentDeletedOnOneMacIsRemovedFromTheOther() throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Outline", to: workspace(macs.a).appendingPathComponent("outline.md"), at: 0)
        try write("Notes", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try macs.sync(from: macs.a, to: macs.b)
        try macs.sync(from: macs.b, to: macs.a)
        #expect(try documents(macs.b) == ["notes.md", "outline.md"])

        // An agent or Finder removes it: Lamp only sees that it's gone.
        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))
        // B, which still has it, publishes first.
        try macs.sync(from: macs.b, to: macs.a)
        #expect(try documents(macs.a) == ["outline.md"])
        try macs.sync(from: macs.a, to: macs.b)
        #expect(try documents(macs.b) == ["outline.md"])
    }

    @Test func aDocumentEditedElsewhereAfterItsDeletionIsKept() throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Draft", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try macs.sync(from: macs.a, to: macs.b)
        try macs.sync(from: macs.b, to: macs.a)

        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))
        try write("Still wanted", to: workspace(macs.b).appendingPathComponent("notes.md"), at: 60)

        try macs.sync(from: macs.a, to: macs.b)
        try macs.sync(from: macs.b, to: macs.a)
        #expect(try String(contentsOf: workspace(macs.a).appendingPathComponent("notes.md"), encoding: .utf8)
            == "Still wanted")
        #expect(try documents(macs.b) == ["notes.md"])
    }

    @Test func aMacSyncingForTheFirstTimeSinceUpgradingCannotUndoADeletion() throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Notes", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try write("Notes", to: workspace(macs.b).appendingPathComponent("notes.md"), at: 0)
        // A already tracks the file; B has never synced with this version.
        try macs.sync(from: macs.b, to: macs.a)

        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))
        try macs.sync(from: macs.b, to: macs.a)
        try macs.sync(from: macs.a, to: macs.b)

        #expect(try documents(macs.a).isEmpty)
        #expect(try documents(macs.b).isEmpty)
    }

    // MARK: - Context

    @Test func aRemovedContextFileIsRemovedFromTheOtherMac() throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let context = workspace(macs.a).appendingPathComponent("context")
        try write("Commentary", to: context.appendingPathComponent("sources/commentary.txt"), at: 0)
        try write("Map", to: context.appendingPathComponent("map.txt"), at: 0)
        try macs.sync(from: macs.a, to: macs.b)
        try macs.sync(from: macs.b, to: macs.a)
        #expect(contextFiles(macs.b) == ["map.txt", "sources/commentary.txt"])

        try FileManager.default.removeItem(at: context.appendingPathComponent("sources"))
        try macs.sync(from: macs.b, to: macs.a)
        #expect(contextFiles(macs.a) == ["map.txt"])
        try macs.sync(from: macs.a, to: macs.b)
        #expect(contextFiles(macs.b) == ["map.txt"])
    }

    @Test func aContextFileAddedAgainAfterRemovalStays() throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        let contextA = workspace(macs.a).appendingPathComponent("context")
        try write("Map", to: contextA.appendingPathComponent("map.txt"), at: 0)
        try macs.sync(from: macs.a, to: macs.b)
        try macs.sync(from: macs.b, to: macs.a)

        try FileManager.default.removeItem(at: contextA.appendingPathComponent("map.txt"))
        try macs.sync(from: macs.a, to: macs.b)
        #expect(contextFiles(macs.b).isEmpty)

        // The same file, added again: still carrying its original, older date.
        try write("Map", to: workspace(macs.b).appendingPathComponent("context/map.txt"), at: 0)
        try macs.sync(from: macs.b, to: macs.a)
        try macs.sync(from: macs.a, to: macs.b)
        try macs.sync(from: macs.b, to: macs.a)
        #expect(contextFiles(macs.a) == ["map.txt"])
        #expect(contextFiles(macs.b) == ["map.txt"])
    }

    // MARK: - Format

    @Test func deletionsTravelBesideTheWorkspaceRatherThanAsAFile() throws {
        let macs = try Macs(devotional: devotional)
        defer { macs.remove() }
        try write("Notes", to: workspace(macs.a).appendingPathComponent("notes.md"), at: 0)
        try macs.sync(from: macs.a, to: macs.b)
        try FileManager.default.removeItem(at: workspace(macs.a).appendingPathComponent("notes.md"))

        let outgoing = macs.root.appendingPathComponent("outgoing", isDirectory: true)
        try LampWorkspaceSync.exportPortableWorkspaces(from: macs.a, to: outgoing, installID: "mac")
        let paths = try LampSyncArchive.create(from: outgoing).entries.map(\.path)
        #expect(paths.contains("Workspaces/Devotionals/\(devotional)/DeletedFiles.json"))
        // Earlier versions import only Documents and Context as files.
        #expect(!paths.contains { $0.contains("/Documents/") || $0.contains("/Context/") })
    }
}
