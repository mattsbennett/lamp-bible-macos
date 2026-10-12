import Foundation
import LampCore

/// What happened the last time Lamp looked at a workspace's
/// `presentation.lampdeck`, written where the agent that wrote the deck can
/// read it.
///
/// Import runs in the app, and its outcome used to appear only in the agent
/// pane — so an agent had no way to tell whether its deck had been taken, or
/// why it had not. This file is that answer. Lamp owns it; an agent reads it.
public struct LampPresentationImportStatus: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The deck was decoded, validated, and saved into Slide Studio.
        case imported
        /// The file has not changed since the last import.
        case unchanged
        /// No `presentation.lampdeck` in the workspace.
        case absent
        /// The deck could not be read or did not validate; nothing was saved.
        case failed
    }

    /// How slide identifiers compared with the deck already in the library.
    ///
    /// Rewriting every ID on each generation throws away the link between a
    /// slide and anything the user did to it, so it is worth reporting.
    public struct SlideIdentity: Codable, Equatable, Sendable {
        public var reused: Int
        public var added: Int
        public var removed: Int

        public init(reused: Int, added: Int, removed: Int) {
            self.reused = reused
            self.added = added
            self.removed = removed
        }
    }

    public struct Issue: Codable, Equatable, Sendable {
        public var severity: String
        public var path: String
        public var message: String

        public init(severity: String, path: String, message: String) {
            self.severity = severity
            self.path = path
            self.message = message
        }
    }

    public static let filename = "presentation-import.json"

    public var formatVersion = 1
    public var outcome: Outcome
    public var checkedAt: Date
    public var message: String
    public var deckID: String?
    public var deckTitle: String?
    public var slideCount: Int?
    public var slideIdentity: SlideIdentity?
    /// Images found beside the deck and copied into the library.
    public var importedAssets: [String]
    /// Images the deck names that are nowhere to be found; these render as
    /// placeholders.
    public var missingAssets: [String]
    /// Everything the validator had to say, warnings included.
    public var issues: [Issue]
    /// How the deck's speaker notes were arrived at, when they follow the
    /// writing rather than being typed on each slide.
    public struct SpeakerNotes: Codable, Equatable, Sendable {
        public var source: String
        /// Slides whose anchor was found and whose notes are current.
        public var resolved: Int
        /// Slides keeping older notes because their anchor is no longer in the
        /// manuscript.
        public var stale: Int
        public var problems: [String]

        public init(source: String, resolved: Int, stale: Int, problems: [String]) {
            self.source = source
            self.resolved = resolved
            self.stale = stale
            self.problems = problems
        }
    }

    public var speakerNotes: SpeakerNotes?

    /// The last time a deck was actually taken, kept through every later check.
    ///
    /// `outcome` describes the most recent look at the artifact, and Lamp looks
    /// several times a second — so within a second of an import the outcome is
    /// `unchanged` again. Without this, the slide identity and asset lists from
    /// the import that just happened were gone before anyone could read them.
    public var lastImport: Completed?

    /// What an import did, detached from whichever check is current.
    public struct Completed: Codable, Equatable, Sendable {
        public var at: Date
        public var deckID: String?
        public var deckTitle: String?
        public var slideCount: Int?
        public var slideIdentity: SlideIdentity?
        public var importedAssets: [String]
        public var missingAssets: [String]

        public init(
            at: Date,
            deckID: String?,
            deckTitle: String?,
            slideCount: Int?,
            slideIdentity: SlideIdentity?,
            importedAssets: [String],
            missingAssets: [String]
        ) {
            self.at = at
            self.deckID = deckID
            self.deckTitle = deckTitle
            self.slideCount = slideCount
            self.slideIdentity = slideIdentity
            self.importedAssets = importedAssets
            self.missingAssets = missingAssets
        }
    }

    public init(
        outcome: Outcome,
        checkedAt: Date = Date(),
        message: String,
        deckID: String? = nil,
        deckTitle: String? = nil,
        slideCount: Int? = nil,
        slideIdentity: SlideIdentity? = nil,
        importedAssets: [String] = [],
        missingAssets: [String] = [],
        issues: [Issue] = [],
        lastImport: Completed? = nil,
        speakerNotes: SpeakerNotes? = nil
    ) {
        self.outcome = outcome
        self.checkedAt = checkedAt
        self.message = message
        self.deckID = deckID
        self.deckTitle = deckTitle
        self.slideCount = slideCount
        self.slideIdentity = slideIdentity
        self.importedAssets = importedAssets
        self.missingAssets = missingAssets
        self.issues = issues
        self.speakerNotes = speakerNotes
        self.lastImport = lastImport
            ?? (outcome == .imported
                ? Completed(
                    at: checkedAt,
                    deckID: deckID,
                    deckTitle: deckTitle,
                    slideCount: slideCount,
                    slideIdentity: slideIdentity,
                    importedAssets: importedAssets,
                    missingAssets: missingAssets
                )
                : nil)
    }

    public init(outcome: Outcome, checkedAt: Date = Date(), message: String) {
        self.init(
            outcome: outcome,
            checkedAt: checkedAt,
            message: message,
            deckID: nil
        )
    }
}

public extension LampPresentationImportStatus {
    init(issues: [LampPresentationDeckIssue], outcome: Outcome, message: String) {
        self.init(
            outcome: outcome,
            message: message,
            issues: issues.map {
                Issue(
                    severity: $0.severity == .error ? "error" : "warning",
                    path: $0.path,
                    message: $0.message
                )
            }
        )
    }

    /// Compares a deck about to be saved with the one already in the library.
    static func slideIdentity(
        importing deck: LampPresentationDeck,
        over existing: LampPresentationDeck?
    ) -> SlideIdentity {
        let incoming = Set(deck.slides.map(\.id))
        let previous = Set(existing?.slides.map(\.id) ?? [])
        return SlideIdentity(
            reused: incoming.intersection(previous).count,
            added: incoming.subtracting(previous).count,
            removed: previous.subtracting(incoming).count
        )
    }
}

public enum LampPresentationImportStatusStore {
    public static func url(in workspace: URL) -> URL {
        workspace.appendingPathComponent(LampPresentationImportStatus.filename)
    }

    /// Writes the status only when it says something new.
    ///
    /// Lamp looks at the artifact several times a second, and rewriting an
    /// unchanged answer that often would churn the workspace and tell the agent
    /// nothing. `checkedAt` is ignored in the comparison, since it moves every
    /// time by definition.
    public static func writeIfChanged(
        _ status: LampPresentationImportStatus,
        in workspace: URL
    ) {
        var status = status
        if let existing = read(in: workspace) {
            // A later check must not erase the import it followed.
            if status.lastImport == nil { status.lastImport = existing.lastImport }
            var compared = existing
            compared.checkedAt = status.checkedAt
            guard compared != status else { return }
        }
        write(status, in: workspace)
    }

    /// Writes the status beside the deck it describes. Never throws into the
    /// import path: a status that cannot be written must not stop a deck that
    /// otherwise imported fine.
    public static func write(_ status: LampPresentationImportStatus, in workspace: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: url(in: workspace), options: [.atomic])
    }

    public static func read(in workspace: URL) -> LampPresentationImportStatus? {
        guard let data = try? Data(contentsOf: url(in: workspace)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LampPresentationImportStatus.self, from: data)
    }
}
