import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Which door a chosen file goes through, and what the window says afterwards.
///
/// Both of these were real: a `.lamp` chosen in the Bible importer was told it
/// "isn't a Bible format Lamp can import" — about a module Lamp wrote — and an
/// install that worked said nothing at all.
struct LibraryAdditionTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private func module(
        _ name: String,
        kind: LampModuleKind = .translation,
        id: String? = nil
    ) -> LampInstalledModule {
        LampInstalledModule(id: id ?? name.lowercased(), kind: kind, name: name)
    }

    // MARK: - Which door

    @Test func amoduleIsInstalledWhicheverPaneChoseIt() {
        #expect(LampLibraryAddition.isModule(url("nasb.lamp")))
        #expect(LampLibraryAddition.isModule(url("NASB.LAMP")), "the extension is the file's, not a spelling")
        #expect(LampLibraryAddition.isModule(url("nasb.usfm")) == false)
    }

    /// The finding: a `.lamp` offered to the Bible importer. It is a Bible —
    /// one already converted — so it is installed rather than refused.
    @Test func afinishedModuleGoesToTheInstaller() {
        #expect(
            LampLibraryAddition.route([url("nasb.lamp")])
                == .installModules(lamp: [url("nasb.lamp")], others: [])
        )
    }

    /// And the other way: a Bible in another format, chosen where a module was
    /// expected, is read instead of being turned away over its extension.
    @Test func abibleInAnotherFormatGoesToTheReader() {
        #expect(LampLibraryAddition.route([url("nasb.usfm")]) == .readBible(url("nasb.usfm")))
        #expect(
            LampLibraryAddition.route([url("SwordModule")]) == .readBible(url("SwordModule")),
            "a folder of books has no extension at all"
        )
    }

    /// A mixed choice installs the modules. The rest are not silently
    /// dropped — the install names them.
    @Test func modulesChosenBesideSomethingElseAreStillInstalled() {
        #expect(
            LampLibraryAddition.route([url("plan.lamp"), url("nasb.usfm")])
                == .installModules(lamp: [url("plan.lamp")], others: [url("nasb.usfm")])
        )
    }

    /// The Bible reader takes one source at a time, so several files with no
    /// module among them is a choice that cannot be carried out.
    @Test func severalFilesWithNoModuleAmongThemCannotBeActedOn() {
        #expect(LampLibraryAddition.route([url("a.usfm"), url("b.usfm")]) == .unusable)
        #expect(LampLibraryAddition.route([]) == .unusable)
    }

    // MARK: - What it says afterwards

    @Test func onemoduleIsNamedWithWhatItIs() {
        #expect(
            LampLibraryAddition.installSummary([module("The Bible Companion", kind: .plan)])
                == "Installed “The Bible Companion”, a reading plan."
        )
    }

    @Test func severalModulesAreCounted() {
        let summary = LampLibraryAddition.installSummary([
            module("Berean Standard Bible"),
            module("Easton's Bible Dictionary", kind: .dictionary),
            module("The Bible Companion", kind: .plan),
        ])

        #expect(
            summary == """
            Installed 3 modules: “Berean Standard Bible”, “Easton's Bible Dictionary” \
            and “The Bible Companion”.
            """
        )
    }

    /// A file that came along and was not a module is accounted for, so
    /// nothing a user chose disappears without a word.
    @Test func whatWasNotAModuleIsAccountedFor() {
        let summary = LampLibraryAddition.installSummary(
            [module("The Bible Companion", kind: .plan)],
            notModules: [url("nasb.usfm")]
        )

        #expect(summary?.contains("“nasb.usfm” isn’t a Lamp module") == true)
        #expect(summary?.hasPrefix("Installed “The Bible Companion”") == true)
    }

    /// Nothing installed is nothing to celebrate: the error says what went
    /// wrong, and a confirmation beside it would contradict it.
    @Test func nothingInstalledSaysNothing() {
        #expect(LampLibraryAddition.installSummary([]) == nil)
        #expect(LampLibraryAddition.installSummary([], notModules: [url("nasb.usfm")]) == nil)
    }

    /// The interface calls a devotional module a writing, as everywhere else
    /// in the app.
    @Test func awritingIsCalledAWriting() {
        #expect(LampModuleKind.devotional.additionDescription == "a writing")
    }
}
