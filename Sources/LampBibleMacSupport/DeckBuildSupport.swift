import Foundation
import LampCore

/// Fills in the parts of a deck that can be derived rather than typed: the
/// speaker notes, and the identifiers of anything newly added.
///
/// A talk's manuscript and its deck are two artifacts that have to agree. Left
/// to hand, the notes are pasted in once and go stale at the first edit, and
/// nothing notices. Here the manuscript is the source and the deck says only
/// where each slide's passage begins.
/// Works out a deck's charts against a library.
///
/// A closure rather than the library itself, because a deck can be built with
/// no library to hand — the command line is given one only when it is asked
/// for — and because it lets the chart reporting be tested without a library
/// holding Strong's-tagged translations.
///
/// At file scope rather than inside `LampDeckBuild`, which is internal: this
/// is named by the public functions that take it.
public typealias LampDeckChartWorker = @Sendable (LampPresentationDeck) async
    -> LampPresentationChartReport

enum LampDeckBuild {
    struct SlideReport: Codable {
        var index: Int
        var id: String
        var title: String
        var notesAnchor: String?
        var notesLength: Int
        var problems: [String]
        var staleQuotations: [String]
        /// What the library said about this slide's charts. Kept apart from
        /// `problems`, which are the manuscript's: a chart whose values were
        /// out of date has been *fixed* by this run, and reading that as a
        /// failure of the notes would be wrong.
        var chartProblems: [String]
    }

    struct Report: Codable {
        var deckTitle: String
        var speakerNotesSource: String
        var slideCount: Int
        var anchoredSlides: Int
        var coveredCharacters: Int
        var manuscriptCharacters: Int
        var assignedIdentifiers: Int
        /// Problems with the deck as a whole. A problem belonging to one slide
        /// is under that slide, and named in `slidesWithProblems`.
        var problems: [String]
        /// The numbers of the slides whose own entry carries a problem.
        ///
        /// This used to be missing, so a report said `"resolved": false` over
        /// an empty `problems` — which reads as "no problems". The broken
        /// anchor was listed under that slide, seventy entries down.
        var slidesWithProblems: [Int]
        var slides: [SlideReport]
        /// Whether any chart's values were rewritten from the library.
        var chartsUpdated: Bool
        /// Whether every anchor was found. The command's exit status follows
        /// it. Deliberately not affected by a chart: an anchor that cannot be
        /// found means the notes are no longer the manuscript's, which is a
        /// failure, whereas every chart report is either a warning or a repair.
        var resolved: Bool
    }

    static func build(
        deckURL: URL,
        manuscriptURL: URL?,
        charts: LampDeckChartWorker? = nil
    ) async throws -> Report {
        let original = try LampPresentationDeckStore.decodeUnvalidated(
            Data(contentsOf: deckURL)
        )
        // Identifiers first: a slide added by hand with no id would otherwise
        // get a fresh one on every run and never hold its notes.
        var (deck, assigned) = withAssignedIdentifiers(original)

        // Charts before the notes, and before the authored-notes exit below:
        // a deck whose notes are written by hand still has charts to fill, and
        // returning early without them was the first thing to get wrong here.
        var chartIssues: [LampPresentationDeckIssue] = []
        var chartsUpdated = false
        if let charts {
            let report = await charts(deck)
            deck = report.deck
            chartIssues = report.issues
            chartsUpdated = report.changed
        }
        let hasCharts = deck.slides.contains { slide in
            slide.blocks.contains { $0.kind == .chart }
        }
        // Deck-wide chart trouble goes in the report's own `problems`, because
        // the slide entries only carry issues whose path names a slide. An
        // issue about the deck as a whole — the access policy refusing the
        // whole call, say — matches no slide, and filing it by slide alone
        // dropped it entirely.
        let chartProblems = (hasCharts && charts == nil
            ? ["This deck has charts, and no library was given to work them "
                + "out from. Pass --library to fill in their values."]
            : [])
            + chartIssues.filter { slideIndex(inPath: $0.path) == nil }.map(\.message)

        guard deck.followsManuscript else {
            try write(deck, to: deckURL, ifChangedFrom: original)
            let slides = slideReports(
                deck, resolution: nil, stale: [], chartIssues: chartIssues
            )
            return Report(
                deckTitle: deck.title,
                speakerNotesSource: (deck.speakerNotesSource ?? .authored).rawValue,
                slideCount: deck.slides.count,
                anchoredSlides: 0,
                coveredCharacters: 0,
                manuscriptCharacters: 0,
                assignedIdentifiers: assigned,
                problems: [
                    "This deck's notes are authored, so there is nothing to derive. "
                        + "Set \"speakerNotesSource\" to \"manuscript\" to have Lamp keep "
                        + "them in step with the writing.",
                ] + chartProblems,
                slidesWithProblems: slides
                    .filter { !$0.chartProblems.isEmpty }
                    .map(\.index),
                slides: slides,
                chartsUpdated: chartsUpdated,
                resolved: true
            )
        }

        guard let manuscriptURL else {
            throw LampDeckBuildError.manuscriptRequired
        }
        let manuscript = try String(contentsOf: manuscriptURL, encoding: .utf8)
        let resolution = LampPresentationManuscriptNotes.resolve(
            deck: deck,
            manuscript: manuscript
        )
        deck = LampPresentationManuscriptNotes.applying(resolution, to: deck)
        let stale = LampPresentationManuscriptNotes.staleQuotations(
            in: deck,
            manuscript: manuscript
        )
        try write(deck, to: deckURL, ifChangedFrom: original)

        let unresolved = resolution.problems.contains { problem in
            if case .anchorNotFound = problem { return true }
            return false
        }
        let slides = slideReports(
            deck, resolution: resolution, stale: stale, chartIssues: chartIssues
        )
        return Report(
            deckTitle: deck.title,
            speakerNotesSource: LampPresentationSpeakerNotesSource.manuscript.rawValue,
            slideCount: deck.slides.count,
            anchoredSlides: deck.slides.count { ($0.notesAnchor ?? "").isEmpty == false },
            coveredCharacters: resolution.coveredCharacters,
            manuscriptCharacters: resolution.manuscriptCharacters,
            assignedIdentifiers: assigned,
            problems: resolution.problems.filter { $0.slideID == nil }.map(\.message)
                + chartProblems,
            slidesWithProblems: slides
                .filter {
                    !$0.problems.isEmpty || !$0.staleQuotations.isEmpty
                        || !$0.chartProblems.isEmpty
                }
                .map(\.index),
            slides: slides,
            chartsUpdated: chartsUpdated,
            resolved: !unresolved
        )
    }

    private static func slideReports(
        _ deck: LampPresentationDeck,
        resolution: LampPresentationManuscriptNotes.Resolution?,
        stale: [LampPresentationManuscriptNotes.StaleQuotation],
        chartIssues: [LampPresentationDeckIssue]
    ) -> [SlideReport] {
        deck.slides.enumerated().map { offset, slide in
            SlideReport(
                index: offset + 1,
                id: slide.id,
                title: slide.displayTitle,
                notesAnchor: slide.notesAnchor,
                notesLength: slide.speakerNotes.count,
                problems: (resolution?.problems ?? [])
                    .filter { $0.slideID == slide.id }
                    .map(\.message),
                staleQuotations: stale
                    .filter { $0.slideID == slide.id }
                    .map(\.message),
                chartProblems: chartIssues
                    .filter { slideIndex(inPath: $0.path) == offset }
                    .map(\.message)
            )
        }
    }

    /// The slide a chart issue belongs to, from a path such as
    /// `slides[2].blocks[1].chart.values`.
    ///
    /// By index, because a `LampPresentationDeckIssue` carries a path and no
    /// slide id. The index in the path is zero-based while a report's own
    /// `index` is one-based, which is exactly the sort of mismatch that puts
    /// an issue under the slide next door.
    static func slideIndex(inPath path: String) -> Int? {
        guard
            path.hasPrefix("slides["),
            let close = path.firstIndex(of: "]")
        else { return nil }
        let digits = path[path.index(path.startIndex, offsetBy: 7)..<close]
        return Int(digits)
    }

    /// Gives a UUID to any slide or block that arrived without one, so an agent
    /// can add a slide without inventing identifiers — and a second run of this
    /// command changes nothing.
    private static func withAssignedIdentifiers(
        _ deck: LampPresentationDeck
    ) -> (LampPresentationDeck, Int) {
        var deck = deck
        var assigned = 0
        for slideIndex in deck.slides.indices {
            if deck.slides[slideIndex].id.trimmingCharacters(in: .whitespaces).isEmpty {
                deck.slides[slideIndex].id = UUID().uuidString.lowercased()
                assigned += 1
            }
            for blockIndex in deck.slides[slideIndex].blocks.indices
            where deck.slides[slideIndex].blocks[blockIndex].id
                .trimmingCharacters(in: .whitespaces).isEmpty {
                deck.slides[slideIndex].blocks[blockIndex].id = UUID().uuidString.lowercased()
                assigned += 1
            }
        }
        return (deck, assigned)
    }

    /// Writes only a deck that actually changed, so a run that had nothing to
    /// do leaves the file's timestamp — and Lamp's import poll — alone.
    private static func write(
        _ deck: LampPresentationDeck,
        to url: URL,
        ifChangedFrom original: LampPresentationDeck
    ) throws {
        guard deck != original else { return }
        try LampPresentationDeckStore.encodedUnvalidated(deck).write(to: url, options: [.atomic])
    }
}

enum LampDeckBuildError: Error, LocalizedError {
    case manuscriptRequired

    var errorDescription: String? {
        switch self {
        case .manuscriptRequired:
            return "This deck's notes follow the manuscript, so --manuscript is required."
        }
    }
}
