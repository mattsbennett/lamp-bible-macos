import AppKit
import LampCore
import LampPresentationUI
import SwiftUI

struct SlidePresentationView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var remoteHost: LampPresentationRemoteHost

    let request: SlidePresentationRequest

    @State private var deck: LampPresentationDeck?
    /// The slide on screen and how far into its reveal; see
    /// `LampPresentationPosition` for what a click does.
    @State private var position = LampPresentationPosition()
    /// Counts changes of slide, so the slide arriving is always drawn above
    /// the one leaving.
    @State private var slideLayer = 0
    @State private var isBlack = false
    @State private var errorMessage: String?
    @State private var presentationStartedAt = Date()

    private var visibleSlides: [LampPresentationSlide] {
        deck?.slides.filter { !$0.isHidden } ?? []
    }

    private var currentIndex: Int { position.slide }

    private var currentSlide: LampPresentationSlide? {
        guard visibleSlides.indices.contains(currentIndex) else { return nil }
        return visibleSlides[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let deck, let currentSlide {
                LampPresentationSlideCanvas(
                    slide: currentSlide,
                    deck: deck,
                    store: LampPresentationDeckStore(rootURL: model.library.rootURL)
                )
                    .revealed(atStep: position.step)
                    .aspectRatio(deck.aspectRatio.ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // One view per slide, so a change of slide is the old one
                    // giving way to the new — a dissolve when animated, a cut
                    // when not — while a step within it fades its parts in.
                    .id(currentSlide.id)
                    // The arriving slide fades in over the one leaving, which
                    // stays whole beneath it until it has gone. Both fading
                    // at once over the black dimmed the screen midway, even
                    // between two slides of the same colour.
                    .transition(.lampSlide)
                    // Each slide above the one before it, whichever way the
                    // presenter moves, and above the black throughout.
                    .zIndex(Double(slideLayer) + 1)
                    .opacity(isBlack ? 0 : 1)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Presentation Unavailable",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.white)
            } else {
                ProgressView("Loading Presentation…")
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            if isBlack {
                Color.black.ignoresSafeArea()
                    // Over the slide, which now has an order of its own.
                    .zIndex(Double(Int32.max))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .task(id: request.deckID) { loadDeck() }
        .task {
            remoteHost.commandHandler = handleRemoteCommand
            remoteHost.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                broadcastRemoteState()
            }
        }
        .onChange(of: position) { broadcastRemoteState() }
        .onChange(of: isBlack) { broadcastRemoteState() }
        .onDisappear { remoteHost.commandHandler = nil }
        .background(SlidePresentationWindowController(handleCommand: handleKeyboardCommand))
    }

    private func handleKeyboardCommand(_ command: SlidePresentationKeyboardCommand) {
        switch command {
        case .next:
            advance()
        case .previous:
            retreat()
        case .first:
            goToSlide(at: 0)
        case .last:
            goToSlide(at: visibleSlides.count - 1)
        case .toggleBlackout:
            withAnimation { isBlack.toggle() }
        }
    }

    private func loadDeck() {
        do {
            let store = LampPresentationDeckStore(rootURL: model.library.rootURL)
            guard let loaded = try store.deck(id: request.deckID) else {
                errorMessage = "The deck was removed or is no longer available."
                return
            }
            guard !loaded.slides.filter({ !$0.isHidden }).isEmpty else {
                errorMessage = "Every slide in this deck is hidden."
                return
            }
            deck = loaded
            position = LampPresentationPosition()
            presentationStartedAt = Date()
            broadcastRemoteState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advance() {
        if let next = position.advanced(in: visibleSlides) { move(to: next) }
    }

    private func retreat() {
        if let previous = position.retreated(in: visibleSlides) { move(to: previous) }
    }

    /// Moves to `next` the way the deck asks: a part fades in, a slide
    /// dissolves into the next unless the deck cuts. Unhurried, since a
    /// change the room notices as motion has taken too long or gone too far,
    /// and nothing at all with Reduce Motion on.
    private func move(to next: LampPresentationPosition) {
        let changesSlide = next.slide != position.slide
        // Read at the moment of the move rather than from the environment:
        // the remote's handler is installed once and would keep the value
        // the presentation opened with.
        let animation = (deck?.transition ?? .dissolve).animation(
            changesSlide: changesSlide,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        withAnimation(animation) {
            if changesSlide { slideLayer += 1 }
            position = next
            isBlack = false
        }
    }

    private func handleRemoteCommand(_ command: LampPresentationRemoteCommand) {
        switch command.action {
        case .next:
            advance()
        case .previous:
            retreat()
        case .first:
            goToSlide(at: 0)
        case .last:
            goToSlide(at: visibleSlides.count - 1)
        case .goTo:
            if let index = command.slideIndex { goToSlide(at: index) }
        case .toggleBlackout:
            withAnimation { isBlack.toggle() }
        case .showBlackout:
            withAnimation { isBlack = true }
        case .hideBlackout:
            withAnimation { isBlack = false }
        case .toggleNotes:
            break
        }
    }

    private func goToSlide(at index: Int) {
        guard visibleSlides.indices.contains(index) else { return }
        move(to: LampPresentationPosition(slide: index, step: 0))
    }

    private func broadcastRemoteState() {
        guard let deck, let currentSlide else { return }
        let nextIndex = currentIndex + 1
        remoteHost.broadcast(
            LampPresentationRemoteState(
                deckID: deck.id,
                deckTitle: deck.title,
                aspectRatio: deck.aspectRatio,
                theme: deck.theme,
                currentSlideIndex: currentIndex,
                slideCount: visibleSlides.count,
                slideReferences: visibleSlides.enumerated().map { index, slide in
                    .init(index: index, id: slide.id, title: slide.displayTitle)
                },
                currentSlide: currentSlide,
                nextSlide: visibleSlides.indices.contains(nextIndex) ? visibleSlides[nextIndex] : nil,
                elapsedSeconds: max(0, Int(Date().timeIntervalSince(presentationStartedAt))),
                isBlackout: isBlack,
                canGoPrevious: position.retreated(in: visibleSlides) != nil,
                canGoNext: position.advanced(in: visibleSlides) != nil,
                currentRevealStep: position.step
            )
        )
    }
}

private enum SlidePresentationKeyboardCommand: Equatable {
    case next
    case previous
    case first
    case last
    case toggleBlackout
}

private struct SlidePresentationWindowController: NSViewRepresentable {
    let handleCommand: (SlidePresentationKeyboardCommand) -> Void

    func makeNSView(context: Context) -> SlidePresentationWindowView {
        let view = SlidePresentationWindowView()
        view.handleCommand = handleCommand
        return view
    }

    func updateNSView(_ view: SlidePresentationWindowView, context: Context) {
        view.handleCommand = handleCommand
    }
}

private final class SlidePresentationWindowView: NSView {
    var handleCommand: ((SlidePresentationKeyboardCommand) -> Void)?

    private var didEnterFullScreen = false
    private var eventMonitor: Any?

    /// How long the pointer has to sit still before it comes off the slide.
    ///
    /// Long enough that a presenter reaching for the next click is not chasing
    /// a pointer that keeps vanishing under their hand, short enough that one
    /// left over a picture is gone before the room has read the slide.
    private static let pointerIdleDelay: TimeInterval = 3
    /// The pointer is watched by asking where it is rather than by a
    /// mouse-moved monitor. Hiding it is a property of the whole application,
    /// so what matters is where the pointer sits on the desktop, not which
    /// window an event happened to be delivered to.
    private static let pointerPollInterval: TimeInterval = 0.5

    private var pointerTimer: Timer?
    private var pointerLocation = NSEvent.mouseLocation
    private var pointerRestingSince = Date()
    private var isPointerHidden = false

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        pointerTimer?.invalidate()
        // Nothing of this view is left to ask, so the pointer is put back
        // unconditionally rather than through `showPointer`.
        if isPointerHidden {
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(false) }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installKeyboardMonitorIfNeeded()
        watchPointerIfNeeded()
        guard let window, !didEnterFullScreen else { return }
        didEnterFullScreen = true
        DispatchQueue.main.async {
            if let mainScreen = NSScreen.main,
               let presentationScreen = NSScreen.screens.first(where: { $0 !== mainScreen }) {
                window.setFrame(presentationScreen.frame, display: true)
            }
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }

    /// Starts watching the pointer. A presentation lasts as long as its window
    /// does, so this runs for the whole of it rather than being started and
    /// stopped around each still spell.
    private func watchPointerIfNeeded() {
        guard window != nil, pointerTimer == nil else { return }
        pointerLocation = NSEvent.mouseLocation
        pointerRestingSince = Date()
        pointerTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pointerPollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkPointer()
        }
    }

    /// Hides the pointer once it has been still long enough, and shows it again
    /// the moment it moves or the show stops being the window in front.
    ///
    /// `setHiddenUntilMouseMoves` is what does the hiding, so the system brings
    /// the pointer back itself on the first movement — this only has to decide
    /// when it should go, and keep its own record of whether it is gone.
    private func checkPointer() {
        let location = NSEvent.mouseLocation
        if location != pointerLocation {
            pointerLocation = location
            pointerRestingSince = Date()
        }

        // Only while the show is the window in front: the pointer is hidden
        // for the whole application, and a presenter who has stepped over to
        // the editor or their notes still needs theirs.
        guard window?.isKeyWindow == true,
              Date().timeIntervalSince(pointerRestingSince) >= Self.pointerIdleDelay
        else {
            showPointer()
            return
        }
        hidePointer()
    }

    private func hidePointer() {
        guard !isPointerHidden else { return }
        isPointerHidden = true
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func showPointer() {
        guard isPointerHidden else { return }
        isPointerHidden = false
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func installKeyboardMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  let command = self.keyboardCommand(for: event) else {
                return event
            }

            if command == .close {
                window.orderOut(nil)
                DispatchQueue.main.async {
                    window.close()
                }
            } else if let presentationCommand = command.presentationCommand {
                self.handleCommand?(presentationCommand)
            }
            return nil
        }
    }

    private func keyboardCommand(for event: NSEvent) -> WindowKeyboardCommand? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return nil
        }

        switch event.keyCode {
        case 53:
            return .close
        case 49:
            return modifiers.contains(.shift) ? .presentation(.previous) : .presentation(.next)
        case 36, 76:
            return .presentation(.next)
        case 51:
            return .presentation(.previous)
        default:
            break
        }

        switch event.specialKey {
        case .rightArrow, .downArrow, .pageDown:
            return .presentation(.next)
        case .leftArrow, .upArrow, .pageUp:
            return .presentation(.previous)
        case .home:
            return .presentation(.first)
        case .end:
            return .presentation(.last)
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b", ".":
            return .presentation(.toggleBlackout)
        default:
            return nil
        }
    }

    private enum WindowKeyboardCommand: Equatable {
        case close
        case presentation(SlidePresentationKeyboardCommand)

        var presentationCommand: SlidePresentationKeyboardCommand? {
            guard case .presentation(let command) = self else { return nil }
            return command
        }
    }
}

