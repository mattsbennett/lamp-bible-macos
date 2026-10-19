import Foundation
import LampCore

/// Fills in the parts of a deck that can be derived rather than typed: the
/// speaker notes, and the identifiers of anything newly added.
///
/// A talk's manuscript and its deck are two artifacts that have to agree. Left
/// to hand, the notes are pasted in once and go stale at the first edit, and
/// nothing notices. Here the manuscript is the source and the deck says only
/// where each slide's passage begins.
enum LampDeckBuild {
    struct SlideReport: Codable {
        var index: Int
        var id: String
        var title: String
        var notesAnchor: String?
        var notesLength: Int
        var problems: [String]
        var staleQuotations: [String]
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
        /// Whether every anchor was found. The command's exit status follows it.
        var resolved: Bool
    }

    static func build(deckURL: URL, manuscriptURL: URL?) throws -> Report {
        let original = try LampPresentationDeckStore.decodeUnvalidated(
            Data(contentsOf: deckURL)
        )
        // Identifiers first: a slide added by hand with no id would otherwise
        // get a fresh one on every run and never hold its notes.
        var (deck, assigned) = withAssignedIdentifiers(original)

        guard deck.followsManuscript else {
            try write(deck, to: deckURL, ifChangedFrom: original)
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
                ],
                slidesWithProblems: [],
                slides: slideReports(deck, resolution: nil, stale: []),
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
        let slides = slideReports(deck, resolution: resolution, stale: stale)
        return Report(
            deckTitle: deck.title,
            speakerNotesSource: LampPresentationSpeakerNotesSource.manuscript.rawValue,
            slideCount: deck.slides.count,
            anchoredSlides: deck.slides.count { ($0.notesAnchor ?? "").isEmpty == false },
            coveredCharacters: resolution.coveredCharacters,
            manuscriptCharacters: resolution.manuscriptCharacters,
            assignedIdentifiers: assigned,
            problems: resolution.problems.filter { $0.slideID == nil }.map(\.message),
            slidesWithProblems: slides
                .filter { !$0.problems.isEmpty || !$0.staleQuotations.isEmpty }
                .map(\.index),
            slides: slides,
            resolved: !unresolved
        )
    }

    private static func slideReports(
        _ deck: LampPresentationDeck,
        resolution: LampPresentationManuscriptNotes.Resolution?,
        stale: [LampPresentationManuscriptNotes.StaleQuotation]
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
                    .map(\.message)
            )
        }
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
