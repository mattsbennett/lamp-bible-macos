import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// Which pass a library gets. This one decision is what keeps a library that
/// has not moved syncing exactly as it did before: a server still holding an
/// archive must take the archive path, untouched, and only a library on the
/// per-file layout goes to the new pass.
struct LibrarySyncLayoutTests {
    @Test func aServerStillHoldingAnArchiveTakesTheArchivePath() async throws {
        let store = LayoutFakeStore()
        let body = Data("a module".utf8)
        store.bodies[LampSyncFolderLayout.bundlePath] = try LampSyncArchive(
            entries: [.init(
                path: "Modules/kjv.lamp",
                data: body,
                modifiedAt: Date(timeIntervalSince1970: 1_000),
                sha256: LampSyncContentRevision.digest(for: body)
            )]
        ).compressedData()
        store.revisions[LampSyncFolderLayout.bundlePath] = "\"archive-1\""

        guard case .archive = try await LampSyncLibraryLayout.of(store) else {
            Issue.record("an archive must not be read as the per-file layout")
            return
        }
    }

    /// And only a *readable* archive means "not yet moved". A damaged one
    /// raises its own error rather than being offered a move, so nobody is
    /// invited to migrate a library that cannot be read.
    @Test func adamagedArchiveIsAnErrorRatherThanAnOffer() async throws {
        let store = LayoutFakeStore()
        store.bodies[LampSyncFolderLayout.bundlePath] = Data("not an archive".utf8)
        store.revisions[LampSyncFolderLayout.bundlePath] = "\"broken-1\""

        await #expect(throws: (any Error).self) {
            _ = try await LampSyncLibraryLayout.of(store)
        }
    }

    @Test func aServerHoldingTheBundleTakesTheNewPass() async throws {
        let store = LayoutFakeStore()
        var bundle = LampSyncSettingsBundle()
        bundle.macSettings = Data("settings".utf8)
        store.bodies[LampSyncFolderLayout.bundlePath] = try bundle.encoded()
        store.revisions[LampSyncFolderLayout.bundlePath] = "\"bundle-1\""

        guard case .perFile(let opened) = try await LampSyncLibraryLayout.of(store) else {
            Issue.record("a bundle must be read as the per-file layout")
            return
        }
        #expect(opened?.revision == "\"bundle-1\"")
        #expect(opened?.bundle.macSettings == Data("settings".utf8))
    }

    /// Nothing there at all is the per-file layout with nothing in it: a
    /// first pass claims the path. Only a library that already holds
    /// *something* of an earlier shape has to be moved.
    @Test func aLibraryNobodyHasSyncedToStartsOnTheNewLayout() async throws {
        guard case .perFile(let opened) = try await LampSyncLibraryLayout.of(LayoutFakeStore())
        else {
            Issue.record("an empty library must start on the per-file layout")
            return
        }
        #expect(opened == nil)
    }
}

/// Only what `layout(of:)` asks of a store.
private final class LayoutFakeStore: LampSyncRemoteStore, @unchecked Sendable {
    var bodies: [String: Data] = [:]
    var revisions: [String: String] = [:]

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        guard let data = bodies[path] else { return nil }
        return LampSyncRemoteFile(data: data, revision: revisions[path])
    }

    func revision(path: String) async throws -> String? { revisions[path] }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        bodies[path] = data
        revisions[path] = "\"written\""
        return revisions[path]
    }
}
