import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// Settings are the part of a sync a person notices going wrong: a font size
/// that keeps reverting, a reminder time that follows the other device. The
/// two kinds travelling in the bundle behave differently on purpose, and
/// these are the tests for the difference.
@Suite(.serialized)
struct LampSyncBundleSettingsTests {
    private let source = LampSyncFileRecords.webDAVSource(
        URL(string: "https://dav.example.com/sync/")!
    )

    private func makeDefaults() -> (defaults: UserDefaults, domain: String) {
        let domain = "lamp-bundle-settings-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }

    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-bundle-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func settings(_ values: [String: Any]) throws -> Data {
        let scratchName = "lamp-settings-source-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: scratchName)!
        defer { scratch.removePersistentDomain(forName: scratchName) }
        for (key, value) in values { scratch.set(value, forKey: key) }
        return try LampPortableSettingsCodec.encode(from: scratch)
    }

    @Test func aPlainSettingArrivesFromTheBundle() throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        defaults.set("Charter", forKey: "reader.typeface")

        var bundle = LampSyncSettingsBundle()
        bundle.macSettings = try settings(["reader.typeface": "Iowan Old Style"])

        let settings = LampSyncBundleSettings(
            defaults: defaults, libraryRoot: library, source: source, domainName: domain
        )
        _ = try settings.receive(bundle)

        #expect(defaults.string(forKey: "reader.typeface") == "Iowan Old Style")
    }

    /// The plist's copy of a shared key must not undo the ledger's merge.
    /// The ledger exists precisely so these keys are decided field by field;
    /// if the plist were applied over the top, a value this Mac had
    /// deliberately kept would be replaced a line later.
    ///
    /// Before any ledger exists there is nothing to undo, so the plist is
    /// applied as it is for any other key. The exclusion begins once the
    /// shared mechanism is in use.
    @Test func onceTheLedgerIsInUseThePlistCannotOverrideASharedKey() throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        let settings = LampSyncBundleSettings(
            defaults: defaults, libraryRoot: library, source: source, domainName: domain
        )

        // A first pass with nothing shared yet: this is what puts a base on
        // record, so the mechanism is in use from here on.
        try settings.remember(try settings.receive(LampSyncSettingsBundle()))

        // The person then chooses 18 here, and the other device's plist still
        // carries its own 11 while its ledger says nothing about the size.
        defaults.set(18.0, forKey: "reader.fontSize")
        var bundle = LampSyncSettingsBundle()
        bundle.macSettings = try self.settings(["reader.fontSize": 11.0])
        _ = try settings.receive(bundle)

        #expect(
            defaults.double(forKey: "reader.fontSize") == 18.0,
            "the plist must not drag a shared key back behind the ledger"
        )
    }

    @Test func whatThisMacHoldsGoesBackIntoTheBundle() throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        defaults.set(21.0, forKey: "devotional.fontSize")

        let settings = LampSyncBundleSettings(
            defaults: defaults, libraryRoot: library, source: source, domainName: domain
        )
        var bundle = LampSyncSettingsBundle()
        bundle.userSettings = Data("the phone's own".utf8)
        let received = try settings.receive(bundle)
        try settings.contribute(received, to: &bundle)

        let encoded = try #require(bundle.macSettings)
        #expect(try LampPortableSettingsCodec.decode(encoded)["devotional.fontSize"] as? Double == 21.0)
        // Not the Mac's to carry, and untouched by it.
        #expect(bundle.userSettings == Data("the phone's own".utf8))
    }

    /// Changed on both devices since they last agreed: neither value is
    /// published and neither overwrites the other, so it is reported instead.
    /// Silence here would leave someone wondering why one device never
    /// catches up.
    @Test func aValueChangedOnBothDevicesIsReportedAndLeftAlone() throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }

        // Both start agreeing at 14.
        defaults.set(14.0, forKey: "reader.fontSize")
        let settings = LampSyncBundleSettings(
            defaults: defaults, libraryRoot: library, source: source, domainName: domain
        )
        var bundle = LampSyncSettingsBundle()
        let agreed = try settings.receive(bundle)
        try settings.contribute(agreed, to: &bundle)
        try settings.remember(agreed)

        // This Mac goes to 20; the other device's ledger says 9.
        defaults.set(20.0, forKey: "reader.fontSize")
        var theirs = bundle
        theirs.preferences = try LampSharedPreferenceLedger.merge(
            local: ["reader.fontSize": .number(9)],
            base: agreed.merge.baseline,
            remote: nil
        ).publishable

        let received = try settings.receive(theirs)

        #expect(received.disputed == ["reader.fontSize"])
        #expect(defaults.double(forKey: "reader.fontSize") == 20.0, "this Mac keeps what its user set")
        var out = theirs
        try settings.contribute(received, to: &out)
        #expect(
            out.preferences.fields["reader.fontSize"]
                == theirs.preferences.fields["reader.fontSize"],
            "publishing a disputed field leaves the server's own value, so the other device's edit survives"
        )
    }

    /// The planned values are journalled into the library before they are
    /// applied, so an interruption leaves the journal to finish rather than
    /// half a person's preferences.
    @Test func theJournalIsWhatAppliesTheSettings() throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        defaults.set("Charter", forKey: "reader.typeface")

        var bundle = LampSyncSettingsBundle()
        bundle.macSettings = try settings(["reader.typeface": "Palatino"])
        _ = try LampSyncBundleSettings(
            defaults: defaults, libraryRoot: library, source: source, domainName: domain
        ).receive(bundle)

        // Replaying an already-applied journal is harmless, which is what
        // makes recovery at the start of every pass safe.
        try LampSyncSettingsCommit.recover(from: library, to: defaults)
        #expect(defaults.string(forKey: "reader.typeface") == "Palatino")
    }

    /// Someone changing a setting while the pass runs must not have it
    /// silently reverted by a plan built before they did. Testable because
    /// planning and writing are separate steps.
    @Test func aSettingChangedWhileThePassRanStopsTheWriteRatherThanLosing() throws {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library) }
        defaults.set("Charter", forKey: "reader.typeface")

        let settings = LampSyncBundleSettings(
            defaults: defaults, libraryRoot: library, source: source, domainName: domain
        )
        var bundle = LampSyncSettingsBundle()
        bundle.macSettings = try self.settings(["reader.typeface": "Palatino"])
        let planned = try settings.plan(bundle)

        // The person picks a typeface while the pass is mid-flight.
        defaults.set("Georgia", forKey: "reader.typeface")

        #expect(throws: LampSyncBundleSettings.SettingsError.self) {
            try settings.apply(planned)
        }
        #expect(
            defaults.string(forKey: "reader.typeface") == "Georgia",
            "what the person just chose stands; the pass tries again next time"
        )
    }
}
