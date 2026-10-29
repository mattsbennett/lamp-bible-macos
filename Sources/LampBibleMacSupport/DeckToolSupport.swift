import Foundation
import LampCore

/// Checking, deriving and drawing a deck, for callers that have the deck's text
/// rather than a folder to put it in.
///
/// The `build-lamp-deck` skill reached these three things through a shell: a
/// `python3` validator, and the helper's own `--build-deck` and
/// `--render-deck`. Two problems with that. An app like Claude Desktop has no
/// shell and no working folder, so the skill simply could not run there. And
/// macOS does not ship `python3` unless the developer tools are installed, so
/// the validation step was already failing on a plain Mac — inside Lamp's own
/// workspace, where the skill was supposed to work.
///
/// So the deck is passed as text and the answer comes back as values. The file
/// variants stay for the command line, which does have a folder, and both go
/// through the same code so a tool and a flag cannot disagree.
public enum LampDeckTools {
    public enum ToolError: Error, LocalizedError, Equatable {
        case undecodableDeck(String)

        public var errorDescription: String? {
            switch self {
            case .undecodableDeck(let detail):
                "The deck is not readable as a Lamp deck: \(detail)"
            }
        }
    }

    // MARK: - Validate

    public struct ValidationReport: Codable, Sendable {
        public var valid: Bool
        public var errorCount: Int
        public var warningCount: Int
        public var issues: [LampPresentationDeckIssue]
        public var deckTitle: String?
        public var slideCount: Int?
    }

    /// Checks a deck against the same rules Lamp applies when it imports one.
    ///
    /// Core's Swift validator, not the skill's `validate_deck.py`. The two are
    /// held to each other by `DeckValidatorAgreementTests`, so this says what
    /// the script says — it just does not need Python to say it.
    ///
    /// A deck too malformed to decode is a report, not a thrown error: "this
    /// is not a deck" is the most useful validation result there is, and an
    /// agent can act on it.
    ///
    /// Two things to know about that case, since it is the one place this and
    /// the script differ. A decoding failure stops at the *first* missing or
    /// wrong field, so a deck short of three required keys is told about one
    /// of them and has to come back; the script walks the whole deck and lists
    /// all three. And these messages are outside `DeckValidatorAgreementTests`,
    /// which compares the two validators on decks that decode — so nothing
    /// holds their wording to the script's, and it could not: `keyNotFound`
    /// knows the key is absent but not what belonged there, which is why the
    /// script can say "expected a string" and this cannot.
    public static func validate(deckJSON: Data) -> ValidationReport {
        let deck: LampPresentationDeck
        do {
            deck = try LampPresentationDeckStore.decodeUnvalidated(deckJSON)
        } catch {
            return ValidationReport(
                valid: false,
                errorCount: 1,
                warningCount: 0,
                issues: [decodingIssue(error)],
                deckTitle: nil,
                slideCount: nil
            )
        }
        let issues = LampPresentationDeckValidator.validate(deck)
        let errors = issues.filter { $0.severity == .error }
        return ValidationReport(
            valid: errors.isEmpty,
            errorCount: errors.count,
            warningCount: issues.count - errors.count,
            issues: issues,
            deckTitle: deck.title,
            slideCount: deck.slides.count
        )
    }

    /// A decoding failure said in terms of the deck, with the field it is at.
    ///
    /// A deck being written by hand is missing a key far more often than it is
    /// malformed, and the deck format requires several a writer would take for
    /// optional — `speakerNotes` on a slide, for one. "This is not a Lamp
    /// deck" is true of such a file and no use at all: it is one key from
    /// being a deck, and the agent cannot see which. The validator this
    /// replaces named the field, so this does too.
    private static func decodingIssue(_ error: Error) -> LampPresentationDeckIssue {
        func path(_ keys: [CodingKey]) -> String {
            keys.reduce(into: "") { result, key in
                if let index = key.intValue {
                    result += "[\(index)]"
                } else {
                    result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
        }

        switch error as? DecodingError {
        case .keyNotFound(let key, let context):
            let location = path(context.codingPath + [key])
            return LampPresentationDeckIssue(
                severity: .error,
                path: location,
                message: "Required field '\(location)' is missing."
            )
        case .typeMismatch(let type, let context):
            return LampPresentationDeckIssue(
                severity: .error,
                path: path(context.codingPath),
                message: "Expected \(type) here. \(context.debugDescription)"
            )
        case .valueNotFound(let type, let context):
            return LampPresentationDeckIssue(
                severity: .error,
                path: path(context.codingPath),
                message: "Expected \(type) here, and found null."
            )
        case .dataCorrupted(let context):
            let location = path(context.codingPath)
            return LampPresentationDeckIssue(
                severity: .error,
                path: location,
                message: location.isEmpty
                    ? "The deck is not valid JSON. \(context.debugDescription)"
                    : "Unreadable value. \(context.debugDescription)"
            )
        default:
            return LampPresentationDeckIssue(
                severity: .error,
                path: "",
                message: "The file is not a Lamp deck, or its JSON is malformed."
            )
        }
    }

    // MARK: - Build

    public struct BuildResult: Sendable {
        /// `LampDeckBuild.Report`, encoded, as `--build-deck` prints it.
        public var reportJSON: Data
        /// The deck with its notes and identifiers filled in.
        public var deckJSON: Data
        /// False when a slide's notes anchor is no longer in the manuscript.
        public var resolved: Bool
    }

    /// Derives what a deck can derive — speaker notes from the manuscript, and
    /// identifiers for anything new — and hands back both the report and the
    /// deck.
    ///
    /// Both, because a caller with no folder cannot read the deck back off
    /// disk afterwards the way the command line does.
    public static func build(
        deckJSON: Data,
        manuscript: String?,
        charts: LampDeckChartWorker? = nil
    ) async throws -> BuildResult {
        try await inScratchDirectory { scratch in
            let deckURL = scratch.appendingPathComponent("presentation.lampdeck")
            try deckJSON.write(to: deckURL)
            let manuscriptURL = try manuscript.map { text -> URL in
                let url = scratch.appendingPathComponent("draft.md")
                try Data(text.utf8).write(to: url)
                return url
            }
            let report = try await LampDeckBuild.build(
                deckURL: deckURL, manuscriptURL: manuscriptURL, charts: charts
            )
            return BuildResult(
                reportJSON: try encoded(report),
                // `build` writes the derived deck back over its input.
                deckJSON: try Data(contentsOf: deckURL),
                resolved: report.resolved
            )
        }
    }

    /// The command line's own path: the deck is already a file, and is
    /// rewritten in place.
    public static func buildFile(
        deckURL: URL,
        manuscriptURL: URL?,
        charts: LampDeckChartWorker? = nil
    ) async throws -> (json: Data, resolved: Bool) {
        let report = try await LampDeckBuild.build(
            deckURL: deckURL, manuscriptURL: manuscriptURL, charts: charts
        )
        return (try encoded(report), report.resolved)
    }

    // MARK: - Render

    public struct SlideImage: Sendable {
        public var slideNumber: Int
        public var title: String
        public var pngData: Data
    }

    public struct RenderResult: Sendable {
        /// `LampDeckPreview.Report`, encoded, as `--render-deck` prints it.
        public var reportJSON: Data
        public var images: [SlideImage]
        /// Slides the report says were drawn whose picture could not be read
        /// back. Carried rather than dropped: a caller comparing the report's
        /// `renderedCount` against the pictures it was given needs to be told
        /// which ones are missing, not left to count.
        public var unreadable: [Int]
    }

    /// Draws the deck and hands back the pictures themselves.
    ///
    /// A report cannot show a layout, which is the whole reason this step
    /// exists: every layout fault found in Lamp's own decks was invisible to
    /// the validator and obvious in a picture. An app that can display an
    /// image gets to see them without a folder to write them into.
    @MainActor
    public static func render(
        deckJSON: Data,
        manuscript: String?,
        libraryRoot: URL?,
        slideNumbers: [Int]?,
        width: Double
    ) async throws -> RenderResult {
        try await inScratchDirectory { scratch in
            let deckURL = scratch.appendingPathComponent("presentation.lampdeck")
            try deckJSON.write(to: deckURL)
            let manuscriptURL = try manuscript.map { text -> URL in
                let url = scratch.appendingPathComponent("draft.md")
                try Data(text.utf8).write(to: url)
                return url
            }
            let output = scratch.appendingPathComponent("preview", isDirectory: true)
            let report = try await LampDeckPreview.render(
                deckURL: deckURL,
                outputDirectory: output,
                overviewURL: nil,
                libraryRoot: libraryRoot,
                manuscriptURL: manuscriptURL,
                slideNumbers: slideNumbers,
                width: width
            )
            var images: [SlideImage] = []
            var unreadable: [Int] = []
            for slide in report.slides {
                // The report names each picture by its full path, so it is
                // used as one. Joining it to the output directory produced a
                // path that could not exist, and every read failed quietly.
                let url = slide.file.hasPrefix("/")
                    ? URL(fileURLWithPath: slide.file)
                    : output.appendingPathComponent(slide.file)
                guard let data = try? Data(contentsOf: url) else {
                    unreadable.append(slide.index)
                    continue
                }
                images.append(SlideImage(
                    slideNumber: slide.index,
                    title: slide.title,
                    pngData: data
                ))
            }
            return RenderResult(
                reportJSON: try encoded(report),
                images: images,
                unreadable: unreadable
            )
        }
    }

    /// The command line's own path: the deck is a file, and the pictures are
    /// written beside it for someone to open.
    @MainActor
    public static func renderFile(
        deckURL: URL,
        outputDirectory: URL,
        overviewURL: URL?,
        libraryRoot: URL?,
        manuscriptURL: URL?,
        slideNumbers: [Int]?,
        width: Double
    ) async throws -> Data {
        try encoded(
            try await LampDeckPreview.render(
                deckURL: deckURL,
                outputDirectory: outputDirectory,
                overviewURL: overviewURL,
                libraryRoot: libraryRoot,
                manuscriptURL: manuscriptURL,
                slideNumbers: slideNumbers,
                width: width
            )
        )
    }

    // MARK: -

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// A directory of its own per call, removed afterwards however the call
    /// ends. The deck and its manuscript are the user's writing, so they do
    /// not stay in the temporary directory after the answer is given.
    static func inScratchDirectory<Result>(
        _ body: (URL) throws -> Result
    ) throws -> Result {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-deck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try body(scratch)
    }

    private static func inScratchDirectory<Result>(
        _ body: (URL) async throws -> Result
    ) async throws -> Result {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-deck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try await body(scratch)
    }
}
