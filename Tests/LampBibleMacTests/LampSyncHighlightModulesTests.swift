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

/// A recorded set-to-module mapping outlives the sets in it, and the phone
/// reuses a module ID as soon as the set holding it goes. Together those make
/// one module ID point at two sets, one of them gone — and a pass that acts on
/// a path has to pick the live one every time, not most of the time.
struct HighlightSetIDsByModuleTests {
    @Test func thesetAModuleStandsForIsTheOneThatStillExists() {
        // The phone's naming: delete a YLT set, make another, and it is
        // `ylt-highlights` again. The Mac learned both.
        let mapping = [
            "set-deleted-earlier": "ylt-highlights",
            "set-made-just-now": "ylt-highlights",
        ]

        let resolved = LampSyncHighlightModules.setIDsByModule(
            mapping, existingSetIDs: ["set-made-just-now"]
        )

        #expect(
            resolved["ylt-highlights"] == "set-made-just-now",
            "inverting the whole mapping picks whichever came out first, which is unordered"
        )
    }

    /// Run it enough times to catch an answer that depends on dictionary
    /// order. A per-process hash seed means one run proves nothing: the
    /// version this replaced passed and failed the same assertion on
    /// different launches.
    @Test func theanswerDoesNotDependOnDictionaryOrder() {
        for index in 0..<200 {
            let stale = "set-deleted-\(index)"
            let live = "set-live-\(index)"
            let resolved = LampSyncHighlightModules.setIDsByModule(
                [stale: "ylt-highlights", live: "ylt-highlights"],
                existingSetIDs: [live]
            )
            #expect(resolved["ylt-highlights"] == live)
        }
    }

    /// A set with no recorded module ID contributes nothing rather than an
    /// empty or guessed entry: the pass must not be handed a module ID it
    /// cannot justify.
    @Test func asetWithNoRecordedModuleIsLeftOut() {
        let resolved = LampSyncHighlightModules.setIDsByModule(
            ["mapped": "esvs-highlights"], existingSetIDs: ["mapped", "never-synced"]
        )

        #expect(resolved == ["esvs-highlights": "mapped"])
    }
}
