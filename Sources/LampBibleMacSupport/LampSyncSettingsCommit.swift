import Foundation
import LampModuleKit

/// Replays the UserDefaults half of a Mac pull after its staged library root
/// has replaced the live root. The journal is part of that root replacement,
/// so an interrupted settings write can be completed before the next sync.
public enum LampSyncSettingsCommit {
    public static let pendingFilename = ".lamp-sync-settings-pending.plist"
    public static let highlightMappingKey = "sync.webdav.iosHighlightModuleIDsBySet"

    public enum CommitError: LocalizedError {
        case invalidJournal
        case changedSetting(String)
        case changedHighlightMapping
        case settingsNotPersisted

        public var errorDescription: String? {
            switch self {
            case .invalidJournal: "The pending sync settings could not be read."
            case .changedSetting(let key): "Local setting changed before sync recovery: \(key)."
            case .changedHighlightMapping: "The local highlight mapping changed before sync recovery."
            case .settingsNotPersisted: "The pending sync settings could not be saved."
            }
        }
    }

    public static func explicitSettings(
        from defaults: UserDefaults,
        storedIn domainName: String? = Bundle.main.bundleIdentifier
    ) -> [String: Any] {
        let explicit: [String: Any]
        if let domainName {
            explicit = defaults.persistentDomain(forName: domainName) ?? [:]
        } else {
            explicit = defaults.dictionaryRepresentation()
        }
        return explicit.filter { LampPortableSettingsCodec.syncedKeys.contains($0.key) }
    }

    public static func stage(
        baseline: [String: Any],
        planned: [String: Any],
        highlightMappingBaseline: [String: String]?,
        plannedHighlightMapping: [String: String]?,
        in libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        guard validSettings(baseline), validSettings(planned) else {
            throw CommitError.invalidJournal
        }
        var journal: [String: Any] = [
            "formatVersion": 1,
            "baseline": baseline,
            "planned": planned,
            "applyHighlightMapping": plannedHighlightMapping != nil,
        ]
        if let plannedHighlightMapping {
            journal["highlightMappingBaseline"] = highlightMappingBaseline ?? [:]
            journal["plannedHighlightMapping"] = plannedHighlightMapping
        }
        guard PropertyListSerialization.propertyList(journal, isValidFor: .binary) else {
            throw CommitError.invalidJournal
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: journal, format: .binary, options: 0
        )
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try data.write(
            to: libraryRoot.appendingPathComponent(pendingFilename), options: .atomic
        )
    }

    @discardableResult
    public static func recover(
        from libraryRoot: URL,
        to defaults: UserDefaults,
        storedIn domainName: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let url = libraryRoot.appendingPathComponent(pendingFilename)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let decoded = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        )
        guard let journal = decoded as? [String: Any],
              journal["formatVersion"] as? Int == 1,
              let baseline = journal["baseline"] as? [String: Any],
              let planned = journal["planned"] as? [String: Any],
              let applyHighlightMapping = journal["applyHighlightMapping"] as? Bool,
              validSettings(baseline), validSettings(planned) else {
            throw CommitError.invalidJournal
        }
        let mappingBaseline: [String: String]
        let mappingPlanned: [String: String]
        if applyHighlightMapping {
            guard let base = journal["highlightMappingBaseline"] as? [String: String],
                  let next = journal["plannedHighlightMapping"] as? [String: String] else {
                throw CommitError.invalidJournal
            }
            mappingBaseline = base
            mappingPlanned = next
        } else {
            mappingBaseline = [:]
            mappingPlanned = [:]
        }

        let current = explicitSettings(from: defaults, storedIn: domainName)
        for key in LampPortableSettingsCodec.syncedKeys {
            guard sameValue(current[key], baseline[key])
                || sameValue(current[key], planned[key]) else {
                throw CommitError.changedSetting(key)
            }
        }
        if applyHighlightMapping {
            let currentMapping = defaults.dictionary(forKey: highlightMappingKey)
                as? [String: String] ?? [:]
            guard currentMapping == mappingBaseline || currentMapping == mappingPlanned else {
                throw CommitError.changedHighlightMapping
            }
        }

        for key in LampPortableSettingsCodec.syncedKeys {
            if let value = planned[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        if applyHighlightMapping {
            defaults.set(mappingPlanned, forKey: highlightMappingKey)
        }
        guard defaults.synchronize() else { throw CommitError.settingsNotPersisted }
        try fileManager.removeItem(at: url)
        return true
    }

    private static func validSettings(_ settings: [String: Any]) -> Bool {
        settings.keys.allSatisfy { LampPortableSettingsCodec.syncedKeys.contains($0) }
            && PropertyListSerialization.propertyList(settings, isValidFor: .binary)
    }

    private static func sameValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let left?, let right?): (left as? NSObject)?.isEqual(right) == true
        default: false
        }
    }
}
