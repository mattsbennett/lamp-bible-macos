import Foundation
import LampCore
import LampModuleKit

/// The decisions and wording around importing a Bible the user already has,
/// kept apart from the sheet that shows them.
public enum TranslationImportSupport {
    public struct Destination: Equatable, Sendable {
        public let moduleID: String
        /// An earlier import under the same abbreviation, which this one replaces.
        public let replacing: LampInstalledModule?
    }

    /// Importing the same abbreviation again replaces the earlier import —
    /// the way to take in a corrected file — rather than adding a second copy.
    /// An ID held by anything that isn't a translation is avoided.
    public static func destination(abbreviation: String, installed: [LampInstalledModule]) -> Destination {
        let moduleID = LampTranslationImporter.moduleID(forAbbreviation: abbreviation)
        if let earlier = installed.first(where: { $0.id.lowercased() == moduleID.lowercased() }) {
            guard earlier.kind == .translation, !earlier.isBundled else {
                return Destination(
                    moduleID: LampTranslationImporter.moduleID(
                        forAbbreviation: abbreviation,
                        avoiding: Set(installed.map(\.id))
                    ),
                    replacing: nil
                )
            }
            // Its own spelling, so the file it lives in is the one replaced.
            return Destination(moduleID: earlier.id, replacing: earlier)
        }
        return Destination(moduleID: moduleID, replacing: nil)
    }

    /// Another translation already shown under this abbreviation.
    public static func translationSharingAbbreviation(
        _ abbreviation: String,
        installed: [LampInstalledModule],
        except destination: Destination
    ) -> LampInstalledModule? {
        let wanted = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return installed.first {
            $0.kind == .translation
                && $0.id != destination.moduleID
                && $0.abbreviation?.lowercased() == wanted
        }
    }

    public struct LanguageOption: Equatable, Sendable {
        public let code: String
        public let name: String
    }

    /// Every language with a two-letter code, by name, with `code` among them
    /// even if Foundation can't name it — so the picker always shows what
    /// the file said.
    public static func languageOptions(including code: String) -> [LanguageOption] {
        languages.contains { $0.code == code } ? languages : [LanguageOption(code: code, name: code)] + languages
    }

    private static let languages: [LanguageOption] = Locale.LanguageCode.isoLanguageCodes
        .compactMap { language -> LanguageOption? in
            guard language.identifier.count == 2,
                  let name = Locale.current.localizedString(forLanguageCode: language.identifier) else { return nil }
            return LanguageOption(code: language.identifier, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    public static func contentsLine(_ report: LampTranslationImportReport) -> String {
        "\(counted(report.bookCount, "book")), \(counted(report.chapterCount, "chapter")) and \(counted(report.verseCount, "verse"))"
    }

    /// What the import left out or changed, one sentence each; empty when it
    /// took everything as it was.
    public static func noticeLines(_ report: LampTranslationImportReport) -> [String] {
        var lines: [String] = []
        if !report.skippedBooks.isEmpty {
            lines.append("Left out, as they aren’t among the 66 books: \(report.skippedBooks.joined(separator: ", ")).")
        }
        if !report.verseBridges.isEmpty {
            let count = report.verseBridges.count
            lines.append(
                "\(counted(count, "bridged verse")) \(count == 1 ? "is" : "are") kept under \(count == 1 ? "its" : "their") first number: \(references(report.verseBridges))."
            )
        }
        if !report.duplicateVerses.isEmpty {
            lines.append("Left out, as \(report.duplicateVerses.count == 1 ? "it appears" : "they appear") twice: \(references(report.duplicateVerses)).")
        }
        if !report.unrecognizedMarkup.isEmpty {
            let markup = report.unrecognizedMarkup
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: ", ")
            lines.append("Formatting Lamp doesn’t know was dropped and its words kept: \(markup).")
        }
        return lines
    }

    public static func completionMessage(name: String, report: LampTranslationImportReport, replaced: Bool) -> String {
        "\(replaced ? "Replaced" : "Imported") \(name): \(contentsLine(report))."
    }

    private static func references(_ references: [Int]) -> String {
        let shown = references.prefix(5).map { LampBibleReferenceFormatter.describeRange(from: $0, to: $0) }
        let rest = references.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }
}
