import AppKit
import LampCore
import SwiftUI

struct SlidePresentationView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var remoteHost: LampPresentationRemoteHost

    let request: SlidePresentationRequest

    @State private var deck: LampPresentationDeck?
    @State private var currentIndex = 0
    @State private var isBlack = false
    @State private var errorMessage: String?
    @State private var presentationStartedAt = Date()

    private var visibleSlides: [LampPresentationSlide] {
        deck?.slides.filter { !$0.isHidden } ?? []
    }

    private var currentSlide: LampPresentationSlide? {
        guard visibleSlides.indices.contains(currentIndex) else { return nil }
        return visibleSlides[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let deck, let currentSlide {
                LampPresentationSlideCanvas(slide: currentSlide, deck: deck)
                    .aspectRatio(deck.aspectRatio.ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: currentIndex) { broadcastRemoteState() }
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
            currentIndex = 0
            presentationStartedAt = Date()
            broadcastRemoteState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advance() {
        guard currentIndex < visibleSlides.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            currentIndex += 1
            isBlack = false
        }
    }

    private func retreat() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            currentIndex -= 1
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
        withAnimation(.easeInOut(duration: 0.18)) {
            currentIndex = index
            isBlack = false
        }
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
                canGoPrevious: currentIndex > 0,
                canGoNext: currentIndex < visibleSlides.count - 1
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

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installKeyboardMonitorIfNeeded()
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
