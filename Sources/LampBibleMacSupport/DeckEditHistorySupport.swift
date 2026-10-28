import Foundation
import LampCore

/// The deck as it was, so an edit can be taken back.
///
/// Slide Studio edits a deck in place and saves as you type, which leaves no
/// way back from a deletion or a paste over the wrong slide. There is no
/// document architecture here to undo through, so this keeps whole decks: they
/// are small, comparing them is how the editor already decides to save, and a
/// snapshot cannot drift from the change it describes the way a recorded
/// action can.
///
/// Edits are gathered into bursts. Typing a title would otherwise leave one
/// step per character, and taking back a word would mean pressing undo as many
/// times as the word is long.
public final class LampDeckEditHistory {
    /// How long a pause ends a burst. Long enough to join typing, short enough
    /// that a deliberate second change is its own step.
    public static let burstPause: TimeInterval = 1.2
    /// Enough to go back through a working session, bounded so a long one
    /// cannot grow without limit.
    public static let limit = 80

    private var past: [LampPresentationDeck] = []
    private var future: [LampPresentationDeck] = []
    private var lastRecordedAt: Date?
    /// The deck ID the burst belongs to. Changing deck always starts a new
    /// step, however quickly it follows the last edit.
    private var lastDeckID: String?

    public init() {}

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Notes that `previous` has been replaced, so it can be returned to.
    ///
    /// `previous` is the deck *before* the change. Within a burst the first
    /// such deck is kept and the rest dropped, so undo returns to where the
    /// burst began rather than to its second-to-last keystroke.
    public func record(
        _ previous: LampPresentationDeck,
        at time: Date = Date()
    ) {
        defer {
            lastRecordedAt = time
            lastDeckID = previous.id
        }
        future.removeAll()

        let continuesBurst = lastDeckID == previous.id
            && lastRecordedAt.map { time.timeIntervalSince($0) < Self.burstPause } ?? false
        guard !continuesBurst else { return }

        past.append(previous)
        if past.count > Self.limit { past.removeFirst(past.count - Self.limit) }
    }

    /// The deck to go back to, given the one on screen now.
    public func undo(from current: LampPresentationDeck) -> LampPresentationDeck? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        // The next edit starts a burst of its own: an edit made after an undo
        // is a new thought, not a continuation of what was undone.
        lastRecordedAt = nil
        lastDeckID = nil
        return previous
    }

    /// The deck to go forward to, given the one on screen now.
    public func redo(from current: LampPresentationDeck) -> LampPresentationDeck? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        lastRecordedAt = nil
        lastDeckID = nil
        return next
    }

    /// Forgets everything, for a window that has moved to another deck by a
    /// route that is not an edit.
    public func forget() {
        past.removeAll()
        future.removeAll()
        lastRecordedAt = nil
        lastDeckID = nil
    }
}
