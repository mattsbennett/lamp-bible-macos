import Foundation

/// Which pane is currently driving a linked scroll.
public enum ScrollLinkSource: String, Codable, Equatable, Sendable {
    case reader
    case tool
}

/// The verse range one entry of a tool panel speaks to.
///
/// Everything a study tool can scroll-link by reduces to this: a commentary unit
/// covering `1:1–3`, a note attached to a verse range, the cross-references and
/// footnotes hanging off a single verse.
public struct VerseAnchor: Equatable, Hashable, Sendable {
    public let reference: Int
    public let endReference: Int

    public init(reference: Int, endReference: Int? = nil) {
        self.reference = reference
        self.endReference = max(endReference ?? reference, reference)
    }

    public func covers(_ candidate: Int) -> Bool {
        candidate >= reference && candidate <= endReference
    }
}

public enum VerseAnchorResolver {
    /// The entry a tool panel should scroll to when the reader is showing `reference`.
    ///
    /// A panel's coverage is almost always sparser than the chapter it accompanies —
    /// a commentary skips verses, a chapter holds three notes — so falling back to
    /// the last entry that *begins* before the verse keeps the panel tracking the
    /// reader instead of snapping back to the top over every gap. The most specific
    /// covering entry wins when several overlap, which is what makes a verse-range
    /// note lose to the single-verse note nested inside it.
    public static func anchor(for reference: Int, in anchors: [VerseAnchor]) -> VerseAnchor? {
        guard !anchors.isEmpty else { return nil }

        var covering: VerseAnchor?
        var preceding: VerseAnchor?
        var first: VerseAnchor?

        for anchor in anchors {
            if anchor.covers(reference),
               covering.map({ anchor.reference >= $0.reference }) ?? true {
                covering = anchor
            }
            if anchor.reference <= reference,
               preceding.map({ anchor.reference > $0.reference }) ?? true {
                preceding = anchor
            }
            if first.map({ anchor.reference < $0.reference }) ?? true {
                first = anchor
            }
        }

        return covering ?? preceding ?? first
    }
}

/// Guards a two-way scroll link against feeding back on itself.
///
/// SwiftUI reports its visible scroll targets identically whether the user dragged
/// them there or `scrollTo` did, so there is no flag to test the way UIKit's
/// `isDragging` lets you. Instead the pane that moves first owns the link and keeps
/// it until it has been quiet for `settleInterval` — long enough for the scroll it
/// caused in the other pane to land and be ignored.
public struct ScrollLinkArbiter: Equatable, Sendable {
    public let settleInterval: TimeInterval
    public private(set) var owner: ScrollLinkSource?
    private var lastClaim: Date?

    public init(settleInterval: TimeInterval = 0.25) {
        self.settleInterval = max(settleInterval, 0)
    }

    /// Whether `source` may drive the other pane, taking ownership when it may.
    public mutating func claim(_ source: ScrollLinkSource, at now: Date = Date()) -> Bool {
        if let owner, owner != source,
           let lastClaim, now.timeIntervalSince(lastClaim) < settleInterval {
            return false
        }
        owner = source
        lastClaim = now
        return true
    }

    /// Drop ownership so the next report from either pane is honoured immediately.
    public mutating func reset() {
        owner = nil
        lastClaim = nil
    }
}
