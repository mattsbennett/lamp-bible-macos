import AppKit
import Foundation
import LampModuleKit
import SwiftUI

/// The AI features switch on the Mac: whether the reader's chat, the writing
/// agent, plans made from a description, the AI settings and the system's
/// Writing Tools in Lamp's text are shown at all.
///
/// The value is core's shared preference (`LampPreferenceDefaults`), off by
/// default. Where none is stored, it is worked out from the library each
/// time it is read, never taken as off: an older Lamp that does not know the
/// key rewrites the shared preferences without it, and someone who uses AI
/// must not come back to find it gone.
public enum AIFeatures {
    public static let key = LampPreferenceDefaults.aiFeaturesKey
    /// The value before anyone chooses: off.
    public static let defaultValue = LampPreferenceDefaults.aiFeaturesEnabled

    /// Whether AI features are on as this moment's settings say, for code
    /// that is not a view and cannot observe the setting.
    public static var isEnabledNow: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    /// The system's Writing Tools in Lamp's text follow the switch: with AI
    /// off, Summarize, Rewrite and the rest are not offered anywhere in Lamp.
    public static var writingToolsBehavior: NSWritingToolsBehavior {
        isEnabledNow ? .default : .none
    }

    /// The reader-chat provider setting. Choosing one is a sign of use.
    static let readerChatProviderKey = "reader.chat.provider"

    /// Whether this library already uses AI: a reader chat kept on disk, a
    /// writing workspace set up for an agent, or a chat provider chosen.
    /// Cheap enough to ask at launch: a few directory listings, nothing read.
    public static func libraryUsesAI(
        libraryRootURL: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        if defaults.object(forKey: readerChatProviderKey) != nil { return true }
        let workspaces = libraryRootURL.appendingPathComponent("AgentWorkspaces", isDirectory: true)
        let chats = workspaces.appendingPathComponent("Reader", isDirectory: true)
        if let entries = try? fileManager.contentsOfDirectory(atPath: chats.path),
           entries.contains(where: { !$0.hasPrefix(".") }) {
            return true
        }
        // A writing's workspace can hold a linked deck without any agent; one
        // an agent was set up in has its instructions file.
        let writings = workspaces.appendingPathComponent("Devotionals", isDirectory: true)
        let folders = (try? fileManager.contentsOfDirectory(atPath: writings.path)) ?? []
        return folders.contains { folder in
            let url = writings.appendingPathComponent(folder, isDirectory: true)
            return ["AGENTS.md", "CLAUDE.md"].contains {
                fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
            }
        }
    }

    /// Where the Mac keeps the shared preferences each sync source last
    /// agreed on (`LibrarySyncController`).
    static let syncBaselinesKey = "sync.sharedPreferences.bases"

    /// The switch as some sync source last agreed it, if one did.
    static func agreedValue(in defaults: UserDefaults) -> Bool? {
        guard let bases = defaults.dictionary(forKey: syncBaselinesKey) else { return nil }
        for data in bases.values.compactMap({ $0 as? Data }) {
            guard let ledger = try? LampSyncPreferenceState.decode(data),
                  case .boolean(let value)? = ledger.fields[key]?.value else { continue }
            return value
        }
        return nil
    }

    /// Stores "on" where nothing is stored and the library already uses AI,
    /// so the choice is explicit and travels to the other devices. Leaves a
    /// stored value alone, and stores nothing for a library that does not use
    /// AI: off is the default, and a device that was never asked must not
    /// switch another off.
    @discardableResult
    public static func settleIfUnset(
        libraryRootURL: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        if let stored = defaults.object(forKey: key) as? Bool { return stored }
        // A value the devices last agreed on comes before anything worked
        // out here. An older Lamp keeps another device's choice in its sync
        // baseline without applying the key it does not know; inferring
        // "on" over it would then be published as this Mac's edit and
        // override that device's "off".
        if let agreed = agreedValue(in: defaults) {
            defaults.set(agreed, forKey: key)
            return agreed
        }
        guard libraryUsesAI(libraryRootURL: libraryRootURL, defaults: defaults, fileManager: fileManager) else {
            return LampPreferenceDefaults.aiFeaturesEnabled
        }
        defaults.set(true, forKey: key)
        return true
    }
}


/// A text view that asks the switch each time Writing Tools are offered, so
/// turning AI off takes effect in text already on screen.
open class LampTextView: NSTextView {
    override open var writingToolsBehavior: NSWritingToolsBehavior {
        get { AIFeatures.isEnabledNow ? super.writingToolsBehavior : .none }
        set { super.writingToolsBehavior = newValue }
    }
}

/// SwiftUI's text and text fields follow the switch: put on the root of every
/// window's content.
public struct LampWritingToolsGate: ViewModifier {
    @AppStorage(AIFeatures.key) private var aiFeaturesEnabled = AIFeatures.defaultValue

    public init() {}

    public func body(content: Content) -> some View {
        content.writingToolsBehavior(aiFeaturesEnabled ? .automatic : .disabled)
    }
}

extension View {
    /// Writing Tools offered only while AI features are on.
    public func lampWritingToolsGate() -> some View {
        modifier(LampWritingToolsGate())
    }
}
