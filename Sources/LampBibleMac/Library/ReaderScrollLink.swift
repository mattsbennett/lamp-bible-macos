import Combine
import Foundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// Keeps the reader and the study tools looking at the same verse.
///
/// Each pane reports the verse that reached its top edge and listens to the subject
/// the *other* pane sends on, so neither one observes its own echo. Whether a report
/// is allowed through at all is the arbiter's call.
@MainActor
final class ReaderScrollLink: ObservableObject {
    /// Anchors travel by subject rather than `@Published` state, and that is the
    /// whole reason scrolling stays smooth. Publishing invalidates every view
    /// observing this object — which is both panes — so at scroll frequency it
    /// rebuilt the visible chapter and restyled every verse dozens of times a
    /// second. A subject moves the other pane without either body re-evaluating.
    let readerAnchors = PassthroughSubject<Int, Never>()
    let toolAnchors = PassthroughSubject<Int, Never>()

    @Published var isLinked: Bool {
        didSet {
            guard isLinked != oldValue else { return }
            defaults.set(isLinked, forKey: Self.defaultsKey)
            reset()
        }
    }

    /// Set while a note is being edited. Typing reflows the panel, and a reflow
    /// looks exactly like a scroll — without this the reader would wander off the
    /// verse as you write about it.
    @Published var isSuspended = false {
        didSet { if isSuspended != oldValue { reset() } }
    }

    private static let defaultsKey = "reader.scrollLink"
    private let defaults: UserDefaults
    private var arbiter = ScrollLinkArbiter()
    private(set) var currentReaderAnchor: Int?
    private var lastReaderAnchor: Int?
    private var lastToolAnchor: Int?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLinked = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func readerDidScroll(to reference: Int?) {
        guard let reference else { return }
        currentReaderAnchor = reference

        // The unchanged-anchor check comes first because claiming has a side
        // effect: a pane that reports the same verse on every frame of a long
        // scroll would hold the link open without ever needing to move anything.
        guard reference != lastReaderAnchor, canDrive(.reader) else { return }
        lastReaderAnchor = reference
        readerAnchors.send(reference)
    }

    func toolDidScroll(to reference: Int?) {
        guard let reference, reference != lastToolAnchor, canDrive(.tool) else { return }
        lastToolAnchor = reference
        toolAnchors.send(reference)
    }

    /// Record the position a tool adopted from the reader without echoing it back.
    /// Subsequent layout reports for that same position are initialization noise,
    /// not a user scroll.
    func toolDidAdopt(_ reference: Int?) {
        lastToolAnchor = reference
    }

    /// Direct manipulation always wins immediately. The quiet-time arbiter is for
    /// ambiguous layout and programmatic-scroll reports; once the user starts a
    /// wheel, trackpad, or drag gesture, its source is no longer ambiguous.
    func readerUserScrollDidBegin() {
        userScrollDidBegin(from: .reader)
    }

    func toolUserScrollDidBegin() {
        userScrollDidBegin(from: .tool)
    }

    /// Hand control back after a chapter change or a jump, so the first scroll in
    /// either pane is honoured rather than losing to whoever moved last.
    func reset() {
        arbiter.reset()
        lastReaderAnchor = nil
        lastToolAnchor = nil
    }

    /// Preserve the reader as the source of truth while a newly selected study
    /// pane lays out at its default (usually first-verse) position.
    func prepareForStudyPaneChange() {
        reset()
        guard currentReaderAnchor != nil, isLinked, !isSuspended else { return }
        _ = arbiter.claim(.reader)
    }

    private func canDrive(_ source: ScrollLinkSource) -> Bool {
        guard isLinked, !isSuspended else { return false }
        return arbiter.claim(source)
    }

    private func userScrollDidBegin(from source: ScrollLinkSource) {
        guard isLinked, !isSuspended else { return }
        arbiter.reset()
        _ = arbiter.claim(source)
        // Force the gesture's first visibility report through even when it starts
        // on the same anchor that the pane last reported during layout.
        switch source {
        case .reader: lastReaderAnchor = nil
        case .tool: lastToolAnchor = nil
        }
    }
}

// The View menu reaches the frontmost reader's link through `.focusedObject`
// rather than a focused value. A focused *value* would have to be a fresh struct
// built on every body evaluation, and SwiftUI cannot tell one from the last —
// which is what "FocusedValue update tried to update multiple times per frame"
// means. The object is the same instance every time, so nothing re-publishes.

/// Wraps a verse-anchored study panel in the reader's scroll link.
///
/// Children must carry `.id(Int)` matching an anchor's `reference`; anything else
/// (section headers, empty-state text) is invisible to the link because SwiftUI
/// only reports targets whose identifier is the type asked for.
struct VerseAnchoredScrollView<Content: View>: View {
    let anchors: [VerseAnchor]
    /// The verse the reader has selected. Following it is selection, not scroll
    /// linking, so it happens whether or not the link is on — and it covers the
    /// case where clicking a verse already at the top scrolls the reader nowhere
    /// and so reports nothing.
    var focusedReference: Int?
    @ViewBuilder let content: Content

    @EnvironmentObject private var scrollLink: ReaderScrollLink
    @State private var isAdoptingReaderPosition = true
    @State private var pendingInitialAnchor: Int?
    @State private var visibleAnchors: [Int] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    .scrollTargetLayout()

                    // This must be an eager sibling of the lazy content. If it is
                    // the lazy stack's last child, SwiftUI discovers its height
                    // only near the bottom and changes the scrollbar range.
                    Color.clear
                        .containerRelativeFrame(.vertical) { viewportHeight, _ in
                            ReaderScrollTail.height(for: viewportHeight)
                        }
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onScrollTargetVisibilityChange(idType: Int.self) { visible in
                // The scroll view first lays out at its first item, even when it
                // is about to adopt a retained reader position. Never publish
                // that transient position back to the reader.
                if isAdoptingReaderPosition {
                    visibleAnchors = visible
                    if let pendingInitialAnchor,
                       visible.contains(pendingInitialAnchor) {
                        scrollLink.toolDidAdopt(visible.min())
                        self.pendingInitialAnchor = nil
                        isAdoptingReaderPosition = false
                    }
                    return
                }
                scrollLink.toolDidScroll(to: visible.min())
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                guard !oldPhase.isUserDriven, newPhase.isUserDriven else { return }
                scrollLink.toolUserScrollDidBegin()
            }
            .onReceive(scrollLink.readerAnchors) { reference in
                scroll(proxy, to: reference)
            }
            .task {
                // A newly mounted tool has not subscribed to the reader's last
                // PassthroughSubject event. Adopt the durable reader position
                // before its initial visibility report can become authoritative.
                scrollLink.prepareForStudyPaneChange()
                isAdoptingReaderPosition = true
                guard let target = resolvedAnchor(
                    for: scrollLink.currentReaderAnchor ?? focusedReference
                ) else {
                    isAdoptingReaderPosition = false
                    return
                }
                pendingInitialAnchor = target

                // Give the scroll targets one layout pass, then keep suppressing
                // their setup reports until the requested target becomes visible.
                await Task.yield()
                proxy.scrollTo(target, anchor: .top)

                // `scrollTo` can be a no-op when the target was already visible,
                // in which case SwiftUI sends no second visibility callback. End
                // setup deterministically, seeding whichever anchor it actually
                // reported so a late duplicate cannot echo into the reader.
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled,
                      pendingInitialAnchor == target else { return }
                scrollLink.toolDidAdopt(visibleAnchors.min() ?? target)
                pendingInitialAnchor = nil
                isAdoptingReaderPosition = false
            }
            .onChange(of: focusedReference) { _, reference in
                scrollLink.reset()
                scroll(proxy, to: reference)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to reference: Int?) {
        guard let anchor = resolvedAnchor(for: reference) else { return }
        proxy.scrollTo(anchor, anchor: .top)
    }

    private func resolvedAnchor(for reference: Int?) -> Int? {
        guard let reference else { return nil }
        return VerseAnchorResolver.anchor(for: reference, in: anchors)?.reference
    }
}

extension ScrollPhase {
    /// Programmatic `scrollTo` movement is `.animating`; every other moving phase
    /// originates with direct manipulation and should take link ownership.
    var isUserDriven: Bool {
        switch self {
        case .tracking, .interacting, .decelerating: true
        case .idle, .animating: false
        }
    }
}
