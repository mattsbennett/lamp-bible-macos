import Foundation
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// The switch is off for a new library, on for one that already uses AI, and
/// a stored choice always wins.
struct AIFeaturesSupportTests {
    private func scratch() throws -> (URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIFeaturesSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AIFeaturesSupportTests.\(UUID().uuidString)"
        return (root, UserDefaults(suiteName: suite)!, suite)
    }

    @Test func aNewLibraryStaysOffAndStoresNothing() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        #expect(AIFeatures.settleIfUnset(libraryRootURL: root, defaults: defaults) == false)
        #expect(defaults.object(forKey: AIFeatures.key) == nil)
    }

    @Test func aLibraryWithAReaderChatIsSwitchedOn() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let chat = root.appendingPathComponent("AgentWorkspaces/Reader/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        #expect(AIFeatures.settleIfUnset(libraryRootURL: root, defaults: defaults))
        #expect(defaults.object(forKey: AIFeatures.key) as? Bool == true)
    }

    @Test func aWritingWorkspaceWithoutAnAgentIsNotUse() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("AgentWorkspaces/Devotionals/gideon", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("presentation.lampdeck"))
        #expect(!AIFeatures.libraryUsesAI(libraryRootURL: root, defaults: defaults))
        try Data().write(to: folder.appendingPathComponent("AGENTS.md"))
        #expect(AIFeatures.libraryUsesAI(libraryRootURL: root, defaults: defaults))
    }

    @Test func aChosenProviderIsUse() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("claude", forKey: "reader.chat.provider")
        #expect(AIFeatures.libraryUsesAI(libraryRootURL: root, defaults: defaults))
    }

    @Test func aStoredChoiceWins() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("claude", forKey: "reader.chat.provider")
        defaults.set(false, forKey: AIFeatures.key)
        #expect(AIFeatures.settleIfUnset(libraryRootURL: root, defaults: defaults) == false)
    }

    /// Codex review, finding 2: an older Mac carried another device's "off"
    /// in its sync baseline without applying the key it did not know. After
    /// the upgrade, inferring "on" from the chats would be published as this
    /// Mac's edit and override the other device's choice.
    @Test func anOffCarriedInTheSyncBaselineIsNotOverridden() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let chat = root.appendingPathComponent("AgentWorkspaces/Reader/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        let baseline = LampSharedPreferenceLedger(fields: [AIFeatures.key: .init(value: .boolean(false))])
        defaults.set(
            ["webdav:https://example.test/lamp": try LampSyncPreferenceState.encode(baseline)],
            forKey: "sync.sharedPreferences.bases"
        )
        #expect(AIFeatures.settleIfUnset(libraryRootURL: root, defaults: defaults) == false)
        #expect(defaults.object(forKey: AIFeatures.key) as? Bool == false)
    }
}
