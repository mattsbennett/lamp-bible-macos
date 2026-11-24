import AppKit
import AVFoundation
import CoreText
import ImageIO
import LampCore
import LampModuleKit
import LampPresentationUI
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI
import UniformTypeIdentifiers

struct SlideStudioRequest: Codable, Hashable {
    var deckID: String?
    var devotionalID: String?
    /// A deck to make when the window opens, if it is not there already.
    ///
    /// New Presentation Deck names the deck it wants rather than asking for
    /// "something new", because this request is what a restored window comes
    /// back with: "something new" would make another empty deck on every
    /// launch, and naming it means the restored window simply reopens the deck
    /// that was made the first time.
    var newDeckID: String?

    init(deckID: String? = nil, devotionalID: String? = nil, newDeckID: String? = nil) {
        self.deckID = deckID
        self.devotionalID = devotionalID
        self.newDeckID = newDeckID
    }
}

/// Slides sent to a deck from elsewhere in the app — a chart from the
/// Strong's analysis — and the Slide Studio windows that would receive them.
///
/// A window holding a deck takes a sent slide into the deck it has on screen,
/// as an edit of its own, rather than finding it on disk: a window with
/// unsaved edits, or an unfinished deck held as a draft, does not reread the
/// disk, and its next save would write over a slide saved behind its back.
@MainActor
final class SlideStudioInbox: ObservableObject {
    static let shared = SlideStudioInbox()

    @Published private(set) var pending: [String: [LampPresentationSlide]] = [:]
    /// The library's decks by title, for a menu that offers them. Shared, so
    /// a deck made from one menu, or in Slide Studio, is in every other.
    @Published private(set) var decks: [DeckSummary] = []
    /// Moves on whenever a deck's file is written, removed or listed
    /// differently: what a list showing more than titles (covers, dates,
    /// order) reloads on. An ordinary save keeps the summaries the same.
    @Published private(set) var revision = 0
    /// The decks as last listed, to tell a change of contents from none.
    private var listed: [LampPresentationDeck] = []

    struct DeckSummary: Identifiable, Equatable {
        let id: String
        let title: String
    }

    private var listing: Task<Void, Never>?
    private var listedAt: Date?
    /// A forced refresh asked for while a load was running. That load began
    /// before whatever prompted the force, a deck just saved, so it runs again.
    private var refreshAgain = false

    /// Reads the library's decks into `decks`, once for however many menus
    /// ask together, and not again for a few seconds. Every deck is decoded
    /// in full to list it, and an analysis pane holds seven menus, so seven
    /// loads on each open were seven reads of every deck for nothing.
    func refreshDecks(rootURL: URL, force: Bool = false) {
        if listing != nil {
            if force { refreshAgain = true }
            return
        }
        if !force, let listedAt, Date().timeIntervalSince(listedAt) < 10 { return }
        let store = LampPresentationDeckStore(rootURL: rootURL)
        listing = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                try? store.decks()
            }.value
            guard let self else { return }
            listing = nil
            // A failed read stamps nothing, so the next menu tries again
            // rather than showing no decks for ten seconds.
            if let found { note(found) }
            if refreshAgain {
                refreshAgain = false
                refreshDecks(rootURL: rootURL, force: true)
            }
        }
    }

    /// The decks as a studio window or a load found them.
    func note(_ decks: [LampPresentationDeck]) {
        listedAt = Date()
        let summaries = decks
            .map { DeckSummary(id: $0.id, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if summaries != self.decks { self.decks = summaries }
        // Any change to a deck's contents, from a save here, a slide added
        // from the analysis or an agent's import read from disk: covers,
        // dates and order move with it, though no title did.
        if decks != listed {
            listed = decks
            revision &+= 1
        }
    }
    /// A deck's file was written or removed: at once, so a window about to
    /// close after a deletion still tells the lists before it goes.
    func deckFilesChanged() {
        revision &+= 1
    }

    /// The deck each open window shows.
    private var windows: [UUID: String] = [:]
    /// The slide a window opening a deck should show first.
    private var selections: [String: String] = [:]

    /// Whether a window shows `deckID`. That window takes a slide sent to it
    /// and brings itself forward.
    func isShowing(_ deckID: String) -> Bool {
        windows.values.contains(deckID)
    }

    func setWindow(_ window: UUID, showing deckID: String?) {
        windows[window] = deckID
    }

    func send(_ slide: LampPresentationSlide, to deckID: String) {
        pending[deckID, default: []].append(slide)
    }

    func take(for deckID: String) -> [LampPresentationSlide] {
        guard pending[deckID] != nil else { return [] }
        return pending.removeValue(forKey: deckID) ?? []
    }

    func select(_ slideID: String, in deckID: String) {
        selections[deckID] = slideID
    }

    func takeSelection(for deckID: String) -> String? {
        selections.removeValue(forKey: deckID)
    }
}

/// The window a view is in, held weakly.
final class HostWindowBox {
    weak var window: NSWindow?
}

/// Records its window in a box as it moves into one. Nothing happens on an
/// update, which runs on every redraw of the view it backs.
private struct HostWindowReader: NSViewRepresentable {
    let box: HostWindowBox

    func makeNSView(context: Context) -> NSView { Reader(box: box) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        let box: HostWindowBox

        init(box: HostWindowBox) {
            self.box = box
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box.window = window
        }
    }
}

struct SlidePresentationRequest: Codable, Hashable {
    let deckID: String
}

struct SlideStudioView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var remoteHost: LampPresentationRemoteHost
    @ObservedObject private var inbox = SlideStudioInbox.shared
    /// This window, to the inbox.
    @State private var windowToken = UUID()
    /// This window, to bring forward when a slide is sent to it.
    @State private var hostWindow = HostWindowBox()

    let request: SlideStudioRequest

    @State private var decks: [LampPresentationDeck] = []
    /// The decks in the deck menu's order: most recently changed first, as
    /// the Presentations section sorts them. Read when the decks change,
    /// not on every redraw of the window.
    @State private var menuDeckIDs: [String] = []
    /// The decks the menu's order was read for: read again when they change.
    private struct MenuOrderKey: Equatable {
        let revision: Int
        let deckIDs: [String]
    }
    @State private var selectedDeckID: String?
    @State private var deck: LampPresentationDeck?
    /// The decks this window has moved on from, so an edit can be taken back.
    @State private var history = LampDeckEditHistory()
    /// True while an undo or redo is being applied, so putting the old deck
    /// back is not itself recorded as an edit to undo.
    @State private var isRestoring = false
    /// Mirrored into state rather than read from `history`, which is a class
    /// SwiftUI does not watch: read directly, these buttons would be right
    /// only because every change to the history happens to accompany a change
    /// to the deck, which is not a thing to rely on.
    @State private var canUndoEdit = false
    @State private var canRedoEdit = false
    @State private var savedDeck: LampPresentationDeck?
    @State private var selectedSlideID: String?
    /// Whether the slide list has the keyboard. Arrow keys step between slides
    /// only while it does, so they still move the caret in the editors.
    @FocusState private var slideListFocused: Bool
    @AppStorage("slideStudio.inspectorWidth") private var inspectorWidth = 340.0
    @State private var inspectorPane: InspectorPane = .slide
    /// Empty until the list arrives from `PresentationTypefaces`.
    @State private var typefaceFamilies: [String] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var statusMessage = ""
    /// The picture blocks a chosen video is being prepared for, by slide id
    /// and block id, each with the choice that is to land: its still taken,
    /// and a copy made smaller where it must be. A later choice for the same
    /// block replaces the token, so the earlier one is dropped when it ends.
    @State private var preparingVideos: [String: UUID] = [:]
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showingDeleteConfirmation = false
    @State private var showingRemotePairing = false
    /// A PDF export is drawing. Drawing is main-actor work that yields between
    /// pages, so the window stays live and a second export could otherwise be
    /// started on top of the first.
    @State private var isExportingPDF = false
    /// How the writing splits across the slides, kept rather than worked out
    /// in `body`: splitting it reads the whole writing, and the notes pane
    /// asked on every redraw. Refreshed when what it depends on changes.
    @State private var resolution: LampPresentationManuscriptNotes.Resolution?
    /// What `resolution` was worked out from, so a change it already reflects
    /// isn't split again.
    @State private var resolvedInputs: ManuscriptNotesInputs?

    /// Laid over the slides in the strip that are not selected: nothing in
    /// light, a fifth of black in dark. Resolved as it is drawn, so it
    /// follows the window's appearance.
    private static let restingThumbnailShade = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // Enough to keep the rail from glaring, not so much that the
            // slides not being worked on look disabled.
            ? NSColor.black.withAlphaComponent(0.1)
            : .clear
    })

    private var store: LampPresentationDeckStore {
        LampPresentationDeckStore(rootURL: model.library.rootURL)
    }

    /// Reads the decks' file dates off the main thread and orders the menu
    /// by them: a read per deck on every autosave held up typing.
    private func refreshMenuOrder() async {
        let store = store
        let summaries = decks.map { ($0.id, $0.title) }
        let ordered = await Task.detached(priority: .utility) {
            LampPresentationShelf.sorted(
                summaries.map {
                    LampPresentationShelf.Deck(
                        id: $0.0, title: $0.1, writingID: nil, writingTitle: nil,
                        modified: store.modificationDate(ofDeck: $0.0)
                    )
                },
                by: .recent
            ).map(\.id)
        }.value
        guard !Task.isCancelled else { return }
        if ordered != menuDeckIDs { menuDeckIDs = ordered }
    }

    /// The decks most recently changed first; any not yet ordered, last.
    private var menuDecks: [LampPresentationDeck] {
        let byID = Dictionary(decks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = menuDeckIDs.compactMap { byID[$0] }
        return ordered + decks.filter { !menuDeckIDs.contains($0.id) }
    }

    /// Brings the library window forward on Presentations, opening one if
    /// none is open.
    private func showAllPresentations() {
        if let library = CommandPaletteWindows.frontmostLibrary() {
            if library.isMiniaturized { library.deminiaturize(nil) }
            library.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .lampShowPresentations, object: library)
        } else {
            // None open: the one opened now takes it, as it registers.
            CommandPaletteWindows.presentationsRequestedForNextWindow = Date()
            openWindow(id: "reader")
        }
    }

    /// The remembered width, held to the range the handle allows, so a stored
    /// value from elsewhere can't size the inspector outside it.
    private var shownInspectorWidth: Double {
        min(max(inspectorWidth, 300), 430)
    }

    private func typefaceName(_ typeface: String?, unset: String) -> String {
        switch typeface {
        case nil, "": unset
        case "system-rounded": "Lamp Rounded"
        case "system-sans": "System Sans"
        case "system-serif": "System Serif"
        case let family?: family
        }
    }

    /// A deck typeface: Lamp's three, then the families this Mac has. `unset`
    /// names what nil means here — Lamp Rounded for the body, the body's own
    /// for headings, which can then still choose Lamp Rounded by name.
    private func typefaceMenu(_ typeface: Binding<String?>, unset: String) -> some View {
        let named = ["", "system-rounded", "system-sans", "system-serif"]
        return Menu(typefaceName(typeface.wrappedValue, unset: unset)) {
            Picker(unset, selection: Binding(
                get: { typeface.wrappedValue ?? "" },
                set: { typeface.wrappedValue = $0.isEmpty ? nil : $0 }
            )) {
                Text(unset).tag("")
                if unset != "Lamp Rounded" {
                    Text("Lamp Rounded").tag("system-rounded")
                }
                Text("System Sans").tag("system-sans")
                Text("System Serif").tag("system-serif")
                Divider()
                ForEach(typefaceFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
                // Before the list arrives, and for a family this Mac doesn't
                // have, the deck's own still needs a tag.
                if let family = typeface.wrappedValue, !named.contains(family),
                   !typefaceFamilies.contains(family) {
                    Text(family).tag(family)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .lampMenu()
        .controlSize(.small)
    }

    /// What the deck would be saved as, so a heading cleared to leave it off
    /// is not an error (`withoutEmptyTextBlocks`).
    ///
    /// Checked as the editor holds it, so a path names the block the author
    /// sees, less the errors of text blocks cleared to leave them off.
    private var issues: [LampPresentationDeckIssue] {
        guard let deck else { return [] }
        let cleared = Set(deck.slides.enumerated().flatMap { slideIndex, slide in
            slide.blocks.enumerated().compactMap { blockIndex, block in
                block.kind != .image && block.kind != .chart
                    && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "slides[\(slideIndex)].blocks[\(blockIndex)]" : nil
            }
        })
        let asEdited = LampPresentationDeckValidator.validate(deck).filter { issue in
            !cleared.contains { issue.path == $0 || issue.path.hasPrefix($0 + ".") }
        }
        // What only the saved form has wrong: a slide left with no blocks
        // once its cleared heading is left off. Slide and deck paths only,
        // which mean the same in both.
        let known = Set(asEdited.map(\.id))
        let asSaved = LampPresentationDeckValidator.validate(deck.withoutEmptyTextBlocks).filter { issue in
            !issue.path.contains(".blocks[") && !known.contains(issue.id)
        }
        return asEdited + asSaved
    }

    private var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    private var hasUnsavedChanges: Bool {
        deck != savedDeck
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Opening Slide Studio…")
            } else if let deckBinding = bindingToDeck {
                // A sidebar of its own, as the reader has: window content runs
                // up under the toolbar, so a plain split view drew its divider
                // through the title bar and the deck's title across it.
                NavigationSplitView {
                    slideNavigator(deck: deckBinding)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
                } detail: {
                    editor(deck: deckBinding)
                        .frame(minWidth: 820)
                }
            } else {
                ContentUnavailableView(
                    "No Presentation",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Open a presentation from the library to begin building slides.")
                )
            }
        }
        .navigationTitle(deck?.title ?? "Slide Studio")
        .toolbar { studioToolbar }
        .toolbarLabelsFit(from: ToolbarLabelFit.slideStudio)
        .task(id: request) { loadInitialDeck() }
        .task {
            typefaceFamilies = await Task.detached(priority: .utility) {
                PresentationTypefaces.families
            }.value
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await refreshDecksFromDisk()
            }
        }
        .onChange(of: selectedDeckID) { _, deckID in selectDeck(deckID) }
        .onChange(of: deck?.id, initial: true) { _, deckID in
            inbox.setWindow(windowToken, showing: deckID)
            if let deckID, let slideID = inbox.takeSelection(for: deckID),
               deck?.slides.contains(where: { $0.id == slideID }) == true {
                selectedSlideID = slideID
            }
            receiveSentSlides()
        }
        // Not `.onReceive(inbox.$pending)`: a published value's publisher
        // fires before the value changes, so the slide was not there yet.
        .onChange(of: inbox.pending) { receiveSentSlides() }
        .background(HostWindowReader(box: hostWindow))
        .task(id: MenuOrderKey(revision: inbox.revision, deckIDs: decks.map(\.id))) { await refreshMenuOrder() }
        .onChange(of: decks, initial: true) { _, decks in
            if !isLoading { inbox.note(decks) }
        }
        .onChange(of: deck) { previousDeck, updatedDeck in
            if let previousDeck, !isRestoring, previousDeck.id == updatedDeck?.id {
                // Only an edit to the deck on screen. Changing deck is a move,
                // not something to undo, and `applySelection` clears the
                // history for that.
                history.record(previousDeck)
            }
            isRestoring = false
            canUndoEdit = history.canUndo
            canRedoEdit = history.canRedo
            scheduleAutosave(updatedDeck)
        }
        // Off the main thread: a long writing over many slides takes a while
        // to split, and opening a deck waited for it.
        .task(id: manuscriptNotesInputs) {
            let inputs = manuscriptNotesInputs
            guard inputs != resolvedInputs else { return }
            guard let deck, deck.followsManuscript, let manuscript = inputs.manuscript else {
                resolution = nil
                resolvedInputs = inputs
                return
            }
            let resolved = await Task.detached(priority: .userInitiated) {
                LampPresentationManuscriptNotes.resolve(deck: deck, manuscript: manuscript)
            }.value
            guard !Task.isCancelled else { return }
            resolution = resolved
            resolvedInputs = inputs
        }
        .alert("Slide Studio", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \(deck?.title ?? "this deck")?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Deck", role: .destructive) { deleteSelectedDeck() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the editable .lampdeck document from the library.")
        }
        .onDisappear {
            inbox.setWindow(windowToken, showing: nil)
            saveTask?.cancel()
            saveNow()
            // A video still being prepared would land after the save, in a
            // deck no longer shown; it is dropped, and its files with it.
            preparingVideos.removeAll()
        }
    }

    /// Slides sent to the deck on screen, added at its end as an edit like any
    /// other: saved by the autosave, and undoable.
    private func receiveSentSlides() {
        guard let deckID = deck?.id else { return }
        let sent = inbox.take(for: deckID)
        guard !sent.isEmpty else { return }
        deck?.slides += sent
        selectedSlideID = sent.last?.id
        // The window raises itself: it alone knows it is the one, whatever
        // its deck is called on disk or on screen.
        // Ordering front leaves a minimized window in the Dock;
        // deminiaturizing brings it forward itself.
        if let window = hostWindow.window {
            if window.isMiniaturized { window.deminiaturize(nil) } else { window.makeKeyAndOrderFront(nil) }
        }
        statusMessage = sent.count == 1 ? "Added a slide" : "Added \(sent.count) slides"
    }

    private var bindingToDeck: Binding<LampPresentationDeck>? {
        guard deck != nil else { return nil }
        return Binding(
            get: { deck ?? LampPresentationDeck.starter() },
            set: { deck = $0 }
        )
    }

    @ToolbarContentBuilder
    private var studioToolbar: some ToolbarContent {
        ToolbarItemGroup {
            // Deliberately without a key equivalent. In AppKit a menu or
            // toolbar shortcut is consulted before the responder chain, so
            // taking Command-Z here would take it from the text field being
            // typed in, and undoing a word would undo the whole slide
            // instead. Wiring these to the window's UndoManager is what lets
            // both live together, and is a piece of work in its own right.
            Button("Undo Edit", systemImage: "arrow.uturn.backward") { undoEdit() }
                .help("Take back the last change to this deck")
                .disabled(!canUndoEdit)
            Button("Redo Edit", systemImage: "arrow.uturn.forward") { redoEdit() }
                .help("Put back the change that was taken back")
                .disabled(!canRedoEdit)
        }

        // The deck's file actions in one labelled menu, as a document app
        // keeps them under File: four icons of one weight in a row — import,
        // export, PDF, delete — were the densest stretch of a toolbar judged
        // a row of look-alike glyphs.
        ToolbarItem {
            Menu {
                // Saving is automatic — the status bar says when it is done —
                // so Save is kept here, with its ⌘S, rather than as a lone
                // checkmark in the toolbar that read as a status light.
                Button("Save", systemImage: "checkmark.circle") { saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(deck == nil || hasErrors || !hasUnsavedChanges)
                Divider()
                Button("Import Deck…", systemImage: "square.and.arrow.down") { importDeck() }
                Button("Export Deck…", systemImage: "square.and.arrow.up") { exportDeck() }
                    .disabled(deck == nil || hasErrors)
                Menu("Export PDF", systemImage: "doc.richtext") {
                    Button("Slides Only…") { exportPDF(includesSpeakerNotes: false) }
                    Button("Slides with Speaker Notes…") { exportPDF(includesSpeakerNotes: true) }
                }
                .disabled(deck == nil || hasErrors || isExportingPDF)
                Divider()
                Button("Delete Deck…", systemImage: "trash", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(deck == nil)
            } label: {
                Label("Deck", systemImage: "rectangle.stack")
                    .labelStyle(.titleAndIcon)
            }
            .help("Save, import, export or delete this deck")
        }

        ToolbarItem {
            Button {
                remoteHost.start()
                showingRemotePairing = true
            } label: {
                Label(
                    remoteHost.connectedClientNames.isEmpty ? "Remote" : "Remote Connected",
                    systemImage: remoteHost.connectedClientNames.isEmpty ? "qrcode" : "iphone.and.arrow.forward"
                )
            }
            .fittingToolbarLabel()
            .accessibilityLabel(remoteHost.connectedClientNames.isEmpty ? "Pair Remote" : "Remote Connected")
            .popover(isPresented: $showingRemotePairing, arrowEdge: .bottom) {
                SlideRemotePairingView(
                    pairingCode: remoteHost.pairingCode,
                    remembered: remoteHost.rememberedRemotes,
                    forget: { remoteHost.forget($0) },
                    forgetAll: { remoteHost.forgetAllRemotes() }
                )
                // Read when the list is about to be shown, never at launch.
                .onAppear { remoteHost.refreshRememberedRemotes() }
            }
            .help("Pair an iPhone or iPad before presenting")
        }

        ToolbarItem {
            // Named, as Keynote names its own: the one action the window
            // is for, and the only one in the accent.
            Button { presentDeck() } label: {
                Label("Play", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.lampProminent)
            .disabled(deck == nil || hasErrors)
            .help("Present this deck")
        }
    }

    private func slideNavigator(
        deck deckBinding: Binding<LampPresentationDeck>
    ) -> some View {
        VStack(spacing: 0) {
            // The deck's title in full, as the head of the rail, with the
            // other decks a click away: a pop-up cut a talk's title — often
            // a question — off after a few words.
            Menu {
                Picker("Deck", selection: $selectedDeckID) {
                    ForEach(menuDecks) { candidate in
                        Text(candidate.title).tag(Optional(candidate.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                // The way back to every deck, in the library window.
                Button("Show All Presentations", systemImage: "rectangle.stack") {
                    showAllPresentations()
                }
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deckBinding.wrappedValue.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(deckBinding.wrappedValue.slides.count) slides")
                            .font(.caption)
                            .foregroundStyle(Color.lampSecondaryText)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.lampSecondaryText)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Choose another deck")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(deckBinding.slides.wrappedValue.enumerated()), id: \.element.id) { index, slide in
                        Button {
                            selectedSlideID = slide.id
                            slideListFocused = true
                        } label: {
                            let isSelected = selectedSlideID == slide.id
                            HStack(alignment: .top, spacing: 8) {
                                // Numbered in a column of their own, as
                                // Keynote numbers its slides, so the number
                                // is found without reading the caption.
                                Text("\(index + 1)")
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                    .frame(width: 20, alignment: .trailing)
                                    .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                ZStack(alignment: .topTrailing) {
                                    // The thumbnail is kept clear of the
                                    // selection, so moving between slides
                                    // redraws two rings rather than every
                                    // slide in the deck. Drawing a slide is
                                    // not cheap — a picture behind one has
                                    // its page laid out three times, to find
                                    // the words, read the picture under them
                                    // and set them again — and the strip was
                                    // paying that for every slide on every
                                    // keystroke.
                                    SlideThumbnail(
                                        slide: slide,
                                        style: .init(deck: deckBinding.wrappedValue),
                                        store: store
                                    )
                                    .equatable()
                                    // In dark, the slides not being worked
                                    // on step back a little: a column of
                                    // bright pages glared beside the canvas.
                                    .overlay {
                                        if !isSelected {
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(Self.restingThumbnailShade)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                                    }


                                    if slide.isHidden {
                                        Image(systemName: "eye.slash.fill")
                                            .font(.caption2)
                                            .padding(5)
                                            .background(.ultraThinMaterial, in: Circle())
                                            .padding(4)
                                    }
                                }
                            }
                            }
                            .padding(6)
                            // The selected slide sits on a soft tile, as
                            // Keynote's rail marks it, rather than in a red
                            // ring that competed with Play for the accent.
                            .background(
                                isSelected ? Color.primary.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The slide's name in the tooltip rather than under it,
                        // as Keynote's rail has it: printed beneath, it repeated
                        // the title the thumbnail already shows, and spaced the
                        // rail so that fewer slides were in view.
                        .help("\(index + 1). \(slide.displayTitle)")
                        .accessibilityLabel("\(index + 1). \(slide.displayTitle)")
                        .id(slide.id)
                        .contextMenu {
                            Button("Duplicate") { duplicateSlide(slide.id) }
                            Button(slide.isHidden ? "Show Slide" : "Hide Slide") {
                                toggleHidden(slide.id)
                            }
                            Divider()
                            Button("Delete Slide", role: .destructive) { deleteSlide(slide.id) }
                                .keyboardShortcut(.delete, modifiers: [])
                                .disabled(deckBinding.slides.wrappedValue.count == 1)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
            .focusable()
            .focused($slideListFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up, .left: selectSlide(by: -1)
                case .down, .right: selectSlide(by: 1)
                @unknown default: break
                }
            }
            // Delete or Backspace with the rail in focus deletes the slide
            // chosen, as the context menu does and as Keynote's rail does:
            // undoable, so not asked about first. Never the deck's last.
            .onDeleteCommand {
                if let selectedSlideID { deleteSlide(selectedSlideID) }
            }
            .onChange(of: selectedSlideID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id, anchor: .center) }
            }
            }

            Divider()
            HStack {
                Button("Add Slide", systemImage: "plus") { addSlide() }
                .buttonStyle(.lampSecondary)
                .controlSize(.small)
                Spacer()
                Button("Move Up", systemImage: "arrow.up") { moveSlide(by: -1) }
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveSlide(by: -1))
                Button("Move Down", systemImage: "arrow.down") { moveSlide(by: 1) }
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveSlide(by: 1))
            }
            .controlSize(.small)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func editor(deck deckBinding: Binding<LampPresentationDeck>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        Color(nsColor: .underPageBackgroundColor)
                        if let slide = selectedSlide {
                            LampPresentationSlideCanvas(
                                slide: slide,
                                deck: deckBinding.wrappedValue,
                                store: store
                            )
                            .aspectRatio(deckBinding.wrappedValue.aspectRatio.ratio, contentMode: .fit)
                            // A lighter shadow: the slide is lifted off the
                            // canvas, not weighed down on it.
                            .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
                            // Tighter, so the slide takes more of the canvas.
                            .padding(30)
                        }
                    }
                    .frame(minHeight: 440)

                    Divider()
                    // Held lower than before: a slide's notes run to a few
                    // lines, and the pane stood mostly empty beneath them
                    // while taking height from the slide.
                    speakerNotesEditor
                        .frame(minHeight: 120, idealHeight: 150, maxHeight: 190)
                }

                PaneResizeHandle(
                    axis: .horizontal,
                    preferredSize: $inspectorWidth,
                    displayedSize: shownInspectorWidth,
                    minimumSize: 300,
                    maximumSize: 430
                )
                inspector(deck: deckBinding)
                    .frame(width: shownInspectorWidth)
            }

            Divider()
            validationBar
        }
    }

    @ViewBuilder
    /// Slide Studio's inspector: what the selected slide holds, or the deck's
    /// look, one at a time, as Keynote's Format and Document panes are.
    ///
    /// With both stacked, the slide's own content sat below the fold behind
    /// the deck's settings, and every group in its own card made a column of
    /// nested boxes. Now each pane is flat: headings and hairlines on the
    /// window's ground, with the controls given the width.
    private func inspector(deck deckBinding: Binding<LampPresentationDeck>) -> some View {
        VStack(spacing: 0) {
            inspectorTabs
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch inspectorPane {
                    case .slide:
                        if let slideBinding = bindingToSelectedSlide {
                            // The layouts as pictures, as a slide tool shows
                            // them: chosen by how the slide will look, not by
                            // a name in a pop-up.
                            StudioInspectorSection("Layout") {
                                VStack(alignment: .leading, spacing: 12) {
                                    StudioLayoutPicker(selection: slideBinding.layout)
                                    StudioVariantControl(slide: slideBinding)
                                    Toggle("Skip while presenting", isOn: slideBinding.isHidden)
                                    .tint(Color.lampAccentMuted)
                                    StudioRevealControls(slide: slideBinding)
                                }
                            }
                            Divider().padding(.vertical, 18)
                            StudioInspectorSection("Background") {
                                StudioSlideBackground(
                                    slide: slideBinding,
                                    theme: deckBinding.wrappedValue.theme
                                )
                            }
                            Divider().padding(.vertical, 18)
                            StudioInspectorSection("Content") {
                                VStack(spacing: 18) {
                                    ForEach(slideBinding.blocks) { $block in
                                        LampSlideBlockEditor(
                                            block: $block,
                                            imageURL: store.assetURL(for: block),
                                            updateCitation: { citation in
                                                updateScriptureCitation(citation, after: block.id)
                                            },
                                            chooseImage: { chooseImage(for: block.id) },
                                            chooseVideo: { chooseMovie(for: block.id, as: .loop) },
                                            chooseClip: { chooseMovie(for: block.id, as: .clip) },
                                            addClipLink: { addClipLink(for: block.id) },
                                            isPreparingVideo: preparingVideos["\(selectedSlide?.id ?? "")/\(block.id)"] != nil,
                                            besideWords: Self.drawsBeside(block.id, on: slideBinding.wrappedValue),
                                            isShown: !slideBinding.wrappedValue.plan.ignored.contains { $0.id == block.id },
                                            layoutName: slideBinding.wrappedValue.layout.displayName,
                                            remove: { removeBlock(block.id) }
                                        )
                                        if block.id != slideBinding.blocks.wrappedValue.last?.id {
                                            Divider()
                                        }
                                    }

                                    Menu("Add Content", systemImage: "plus") {
                                        ForEach(LampPresentationBlockKind.authorableHere) { kind in
                                            Button(kind.displayName) { addBlock(kind) }
                                        }
                                        // A video is a picture that moves, so
                                        // each of these adds a picture block
                                        // and asks for the video at once.
                                        Divider()
                                        Button("Looping Video…", systemImage: "film") { addMovie(.loop) }
                                        Button("Clip with Sound…", systemImage: "play.rectangle") { addMovie(.clip) }
                                        Button("YouTube or Vimeo…", systemImage: "play.tv") { addMovie(nil) }
                                    }
                                    .lampMenu()
                                    .controlSize(.small)
                                    .fixedSize()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if preparingVideos.keys.contains(where: {
                                        $0.hasPrefix("\(slideBinding.wrappedValue.id)/\(Self.newVideoBlock)-")
                                    }) {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small)
                                            Text("Preparing video…").font(.callout).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("Choose a slide to edit it.")
                                .foregroundStyle(Color.lampSecondaryText)
                        }
                    case .deck:
                        StudioInspectorSection(nil) {
                            VStack(alignment: .leading, spacing: 12) {
                                StudioInspectorRow("Title") {
                                    // Wraps rather than scrolls: a talk's title is
                                    // often a question, longer than the inspector.
                                    TextField("Title", text: deckBinding.title, axis: .vertical)
                                        .lineLimit(1...3)
                                        .labelsHidden()
                                }
                                StudioInspectorRow("Aspect") {
                                Picker("Aspect", selection: deckBinding.aspectRatio) {
                                    ForEach(LampPresentationAspectRatio.allCases) { ratio in
                                        Text(ratio.displayName).tag(ratio)
                                    }
                                }
                                .labelsHidden()
                                }
                                // A dissolve or a cut, and nothing showier: a
                                // slide that moves draws the eye from what it
                                // says. Absent in the file means a dissolve.
                                StudioInspectorRow("Transition") {
                                    Picker("Transition", selection: Binding(
                                        get: { deckBinding.wrappedValue.transition ?? .dissolve },
                                        set: { deckBinding.transition.wrappedValue = $0 == .dissolve ? nil : $0 }
                                    )) {
                                        ForEach(LampPresentationTransition.allCases) { transition in
                                            Text(transition.displayName).tag(transition)
                                        }
                                    }
                                    .labelsHidden()
                                }
                                // The themes as the deck's own first slide
                                // drawn in each, so the choice is seen rather
                                // than named.
                                StudioStackedField("Theme") {
                                    themeChoices(deck: deckBinding.wrappedValue)
                                }
                                // Headings and body apart, the commonest way a
                                // deck looks designed: a serif title over sans
                                // body text, or the reverse.
                                StudioInspectorRow("Headings") {
                                    typefaceMenu(
                                        deckBinding.theme.headingTypeface,
                                        unset: "Same as Body"
                                    )
                                }
                                StudioInspectorRow("Body") {
                                    typefaceMenu(deckBinding.theme.typeface, unset: "Lamp Rounded")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func themeChoices(deck: LampPresentationDeck) -> some View {
        let builtIn = LampPresentationTheme.builtIn
        let isCustom = !builtIn.contains { $0.id == deck.theme.id }
        let themes: [(theme: LampPresentationTheme, name: String)] =
            (isCustom ? [(deck.theme, "This Deck’s")] : [])
            + builtIn.map { ($0, LampPresentationTheme.displayName(of: $0.id) ?? $0.id) }
        let sample = deck.slides.first ?? LampPresentationSlide(layout: .title, blocks: [])
        // Three across: seven side by side were too small to judge by.
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
            spacing: 12
        ) {
            ForEach(themes, id: \.theme.id) { entry in
                let isChosen = entry.theme.id == deck.theme.id
                // Drawn as choosing it would leave the deck: its typefaces,
                // and its highlights in this theme's palette.
                let shown = isChosen ? deck.theme : entry.theme.applied(over: deck.theme)
                Button {
                    if !isChosen { applyTheme(entry.theme.id) }
                } label: {
                    VStack(spacing: 5) {
                        LampPresentationSlideCanvas(
                            slide: sample,
                            style: .init(theme: shown, aspectRatio: deck.aspectRatio),
                            compact: true,
                            assetURL: { store.assetURL(for: $0) }
                        )
                        .aspectRatio(deck.aspectRatio.ratio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    isChosen ? Color.primary.opacity(0.7) : Color.lampCardStroke,
                                    lineWidth: isChosen ? 2 : 1
                                )
                        }
                        .allowsHitTesting(false)
                        Text(entry.name)
                            .font(.caption.weight(isChosen ? .semibold : .regular))
                            .foregroundStyle(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.lampSecondaryText))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.name) theme")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
    }


    private enum InspectorPane: String, CaseIterable, Identifiable {
        case slide = "Slide"
        case deck = "Deck"
        var id: String { rawValue }
    }

    /// The two panes, chosen in the text's own colour: a segmented control
    /// would have filled the chosen one with the accent, one more red mark.
    ///
    /// `LampSegmentedPicker` in all but shape — it is drawn here because
    /// these two span the inspector's width, which that control does not do
    /// (it sizes to its items). Its capsule and its height are matched by
    /// hand, so a toggle does not change shape from one pane to the next.
    private var inspectorTabs: some View {
        HStack(spacing: 4) {
            ForEach(InspectorPane.allCases) { pane in
                let isChosen = inspectorPane == pane
                Button {
                    inspectorPane = pane
                } label: {
                    Text(pane.rawValue)
                        .font(.callout.weight(isChosen ? .semibold : .regular))
                        .foregroundStyle(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.lampSecondaryText))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            isChosen ? Color.primary.opacity(0.09) : Color.clear,
                            in: Capsule(style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.04), in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    @ViewBuilder
    private var speakerNotesEditor: some View {
        if let slideBinding = bindingToSelectedSlide {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Presenter Notes", systemImage: "person.crop.rectangle.badge.plus")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle("Follow the writing", isOn: followsManuscriptBinding)
                    .tint(Color.lampAccentMuted)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                        .disabled(manuscript == nil)
                        .help(manuscript == nil
                            ? "Link this deck to a writing to derive its notes from it."
                            : "Split the writing across the slides instead of typing notes.")
                }

                if deck?.followsManuscript == true {
                    manuscriptNotes(for: slideBinding)
                } else {
                    TextEditor(text: slideBinding.speakerNotes)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1))
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// In manuscript mode the notes are derived, so the anchor is the only
    /// thing to edit and the passage is shown as it will be spoken.
    ///
    /// The anchor is the phrase the notes begin at, so it is always the first
    /// words of the passage below it. Shown as a field of its own above them it
    /// read as a title for each note — a title that was only the note's own
    /// opening sentence. It is a lookup phrase, so it is labelled as one and
    /// kept small, and the words it matched are tinted where they occur in the
    /// passage: the repetition then reads as a mark on the join rather than a
    /// heading.
    @ViewBuilder
    private func manuscriptNotes(
        for slideBinding: Binding<LampPresentationSlide>
    ) -> some View {
        // Found until the split says otherwise, so the warning never flashes
        // while it is still being worked out; not found when there is no
        // writing to find it in.
        let anchorFound = resolution.map { $0.notesBySlideID[slideBinding.wrappedValue.id] != nil }
            ?? (resolvedInputs.map { $0.manuscript != nil } ?? true)
        let anchor = (slideBinding.wrappedValue.notesAnchor ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAnchor = !anchor.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Begins at")
                    .foregroundStyle(.secondary)
                TextField(
                    "the first words this slide is spoken over",
                    text: Binding(
                        get: { slideBinding.wrappedValue.notesAnchor ?? "" },
                        set: { anchor in
                            let typed = anchor.isEmpty ? nil : anchor
                            // The field writes back what it shows as it takes
                            // focus, which is not a change to split for.
                            guard typed != slideBinding.wrappedValue.notesAnchor else { return }
                            slideBinding.wrappedValue.notesAnchor = typed
                            // Re-split as the phrase is typed, so the passage
                            // below is always what this anchor actually claims.
                            resolveNotesFromManuscript()
                        }
                    )
                )
                .textFieldStyle(.plain)
                .foregroundStyle(hasAnchor && !anchorFound ? Color.orange : .secondary)
                if hasAnchor && !anchorFound {
                    // The last good notes stay on screen beneath this.
                    Label("Not in the writing", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help("This phrase is no longer in the writing. The notes below "
                            + "are the last that resolved.")
                }
            }
            .font(.caption)
            ScrollView {
                notesPassage(
                    slideBinding.wrappedValue.speakerNotes,
                    openingAt: anchorFound ? anchor : ""
                )
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                // A speaker reads these at a glance, mid-sentence; a line the
                // width of the canvas is too long to find one's place in.
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1))
            }
        }
    }

    /// The writing this deck is linked to, when there is one.
    private var manuscript: String? {
        guard let writingID = deck?.writingID,
              let devotional = model.devotionals.first(where: { $0.id == writingID })
        else { return nil }
        return devotional.displayMarkdown
    }

    /// What the split depends on: the writing, and each slide's anchor in
    /// order. Not the notes, which the split itself writes.
    private struct ManuscriptNotesInputs: Equatable {
        let manuscript: String?
        let anchors: [String]
    }

    private var manuscriptNotesInputs: ManuscriptNotesInputs {
        manuscriptNotesInputs(for: deck)
    }

    private func manuscriptNotesInputs(for deck: LampPresentationDeck?) -> ManuscriptNotesInputs {
        guard let deck, deck.followsManuscript else {
            return ManuscriptNotesInputs(manuscript: nil, anchors: [])
        }
        return ManuscriptNotesInputs(
            manuscript: manuscript,
            anchors: deck.slides.map { "\($0.id)\u{0}\($0.notesAnchor ?? "")" }
        )
    }

    private var followsManuscriptBinding: Binding<Bool> {
        Binding(
            get: { deck?.followsManuscript == true },
            set: { follows in
                guard var current = deck else { return }
                // Turning this off keeps whatever is on screen as authored
                // notes, so nothing a speaker was relying on disappears.
                current.speakerNotesSource = follows ? .manuscript : .authored
                deck = current
                if follows { resolveNotesFromManuscript() }
            }
        )
    }

    /// Re-splits the writing across the slides.
    private func resolveNotesFromManuscript() {
        guard let current = deck, current.followsManuscript, let manuscript else { return }
        let resolved = LampPresentationManuscriptNotes.resolve(deck: current, manuscript: manuscript)
        resolution = resolved
        resolvedInputs = manuscriptNotesInputs(for: current)
        deck = LampPresentationManuscriptNotes.applying(resolved, to: current)
    }

    private var validationBar: some View {
        HStack(spacing: 8) {
            if let firstIssue = issues.first {
                Image(systemName: firstIssue.severity == .error
                    ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                    .foregroundStyle(firstIssue.severity == .error ? .red : .orange)
                Text("\(firstIssue.path): \(firstIssue.message)")
                    .lineLimit(1)
                if issues.count > 1 {
                    Text("+\(issues.count - 1) more")
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: hasUnsavedChanges ? "circle.dotted" : "checkmark.circle.fill")
                    .foregroundStyle(hasUnsavedChanges ? Color.secondary : Color.green)
                Text(statusMessage.isEmpty
                    ? (hasUnsavedChanges ? "Waiting to save…" : "Saved")
                    : statusMessage)
            }
            Spacer()
            // The slide count is under the deck's title at the head of the
            // rail; said here as well it was one more grey caption.
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private var selectedSlide: LampPresentationSlide? {
        guard let selectedSlideID else { return deck?.slides.first }
        return deck?.slides.first { $0.id == selectedSlideID }
    }

    private var bindingToSelectedSlide: Binding<LampPresentationSlide>? {
        guard let slideID = selectedSlide?.id else { return nil }
        return Binding(
            get: {
                deck?.slides.first { $0.id == slideID }
                    ?? LampPresentationSlide(layout: .blank)
            },
            set: { updated in
                guard let index = deck?.slides.firstIndex(where: { $0.id == slideID }) else { return }
                deck?.slides[index] = updated
            }
        )
    }

    private func loadInitialDeck() {
        saveTask?.cancel()
        do {
            decks = try store.decks()
            if let newDeckID = request.newDeckID {
                // Asked for a new deck. Opening the first existing one instead
                // meant File → New Presentation Deck handed you a deck you had
                // already written, and Slide Studio saves as you type.
                try openOrMakeDeck(id: newDeckID)
                isLoading = false
                return
            }
            let requestedDeck: LampPresentationDeck?
            if let deckID = request.deckID {
                requestedDeck = decks.first { $0.id == deckID }
            } else if let devotionalID = request.devotionalID {
                requestedDeck = decks.first {
                    $0.writingID == devotionalID
                }
            } else {
                requestedDeck = decks.first
            }

            if let requestedDeck {
                applySelection(requestedDeck)
            } else {
                let newDeck = starterDeck(devotionalID: request.devotionalID)
                try store.save(newDeck)
                inbox.deckFilesChanged()
                decks.append(newDeck)
                decks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                applySelection(newDeck)
            }
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func refreshDecksFromDisk() async {
        guard !isLoading else { return }
        // Read and decoded off the main thread: every deck, every second,
        // is long enough there to drop a frame while someone types.
        let store = store
        let knownDecks = decks
        let knownSavedDeck = savedDeck
        let result = await Task.detached(priority: .utility) {
            Result { () throws -> [LampPresentationDeck]? in
                let refreshed = try store.decks()
                return refreshed == knownDecks ? nil : refreshed
            }
        }.value
        // A save or a deck change while it was read makes what was read
        // older than what's here: taking it would put the save back.
        guard !Task.isCancelled, !isLoading, decks == knownDecks, savedDeck == knownSavedDeck else { return }
        do {
            guard let refreshed = try result.get() else { return }
            if let selectedDeckID,
               let diskDeck = refreshed.first(where: { $0.id == selectedDeckID }),
               deck == savedDeck,
               // Against what was saved, which leaves cleared blocks out.
               diskDeck != savedDeck?.withoutEmptyTextBlocks {
                let priorSlideID = selectedSlideID
                deck = diskDeck
                savedDeck = diskDeck
                selectedSlideID = diskDeck.slides.contains { $0.id == priorSlideID }
                    ? priorSlideID : diskDeck.slides.first?.id
                statusMessage = "Updated from agent workspace"
            }
            decks = refreshed
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens the deck with this ID, making it first if it is not there.
    ///
    /// Idempotent, which is what lets a restored window carry the same request
    /// without making a second deck.
    private func openOrMakeDeck(id: String) throws {
        if let existing = decks.first(where: { $0.id == id }) {
            applySelection(existing)
            return
        }
        var newDeck = starterDeck(devotionalID: request.devotionalID)
        newDeck.id = id
        try store.save(newDeck)
        inbox.deckFilesChanged()
        decks.append(newDeck)
        decks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        applySelection(newDeck)
    }

    private func starterDeck(devotionalID: String?) -> LampPresentationDeck {
        guard let devotionalID,
              let devotional = model.devotionals.first(where: { $0.id == devotionalID }) else {
            return .starter()
        }
        return .starter(
            title: devotional.title,
            subtitle: devotional.subtitle ?? devotional.author,
            // `writing`, the format's current name; `devotional` is still
            // read, as every deck made before says it.
            source: .init(kind: .writing, id: devotional.id)
        )
    }

    private func applySelection(_ selected: LampPresentationDeck) {
        // A different deck is a different history. Undoing across that
        // boundary would put one deck's slides into another.
        if selected.id != deck?.id {
            history.forget()
            canUndoEdit = false
            canRedoEdit = false
        }
        // An unfinished version of this deck outranks the stored one: it is
        // what the writer last had on screen, and the only reason it is not in
        // the library is that it does not validate yet. `savedDeck` stays the
        // stored deck, so the draft still counts as unsaved work.
        let draft = LampSlideStudioDrafts.read(
            forDeck: selected.id, inApplicationSupport: applicationSupportURL
        )
        deck = draft ?? selected
        savedDeck = selected
        selectedDeckID = selected.id
        selectedSlideID = (draft ?? selected).slides.first?.id
        statusMessage = draft == nil ? "Saved" : "Unfinished — fix the errors to save"
    }

    /// Where this machine's own unfinished work is kept. Not the library: the
    /// library syncs, and a broken deck is not something to send to a phone.
    private var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private func undoEdit() {
        guard let current = deck, let previous = history.undo(from: current) else { return }
        isRestoring = true
        deck = previous
        selectedSlideID = previous.slides.first { $0.id == selectedSlideID }?.id
            ?? previous.slides.first?.id
    }

    private func redoEdit() {
        guard let current = deck, let next = history.redo(from: current) else { return }
        isRestoring = true
        deck = next
        selectedSlideID = next.slides.first { $0.id == selectedSlideID }?.id
            ?? next.slides.first?.id
    }

    private func selectDeck(_ deckID: String?) {
        guard let deckID, deckID != deck?.id,
              let selected = decks.first(where: { $0.id == deckID }) else { return }
        saveNow()
        applySelection(selected)
    }

    private func scheduleAutosave(_ updatedDeck: LampPresentationDeck?) {
        saveTask?.cancel()
        guard let updatedDeck, updatedDeck != savedDeck else { return }
        statusMessage = "Waiting to save…"
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, deck == updatedDeck else { return }
            saveNow()
        }
    }

    /// Writes the deck as it stands, whether or not it validates.
    ///
    /// Validity used to gate this, and that lost people's work. Every error the
    /// validator raises is a state you pass through while editing — a title
    /// cleared to retype it, a half-typed hex colour, every slide deleted to
    /// start again — so a deck sitting invalid for a few seconds is ordinary.
    /// Closing the window or changing deck in those seconds threw away
    /// everything since the deck last validated, and said so only in a status
    /// message.
    ///
    /// Validity governs publishing instead, which is where it was always
    /// enforced anyway: `presentDeck` refuses an invalid deck, and the agent's
    /// preview and the workspace import each validate what they read. An editor
    /// that will not remember what you typed is a worse failure than a deck
    /// that is briefly unpresentable.
    private func saveNow() {
        saveTask?.cancel()
        guard let deck, deck != savedDeck else { return }
        do {
            let stored = deck.withoutEmptyTextBlocks
            try store.save(stored)
            inbox.deckFilesChanged()
            // The editor's own copy, empty blocks and all; but the list holds
            // what is on disk, so a refresh does not take the save for a
            // change from elsewhere.
            savedDeck = deck
            if let index = decks.firstIndex(where: { $0.id == deck.id }) {
                decks[index] = stored
            } else {
                decks.append(stored)
            }
            decks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            statusMessage = "Saved"
            LampSlideStudioDrafts.discard(
                forDeck: deck.id, inApplicationSupport: applicationSupportURL
            )
        } catch let error as LampPresentationDeckStoreError {
            // The library takes valid decks only. Keep the work beside the app
            // so closing the window does not throw it away, and say that it is
            // held rather than stored.
            guard case .invalidDeck = error else {
                errorMessage = error.localizedDescription
                return
            }
            do {
                try LampSlideStudioDrafts.write(deck, inApplicationSupport: applicationSupportURL)
                // The draft keeps everything as typed, empty blocks and all.
                statusMessage = "Unfinished — fix the errors to save"
            } catch {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedDeck() {
        guard let deck else { return }
        saveTask?.cancel()
        do {
            // Recorded first, so the deletion reaches other Macs rather than
            // their copies bringing the deck back.
            try LampPresentationDeckSync.recordDeletion(of: deck.id, in: model.library.rootURL)
            try store.delete(id: deck.id)
            inbox.deckFilesChanged()
            decks.removeAll { $0.id == deck.id }
            // Images the removed deck owned, unless another deck shares them.
            try? LampPresentationDeckSync.pruneUnreferencedAssets(in: model.library.rootURL)
            // The window closes rather than opening some other deck in its
            // place, which read as a deck chosen at random. The deck is let
            // go first: the window saves what it holds as it closes, and
            // would write the deleted deck straight back.
            LampSlideStudioDrafts.discard(forDeck: deck.id, inApplicationSupport: applicationSupportURL)
            history.forget()
            self.deck = nil
            savedDeck = nil
            // Its own window, closed directly: the dismiss action left a
            // studio window open on "No Presentation".
            hostWindow.window?.close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addSlide() {
        guard deck != nil else { return }
        let slide = LampPresentationSlide(
            layout: .titleAndBody,
            blocks: [
                .init(kind: .title, text: "New Slide"),
                .init(kind: .body, text: "Add your thought here."),
            ]
        )
        deck?.slides.append(slide)
        selectedSlideID = slide.id
    }

    private func duplicateSlide(_ slideID: String) {
        guard let index = deck?.slides.firstIndex(where: { $0.id == slideID }),
              var copy = deck?.slides[index] else { return }
        copy.id = UUID().uuidString.lowercased()
        copy.blocks = copy.blocks.map { block in
            var updated = block
            updated.id = UUID().uuidString.lowercased()
            return updated
        }
        deck?.slides.insert(copy, at: index + 1)
        selectedSlideID = copy.id
    }

    private func deleteSlide(_ slideID: String) {
        guard let index = deck?.slides.firstIndex(where: { $0.id == slideID }),
              (deck?.slides.count ?? 0) > 1 else { return }
        deck?.slides.remove(at: index)
        let nextIndex = min(index, (deck?.slides.count ?? 1) - 1)
        selectedSlideID = deck?.slides[nextIndex].id
    }

    private func toggleHidden(_ slideID: String) {
        guard let index = deck?.slides.firstIndex(where: { $0.id == slideID }) else { return }
        deck?.slides[index].isHidden.toggle()
    }

    /// The notes, with the phrase they were found by tinted where it opens
    /// them. Nothing is tinted when the anchor no longer matches, because then
    /// the passage below is the last one that resolved and does not begin with
    /// what the field now says.
    private func notesPassage(_ notes: String, openingAt opening: String) -> Text {
        guard !notes.isEmpty else {
            return Text("This slide is silent. Give it an opening phrase to speak over it.")
                .foregroundColor(.secondary)
        }
        guard !opening.isEmpty, notes.hasPrefix(opening) else { return Text(notes) }
        // Marked as the join it is, in the text's own colour: drawn in the
        // accent, a sentence of red on the dark notes was hard to read and
        // was one more red mark in a window that had too many.
        return Text(opening)
            .fontWeight(.semibold)
            .underline(true, color: Color.accentColor.opacity(0.55))
            + Text(notes.dropFirst(opening.count))
    }

    /// Steps the selection through the deck. Arrow keys reach every slide the
    /// navigator shows, hidden ones included: they are still in the deck, and
    /// skipping them would make the list disagree with the keyboard.
    private func selectSlide(by offset: Int) {
        guard let slides = deck?.slides else { return }
        guard let next = LampSlideSelection.stepping(
            from: selectedSlideID,
            by: offset,
            through: slides.map(\.id)
        ) else { return }
        selectedSlideID = next
    }

    private func canMoveSlide(by offset: Int) -> Bool {
        guard let selectedSlideID,
              let index = deck?.slides.firstIndex(where: { $0.id == selectedSlideID }) else {
            return false
        }
        let destination = index + offset
        return destination >= 0 && destination < (deck?.slides.count ?? 0)
    }

    private func moveSlide(by offset: Int) {
        guard let selectedSlideID,
              let index = deck?.slides.firstIndex(where: { $0.id == selectedSlideID }) else { return }
        let destination = index + offset
        guard destination >= 0, destination < (deck?.slides.count ?? 0),
              let slide = deck?.slides.remove(at: index) else { return }
        deck?.slides.insert(slide, at: destination)
    }

    /// Copies a chosen image into the library and points the block at it.
    ///
    /// The file is copied rather than referenced: a deck travels to other Macs
    /// and to iPhone and iPad, where a path into this machine's home folder
    /// would mean nothing. The stored name is generated so two images called
    /// `photo.jpg` cannot collide in the one flat assets directory.
    private func chooseImage(for blockID: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to copy into this presentation."
        guard panel.runModal() == .OK, let source = panel.url else { return }

        guard let slideID = selectedSlide?.id,
              let slideIndex = deck?.slides.firstIndex(where: { $0.id == slideID }),
              let blockIndex = deck?.slides[slideIndex].blocks.firstIndex(where: { $0.id == blockID })
        else { return }

        // A photo not already HEIC is offered as HEIC, and one larger than any
        // slide shows at slide size: the same picture on screen, in a
        // fraction of the space on every device the deck syncs to.
        let smaller = Self.smallerPicture(of: source)
        if let smaller {
            let formatter = ByteCountFormatter()
            let alert = NSAlert()
            let oversized = max(smaller.width, smaller.height) > Self.largestPicturePixels
            alert.messageText = "Save this picture as HEIC?"
            alert.informativeText = "It is \(formatter.string(fromByteCount: smaller.bytes))"
                + (oversized
                    ? ", \(smaller.width) × \(smaller.height) pixels, and a slide shows at most "
                        + "\(Self.largestPicturePixels) across. "
                    : ". ")
                + "Lamp can save a HEIC copy that looks the same on screen in "
                + "\(formatter.string(fromByteCount: Int64(smaller.data.count))). Your original is left as it is."
            alert.addButton(withTitle: "Save Smaller Copy")
            alert.addButton(withTitle: "Use As It Is")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: return copyPicture(source, data: nil, into: slideIndex, blockIndex, slideID: slideID, blockID: blockID)
            default: return
            }
            return copyPicture(source, data: smaller.data, into: slideIndex, blockIndex, slideID: slideID, blockID: blockID)
        }
        copyPicture(source, data: nil, into: slideIndex, blockIndex, slideID: slideID, blockID: blockID)
    }

    /// The most pixels across a picture needs: a 4K display's width.
    static let largestPicturePixels = 3_840

    /// HEIC's quality for a copy no one can tell apart: measured on a 4K
    /// picture of soft gradients, small type and grain, 0.9 kept it 41.7 dB
    /// from its source (above the usual 40 dB mark) and 0.8 only 39.2.
    static let pictureQuality = 0.9

    /// A HEIC copy of the picture at `source`, no larger than a slide shows,
    /// where the photo is not HEIC already or is larger than that, and the
    /// copy comes out smaller.
    private static func smallerPicture(of source: URL) -> (data: Data, width: Int, height: Int, bytes: Int64)? {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let isHEIC = ["heic", "heif"].contains(source.pathExtension.lowercased())
        guard max(width, height) > largestPicturePixels || !isHEIC else { return nil }
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), largestPicturePixels),
        ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: Self.pictureQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), Int64(data.length) < bytes else { return nil }
        return (data as Data, width, height, bytes)
    }

    /// Writes the picture, as chosen or as `data` (a HEIC copy), into the
    /// library and points the block at it.
    private func copyPicture(
        _ source: URL,
        data: Data?,
        into slideIndex: Int,
        _ blockIndex: Int,
        slideID: String,
        blockID: String
    ) {
        let extensionName = data != nil ? "heic" : source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let name = "\(UUID().uuidString.lowercased()).\(extensionName)"
        let destination = store.assetsDirectoryURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: store.assetsDirectoryURL,
                withIntermediateDirectories: true
            )
            try (data ?? Data(contentsOf: source)).write(to: destination, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // A picture chosen now outranks a video still being prepared.
        preparingVideos["\(slideID)/\(blockID)"] = nil
        deck?.slides[slideIndex].blocks[blockIndex].assetPath =
            "\(LampPresentationDeckStore.assetsDirectoryName)/\(name)"
        if deck?.slides[slideIndex].blocks[blockIndex].altText?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            deck?.slides[slideIndex].blocks[blockIndex].altText =
                source.deletingPathExtension().lastPathComponent
        }
    }

    /// What a chosen video is for: a picture's silent loop, or a clip the
    /// talk stops to watch, with its sound.
    enum MoviePurpose {
        case loop
        case clip

        var largestFileBytes: Int64 {
            self == .loop ? LampPresentationVideo.largestFileBytes : LampPresentationClip.largestFileBytes
        }
    }

    /// Copies a video into the library, as a picture's looping video or as
    /// its clip, and makes its first frame the picture: the still shown
    /// everywhere it is not playing, and what the words over it are
    /// coloured for.
    ///
    /// Kept to the purpose's largest size, since every file a deck names
    /// travels with it to each device it syncs to; and offered as HEVC when
    /// it is not, which is about half the size for the same picture.
    @discardableResult
    private func chooseMovie(for blockID: String?, as purpose: MoviePurpose) -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = LampPresentationVideo.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = purpose == .loop
            ? "Choose a short video to play, silent and looping, while this slide is presented."
            : "Choose a clip to play, with its sound, when the slide reaches it."
        guard panel.runModal() == .OK, let source = panel.url else { return false }
        // Block ids are unique within a slide, not across the deck, so the
        // block is found again in the slide it was chosen on.
        guard let slideID = selectedSlide?.id, let deckID = deck?.id else { return false }
        guard LampPresentationVideo.isPlayable(source.lastPathComponent) else {
            errorMessage = "Lamp plays .mp4, .mov and .m4v video."
            return false
        }
        let formatter = ByteCountFormatter()
        let limit = formatter.string(fromByteCount: purpose.largestFileBytes)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let what = purpose == .loop ? "videos" : "clips"
        let reencodes: Bool
        if size > purpose.largestFileBytes {
            // Too large to copy as it is: offered in HEVC at a quality no one
            // can tell from the original, which usually brings it to a
            // fraction of its size.
            let alert = NSAlert()
            alert.messageText = "Make this video smaller?"
            alert.informativeText = "It is \(formatter.string(fromByteCount: size)). A deck's \(what) travel with it to "
                + "every device it syncs to, so Lamp keeps each to \(limit). Lamp can save a copy in HEVC that looks "
                + "the same\(purpose == .loop ? ", without sound" : ""); your original is left as it is."
            alert.addButton(withTitle: "Make Smaller")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            reencodes = true
        } else if !Self.isHEVC(source) {
            let alert = NSAlert()
            alert.messageText = "Save this video as HEVC?"
            alert.informativeText = "HEVC keeps a picture no one can tell from this one in about half the space, so the "
                + "deck syncs faster and takes less room on every device. Lamp saves a copy, up to 4K; your original "
                + "is left as it is."
            alert.addButton(withTitle: "Save as HEVC")
            alert.addButton(withTitle: "Use As It Is")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: reencodes = true
            case .alertSecondButtonReturn: reencodes = false
            default: return false
            }
        } else {
            reencodes = false
        }

        let assets = store.assetsDirectoryURL
        let stem = UUID().uuidString.lowercased()
        let videoName = "\(stem).\(reencodes ? "mp4" : source.pathExtension.lowercased())"
        let stillName = "\(stem).jpg"
        let preparing = "\(slideID)/\(blockID ?? "\(Self.newVideoBlock)-\(UUID().uuidString)")"
        let token = UUID()
        preparingVideos[preparing] = token
        Task { @MainActor in
            defer { if preparingVideos[preparing] == token { preparingVideos[preparing] = nil } }
            let video = assets.appendingPathComponent(videoName)
            let stillFile = assets.appendingPathComponent(stillName)
            do {
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                let still = try await Self.firstFrameJPEG(of: source)
                if reencodes {
                    var made = try await LampVisuallyLosslessVideo.encode(
                        source, to: video, keepingSound: purpose == .clip
                    )
                    // Too large at up to 4K: offered at 1080p, which still
                    // looks the same at the size most rooms see it.
                    if made.bytes > purpose.largestFileBytes, max(made.width, made.height) > 1_920 {
                        let alert = NSAlert()
                        alert.messageText = "Save it at 1080p?"
                        alert.informativeText = "At full size this video is \(formatter.string(fromByteCount: made.bytes)), "
                            + "over Lamp's \(limit) for a deck's \(what). At 1080p it keeps every detail a projector "
                            + "or a 1080p screen shows, in less space."
                        alert.addButton(withTitle: "Save at 1080p")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else {
                            try? FileManager.default.removeItem(at: video)
                            return
                        }
                        made = try await LampVisuallyLosslessVideo.encode(
                            source, to: video, keepingSound: purpose == .clip, largestSide: 1_920
                        )
                    }
                    guard made.bytes <= purpose.largestFileBytes else {
                        try? FileManager.default.removeItem(at: video)
                        errorMessage = "Even in HEVC, this video is \(formatter.string(fromByteCount: made.bytes)), over "
                            + "Lamp's \(limit) for a deck's \(what). Choose a shorter one"
                            + (purpose == .clip ? ", or stream it from YouTube or Vimeo." : ".")
                        return
                    }
                } else {
                    try FileManager.default.copyItem(at: source, to: video)
                }
                try still.write(to: stillFile, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: video)
                try? FileManager.default.removeItem(at: stillFile)
                errorMessage = "Lamp could not use that video: \(error.localizedDescription)"
                return
            }
            // Dropped, and its files with it, when the author has since
            // chosen another video for the block, opened another deck, or
            // removed the slide or block: nothing would name the files, and
            // a video is too large to leave for a later prune.
            guard preparingVideos[preparing] == token,
                  deck?.id == deckID,
                  let slideIndex = deck?.slides.firstIndex(where: { $0.id == slideID }),
                  var block = Self.target(blockID, in: deck?.slides[slideIndex])
            else {
                try? FileManager.default.removeItem(at: video)
                try? FileManager.default.removeItem(at: stillFile)
                return
            }
            let directory = LampPresentationDeckStore.assetsDirectoryName
            block.assetPath = "\(directory)/\(stillName)"
            switch purpose {
            case .loop: block.video = "\(directory)/\(videoName)"
            case .clip: block.clip = LampPresentationClip(source: "\(directory)/\(videoName)")
            }
            if block.altText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                block.altText = source.deletingPathExtension().lastPathComponent
            }
            place(block, in: slideIndex)
        }
        return true
    }

    /// Asks for a YouTube or Vimeo address and makes it the picture's clip,
    /// with the site's own picture of the video as its still.
    @discardableResult
    private func addClipLink(for blockID: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Play a video from YouTube or Vimeo"
        alert.informativeText = "Paste the video's address. It plays in the site's own player while you present, "
            + "which needs an internet connection; without one the slide shows its still."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://www.youtube.com/watch?v=…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = LampPresentationClip.origin(of: address)
        switch origin {
        case .youtube, .vimeo: break
        case .file, .unplayable:
            errorMessage = "That is not a YouTube or Vimeo video's address."
            return false
        }
        guard let slideID = selectedSlide?.id, let deckID = deck?.id else { return false }
        let assets = store.assetsDirectoryURL
        let stillName = "\(UUID().uuidString.lowercased()).jpg"
        let preparing = "\(slideID)/\(blockID ?? "\(Self.newVideoBlock)-\(UUID().uuidString)")"
        let token = UUID()
        preparingVideos[preparing] = token
        Task { @MainActor in
            defer { if preparingVideos[preparing] == token { preparingVideos[preparing] = nil } }
            let stillFile = assets.appendingPathComponent(stillName)
            // The site's own picture, or where it cannot be had, a plain one
            // of Lamp's: a picture needs a still, or its deck will not open.
            var still = await Self.thumbnail(of: origin) ?? Self.plainStill()
            if let data = still {
                do {
                    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                    try data.write(to: stillFile, options: .atomic)
                } catch {
                    // Not written, so not named: the block keeps what it had.
                    still = nil
                }
            }
            guard preparingVideos[preparing] == token,
                  deck?.id == deckID,
                  let slideIndex = deck?.slides.firstIndex(where: { $0.id == slideID }),
                  var block = Self.target(blockID, in: deck?.slides[slideIndex])
            else {
                try? FileManager.default.removeItem(at: stillFile)
                return
            }
            if still != nil {
                block.assetPath = "\(LampPresentationDeckStore.assetsDirectoryName)/\(stillName)"
            }
            // A picture with no still is a deck that will not open.
            guard block.assetPath != nil else {
                errorMessage = "Lamp could not make a still for that video."
                return
            }
            block.clip = LampPresentationClip(source: address)
            place(block, in: slideIndex)
        }
        return true
    }

    /// The site's own picture of a streamed video, as JPEG: YouTube's at its
    /// largest, else its standard size; Vimeo's from its oEmbed answer.
    private static func thumbnail(of origin: LampPresentationClip.Origin) async -> Data? {
        func fetch(_ address: String) async -> Data? {
            guard let url = URL(string: address),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return data
        }
        switch origin {
        case .youtube(let id):
            if let data = await fetch("https://i.ytimg.com/vi/\(id)/maxresdefault.jpg") { return data }
            return await fetch("https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        case .vimeo(let id, let hash):
            let page = "https://vimeo.com/\(id)" + (hash.map { "/\($0)" } ?? "")
            guard let encoded = page.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let json = await fetch("https://vimeo.com/api/oembed.json?url=\(encoded)&width=1920"),
                  let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let address = object["thumbnail_url"] as? String
            else { return nil }
            return await fetch(address)
        case .file, .unplayable:
            return nil
        }
    }

    /// A dark 16:9 still with a play mark, for a streamed clip whose site
    /// gave no picture of its own.
    private static func plainStill() -> Data? {
        let width = 1_280, height = 720
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        let middle = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.move(to: CGPoint(x: middle.x - 40, y: middle.y - 50))
        context.addLine(to: CGPoint(x: middle.x - 40, y: middle.y + 50))
        context.addLine(to: CGPoint(x: middle.x + 50, y: middle.y))
        context.closePath()
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// Whether `url`'s pictures are already HEVC.
    private static func isHEVC(_ url: URL) -> Bool {
        guard let track = AVURLAsset(url: url).tracks(withMediaType: .video).first,
              let format = track.formatDescriptions.first
        else { return false }
        // swiftlint:disable:next force_cast
        return CMFormatDescriptionGetMediaSubType(format as! CMFormatDescription) == kCMVideoCodecType_HEVC
    }

    /// The video's first frame, upright, as a JPEG.
    private static func firstFrameJPEG(of url: URL) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: .zero)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private func addBlock(_ kind: LampPresentationBlockKind) {
        guard let slideID = selectedSlide?.id,
              let index = deck?.slides.firstIndex(where: { $0.id == slideID }) else { return }
        let block: LampPresentationBlock
        if kind == .image {
            block = .init(
                kind: .image,
                assetPath: "\(LampPresentationDeckStore.assetsDirectoryName)/image.jpg",
                altText: "Describe the image"
            )
        } else if kind == .chart {
            // With a translation already chosen, so the block is one field
            // short of valid rather than two. The key has no sensible default
            // — it is the whole question the chart asks.
            block = .init(
                kind: .chart,
                text: "",
                chart: LampPresentationChart(
                    source: .init(
                        strongs: "",
                        translationID: model.selectedTranslationID
                            ?? model.translations.first?.id
                            ?? ""
                    ),
                    by: .book
                )
            )
        } else {
            block = .init(kind: kind, text: kind == .title ? "New Title" : "New content")
        }
        deck?.slides[index].blocks.append(block)
    }

    /// Asks for a video and, once it is ready, adds a picture block that
    /// plays it: a looping video or a clip from a file, or (nil) a YouTube or
    /// Vimeo address. Nothing is added until then, so a cancelled or failed
    /// video leaves nothing behind, and the new block is one edit to undo.
    private func addMovie(_ purpose: MoviePurpose?) {
        if let purpose { chooseMovie(for: nil, as: purpose) } else { addClipLink(for: nil) }
    }

    /// Whether a slide of this layout draws a picture beside its words at
    /// all, whatever else is on it: a title or closing slide frames none,
    /// only one behind it.
    static func drawsBeside(_ blockID: String, on slide: LampPresentationSlide) -> Bool {
        guard var picture = slide.blocks.first(where: { $0.id == blockID }) else { return true }
        picture.placement = nil
        let probe = LampPresentationSlide(layout: slide.layout, blocks: [picture])
        return !probe.plan.ignored.contains { $0.id == blockID }
    }

    /// Whether `slide` would draw `block` if it were added to it.
    static func drawn(_ block: LampPresentationBlock, on slide: LampPresentationSlide) -> Bool {
        var probe = slide
        probe.blocks.append(block)
        return !probe.plan.ignored.contains { $0.id == block.id }
    }

    /// What `preparingVideos` calls a video on its way to a new block.
    static let newVideoBlock = "new"

    /// The block a prepared video goes to: the one named, as it is now, or a
    /// new picture block. Nil where the named block has gone.
    private static func target(_ blockID: String?, in slide: LampPresentationSlide?) -> LampPresentationBlock? {
        guard let slide else { return nil }
        guard let blockID else { return LampPresentationBlock(kind: .image) }
        return slide.blocks.first { $0.id == blockID }
    }

    /// Puts `block` on the slide at `slideIndex`: in its own place where it
    /// is there, else at the end. One change, so one undo.
    private func place(_ block: LampPresentationBlock, in slideIndex: Int) {
        if let index = deck?.slides[slideIndex].blocks.firstIndex(where: { $0.id == block.id }) {
            deck?.slides[slideIndex].blocks[index] = block
        } else if let slide = deck?.slides[slideIndex] {
            // A new picture goes beside the words where the slide draws one
            // there, and behind the slide where it would not: a title slide
            // frames no picture, and one added to it would never be seen.
            var placed = block
            if !Self.drawsBeside(placed.id, on: LampPresentationSlide(layout: slide.layout, blocks: [placed])) {
                placed.placement = .background
            }
            // Behind a slide that already has a picture there, the video
            // becomes that picture's, keeping how it is cropped, tinted and
            // moved: a second picture behind is never drawn.
            if placed.placement == .background, !Self.drawn(placed, on: slide),
               let index = slide.blocks.firstIndex(where: { $0.isBackground }) {
                var existing = slide.blocks[index]
                existing.assetPath = placed.assetPath
                existing.video = placed.video
                existing.clip = placed.clip
                if existing.altText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    existing.altText = placed.altText
                }
                deck?.slides[slideIndex].blocks[index] = existing
                return
            }
            deck?.slides[slideIndex].blocks.append(placed)
        }
    }

    private func removeBlock(_ blockID: String) {
        guard let slideID = selectedSlide?.id,
              let slideIndex = deck?.slides.firstIndex(where: { $0.id == slideID }) else { return }
        deck?.slides[slideIndex].blocks.removeAll { $0.id == blockID }
    }

    private func updateScriptureCitation(_ citation: String, after scriptureBlockID: String) {
        guard let slideID = selectedSlide?.id,
              let slideIndex = deck?.slides.firstIndex(where: { $0.id == slideID }),
              let scriptureIndex = deck?.slides[slideIndex].blocks.firstIndex(
                where: { $0.id == scriptureBlockID }
              ) else { return }

        if let citationIndex = deck?.slides[slideIndex].blocks.firstIndex(
            where: { $0.kind == .citation }
        ) {
            deck?.slides[slideIndex].blocks[citationIndex].text = citation
        } else {
            deck?.slides[slideIndex].blocks.insert(
                .init(kind: .citation, text: citation),
                at: scriptureIndex + 1
            )
        }
    }

    /// Changes the deck's colours and keeps what the author chose besides
    /// them: the typefaces, and the highlights emphasised words name, each
    /// recoloured from the new theme's palette in the hue it had, so it reads
    /// on the new ground (`LampPresentationTheme.applied(over:)`).
    private func applyTheme(_ themeID: String) {
        guard let current = deck?.theme,
              let chosen = LampPresentationTheme.builtIn.first(where: { $0.id == themeID }) else { return }
        deck?.theme = chosen.applied(over: current)
    }

    private func presentDeck() {
        saveNow()
        guard let deck, LampPresentationDeckValidator.errors(in: deck.withoutEmptyTextBlocks).isEmpty else { return }
        remoteHost.start()
        openWindow(id: "slide-presenter", value: SlidePresentationRequest(deckID: deck.id))
    }

    private func exportDeck() {
        guard let deck else { return }
        let panel = NSSavePanel()
        panel.title = "Export Presentation Deck"
        panel.nameFieldStringValue = "\(sanitizedFilename(deck.title)).lampdeck"
        panel.allowedContentTypes = [.lampPresentationDeck]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try store.encoded(deck.withoutEmptyTextBlocks).write(to: destination, options: [.atomic])
            statusMessage = "Exported \(destination.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes the slides to a PDF, one to a page, with or without the notes.
    ///
    /// Which of the two it is, is chosen in the menu rather than in the save
    /// panel. A panel accessory view is easy to put there and easy not to see,
    /// and this choice decides who the file is for — an audience, or the
    /// speaker at a lectern — so it is named in full where it is picked.
    ///
    /// The save panel is answered before any drawing starts, so the export is
    /// never waiting behind a sheet. Drawing then runs on the main actor —
    /// `ImageRenderer` is main-isolated — yielding between pages so a long deck
    /// does not stop the window answering, which is why the button disables
    /// itself for the duration rather than relying on it being quick.
    private func exportPDF(includesSpeakerNotes includesNotes: Bool) {
        guard let deck else { return }
        let panel = NSSavePanel()
        panel.title = includesNotes ? "Export Slides and Notes as PDF" : "Export Slides as PDF"
        // Two files a person keeps apart — one to hand out, one to read from —
        // so they are not offered the same name by default.
        panel.nameFieldStringValue = includesNotes
            ? "\(sanitizedFilename(deck.title)) (Notes).pdf"
            : "\(sanitizedFilename(deck.title)).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingPDF = true
        Task {
            do {
                try await LampPresentationPDFExport.write(
                    deck: deck,
                    store: store,
                    to: destination,
                    options: .init(includesSpeakerNotes: includesNotes),
                    progress: { page, total in
                        statusMessage = "Exporting slide \(page) of \(total)…"
                    }
                )
                statusMessage = "Exported \(destination.lastPathComponent)"
            } catch {
                errorMessage = error.localizedDescription
            }
            isExportingPDF = false
        }
    }

    private func importDeck() {
        let panel = NSOpenPanel()
        panel.title = "Import Presentation Deck"
        panel.allowedContentTypes = [.lampPresentationDeck]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try store.decode(Data(contentsOf: source))
            try store.save(imported)
            inbox.deckFilesChanged()
            if let index = decks.firstIndex(where: { $0.id == imported.id }) {
                decks[index] = imported
            } else {
                decks.append(imported)
            }
            decks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            applySelection(imported)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sanitizedFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }
}

private extension UTType {
    static let lampPresentationDeck = UTType(
        "com.neus.lamp-bible.presentation-deck"
    ) ?? UTType(filenameExtension: "lampdeck", conformingTo: .json) ?? .json
}

private struct LampSlideBlockEditor: View {
    /// What to type for each line of a figure.
    static func figureHint(_ figure: LampPresentationFigure?) -> String? {
        switch figure {
        case .timeline?: "One event per line: a date, a spaced dash, and what happened — “c. 1000 BC — David king in Jerusalem”."
        case .chiasm?: "One member per line, in order; the first pairs with the last, and an odd line is the centre."
        case .parallel?: "Lines in pairs: each line, then the line that answers it."
        case .map?: "One place per line, as OpenBible.info names it. After a dash, what the map should call it — “Antioch 2 — Pisidian Antioch”."
        default: nil
        }
    }

    /// A clip in a word or two: its file's name, or its site.
    static func clipSummary(_ clip: LampPresentationClip) -> String {
        switch clip.origin {
        case .file(let path): (path as NSString).lastPathComponent
        case .youtube: "YouTube video"
        case .vimeo: "Vimeo video"
        case .unplayable: clip.source
        }
    }

    /// Seconds as minutes:seconds, or empty for none.
    static func clipTime(_ seconds: Double?) -> String {
        // Past a day is no time a clip has; shown as seconds, not converted
        // to a whole number that cannot hold it.
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        guard seconds < 86_400 else { return String(format: "%.0f", seconds) }
        // Rounded to hundredths first, so 59.996 carries to 1:00 rather
        // than showing a hundred hundredths.
        let hundredthsInAll = Int((seconds * 100).rounded())
        let whole = hundredthsInAll / 100
        let hundredths = hundredthsInAll % 100
        let fraction = hundredths == 0 ? "" : hundredths % 10 == 0
            ? ".\(hundredths / 10)" : "." + String(format: "%02d", hundredths)
        return "\(whole / 60):" + String(format: "%02d", whole % 60) + fraction
    }

    /// Minutes:seconds, or seconds alone, as seconds; nil for empty or
    /// anything else.
    static func clipSeconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            total = total * 60 + value
        }
        // Nothing that cannot be saved: a time too large for a number.
        return total.isFinite ? total : nil
    }

    @Binding var block: LampPresentationBlock
    /// Where an image block's picture is, so the inspector can show it.
    var imageURL: URL? = nil
    let updateCitation: (String) -> Void
    let chooseImage: () -> Void
    let chooseVideo: () -> Void
    let chooseClip: () -> Void
    let addClipLink: () -> Void
    var isPreparingVideo = false
    /// Whether this slide draws a picture beside its words; where it does
    /// not, the picture can only go behind the slide.
    var besideWords = true
    /// Whether the slide draws this block at all.
    var isShown = true
    var layoutName = ""
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                // Including this block's own role even when it is one Studio
                // cannot add. A picker whose selection has no matching tag
                // draws blank and can reset the value, which would turn an
                // agent's chart into a title the moment it was looked at.
                // The block's role as its heading, a menu that says what it
                // is: as a bordered pop-up it read as one more form field.
                Menu {
                    Picker("Role", selection: $block.kind) {
                        ForEach(LampPresentationBlockKind.authorableHere(including: block.kind)) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 4) {
                        Text(block.kind.displayName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Role")
                .accessibilityValue(block.kind.displayName)
                .help("What this block is on the slide")
                Spacer()
                Button("Remove Content", systemImage: "minus.circle", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }

            if block.kind == .image {
                // The picture itself, with its file beside it: a design tool
                // shows what is placed, and a path in a form field said only
                // where it was kept.
                HStack(alignment: .top, spacing: 12) {
                    StudioImageThumbnail(url: imageURL)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Asset path", text: Binding(
                            get: { block.assetPath ?? "" },
                            set: { block.assetPath = $0 }
                        ))
                        // The video being prepared sets the picture when done.
                        .disabled(isPreparingVideo)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .labelsHidden()
                        .help(block.assetPath ?? "")
                        Button("Choose Image…", systemImage: "photo", action: chooseImage)
                        .disabled(isPreparingVideo)
                        .buttonStyle(.lampSecondary)
                        .controlSize(.small)
                            .controlSize(.small)
                            .help("Copy an image into this library and use it here")
                        // A video plays only while presenting; the picture
                        // above is its still everywhere else.
                        if isPreparingVideo {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Preparing video…").font(.callout).foregroundStyle(.secondary)
                            }
                        } else if let clip = block.clip {
                            HStack(spacing: 6) {
                                Label(Self.clipSummary(clip), systemImage: clip.isStreamed ? "play.tv" : "play.rectangle")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                    .help(clip.isStreamed
                                        ? "Plays in the site's own player while presenting, which needs an internet connection"
                                        : "Plays with its sound while presenting; the picture is its still")
                                Button("Remove Clip", systemImage: "xmark.circle") { block.clip = nil }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("Show the picture alone")
                            }
                        } else if let video = block.video {
                            HStack(spacing: 6) {
                                Label((video as NSString).lastPathComponent, systemImage: "film")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                    .help("Plays silently, looping, while the slide is presented; the picture is its still")
                                Button("Remove Video", systemImage: "xmark.circle") { block.video = nil }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("Show the picture alone")
                            }
                        } else {
                            Menu {
                                Button("Looping Video…", systemImage: "film", action: chooseVideo)
                                    .help("A short video that plays silently in the picture's place while presenting")
                                Button("Clip with Sound…", systemImage: "play.rectangle", action: chooseClip)
                                    .help("A video the talk stops to watch, played once with its sound")
                                Button("YouTube or Vimeo…", systemImage: "play.tv", action: addClipLink)
                                    .help("A clip played from the site, which needs an internet connection while presenting")
                            } label: {
                                Label("Add Video", systemImage: "film")
                            }
                            .lampMenu()
                            .controlSize(.small)
                            .fixedSize()
                            .help("Make the picture move: a looping video, a clip with sound, or one from YouTube or Vimeo")
                        }
                    }
                }
                StudioStackedField("Description") {
                    TextField("Accessibility description", text: Binding(
                        get: { block.altText ?? "" },
                        set: { block.altText = $0 }
                    ), axis: .vertical)
                    .lineLimit(2...3)
                    .labelsHidden()
                }
                // Two pictures of where it goes, in the text's own colour:
                // the choice is read more than it is changed, and a filled
                // red segment was one more red mark in the window.
                StudioStackedField("Placement") {
                    VStack(alignment: .leading, spacing: 4) {
                        // Only the places this slide draws a picture: a title
                        // slide frames none beside its words.
                        StudioChoiceTiles(
                            selection: $block.placement,
                            choices: (besideWords
                                ? [.init(value: nil, title: "Beside the text", systemImage: "rectangle.split.2x1")]
                                : [])
                                + [.init(
                                    value: .background,
                                    title: "Behind the slide",
                                    systemImage: "rectangle.inset.filled"
                                )]
                        )
                        if !isShown {
                            Text(!besideWords && block.placement != .background
                                ? "A \(layoutName) slide shows a picture only behind it, so this one is not shown yet."
                                : "This slide already shows another picture there, so this one is not shown.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .help("Behind the slide, Lamp chooses the colour of the words and covers the picture only as far as they need")
                // Drawn in the deck's colours, so pictures from different
                // places look as if they belong to one deck.
                StudioStackedField("Tint") {
                    LampSegmentedPicker(
                        "Tint",
                        selection: Binding(
                            get: { block.tint == LampPresentationImageTint.none ? nil : block.tint },
                            set: { block.tint = $0 }
                        ),
                        items: [.init(id: nil, title: "None")]
                            + [LampPresentationImageTint.duotone, .muted].map { .init(id: Optional($0), title: $0.displayName) }
                    )
                    .controlSize(.small)
                }
                .help("Duotone draws the picture in the theme’s accent and ground; Muted quiets it toward the ground")
                // Off unless asked for, and only while presenting: Studio
                // and thumbnails keep the picture still.
                StudioStackedField("Motion") {
                    LampSegmentedPicker(
                        "Motion",
                        selection: Binding(
                            get: { block.motion == LampPresentationImageMotion.none ? nil : block.motion },
                            set: { block.motion = $0 }
                        ),
                        items: [.init(id: nil, title: LampPresentationImageMotion.none.displayName)]
                            + [.init(id: Optional(LampPresentationImageMotion.drift), title: LampPresentationImageMotion.drift.displayName)]
                    )
                    .controlSize(.small)
                }
                .help("While presenting, Drift closes in on the picture by 3% over a minute and back, too slowly to see it move")
                if block.clip != nil {
                    StudioStackedField("Clip") {
                        VStack(alignment: .leading, spacing: 6) {
                            LampSegmentedPicker(
                                "Starts",
                                selection: Binding(
                                    get: { block.clip?.starts ?? .click },
                                    set: { block.clip?.starts = $0 == .click ? nil : $0 }
                                ),
                                items: LampPresentationClip.Starting.allCases.map { .init(id: $0, title: $0.displayName) }
                            )
                            .controlSize(.small)
                            HStack(spacing: 8) {
                                StudioClipTimeField(title: "Start", seconds: Binding(
                                    get: { block.clip?.start },
                                    set: { block.clip?.start = $0 }
                                ))
                                .frame(width: 70)
                                Text("to").foregroundStyle(.secondary)
                                StudioClipTimeField(title: "End", seconds: Binding(
                                    get: { block.clip?.end },
                                    set: { block.clip?.end = $0 }
                                ))
                                .frame(width: 70)
                            }
                            .font(.callout)
                            .textFieldStyle(.roundedBorder)
                            .help("Where the clip starts and stops, as minutes:seconds; empty is its beginning or its end")
                        }
                    }
                }
                // Only a picture behind the slide is cropped, so only it has
                // a focus to set.
                if block.placement == .background {
                    StudioStackedField("Focus") {
                        StudioFocusPicker(url: imageURL, focus: $block.focus)
                    }
                }
            } else {
                if block.kind == .body {
                    LampSegmentedPicker(
                        "Body format",
                        selection: $block.listStyle,
                        items: [.init(id: nil, title: "Text")]
                            + LampPresentationListStyle.allCases.map { .init(id: Optional($0), title: $0.displayName) }
                    )
                    .controlSize(.small)

                    if block.listStyle != nil {
                        Text("Enter one list item per line.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // The lines drawn as a timeline or a passage's structure;
                    // anything that does not know the figure shows the list.
                    StudioStackedField("Figure") {
                        LampSegmentedPicker(
                            "Figure",
                            selection: Binding(
                                get: { block.figure == LampPresentationFigure.none ? nil : block.figure },
                                set: { figure in
                                    block.figure = figure
                                    // Only a timeline zooms, and only a map
                                    // takes a route.
                                    if figure != .timeline { block.zoom = nil }
                                    if figure != .map { block.map = nil }
                                }
                            ),
                            items: [.init(id: nil, title: "None")]
                                + [LampPresentationFigure.timeline, .chiasm, .parallel, .map]
                                    .map { .init(id: Optional($0), title: $0.displayName) }
                        )
                        .controlSize(.small)
                    }
                    if let hint = Self.figureHint(block.figure) {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if block.figure == .timeline {
                        StudioTimelineZoomControls(block: $block)
                    }
                    if block.figure == .map {
                        StudioMapControls(block: $block)
                    }
                }

                if block.kind == .scripture {
                    LampSlideScripturePicker(
                        block: $block,
                        updateCitation: updateCitation
                    )
                }

                if block.kind == .chart {
                    LampSlideChartEditor(block: $block)
                    Text("An optional heading, drawn over the bars.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $block.text)
                    .font(.body)
                    .frame(minHeight: block.kind == .body ? 90 : 52)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.12))
                    }
            }
        }
        .onChange(of: block.kind) { _, kind in
            if kind != .body {
                block.listStyle = nil
            }
            if kind != .scripture {
                block.scriptureReference = nil
            }
            if kind != .image {
                block.placement = nil
            }
        }
    }
}

/// Builds a chart block: what to count, where, and how to group it.
///
/// The values themselves are never typed. They are worked out from the
/// library whenever the source changes, which is the same rule the build
/// command and the deck import follow — a chart is a question about the
/// library, and only the library can answer it.
private struct LampSlideChartEditor: View {
    @Binding var block: LampPresentationBlock
    @EnvironmentObject private var model: LibraryModel
    @State private var status: String?
    @State private var isWorking = false

    /// What a refill depends on.
    ///
    /// The values are deliberately not part of this: writing them back would
    /// change the chart, which would ask for them again, for ever.
    private struct Source: Equatable {
        var source = LampPresentationChart.Source(strongs: "", translationID: "")
        var by = LampPresentationChart.Grouping.book
        var feature: LampGrammarFeature?
        var measure = LampPresentationChart.Measure.occurrences
        /// Part of the key, because the values themselves depend on it: a
        /// grid carries each book's chapters, a share drops the empty
        /// divisions, and columns keep them.
        var style = LampPresentationChart.Style.bars
    }

    private var source: Source {
        guard let chart = block.chart else { return Source() }
        return Source(
            source: chart.source,
            by: chart.by,
            feature: chart.feature,
            measure: chart.measure,
            style: chart.drawnStyle
        )
    }

    var body: some View {
        if let chart = Binding($block.chart) {
            let current = chart.wrappedValue
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    TextField("Strong's key", text: chart.source.strongs)
                        .frame(width: 110)
                        .help("A key such as G26 or H3068")
                    if current.by == .translation {
                        comparedTranslations(chart)
                    } else {
                        // Through the map, so a chart written when the
                        // translation was called "ESVs" shows ESV selected
                        // rather than an empty picker. Only the reading is
                        // resolved; picking writes the id of the module
                        // picked, as everywhere else.
                        Picker("Translation", selection: Binding(
                            get: {
                                LampTranslationID.held(
                                    chart.wrappedValue.source.translationID,
                                    among: model.installedTranslationIDs
                                ) ?? chart.wrappedValue.source.translationID
                            },
                            set: { chart.wrappedValue.source.translationID = $0 }
                        )) {
                            // Every translation, not only the tagged ones: Lamp
                            // says below when one has no tags for this key, which
                            // is a more useful answer than a shorter menu.
                            TranslationPickerOptions(
                                translations: model.translations,
                                title: { $0.abbreviation ?? $0.name },
                                tag: \.id
                            )
                        }
                        .labelsHidden()
                    }
                    TextField("Books", text: Binding(
                        get: { chart.wrappedValue.source.range ?? "" },
                        set: { chart.wrappedValue.source.range = $0.isEmpty ? nil : $0 }
                    ))
                    .help("Whole books: NT, Romans, Matthew-John. Empty means the whole translation.")
                }
                // One per row. Side by side, the inspector is too narrow for
                // two labelled pickers and the measure drew as "Occurr…".
                Picker("Draw as", selection: Binding(
                    get: { chart.wrappedValue.drawnStyle },
                    set: { style in
                        chart.wrappedValue.style = style
                        // A grid and a card are of books, so choosing one
                        // moves the grouping with it. Disabling the control
                        // alone would leave a deck that fails to validate
                        // behind a picker nobody can reach.
                        if style.isOfBooks { chart.wrappedValue.by = .book }
                        if style == .share, !chart.wrappedValue.by.isPartOfWhole {
                            chart.wrappedValue.by = .rendering
                        }
                    }
                )) {
                    ForEach(LampPresentationChart.Style.allCases) { style in
                        Text(studioStyleName(style)).tag(style)
                    }
                }
                Picker("Group by", selection: Binding(
                    get: { chart.wrappedValue.by },
                    set: { grouping in
                        chart.wrappedValue.by = grouping
                        // A feature only means something to a chart of
                        // grammar, and the validator says so of a stray one.
                        if grouping == .grammar {
                            chart.wrappedValue.feature = chart.wrappedValue.feature ?? .grammaticalCase
                        } else {
                            chart.wrappedValue.feature = nil
                        }
                        if grouping != .translation { chart.wrappedValue.source.translations = nil }
                        if !grouping.isPartOfWhole, chart.wrappedValue.drawnStyle == .share {
                            chart.wrappedValue.style = .bars
                        }
                    }
                )) {
                    ForEach(LampPresentationChart.Grouping.allCases) { grouping in
                        Text(studioGroupingName(grouping)).tag(grouping)
                    }
                }
                .disabled(current.drawnStyle.isOfBooks)
                .help(current.drawnStyle.isOfBooks
                    ? "A \(current.drawnStyle == .grid ? "grid" : "card") draws each book, so it charts by book"
                    : "")
                if current.by == .grammar {
                    Picker("Feature", selection: Binding(
                        get: { chart.wrappedValue.feature ?? .grammaticalCase },
                        set: { chart.wrappedValue.feature = $0 }
                    )) {
                        ForEach(LampGrammarFeature.allCases, id: \.self) { feature in
                            Text(feature.title).tag(feature)
                        }
                    }
                }
                Picker("Measure", selection: chart.measure) {
                    Text("Occurrences").tag(LampPresentationChart.Measure.occurrences)
                    Text("Per 1,000 words").tag(LampPresentationChart.Measure.perThousandWords)
                }
                .disabled(current.drawnStyle == .share || !current.by.usesMeasure)
                .help(current.drawnStyle == .share
                    ? "A share is of occurrences: rates do not add up to a whole"
                    : current.by.usesMeasure ? "" : "Companions are measured against chance")
                filterFields(chart)
                HStack(spacing: 6) {
                    if isWorking { ProgressView().controlSize(.small) }
                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .task(id: source) { await fill() }
        } else {
            // A chart block that arrived with no chart in it. Invalid, and the
            // validator says so, but it is repairable here rather than only in
            // a text editor.
            Button("Add Chart Details") {
                block.chart = LampPresentationChart(
                    source: .init(strongs: "", translationID: defaultTranslationID),
                    by: .book
                )
            }
            .buttonStyle(.lampSecondary)
            .controlSize(.small)
        }
    }

    /// Only some occurrences: a rendering, a form, a grammatical value. Each
    /// field narrows further, as the deck's filter does.
    private func filterFields(_ chart: Binding<LampPresentationChart>) -> some View {
        func field(_ path: WritableKeyPath<LampPresentationChart.Filter, String?>) -> Binding<String> {
            Binding(
                get: { chart.wrappedValue.source.filter?[keyPath: path] ?? "" },
                set: { text in
                    var filter = chart.wrappedValue.source.filter ?? .init()
                    filter[keyPath: path] = text.isEmpty ? nil : text
                    chart.wrappedValue.source.filter = filter.isEmpty && filter.grammar == nil ? nil : filter
                }
            )
        }
        let grammar = Binding<LampGrammarFeature?>(
            get: { chart.wrappedValue.source.filter?.grammar?.feature },
            set: { feature in
                var filter = chart.wrappedValue.source.filter ?? .init()
                filter.grammar = feature.map { .init(feature: $0, value: filter.grammar?.value ?? "") }
                chart.wrappedValue.source.filter =
                    filter.rendering == nil && filter.form == nil && filter.grammar == nil ? nil : filter
            }
        )
        return VStack(alignment: .leading, spacing: 5) {
            Text("Only occurrences")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Translated as", text: field(\.rendering))
                    .help("An English translation of the word, as Translated As lists it: love")
                TextField("Form", text: field(\.form))
                    .help("An original-language form, as Forms lists it: ἀγάπης")
            }
            HStack(spacing: 6) {
                Picker("Grammar", selection: grammar) {
                    Text("Any grammar").tag(LampGrammarFeature?.none)
                    ForEach(LampGrammarFeature.allCases, id: \.self) { feature in
                        Text(feature.title).tag(LampGrammarFeature?.some(feature))
                    }
                }
                .labelsHidden()
                if grammar.wrappedValue != nil {
                    TextField("Value", text: Binding(
                        get: { chart.wrappedValue.source.filter?.grammar?.value ?? "" },
                        set: { chart.wrappedValue.source.filter?.grammar?.value = $0 }
                    ))
                    .help("As Grammar lists it: Genitive, Aorist")
                }
            }
        }
    }

    /// The translations a comparison counts: every tagged one, or those ticked.
    private func comparedTranslations(_ chart: Binding<LampPresentationChart>) -> some View {
        let chosen = chart.wrappedValue.source.translations
        return Menu(chosen.map { $0.count == 1 ? "1 translation" : "\($0.count) translations" }
            ?? "Every tagged translation") {
            Button("Every Tagged Translation") { chart.wrappedValue.source.translations = nil }
            // Only where the chart compares them all. A named list is drawn
            // as named — ticking the Greek text below is how it is asked for
            // there — so the option would be a toggle that did nothing.
            if chart.wrappedValue.source.translations == nil {
                Toggle("Include the Hebrew and Greek Texts", isOn: Binding(
                    get: { chart.wrappedValue.source.includesOriginalLanguages },
                    set: { chart.wrappedValue.source.includesOriginalLanguages = $0 }
                ))
                .tint(Color.lampAccentMuted)
            }
            Divider()
            // Only those tagged with Strong's: no other can be compared.
            let tagged = model.translations.filter(\.tagsStrongs)
            let groups = TranslationGroups.of(tagged)
            ForEach(groups) { group in
                Section(groups.count > 1 ? group.title : "") {
                    TranslationGroups.parts(of: group) { items in
                        compareToggles(items, chart: chart, chosen: chosen)
                    }
                }
            }
        }
        .fixedSize()
        .help("The translations to set side by side")
    }

    private func compareToggles(
        _ translations: [LampInstalledModule],
        chart: Binding<LampPresentationChart>,
        chosen: [String]?
    ) -> some View {
        let installedIDs = model.installedTranslationIDs
        return ForEach(translations, id: \.id) { translation in
                Toggle(translation.abbreviation ?? translation.name, isOn: Binding(
                    // The deck's list is as it was written, so a chart
                    // naming "ESVs" ticks the installed ESV — but by
                    // resolving each stored id to the module it names, not by
                    // calling the two the same translation. With both
                    // spellings installed they are two modules: matching by
                    // translation ticked both and unticking one removed the
                    // other's entry.
                    get: {
                        chosen?.contains {
                            LampTranslationID.held($0, among: installedIDs) == translation.id
                        } == true
                    },
                    set: { isOn in
                        var list = chart.wrappedValue.source.translations ?? []
                        // Whatever spelling names THIS module, so unticking
                        // a deck's older "ESVs" really removes it, while an
                        // independently installed "ESV" keeps its own entry.
                        list.removeAll {
                            LampTranslationID.held($0, among: installedIDs) == translation.id
                        }
                        if isOn { list.append(translation.id) }
                        chart.wrappedValue.source.translations = list.isEmpty ? nil : list
                    }
                ))
                .tint(Color.lampAccentMuted)
            }
    }

    private func studioGroupingName(_ grouping: LampPresentationChart.Grouping) -> String {
        switch grouping {
        case .book: "Book"
        case .section: "Section"
        case .rendering: "Translated As"
        case .form: "Form"
        case .grammar: "Grammar"
        case .translation: "Translation (compare)"
        case .companion: "Companion words"
        }
    }

    /// What this style draws, for counting them in the status line. A grid
    /// draws a row per book, not a bar.
    private func drawnThings(_ style: LampPresentationChart.Style) -> String {
        switch style {
        case .bars: "bars"
        case .columns: "columns"
        case .grid, .card: "books"
        case .share: "slices"
        }
    }

    /// Too much to read, in the terms that style is read in.
    ///
    /// Each style has its own limit and they are not interchangeable: 27
    /// columns are exactly what columns are for, while 27 bars are a wall.
    /// The same split is in `LampPresentationDeckValidator` and in the
    /// skill's `validate_deck.py`, so all three say one thing.
    private func crowding(_ count: Int, style: LampPresentationChart.Style) -> String? {
        switch style {
        case .bars where count > LampPresentationChart.readableBars:
            "\(count) bars — hard to read from the back of a room; try grouping by section."
        case .grid where count > LampPresentationChart.readableGridRows:
            "A grid of \(count) books is too dense to read. Narrow the range."
        case .share where count > LampPresentationChart.shareSlices:
            "\(count) slices cannot be told apart; the smallest are gathered."
        default:
            nil
        }
    }

    /// Named for what the chart shows rather than by its raw value, which
    /// is the deck format's word and not a reader's.
    private func studioStyleName(_ style: LampPresentationChart.Style) -> String {
        switch style {
        case .bars: "Bars"
        case .columns: "Columns in Bible order"
        case .grid: "Chapter grid"
        case .share: "Share of the whole"
        case .card: "Headword card"
        }
    }

    private var defaultTranslationID: String {
        model.selectedTranslationID ?? model.translations.first?.id ?? ""
    }

    /// A translation as a reader knows it, not by its id ("BSB", not "BSBs").
    ///
    /// A deck carries the ID as it was written, and a deck written before
    /// the rename names "ESVs". Resolved, so that an older deck still shows
    /// the name of the translation it meant; falling through to the raw ID
    /// is what this helper exists to avoid.
    private func translationName(_ id: String) -> String {
        // Every installed translation, hidden ones included: hiding one does
        // not stop a deck naming it, and resolving against the visible list
        // would hand the name of a different module.
        let held = LampTranslationID.held(id, among: model.installedTranslationIDs) ?? id
        return model.modules.first { $0.id == held }.map { $0.abbreviation ?? $0.name } ?? id
    }

    private func fill() async {
        guard var chart = block.chart,
              !chart.source.strongs.trimmingCharacters(in: .whitespaces).isEmpty,
              chart.by == .translation || !chart.source.translationID.isEmpty
        else {
            status = "Name a key and a translation to draw."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let worked = try await model.library.workedOut(chart) else {
                status = chart.by == .translation
                    ? "No translation here tags \(chart.source.strongs), so the chart draws empty."
                    : "\(translationName(chart.source.translationID)) has no tags for "
                        + "\(chart.source.strongs) here, so the chart draws empty."
                return
            }
            let values = worked.values ?? []
            // Only when they differ, so opening a slide does not mark its deck
            // changed and send it round the sync for nothing.
            if chart.values != worked.values || chart.headword != worked.headword
                || chart.sources != worked.sources {
                chart.values = worked.values
                chart.headword = worked.headword
                chart.sources = worked.sources
                block.chart = chart
            }
            if values.isEmpty {
                status = "Nothing to chart in this range."
            } else {
                status = crowding(values.count, style: chart.drawnStyle)
                    ?? "\(values.count) \(drawnThings(chart.drawnStyle)) from "
                        + (chart.by == .translation ? "the translations." : "\(translationName(chart.source.translationID)).")
            }
        } catch {
            // An unreadable range arrives here, which is the one mistake easy
            // to make in the books field.
            status = error.localizedDescription
        }
    }
}

private struct LampSlideScripturePicker: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var block: LampPresentationBlock
    let updateCitation: (String) -> Void

    @State private var translationID: String
    @State private var books: [LampTranslationBook] = []
    @State private var bookNumber: Int
    @State private var chapterNumber: Int
    @State private var verses: [LampVerse] = []
    @State private var startVerse: Int
    @State private var endVerse: Int
    @State private var isExpanded: Bool
    @State private var isLoadingBooks = false
    @State private var isLoadingChapter = false
    @State private var errorMessage: String?

    init(
        block: Binding<LampPresentationBlock>,
        updateCitation: @escaping (String) -> Void
    ) {
        _block = block
        self.updateCitation = updateCitation
        let reference = block.wrappedValue.scriptureReference
        _translationID = State(initialValue: reference?.translationID ?? "")
        _bookNumber = State(initialValue: reference?.bookNumber ?? 0)
        _chapterNumber = State(initialValue: reference?.chapterNumber ?? 1)
        _startVerse = State(initialValue: reference?.startVerse ?? 1)
        _endVerse = State(initialValue: reference?.endVerse ?? reference?.startVerse ?? 1)
        // Open only for a block that has nothing in it yet. A passage already
        // on the slide shows as its text; the five pickers that chose it fold
        // away until they are wanted again.
        _isExpanded = State(
            initialValue: reference == nil
                && block.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Translation", selection: $translationID) {
                    TranslationPickerOptions(
                        translations: model.translations,
                        title: { $0.abbreviation ?? $0.name },
                        tag: \.id
                    )
                }

                Picker("Book", selection: $bookNumber) {
                    if books.isEmpty {
                        Text(isLoadingBooks ? "Loading…" : "No books available").tag(0)
                    }
                    ForEach(books) { book in
                        Text(book.name).tag(book.id)
                    }
                }
                .disabled(books.isEmpty)

                Picker("Chapter", selection: $chapterNumber) {
                    if let selectedBook {
                        ForEach(1...selectedBook.chapterCount, id: \.self) { chapter in
                            Text(chapter.formatted()).tag(chapter)
                        }
                    } else {
                        Text("—").tag(1)
                    }
                }
                .disabled(selectedBook == nil)

                HStack(spacing: 8) {
                    Picker("Start", selection: $startVerse) {
                        ForEach(verses) { verse in
                            Text(verse.number.formatted()).tag(verse.number)
                        }
                    }
                    Picker("End", selection: $endVerse) {
                        ForEach(verses.filter { $0.number >= startVerse }) { verse in
                            Text(verse.number.formatted()).tag(verse.number)
                        }
                    }
                }
                .disabled(isLoadingChapter || verses.isEmpty)

                if isLoadingBooks || isLoadingChapter {
                    ProgressView("Loading scripture…")
                        .controlSize(.small)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(
                    block.scriptureReference == nil ? "Insert Passage" : "Update Passage",
                    systemImage: "quote.opening"
                ) {
                    applyPassage()
                }
                // Bordered, not filled: Play is the window's one filled
                // button, and this one beside the selected slide and the
                // placement control made four red marks competing.
                .buttonStyle(.lampSecondary)
                .controlSize(.small)
                .disabled(selectedVerses.isEmpty)
            }
            .padding(.top, 8)
        } label: {
            Label("Choose Scripture", systemImage: "quote.opening")
                .font(.callout.weight(.medium))
        }
        .disclosureGroupStyle(LampDisclosureStyle())
        .onAppear { chooseDefaultTranslationIfNeeded() }
        .onChange(of: model.translations.map(\.id)) { _, _ in
            chooseDefaultTranslationIfNeeded()
        }
        .onChange(of: translationID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            books = []
            verses = []
            bookNumber = 0
            chapterNumber = 1
            startVerse = 1
            endVerse = 1
        }
        .onChange(of: bookNumber) { oldValue, newValue in
            guard oldValue != newValue else { return }
            chapterNumber = 1
            startVerse = 1
            endVerse = 1
            verses = []
        }
        .onChange(of: chapterNumber) { oldValue, newValue in
            guard oldValue != newValue else { return }
            startVerse = 1
            endVerse = 1
            verses = []
        }
        .onChange(of: startVerse) { _, newValue in
            if endVerse < newValue { endVerse = newValue }
        }
        .task(id: translationID) { await loadBooks() }
        .task(id: chapterLoadID) { await loadChapter() }
    }

    private var selectedBook: LampTranslationBook? {
        books.first { $0.id == bookNumber }
    }

    private var selectedVerses: [LampVerse] {
        verses.filter { $0.number >= startVerse && $0.number <= endVerse }
    }

    private var chapterLoadID: String {
        "\(translationID):\(bookNumber):\(chapterNumber):\(books.count)"
    }

    private func chooseDefaultTranslationIfNeeded() {
        // A slide names its translation as it was written, so resolve before
        // judging it missing. Judged exactly, a block saved in "ESVs" was
        // replaced by whatever the reader happened to be in, and the
        // translation-changed handler then reset the book, chapter and verses
        // — so applying the picker could overwrite the quotation.
        if !translationID.isEmpty,
           let held = LampTranslationID.held(translationID, among: model.installedTranslationIDs) {
            if held != translationID { translationID = held }
            return
        }
        translationID = model.selectedTranslationID ?? model.translations.first?.id ?? ""
    }

    @MainActor
    private func loadBooks() async {
        guard !translationID.isEmpty else {
            books = []
            return
        }
        let requestedTranslationID = translationID
        isLoadingBooks = true
        errorMessage = nil
        do {
            let loaded = try await model.library.translationBooks(moduleID: requestedTranslationID)
            guard translationID == requestedTranslationID else { return }
            books = loaded
            if !loaded.contains(where: { $0.id == bookNumber }) {
                bookNumber = loaded.first?.id ?? 0
            }
            if let selectedBook {
                chapterNumber = min(max(chapterNumber, 1), selectedBook.chapterCount)
            }
        } catch {
            guard translationID == requestedTranslationID else { return }
            books = []
            errorMessage = error.localizedDescription
        }
        if translationID == requestedTranslationID { isLoadingBooks = false }
    }

    @MainActor
    private func loadChapter() async {
        guard !translationID.isEmpty, bookNumber > 0, selectedBook != nil else {
            verses = []
            return
        }
        let requestedLoadID = chapterLoadID
        isLoadingChapter = true
        errorMessage = nil
        do {
            let loaded = try await model.library.chapter(
                moduleID: translationID,
                bookNumber: bookNumber,
                chapterNumber: chapterNumber
            )
            guard chapterLoadID == requestedLoadID else { return }
            verses = loaded.verses
            let verseNumbers = Set(loaded.verses.map(\.number))
            if !verseNumbers.contains(startVerse) {
                startVerse = loaded.verses.first?.number ?? 1
            }
            if !verseNumbers.contains(endVerse) || endVerse < startVerse {
                endVerse = startVerse
            }
        } catch {
            guard chapterLoadID == requestedLoadID else { return }
            verses = []
            errorMessage = error.localizedDescription
        }
        if chapterLoadID == requestedLoadID { isLoadingChapter = false }
    }

    private func applyPassage() {
        guard let selectedBook, !selectedVerses.isEmpty else { return }
        let reference = LampPresentationScriptureReference(
            translationID: translationID,
            bookNumber: bookNumber,
            chapterNumber: chapterNumber,
            startVerse: startVerse,
            endVerse: endVerse
        )
        // A slide's scripture reference names its translation as it was
        // written, so an older deck's "ESVs" is resolved to what is held.
        let heldID = LampTranslationID.held(translationID, among: model.installedTranslationIDs)
            ?? translationID
        let translation = model.translations.first { $0.id == heldID }
        let translationName = translation?.abbreviation ?? translation?.name ?? translationID
        let verseRange = startVerse == endVerse
            ? startVerse.formatted()
            : "\(startVerse.formatted())–\(endVerse.formatted())"

        block.scriptureReference = reference
        block.text = selectedVerses.map(\.text).joined(separator: " ")
        updateCitation("\(selectedBook.name) \(chapterNumber):\(verseRange) (\(translationName))")
    }
}

/// Every font family on this Mac, listed once for the app and off the main
/// thread: the first ask costs tens of milliseconds, for a menu few open.
private enum PresentationTypefaces {
    static let families: [String] = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

/// One section of Slide Studio's inspector: a heading, then its controls,
/// flat on the inspector's ground. Sections are parted by hairlines rather
/// than each boxed: cards inside a column of cards read as fragments.
private struct StudioInspectorSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .lampSectionHeading()
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A labelled row whose label sits in a column shared by every row, so the
/// controls line up down the inspector as a form's do.
private struct StudioInspectorRow<Content: View>: View {
    static var labelWidth: CGFloat { 66 }
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(Color.lampSecondaryText)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .accessibilityHidden(label.isEmpty)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A label over its field, for the inspector's longer entries, where a label
/// column beside them took width the text needed.
private struct StudioStackedField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.callout)
                .foregroundStyle(Color.lampSecondaryText)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The picture an image block places, small, from the library's copy.
///
/// Read once per file as a thumbnail, off the main thread: the pictures
/// behind slides are paintings at full resolution, and decoding one whole on
/// every redraw of the inspector would stall typing beside it.
private struct StudioImageThumbnail: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous)
            .fill(Color.lampTileFill)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(Color.lampSecondaryText)
                }
            }
            .frame(width: 84, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous)
                    .strokeBorder(Color.lampCardStroke)
            }
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                image = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 240,
                    ]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }.value
            }
    }
}

/// A small set of choices drawn as tiles with a picture each, the chosen one
/// outlined. In the text's colour rather than the accent: the window keeps
/// red for Play and the selected slide.
private struct StudioChoiceTiles<Value: Hashable>: View {
    struct Choice: Identifiable {
        let value: Value
        let title: String
        let systemImage: String
        var id: String { title }
    }

    @Binding var selection: Value
    let choices: [Choice]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(choices) { choice in
                let isChosen = choice.value == selection
                Button {
                    selection = choice.value
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: choice.systemImage)
                            .font(.system(size: 15, weight: .regular))
                        Text(choice.title)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.lampSecondaryText))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        isChosen ? Color.lampTileFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous)
                            .strokeBorder(
                                isChosen ? Color.primary.opacity(0.55) : Color.lampCardStroke,
                                lineWidth: isChosen ? 1.5 : 1
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
    }
}

/// The slide layouts as small drawings of the slide each makes — a title
/// bar, lines of body, a picture, two columns — chosen by look, as Keynote
/// shows its layouts. The chosen one is outlined in the text colour; the
/// window keeps its accent for Play and the selected slide.
private struct StudioLayoutPicker: View {
    @Binding var selection: LampPresentationSlideLayout

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
        count: 4
    )

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(LampPresentationSlideLayout.allCases) { layout in
                let isChosen = layout == selection
                Button {
                    selection = layout
                } label: {
                    VStack(spacing: 4) {
                        LayoutSketch(layout: layout)
                            .padding(6)
                            .aspectRatio(16 / 10, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(
                                Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(
                                        isChosen ? Color.primary.opacity(0.7) : Color.lampCardStroke,
                                        lineWidth: isChosen ? 2 : 1
                                    )
                            }
                        Text(layout.displayName)
                            .font(.system(size: 10.5, weight: isChosen ? .semibold : .regular))
                            .foregroundStyle(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.lampSecondaryText))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layout.displayName)
                .accessibilityLabel(layout.displayName)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout")
    }
}

/// A schematic of one layout, in the text colour at low strength.
private struct LayoutSketch: View {
    let layout: LampPresentationSlideLayout

    private var ink: Color { Color.primary.opacity(0.45) }
    private var faint: Color { Color.primary.opacity(0.22) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            switch layout {
            case .title:
                VStack(spacing: height * 0.1) {
                    bar(width * 0.7, height * 0.16, ink)
                    bar(width * 0.4, height * 0.08, faint)
                }
                .frame(width: width, height: height)
            case .titleAndBody:
                VStack(alignment: .leading, spacing: height * 0.09) {
                    bar(width * 0.6, height * 0.13, ink)
                    lines(width, height, count: 3)
                }
                .frame(width: width, height: height, alignment: .topLeading)
            case .scripture:
                VStack(spacing: height * 0.09) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: height * 0.24, weight: .bold))
                        .foregroundStyle(ink)
                    lines(width, height, count: 2, centred: true)
                }
                .frame(width: width, height: height)
            case .quotation:
                HStack(spacing: width * 0.06) {
                    Rectangle().fill(ink).frame(width: max(1.5, width * 0.03))
                    lines(width * 0.8, height, count: 3)
                }
                .frame(width: width, height: height * 0.6)
                .frame(width: width, height: height)
            case .twoColumn:
                VStack(alignment: .leading, spacing: height * 0.1) {
                    bar(width * 0.5, height * 0.12, ink)
                    HStack(alignment: .top, spacing: width * 0.08) {
                        lines(width * 0.46, height, count: 3)
                        lines(width * 0.46, height, count: 3)
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            case .image:
                HStack(spacing: width * 0.07) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(faint)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: height * 0.28))
                                .foregroundStyle(ink)
                        }
                        .frame(width: width * 0.52)
                    lines(width * 0.4, height, count: 3)
                }
                .frame(width: width, height: height)
            case .closing:
                VStack(spacing: height * 0.12) {
                    bar(width * 0.45, height * 0.14, ink)
                    bar(width * 0.25, height * 0.06, faint)
                }
                .frame(width: width, height: height)
            case .blank:
                Color.clear
            }
        }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(color)
            .frame(width: width, height: max(1.5, height))
    }

    private func lines(_ width: CGFloat, _ height: CGFloat, count: Int, centred: Bool = false) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: height * 0.08) {
            ForEach(0..<count, id: \.self) { index in
                bar(index == count - 1 ? width * 0.62 : width, height * 0.07, faint)
            }
        }
    }
}

/// A map's places as Lamp finds them, each line marked found, unsure, or not
/// found, so a name that will not draw is caught here and not in front of a
/// room; and whether the places are joined as a route.
private struct StudioMapControls: View {
    @Binding var block: LampPresentationBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Join the places as a route", isOn: Binding(
                get: { block.map?.route == true },
                set: { block.map = $0 ? LampPresentationMapOptions(route: true) : nil }
            ))
            .tint(Color.lampAccentMuted)
            .help("A line from each place to the next, in the order written, as for a journey")
            ForEach(Array(block.mapStops.enumerated()), id: \.offset) { _, stop in
                Label {
                    Text(Self.describe(stop))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Self.symbol(stop))
                        .foregroundStyle(stop.place.map { $0.isUncertain ? Color.lampSecondaryText : Color.lampAccentMuted } ?? .orange)
                }
                .font(.caption)
                .foregroundStyle(Color.lampSecondaryText)
            }
            Text("Places from OpenBible.info, land from Natural Earth; both are credited on the map. Coastlines are today's.")
                .font(.caption2)
                .foregroundStyle(Color.lampSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func symbol(_ stop: LampMapStop) -> String {
        switch stop.match {
        case .place(let place): place.isUncertain ? "questionmark.circle" : "mappin.circle.fill"
        case .ambiguous, .unknown: "exclamationmark.triangle.fill"
        }
    }

    private static func describe(_ stop: LampMapStop) -> String {
        switch stop.match {
        case .place(let place):
            let named = stop.label == place.name ? place.name : "\(stop.label) (\(place.name))"
            return place.isUncertain
                ? "\(named): an uncertain site, \(place.confidence / 10)% sure; drawn as an open ring"
                : "\(named), \(place.firstVerse)"
        case .ambiguous(let places):
            let named = places.prefix(4).map { "\($0.name) (\($0.firstVerse))" }.joined(separator: ", ")
            return "\(stop.name) could be \(named); write one of these"
        case .unknown:
            return "\(stop.name) is not a place Lamp knows, so it is left off"
        }
    }
}

/// A timeline too long for one slide, shown whole, then a few events at a
/// time along the stretch chosen, then whole again with that stretch marked.
/// Says how many clicks that takes, since the presenter has to know.
private struct StudioTimelineZoomControls: View {
    @Binding var block: LampPresentationBlock

    var body: some View {
        let count = block.listItemRuns.count
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Zoom in a few events at a time", isOn: Binding(
                get: { block.zoom != nil },
                set: { block.zoom = $0 ? LampPresentationTimelineZoom() : nil }
            ))
            .tint(Color.lampAccentMuted)
            .help("Starts with the whole timeline; each click moves in and along it, then back out")
            if let zoom = block.zoom {
                let spans = LampPresentationTimelineZoom.spans
                let span = min(max(zoom.span, spans.lowerBound), spans.upperBound)
                Stepper(value: Binding(
                    get: { span },
                    set: { block.zoom?.span = $0 }
                ), in: spans) {
                    Text("\(span) events in view")
                }
                .controlSize(.small)
                if count > 1 {
                    // The stretch as stored, held to the events, whether or
                    // not there are yet enough events to zoom.
                    let from = min(max(zoom.from ?? 1, 1), count)
                    let through = max(min(max(zoom.through ?? count, 1), count), from)
                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(value: Binding(
                            get: { from },
                            set: { value in
                                block.zoom?.from = value == 1 ? nil : value
                                if let through = block.zoom?.through, through < value { block.zoom?.through = value }
                            }
                        ), in: 1...count) {
                            Text("Explore from event \(from)")
                        }
                        Stepper(value: Binding(
                            get: { through },
                            set: { value in
                                block.zoom?.through = value == count ? nil : value
                                if let from = block.zoom?.from, from > value { block.zoom?.from = value }
                            }
                        ), in: 1...count) {
                            Text("through event \(through)")
                        }
                    }
                    .controlSize(.small)
                }
                Text(Self.summary(block, count: count, span: span))
                    .font(.caption)
                    .foregroundStyle(Color.lampSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func summary(_ block: LampPresentationBlock, count: Int, span: Int) -> String {
        guard count > span else {
            return "A view of \(span) shows all \(count) events, so the timeline is drawn whole. "
                + "Add events, or show fewer at a time."
        }
        // Read as a slide that draws figures would, since that is where the
        // zoom is drawn; elsewhere the timeline is a list.
        let moves = max(block.timelineViews(on: .titleAndBody).count - 2, 0)
        guard moves > 0 else { return "Only a timeline zooms." }
        let along = moves == 1 ? "one click zooms in" : "\(moves) clicks zoom in and move along"
        return "Starts whole; \(along), and one more zooms back out with the stretch explored marked."
    }
}

/// Whether a slide brings its content in a part at a time while presenting,
/// and whether its emphasised words light up last. Says how many clicks that
/// makes, since that is what the presenter has to remember.
private struct StudioRevealControls: View {
    @Binding var slide: LampPresentationSlide

    var body: some View {
        let plan = slide.revealPlan
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Reveal one part at a time", isOn: Binding(
                get: { slide.reveal == .stepwise },
                set: { slide.reveal = $0 ? .stepwise : nil }
            ))
            .tint(Color.lampAccentMuted)
            .help("Each passage, list item or column fades in on a click")
            Toggle("Light up emphasis last", isOn: Binding(
                get: { slide.revealsEmphasis == true },
                set: { slide.revealsEmphasis = $0 ? true : nil }
            ))
            .tint(Color.lampAccentMuted)
            .help("Emphasised words take their colour on a click of their own")
            if slide.reveal == .stepwise || slide.revealsEmphasis == true {
                Text(Self.summary(plan))
                    .font(.caption)
                    .foregroundStyle(Color.lampSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func summary(_ plan: LampPresentationRevealPlan) -> String {
        // A zoomed timeline's moves are steps too, but not parts arriving;
        // its own controls count those.
        let moves = plan.units.flatMap { $0 }.filter {
            if case .view(_, let index) = $0 { index > 0 } else { false }
        }.count
        let parts = max(plan.units.count - 1 - moves, 0)
        let rest = parts == 1 ? "one click brings in the rest" : "\(parts) clicks bring in the rest"
        switch (parts > 0, plan.emphasisStep) {
        case (true, true): return "Arrives with its first part; \(rest), then one more lights the emphasis."
        case (true, false): return "Arrives with its first part; \(rest)."
        case (false, true): return "Arrives whole; one click lights the emphasised words."
        case (false, false): return "Nothing here to bring in a part at a time, and no emphasis to light, so the slide arrives whole."
        }
    }
}

/// A slide's own ground: the theme's, the theme's accent or its words' colour
/// (a slide set apart, such as a section break), or any colour. Lamp sets the
/// words in whichever of the theme's colours reads on it, so there is nothing
/// else to choose.
private struct StudioSlideBackground: View {
    @Binding var slide: LampPresentationSlide
    let theme: LampPresentationTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                swatch(nil, name: "Theme")
                swatch(theme.accentColor, name: "Accent")
                swatch(theme.foregroundColor, name: "Inverse")
                ColorPicker(
                    "Other colour",
                    selection: Binding(
                        get: { Color(slideHex: slide.backgroundColor ?? theme.backgroundColor) },
                        set: { slide.backgroundColor = $0.slideHex }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                .help("Any colour; the words take whichever of the theme’s colours reads on it")
            }
            if let ground = slide.backgroundColor,
               let ink = theme.ink(on: ground), ink.contrast < 4.5 {
                Text("The words are hard to read on this colour. Choose a lighter or darker one.")
                    .font(.caption)
                    .foregroundStyle(Color.lampSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func swatch(_ hex: String?, name: String) -> some View {
        let isChosen = slide.backgroundColor?.uppercased() == hex?.uppercased()
        let shown = hex ?? theme.backgroundColor
        return Button {
            slide.backgroundColor = hex
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(slideHex: shown))
                    .frame(width: 34, height: 22)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(
                                isChosen ? Color.primary.opacity(0.7) : Color.lampCardStroke,
                                lineWidth: isChosen ? 2 : 1
                            )
                    }
                Text(name)
                    .font(.caption2.weight(isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.lampSecondaryText))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) background")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

private extension Color {
    init(slideHex: String) {
        let color = LampPresentationColor(hex: slideHex) ?? LampPresentationColor(red: 0, green: 0, blue: 0)
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    /// `#RRGGBB` in sRGB, as a deck stores a colour.
    var slideHex: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return "#" + channel(srgb.redComponent) + channel(srgb.greenComponent) + channel(srgb.blueComponent)
    }
}

/// Where a picture's subject is, set by clicking it: the slide's crop keeps
/// that point in view (`LampPresentationFocus`). A ring marks it.
private struct StudioFocusPicker: View {
    let url: URL?
    @Binding var focus: LampPresentationFocus?
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                // The overlay is on the fitted picture itself, before the
                // frame that caps its height: after it, the margins either
                // side of a narrow picture counted as picture and every click
                // was stored a little off.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        GeometryReader { proxy in
                            let shown = focus ?? .centre
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                                    focus = Self.focus(at: drag.location, in: proxy.size)
                                })
                            Circle()
                                .fill(Color.black.opacity(0.3))
                                .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
                                .frame(width: 16, height: 16)
                                .position(x: shown.x * proxy.size.width, y: shown.y * proxy.size.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxHeight: 150)
                    .accessibilityLabel("Picture focus")
                    .accessibilityValue(focus.map { "\(Int($0.x * 100))% across, \(Int($0.y * 100))% down" } ?? "Centre")
            }
            HStack {
                Text("Click where the subject is; the crop keeps it in view.")
                    .font(.caption)
                    .foregroundStyle(Color.lampSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Centre") { focus = nil }
                    .buttonStyle(.lampSecondary)
                    .controlSize(.small)
                    .disabled(focus == nil)
            }
        }
        // Read again when the file changes as well as when the path does: a
        // reimported deck can replace a picture under the same name, and
        // focus clicked on the old one would be saved against the new.
        .task(id: PictureIdentity(url: url, modified: url.flatMap(LampFileModification.date(of:)))) {
            image = url.flatMap(NSImage.init(contentsOf:))
        }
    }

    private struct PictureIdentity: Equatable {
        let url: URL?
        let modified: Date?
    }

    /// The point clicked, as fractions of the picture, held inside it and
    /// rounded to a hundredth so a drag does not write noise into the deck.
    private static func focus(at point: CGPoint, in size: CGSize) -> LampPresentationFocus {
        func fraction(_ value: CGFloat, _ length: CGFloat) -> Double {
            guard length > 0 else { return 0.5 }
            return (Double(min(max(value / length, 0), 1)) * 100).rounded() / 100
        }
        return LampPresentationFocus(x: fraction(point.x, size.width), y: fraction(point.y, size.height))
    }
}

/// A layout's forms, where it has any: a title slide as a statement or a
/// word, columns that mark where they differ. Kept beside the layout rather
/// than as layouts of their own, so an older Lamp draws the plain layout.
private struct StudioVariantControl: View {
    @Binding var slide: LampPresentationSlide

    var body: some View {
        controls
            // A form the new layout has none of is dropped with the change,
            // or it would be saved behind a control no longer shown and
            // warned of with no way to clear it.
            // Only when this slide's layout changes: moving to another slide
            // reuses this control, and clearing that slide's variant would
            // edit a slide no one touched.
            .onChange(of: LayoutEdit(slide: slide.id, layout: slide.layout)) { old, new in
                guard old.slide == new.slide, old.layout != new.layout else { return }
                if let variant = slide.variant, variant != .none, !variant.layouts.contains(new.layout) {
                    slide.variant = nil
                }
            }
    }

    private struct LayoutEdit: Equatable {
        let slide: String
        let layout: LampPresentationSlideLayout
    }

    @ViewBuilder
    private var controls: some View {
        switch slide.layout {
        case .title, .closing:
            VStack(alignment: .leading, spacing: 6) {
                LampSegmentedPicker(
                    "Form",
                    selection: Binding(
                        get: { slide.drawnVariant == .none ? nil : slide.drawnVariant },
                        set: { slide.variant = $0 }
                    ),
                    items: [.init(id: nil, title: "Title")]
                        + [LampPresentationSlideVariant.statement, .word]
                            .map { .init(id: Optional($0), title: $0.displayName) }
                )
                .controlSize(.small)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Color.lampSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .twoColumn:
            Toggle("Mark where the columns differ", isOn: Binding(
                get: { slide.drawnVariant == .comparison },
                set: { slide.variant = $0 ? .comparison : nil }
            ))
            .tint(Color.lampAccentMuted)
            .help("Words one column has and the others do not are drawn in the accent: for translations of one passage, or two accounts of one event")
        default:
            EmptyView()
        }
    }

    private var caption: String {
        switch slide.drawnVariant {
        case .statement: "The heading as large as the slide allows."
        case .word: "The heading is the word; a subtitle its transliteration, a body line its gloss."
        default: "A heading with a line beneath it."
        }
    }
}

/// A clip's start or end, typed as minutes:seconds. What is typed is kept
/// as typed, and read only on Return or on leaving the field, so "1:30" is
/// not turned into "0:01" at its first keystroke; and only when it was
/// typed, so a time is never changed by being looked at. Something that does
/// not read as a time puts the last good one back; an empty field is none.
/// Nothing is written as the field goes away: the block may be gone with it.
private struct StudioClipTimeField: View {
    let title: String
    @Binding var seconds: Double?
    @State private var text = ""
    @State private var isEditing = false
    @State private var typed = false

    var body: some View {
        TextField(title, text: $text, onEditingChanged: { editing in
            isEditing = editing
            if !editing { commit() }
        })
        .onSubmit(commit)
        .onAppear { text = LampSlideBlockEditor.clipTime(seconds) }
        .onChange(of: text) { _, _ in if isEditing { typed = true } }
        .onChange(of: seconds) { _, value in
            if !isEditing { text = LampSlideBlockEditor.clipTime(value) }
        }
    }

    private func commit() {
        guard typed else { return }
        typed = false
        let entry = text.trimmingCharacters(in: .whitespaces)
        if entry.isEmpty {
            seconds = nil
        } else if let value = LampSlideBlockEditor.clipSeconds(entry) {
            seconds = value
        }
        text = LampSlideBlockEditor.clipTime(seconds)
    }
}
