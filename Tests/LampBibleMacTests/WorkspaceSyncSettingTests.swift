import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMac

/// The workspace-sync setting as the controller enforces it (`decisions/0024`).
@MainActor
struct WorkspaceSyncSettingTests {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "lamp-workspace-setting-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// Turning it off is refused while sources are only on the server — they
    /// would be stranded there — and allowed once they are not.
    @Test func itCannotBeTurnedOffWhileSourcesAreOnlyOnTheServer() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: WorkspaceFilesSync.key)
        defaults.set(
            try JSONEncoder().encode(OffloadLock(source: "webdav:https://nas/s/", account: "user:a")),
            forKey: "sync.offloadLock"
        )
        let controller = LibrarySyncController(defaults: defaults)

        controller.syncsWorkspaceFiles = false
        #expect(controller.syncsWorkspaceFiles, "refused")
        #expect(controller.errorMessage != nil, "and said")

        defaults.removeObject(forKey: "sync.offloadLock")
        controller.syncsWorkspaceFiles = false
        #expect(!controller.syncsWorkspaceFiles)
    }

    /// Turning it off withdraws an offload still waiting, with no pass and no
    /// server, and the writing's pane is told why.
    @Test func turningItOffWithdrawsWaitingOffloads() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LibrarySyncController.Provider.webDAV.rawValue, forKey: "sync.provider")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-withdraw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("AgentWorkspaces/Writing/advent", isDirectory: true)
        let file = workspace.appendingPathComponent("context/history.pdf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Daniell".utf8).write(to: file)
        try await WorkspaceContextFileStore.queueOffload(relativePath: "history.pdf", in: workspace)
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspace) == ["history.pdf"])

        let controller = LibrarySyncController(defaults: defaults)
        await controller.withdrawRequestsOffAWebDAVServer(library: LampLibrary(rootURL: root))

        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspace).isEmpty)
        // Keyed by the workspace as the library lists it; the temporary
        // folder this test uses is reached through a link.
        let key = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(controller.offloadRefusals.count == 1)
        #expect(controller.offloadRefusals.first.map {
            $0.key.hasSuffix("AgentWorkspaces/Writing/advent") && $0.value.contains("workspace sync")
        } == true, "for \(key)")
        #expect(FileManager.default.fileExists(atPath: file.path), "nothing deleted")
    }

    private func libraryWithAWaitingOffload() async throws -> (root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-withdraw-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("AgentWorkspaces/Writing/advent", isDirectory: true)
        let file = workspace.appendingPathComponent("context/history.pdf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Daniell".utf8).write(to: file)
        try await WorkspaceContextFileStore.queueOffload(relativePath: "history.pdf", in: workspace)
        return (root, workspace)
    }

    /// While offloads are allowed again — workspace sync turned back on
    /// before a withdrawal ran — a waiting request is the reader's to keep.
    @Test func awithdrawalLeavesRequestsAloneOnceOffloadsAreAllowedAgain() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LibrarySyncController.Provider.webDAV.rawValue, forKey: "sync.provider")
        defaults.set(true, forKey: WorkspaceFilesSync.key)
        let (root, workspace) = try await libraryWithAWaitingOffload()
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = LibrarySyncController(defaults: defaults)
        await controller.withdrawRequestsOffAWebDAVServer(library: LampLibrary(rootURL: root))
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspace) == ["history.pdf"])
        #expect(controller.offloadRefusals.isEmpty)
    }

    /// A withdrawal that could not be saved is said as one, not as done.
    @Test(.enabled(if: geteuid() != 0, "root is not refused by permission bits"))
    func awithdrawalThatCannotBeSavedIsSaidAsSuch() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LibrarySyncController.Provider.webDAV.rawValue, forKey: "sync.provider")
        defaults.set(false, forKey: WorkspaceFilesSync.key)
        let (root, workspace) = try await libraryWithAWaitingOffload()
        defer { try? FileManager.default.removeItem(at: root) }
        let lamp = workspace.appendingPathComponent(".lamp", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lamp.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lamp.path) }

        let controller = LibrarySyncController(defaults: defaults)
        await controller.withdrawRequestsOffAWebDAVServer(library: LampLibrary(rootURL: root))
        #expect(await LampWorkspaceSync.leavingSourceNames(in: workspace) == ["history.pdf"], "still standing")
        #expect(controller.offloadRefusals.first?.value.contains("couldn't withdraw") == true)
    }
}
