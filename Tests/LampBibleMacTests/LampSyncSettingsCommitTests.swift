import Foundation
import LampBibleMacSupport
import LampCore
import Testing

@Suite struct LampSyncSettingsCommitTests {
    @Test func registeredDefaultsAreNotExplicitLocalSettings() throws {
        let domain = "lamp-settings-registered-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.register(defaults: ["reader.fontSize": 18.0])
        #expect(defaults.double(forKey: "reader.fontSize") == 18.0)
        #expect(LampSyncSettingsCommit.explicitSettings(
            from: defaults, storedIn: domain
        ).isEmpty)
    }

    @Test func interruptedSettingsCommitReplaysAfterLibrarySwap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-settings-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "lamp-settings-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(16.0, forKey: "reader.fontSize")
        defaults.set(1.2, forKey: "reader.lineSpacing")
        defaults.set("serif", forKey: "reader.typeface")
        defaults.set(["set-a": "old"], forKey: LampSyncSettingsCommit.highlightMappingKey)

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await library.withStagedChanges { staged in
            try LampSyncSettingsCommit.stage(
                baseline: ["reader.fontSize": 16.0, "reader.lineSpacing": 1.2,
                           "reader.typeface": "serif"],
                planned: ["reader.fontSize": 19.0, "reader.lineSpacing": 1.4],
                highlightMappingBaseline: ["set-a": "old"],
                plannedHighlightMapping: ["set-a": "new"],
                in: staged.rootURL
            )
        }
        let pending = library.rootURL.appendingPathComponent(
            LampSyncSettingsCommit.pendingFilename
        )
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(defaults.double(forKey: "reader.fontSize") == 16.0)

        // Simulate a crash after one UserDefaults field was applied.
        defaults.set(19.0, forKey: "reader.fontSize")
        #expect(try LampSyncSettingsCommit.recover(
            from: library.rootURL, to: defaults, storedIn: domain
        ))
        #expect(defaults.double(forKey: "reader.fontSize") == 19.0)
        #expect(defaults.double(forKey: "reader.lineSpacing") == 1.4)
        #expect(defaults.object(forKey: "reader.typeface") == nil)
        #expect(defaults.dictionary(
            forKey: LampSyncSettingsCommit.highlightMappingKey
        ) as? [String: String] == ["set-a": "new"])
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(try !LampSyncSettingsCommit.recover(
            from: library.rootURL, to: defaults, storedIn: domain
        ))
    }

    @Test func unrelatedSettingsEditStopsRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-settings-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "lamp-settings-conflict-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(16.0, forKey: "reader.fontSize")
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await library.withStagedChanges { staged in
            try LampSyncSettingsCommit.stage(
                baseline: ["reader.fontSize": 16.0],
                planned: ["reader.fontSize": 19.0],
                highlightMappingBaseline: nil,
                plannedHighlightMapping: nil,
                in: staged.rootURL
            )
        }
        defaults.set(22.0, forKey: "reader.fontSize")
        #expect(throws: LampSyncSettingsCommit.CommitError.self) {
            try LampSyncSettingsCommit.recover(
                from: library.rootURL, to: defaults, storedIn: domain
            )
        }
        #expect(defaults.double(forKey: "reader.fontSize") == 22.0)
        #expect(FileManager.default.fileExists(atPath: library.rootURL
            .appendingPathComponent(LampSyncSettingsCommit.pendingFilename).path))
    }
}
