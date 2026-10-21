import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

struct TranslationImportSupportTests {
    private let bundledKJV = LampInstalledModule(
        id: "KJVs", kind: .translation, name: "King James Version", abbreviation: "KJV", isBundled: true
    )

    @Test func aNewAbbreviationGetsItsOwnModule() {
        let destination = TranslationImportSupport.destination(abbreviation: "NASB", installed: [bundledKJV])
        #expect(destination.moduleID == "imported-NASB")
        #expect(destination.replacing == nil)
    }

    @Test func importingAnAbbreviationAgainReplacesTheEarlierImport() {
        let earlier = LampInstalledModule(
            id: "imported-nasb", kind: .translation, name: "NASB 1995", abbreviation: "nasb"
        )
        let destination = TranslationImportSupport.destination(abbreviation: "NASB", installed: [bundledKJV, earlier])
        // The earlier module's own spelling, so the same file is replaced.
        #expect(destination.moduleID == "imported-nasb")
        #expect(destination.replacing == earlier)
    }

    @Test func anIDHeldByAnythingElseIsAvoided() {
        let dictionary = LampInstalledModule(id: "imported-NASB", kind: .dictionary, name: "Not a Bible")
        let destination = TranslationImportSupport.destination(abbreviation: "NASB", installed: [dictionary])
        #expect(destination.moduleID == "imported-NASB-2")
        #expect(destination.replacing == nil)
    }

    @Test func aSharedAbbreviationIsPointedOutUnlessItIsTheOneBeingReplaced() {
        let fresh = TranslationImportSupport.destination(abbreviation: "kjv", installed: [bundledKJV])
        #expect(TranslationImportSupport.translationSharingAbbreviation("kjv", installed: [bundledKJV], except: fresh) == bundledKJV)

        let earlier = LampInstalledModule(id: "imported-ESV", kind: .translation, name: "ESV", abbreviation: "ESV")
        let replacing = TranslationImportSupport.destination(abbreviation: "ESV", installed: [earlier])
        #expect(TranslationImportSupport.translationSharingAbbreviation("ESV", installed: [earlier], except: replacing) == nil)
    }

    @Test func theReportReadsAsSentences() {
        var report = LampTranslationImportReport()
        report.bookCount = 1
        report.chapterCount = 16
        report.verseCount = 433
        report.skippedBooks = ["TOB", "1MA"]
        report.verseBridges = [45_016_025]
        report.duplicateVerses = [45_001_001, 45_001_002]
        report.unrecognizedMarkup = ["\\zz": 2, "<foo>": 3]

        #expect(TranslationImportSupport.contentsLine(report) == "1 book, 16 chapters and 433 verses")
        #expect(TranslationImportSupport.noticeLines(report) == [
            "Left out, as they aren’t among the 66 books: TOB, 1MA.",
            "1 bridged verse is kept under its first number: Romans 16:25.",
            "Left out, as they appear twice: Romans 1:1, Romans 1:2.",
            "Formatting Lamp doesn’t know was dropped and its words kept: <foo> ×3, \\zz ×2.",
        ])
        #expect(TranslationImportSupport.completionMessage(name: "Romans Test", report: report, replaced: true)
            == "Replaced Romans Test: 1 book, 16 chapters and 433 verses.")
    }

    @Test func aCleanImportHasNothingToSayAndLongListsAreCut() {
        #expect(TranslationImportSupport.noticeLines(LampTranslationImportReport()).isEmpty)

        var report = LampTranslationImportReport()
        report.verseBridges = (1...7).map { 43_001_000 + $0 }
        #expect(TranslationImportSupport.noticeLines(report) == [
            "7 bridged verses are kept under their first number: John 1:1, John 1:2, John 1:3, John 1:4, John 1:5 and 2 more.",
        ])
    }

    @Test func theLanguagePickerAlwaysOffersWhatTheFileSaid() {
        let options = TranslationImportSupport.languageOptions(including: "en")
        #expect(options.contains { $0.code == "en" })
        #expect(options.allSatisfy { $0.code.count == 2 })
        #expect(TranslationImportSupport.languageOptions(including: "x-unknown").first?.code == "x-unknown")
    }
}
