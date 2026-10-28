import Foundation
import LampCore
import LampModuleKit

/// Which way into the library a chosen file belongs to, and what to say once
/// it is there.
///
/// There are two ways in. A finished `.lamp` module is installed as it
/// stands; a Bible in somebody else's format — USFM, OSIS, an XML Bible, a
/// SWORD module — has to be read and converted first. The window offers them
/// as separate panes, which is honest about the difference but leaves a user
/// holding a `.lamp` standing in front of the Bible importer, where their own
/// module was told it "isn't a Bible format Lamp can import".
///
/// So the panes ask here rather than assuming. The pane someone chose is a
/// guess about what they have; the file is the fact, and either door takes
/// either file.
public enum LampLibraryAddition {
    public enum Route: Equatable {
        /// Install `lamp`. `others` were chosen alongside and are not
        /// modules; they are named in what the install reports rather than
        /// dropped in silence.
        case installModules(lamp: [URL], others: [URL])
        /// One file that is not a module: read it as a Bible instead.
        case readBible(URL)
        /// Nothing to act on: no module, and not a single other file to try
        /// to read as a Bible.
        case unusable
    }

    public static func isModule(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "lamp"
    }

    public static func route(_ urls: [URL]) -> Route {
        let lamp = urls.filter(isModule)
        guard lamp.isEmpty else {
            return .installModules(lamp: lamp, others: urls.filter { !isModule($0) })
        }
        // A Bible may be one file, a zip, or a folder of books, so anything at
        // all may be one and only the Bible reader can tell. It reads one
        // source at a time, though, so several files without a module among
        // them is a choice nobody can carry out.
        guard urls.count == 1, let url = urls.first else { return .unusable }
        return .readBible(url)
    }

    /// What to tell someone who has just installed modules, or nil when
    /// nothing was installed.
    ///
    /// Installing used to say nothing at all when it worked. The module
    /// appearing in the library is the proof, but it is not where the person
    /// who asked for it is standing.
    public static func installSummary(
        _ installed: [LampInstalledModule],
        notModules: [URL] = []
    ) -> String? {
        guard !installed.isEmpty else { return nil }
        var sentence = installed.count == 1
            ? "Installed \(quoted(installed[0].name)), \(installed[0].kind.additionDescription)."
            : "Installed \(installed.count) modules: \(list(installed.map(\.name)))."
        if !notModules.isEmpty {
            let names = list(notModules.map(\.lastPathComponent))
            sentence += notModules.count == 1
                ? " \(names) isn’t a Lamp module and was left alone — a Bible in another format comes in through Import a Bible."
                : " \(names) aren’t Lamp modules and were left alone — Bibles in other formats come in through Import a Bible."
        }
        return sentence
    }

    private static func list(_ names: [String]) -> String {
        let quoted = names.map { self.quoted($0) }
        guard let last = quoted.last else { return "" }
        guard quoted.count > 1 else { return last }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func quoted(_ name: String) -> String { "“\(name)”" }
}

extension LampModuleKind {
    /// How to name this kind in a sentence about one module: "Installed
    /// “The Bible Companion”, a reading plan."
    public var additionDescription: String {
        switch self {
        case .translation: "a translation"
        case .dictionary: "a dictionary"
        case .commentary: "a commentary"
        case .book: "a book"
        case .devotional: "a writing"
        case .notes: "a collection of notes"
        case .plan: "a reading plan"
        case .highlights: "a collection of highlights"
        case .quiz: "a quiz"
        }
    }
}
