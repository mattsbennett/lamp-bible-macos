import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// Which module a highlight set is published under is chosen once and then
/// lives only inside that module. A Mac that has lost the mapping must read
/// it back rather than choose again: choosing again publishes a second module
/// for a set that already has one, and the person then has the same
/// highlights twice.
struct LampSyncHighlightModulesTests {
    @Test func aMintedIdentityIsDerivedFromTheSetAndSafeForAPath() {
        #expect(LampSyncHighlightModules.mintedModuleID(forSet: "ESVs") == "esvs-highlights")
        #expect(
            LampSyncHighlightModules.mintedModuleID(forSet: "My Highlights")
                == "my-highlights-highlights"
        )
        // Nothing that could leave the folder it belongs in.
        for awkward in ["../escape", "a/b", "", "???"] {
            let minted = LampSyncHighlightModules.mintedModuleID(forSet: awkward)
            #expect(!minted.contains("/"))
            #expect(!minted.contains(".."))
            #expect(
                (try? LampSyncFolderLayout.modulePath(kind: .highlights, moduleID: minted)) != nil,
                "a minted ID must be spellable as a path: \(minted)"
            )
        }
    }

    @Test func anEmptyHighlightsFolderYieldsNothingRatherThanFailing() async throws {
        #expect(try await LampSyncHighlightModules.discover(in: EmptyStore()).isEmpty)
    }

    /// A module whose contents cannot be read teaches nothing, and must not
    /// stop the rest from being read.
    @Test func anUnreadableModuleIsSkipped() async throws {
        let store = HighlightsStore(bodies: [
            "Highlights/one.lamp": Data("not a module".utf8),
            "Highlights/two.lamp": Data("also not".utf8),
        ])
        #expect(try await LampSyncHighlightModules.discover(in: store).isEmpty)
    }
}

private struct EmptyStore: LampSyncRemoteStore {
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { nil }
    func read(path: String) async throws -> LampSyncRemoteFile? { nil }
    func revision(path: String) async throws -> String? { nil }
    func write(
        _ data: Data, to path: String, condition: LampSyncWriteCondition
    ) async throws -> String? { nil }
}

private struct HighlightsStore: LampSyncRemoteStore {
    let bodies: [String: Data]

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        bodies.keys.sorted().map { path in
            LampSyncRemoteEntry(
                path: path,
                name: String(path.split(separator: "/").last ?? ""),
                isDirectory: false,
                revision: "\"\(path)\"",
                modifiedAt: nil,
                size: Int64(bodies[path]?.count ?? 0)
            )
        }
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        bodies[path].map { LampSyncRemoteFile(data: $0, revision: "\"\(path)\"") }
    }

    func revision(path: String) async throws -> String? { bodies[path] == nil ? nil : "\"\(path)\"" }

    func write(
        _ data: Data, to path: String, condition: LampSyncWriteCondition
    ) async throws -> String? { nil }
}
