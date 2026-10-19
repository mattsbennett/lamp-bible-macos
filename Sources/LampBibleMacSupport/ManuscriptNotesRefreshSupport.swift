import Foundation
import LampCore

/// Re-splits the writing across the decks whose notes follow it, once per burst
/// of saves, and reports each split where the agent that wrote the deck can
/// read it.
///
/// Two things used to be missing. The split ran on every save but wrote no
/// status, and the status was written only by the import — which re-reads the
/// notes only when `presentation.lampdeck` itself changes. So a reworded
/// opening could break a slide's anchor, and `presentation-import.json` would
/// go on reporting every slide resolved until the agent next touched the deck
/// file. The summary now follows the writing instead.
///
/// Off the main actor, and coalesced: autosave arrives while the writer is
/// still typing, and each pass decodes every deck in the library and rewrites
/// the ones that follow this writing. A deck with its notes in it is not small.
public actor LampManuscriptNotesRefresh {
    public static let shared = LampManuscriptNotesRefresh()

    /// One writing, as it stood when a save arrived.
    public struct Request: Sendable {
        public var libraryRootURL: URL
        public var devotionalID: String
        public var manuscript: String
        /// The agent workspace for this writing, when it has one. Its status
        /// file is where the summary goes; without one there is nobody to tell.
        public var workspaceURL: URL?

        public init(
            libraryRootURL: URL,
            devotionalID: String,
            manuscript: String,
            workspaceURL: URL? = nil
        ) {
            self.libraryRootURL = libraryRootURL
            self.devotionalID = devotionalID
            self.manuscript = manuscript
            self.workspaceURL = workspaceURL
        }
    }

    /// How long a save waits to see whether another follows it.
    private let settleInterval: Duration
    /// The latest state of each writing waiting to be split, by devotional ID.
    private var pending: [String: Request] = [:]
    private var isDraining = false

    public init(settleInterval: Duration = .milliseconds(400)) {
        self.settleInterval = settleInterval
    }

    /// Takes the latest state of one writing, to be split once the typing
    /// stops.
    ///
    /// A save that arrives while another is still settling replaces it rather
    /// than queueing behind it: only the newest writing matters, and splitting
    /// an older copy across the decks afterwards would undo the newer one.
    public func schedule(_ request: Request) {
        pending[request.devotionalID] = request
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    private func drain() async {
        // The actor is suspended across the sleep, so the saves arriving during
        // it collect in `pending` and the batch below takes the last of them.
        while !pending.isEmpty {
            try? await Task.sleep(for: settleInterval)
            let batch = pending
            pending.removeAll()
            for request in batch.values { refresh(request) }
        }
        isDraining = false
    }

    /// Splits the writing across every deck that follows it, saving a deck
    /// whose notes changed and reporting the split into the workspace.
    ///
    /// Returns the IDs of the decks it rewrote, so a test need not sleep
    /// through the settling interval to see what happened.
    @discardableResult
    public func refresh(_ request: Request) -> [String] {
        let store = LampPresentationDeckStore(rootURL: request.libraryRootURL)
        guard let decks = try? store.decks() else { return [] }
        // A workspace holds one deck, but a writing may have several decks
        // following it in the library. Only the workspace's own deck is
        // reported there; the others have nowhere to report to.
        let reportedDeckID = request.workspaceURL
            .flatMap { LampPresentationImportStatusStore.read(in: $0) }
            .flatMap { $0.deckID ?? $0.lastImport?.deckID }
        var rewritten: [String] = []
        for deck in decks
        where deck.followsManuscript && deck.source?.id == request.devotionalID {
            let resolution = LampPresentationManuscriptNotes.resolve(
                deck: deck,
                manuscript: request.manuscript
            )
            let resolved = LampPresentationManuscriptNotes.applying(resolution, to: deck)
            if resolved != deck {
                _ = try? store.save(resolved)
                rewritten.append(deck.id)
            }
            // Reported whether or not a slide's notes changed. A reworded
            // opening breaks an anchor, and the slide then *keeps* the notes it
            // had — which is precisely the case that went unreported.
            if let workspaceURL = request.workspaceURL,
               reportedDeckID == nil || reportedDeckID == deck.id {
                LampPresentationImportStatusStore.updateSpeakerNotesIfChanged(
                    .init(resolution: resolution, deck: resolved),
                    in: workspaceURL
                )
            }
        }
        return rewritten
    }
}
