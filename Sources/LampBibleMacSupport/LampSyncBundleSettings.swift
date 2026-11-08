import Foundation
import LampCore
import LampModuleKit

/// The Mac's settings, as a Design B pass takes them from the bundle and puts
/// them back.
///
/// Two different things travel together here. `macSettings` is a plist of the
/// keys in `LampPortableSettingsCodec.syncedKeys` — font sizes, typefaces, a
/// chosen dictionary — which have no merge of their own: the newer copy
/// stands. `preferences` is the shared preference ledger, a handful of keys
/// (`LampSharedPreferenceLedger.sharedKeys`) that *are* merged field by field
/// against a remembered base, so a value changed on both devices is reported
/// as disputed and neither copy overwrites the other.
///
/// Where both carry the same key, the ledger wins: the plist's copies of the
/// shared keys are excluded on the way in, or a merge that deliberately kept
/// this Mac's value would be undone a line later by the other device's plist.
///
/// Nothing is written to the live defaults directly. The planned values are
/// journalled into the library root first and then replayed, so a crash
/// part-way through leaves the journal to finish the job rather than half a
/// person's preferences. `LampSyncSettingsCommit.recover` runs at the start of
/// every pass, which is what completes an interrupted one.
///
/// This duplicates a little of the archive pass's own settings handling, on
/// purpose: that path still runs until a library is migrated, and it was not
/// worth changing working code that governs someone's preferences in order to
/// share a few lines. It goes when the archive path does.
public struct LampSyncBundleSettings {
    /// What this Mac's settings would become, worked out but not yet written.
    ///
    /// Separate from applying it so the two can be told apart: the values are
    /// decided against a baseline, and the write refuses if that baseline has
    /// moved since.
    public struct Planned {
        public let merge: LampSharedPreferenceLedger.Merge
        let baseline: [String: Any]
        let planned: [String: Any]
        /// What this Mac and the server last agreed these settings were, or
        /// nil where no pass has published any yet. Without it a change made
        /// here and a change arriving from elsewhere look exactly alike.
        let base: [String: Any]?
        /// Filled in by `contribute` and read by `remember`: the settings as
        /// published, which is what the next pass judges against. A reference
        /// because `contribute` is handed the plan by value.
        let published = PublishedSettings()

        /// Shared preferences the two devices disagree about. Not an error:
        /// everything else syncs, neither value is published, and it stays
        /// disputed until the two are given the same value — so it has to be
        /// visible or it will sit there unnoticed.
        public var disputed: [String] { merge.disputed }
    }

    public typealias Received = Planned

    /// See `Planned.published`.
    final class PublishedSettings {
        var values: [String: Any]?
    }

    public enum SettingsError: LocalizedError {
        case couldNotStage
        case changedDuringSync

        public var errorDescription: String? {
            switch self {
            case .couldNotStage: "Lamp Bible could not prepare sync settings."
            case .changedDuringSync: "Local settings changed during sync."
            }
        }
    }

    private static let preferenceLedgerStateKey = "sync.sharedPreferences.bases"
    private static let macSettingsStateKey = "sync.macSettings.bases"

    private let defaults: UserDefaults
    private let libraryRoot: URL
    private let source: String
    private let domainName: String?
    private let fileManager: FileManager

    public init(
        defaults: UserDefaults,
        libraryRoot: URL,
        source: String,
        domainName: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.libraryRoot = libraryRoot
        self.source = source
        self.domainName = domainName
        self.fileManager = fileManager
    }

    /// Applies the bundle's settings to this Mac: plan, then write.
    @discardableResult
    public func receive(_ bundle: LampSyncSettingsBundle) throws -> Planned {
        let planned = try plan(bundle)
        try apply(planned)
        return planned
    }

    /// Works out what this Mac's settings become, writing nothing.
    public func plan(_ bundle: LampSyncSettingsBundle) throws -> Planned {
        let baseline = LampSyncSettingsCommit.explicitSettings(
            from: defaults, storedIn: domainName
        )
        let scratchName = "lamp-bundle-settings-\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: scratchName) else {
            throw SettingsError.couldNotStage
        }
        defer { scratch.removePersistentDomain(forName: scratchName) }
        scratch.setPersistentDomain(baseline, forName: scratchName)

        let base = cachedLedger()
        let sharedInUse = !bundle.preferences.fields.isEmpty || base != nil
        let settingsBase = cachedMacSettings()
        if let macSettings = bundle.macSettings {
            let excluded: Set<String> = sharedInUse
                ? LampSharedPreferenceLedger.sharedKeys
                : []
            if let settingsBase {
                // No one but a Mac writes `macSettings`, so a copy that
                // differs from the live settings is as likely to be this Mac's
                // own — published before the person changed something — as it
                // is another device's news. The base tells the two apart: where
                // the live value has moved away from it the change was made
                // here, and stands, for `contribute` to publish; where it has
                // not, the bundle's copy is the newer one and arrives.
                //
                // Both moved, differently, leaves the person's own choice where
                // they made it: this Mac publishes it, and the other device
                // takes it as news on its next pass, as it would any change.
                //
                // A key the bundle does not carry is no news either way. An
                // older Mac publishes only the keys its build knew, so absence
                // must never read as a deletion.
                for (key, value) in try LampPortableSettingsCodec.decode(macSettings)
                where !excluded.contains(key) {
                    guard Self.sameValue(baseline[key], settingsBase[key]) else { continue }
                    scratch.set(value, forKey: key)
                }
            } else {
                try LampPortableSettingsCodec.apply(
                    macSettings, to: scratch, excluding: excluded
                )
            }
        }

        let merge = try LampSharedPreferenceLedger.merge(
            local: try LampSharedPreferenceLedger.explicitValues(
                from: scratch, storedIn: scratchName
            ),
            base: base,
            remote: bundle.preferences.fields.isEmpty ? nil : bundle.preferences
        )
        // A disputed field is left out of `applicable`, so this Mac keeps what
        // its user set rather than having it replaced.
        try merge.applicable.apply(to: scratch)

        return Planned(
            merge: merge,
            baseline: baseline,
            planned: scratch.persistentDomain(forName: scratchName) ?? [:],
            base: settingsBase
        )
    }

    /// Writes the planned settings, through the journal.
    ///
    /// Refuses if the live settings have moved since the plan was made:
    /// someone changing a setting while the pass ran would otherwise have it
    /// silently reverted by a plan built before they did.
    public func apply(_ planned: Planned) throws {
        guard NSDictionary(
            dictionary: LampSyncSettingsCommit.explicitSettings(
                from: defaults, storedIn: domainName
            )
        ).isEqual(to: planned.baseline) else {
            throw SettingsError.changedDuringSync
        }
        guard !NSDictionary(dictionary: planned.planned).isEqual(to: planned.baseline) else {
            return
        }
        try LampSyncSettingsCommit.stage(
            baseline: planned.baseline,
            planned: planned.planned,
            highlightMappingBaseline: nil,
            plannedHighlightMapping: nil,
            in: libraryRoot,
            fileManager: fileManager
        )
        // `storedIn:` explicitly: it defaults to the bundle identifier, so
        // leaving it off reads a different domain from the one every other
        // line here uses. The two agree inside the app and disagree
        // anywhere else — the sort of difference that surfaces as a test
        // failing now and then rather than as a bug.
        try LampSyncSettingsCommit.recover(
            from: libraryRoot,
            to: defaults,
            storedIn: domainName,
            fileManager: fileManager
        )
    }

    /// Puts this Mac's settings into the bundle being written.
    ///
    /// Called after `receive`, so what goes up already holds whatever came
    /// down — the same order the archive pass publishes in.
    ///
    /// `publishable` rather than the whole ledger: a disputed field is
    /// published by neither device, which is what stops two Macs trading the
    /// same pair of values back and forth.
    /// Left exactly as it is when the values have not changed, even though a
    /// fresh encoding of them would differ.
    ///
    /// `LampPortableSettingsCodec.encode` serialises a Swift dictionary as a
    /// binary plist, and the key order follows the dictionary's iteration
    /// order, which Swift seeds per process. Measured: three runs of the same
    /// settings gave three different digests. Assigning the new bytes
    /// unconditionally would therefore change the bundle on every launch,
    /// write it, and hand every other device a revision to fetch and merge —
    /// for a file whose meaning had not moved.
    ///
    /// Compared by value, which is this project's rule for deciding whether
    /// anything changed, and the same rule that stops two clients trading
    /// their own spellings of identical content for ever.
    public func contribute(
        _ received: Received,
        to bundle: inout LampSyncSettingsBundle
    ) throws {
        let encoded = try LampPortableSettingsCodec.encode(from: defaults)
        if !settingsMatch(bundle.macSettings, encoded) {
            bundle.macSettings = encoded
        }
        // Left alone or written, these are the values the bundle now carries,
        // and so what the next pass judges a change against. Recorded here
        // rather than read back in `remember`: a setting changed between the
        // two would otherwise be remembered as published when it never was,
        // and the pass after that would take the server's copy over it.
        received.published.values = try LampPortableSettingsCodec.decode(encoded)
        bundle.preferences = received.merge.publishable
    }

    private func settingsMatch(_ existing: Data?, _ fresh: Data) -> Bool {
        guard let existing,
              let a = try? LampPortableSettingsCodec.decode(existing),
              let b = try? LampPortableSettingsCodec.decode(fresh)
        else { return false }
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    /// Remembers the merge's base for this source, once a publish has landed.
    ///
    /// Only after: the base is what the next merge judges "who changed it"
    /// against, so recording it for a publish that never happened would make
    /// this Mac's own unsent change look like the other device's.
    public func remember(_ received: Received) throws {
        try LampSyncPreferenceState.remember(
            received.merge.baseline,
            for: source,
            in: defaults,
            key: Self.preferenceLedgerStateKey
        )
        // Only what `contribute` actually put in the bundle: as with the
        // ledger's base, remembering a publish that never happened would make
        // this Mac's own unsent change look like the other device's.
        if let published = received.published.values {
            try rememberMacSettings(published)
        }
    }

    /// These settings as this Mac last published them to `source`.
    private func cachedMacSettings() -> [String: Any]? {
        guard let states = defaults.dictionary(forKey: Self.macSettingsStateKey),
              let data = states[source] as? Data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let settings = plist as? [String: Any]
        else { return nil }
        return settings.filter { LampPortableSettingsCodec.syncedKeys.contains($0.key) }
    }

    private func rememberMacSettings(_ settings: [String: Any]) throws {
        guard PropertyListSerialization.propertyList(settings, isValidFor: .binary) else {
            throw SettingsError.couldNotStage
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: settings, format: .binary, options: 0
        )
        var states = defaults.dictionary(forKey: Self.macSettingsStateKey) ?? [:]
        states[source] = data
        defaults.set(states, forKey: Self.macSettingsStateKey)
    }

    private static func sameValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let left?, let right?): (left as? NSObject)?.isEqual(right) == true
        default: false
        }
    }

    private func cachedLedger() -> LampSharedPreferenceLedger? {
        LampSyncPreferenceState.cached(
            for: source, in: defaults, key: Self.preferenceLedgerStateKey
        )
    }
}
