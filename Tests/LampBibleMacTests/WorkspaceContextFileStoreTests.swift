import Foundation
import Testing
@testable import LampBibleMacSupport

struct WorkspaceContextFileStoreTests {
    @Test func reusesIdenticalFilesWithinAndAcrossWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let firstSource = fixture.sourceDirectory.appendingPathComponent("research.md")
        let secondSource = fixture.sourceDirectory.appendingPathComponent("same-bytes.txt")
        try Data("shared context".utf8).write(to: firstSource)
        try Data("shared context".utf8).write(to: secondSource)

        let first = try #require(try WorkspaceContextFileStore.addContextItem(
            from: firstSource,
            to: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        ))
        let repeated = try #require(try WorkspaceContextFileStore.addContextItem(
            from: secondSource,
            to: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        ))
        let second = try #require(try WorkspaceContextFileStore.addContextItem(
            from: secondSource,
            to: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        ))

        #expect(try sameFile(first, repeated))
        #expect(try contextChildren(in: fixture.firstWorkspace).map(\.lastPathComponent) == [
            "research.md",
        ])
        #expect(try sameFile(first, second))

        let objects = fixture.libraryRoot
            .appendingPathComponent("AgentWorkspaces/.ContextObjects", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: objects.path).count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions]
            as? NSNumber
        #expect((permissions?.intValue ?? 0) & 0o222 == 0)

        try WorkspaceContextFileStore.removeContextItem(
            at: first,
            from: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: objects.path).count == 1)

        try WorkspaceContextFileStore.removeContextItem(
            at: second,
            from: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: objects.path).isEmpty)
    }

    @Test func preservesDirectoryLayoutWhileSharingIdenticalLeaves() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sourceFolder = fixture.sourceDirectory.appendingPathComponent("Class Sources")
        let nested = sourceFolder.appendingPathComponent("Week 2", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let firstSource = sourceFolder.appendingPathComponent("reading.md")
        let nestedSource = nested.appendingPathComponent("reading-copy.md")
        try Data("one reading".utf8).write(to: firstSource)
        try Data("one reading".utf8).write(to: nestedSource)

        let addedFolder = try #require(try WorkspaceContextFileStore.addContextItem(
            from: sourceFolder,
            to: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        ))
        let first = addedFolder.appendingPathComponent("reading.md")
        let second = addedFolder.appendingPathComponent("Week 2/reading-copy.md")

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(try sameFile(first, second))
        let objects = fixture.libraryRoot
            .appendingPathComponent("AgentWorkspaces/.ContextObjects", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: objects.path).count == 1)
    }

    @Test func consolidatesStandaloneFilesRestoredBySync() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let source = fixture.sourceDirectory.appendingPathComponent("source.pdf")
        try Data("restored bytes".utf8).write(to: source)
        let first = try #require(try WorkspaceContextFileStore.addContextItem(
            from: source,
            to: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        ))

        let secondContext = fixture.secondWorkspace.appendingPathComponent("context")
        try FileManager.default.createDirectory(at: secondContext, withIntermediateDirectories: true)
        let restored = secondContext.appendingPathComponent("restored.pdf")
        try Data("restored bytes".utf8).write(to: restored)

        try WorkspaceContextFileStore.consolidate(
            in: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        )

        #expect(try sameFile(first, restored))
        #expect(try Data(contentsOf: restored) == Data("restored bytes".utf8))
    }

    private func contextChildren(in workspace: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: workspace.appendingPathComponent("context"),
            includingPropertiesForKeys: nil
        )
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileManager.default.attributesOfItem(atPath: lhs.path)
        let right = try FileManager.default.attributesOfItem(atPath: rhs.path)
        return (left[.systemNumber] as? NSNumber) == (right[.systemNumber] as? NSNumber)
            && (left[.systemFileNumber] as? NSNumber) == (right[.systemFileNumber] as? NSNumber)
    }

    private struct Fixture {
        let root: URL
        let libraryRoot: URL
        let sourceDirectory: URL
        let firstWorkspace: URL
        let secondWorkspace: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
            sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
            firstWorkspace = libraryRoot
                .appendingPathComponent("AgentWorkspaces/Devotionals/first", isDirectory: true)
            secondWorkspace = libraryRoot
                .appendingPathComponent("AgentWorkspaces/Devotionals/second", isDirectory: true)
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
