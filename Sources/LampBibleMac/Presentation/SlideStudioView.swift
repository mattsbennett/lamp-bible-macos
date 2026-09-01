import AppKit
import LampCore
import SwiftUI
import UniformTypeIdentifiers

struct SlideStudioRequest: Codable, Hashable {
    var deckID: String?
    var devotionalID: String?

    init(deckID: String? = nil, devotionalID: String? = nil) {
        self.deckID = deckID
        self.devotionalID = devotionalID
    }
}

struct SlidePresentationRequest: Codable, Hashable {
    let deckID: String
}

struct SlideStudioView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var remoteHost: LampPresentationRemoteHost

    let request: SlideStudioRequest

    @State private var decks: [LampPresentationDeck] = []
    @State private var selectedDeckID: String?
    @State private var deck: LampPresentationDeck?
    @State private var savedDeck: LampPresentationDeck?
    @State private var selectedSlideID: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showingDeleteConfirmation = false
    @State private var showingRemotePairing = false

    private var store: LampPresentationDeckStore {
        LampPresentationDeckStore(rootURL: model.library.rootURL)
    }

    private var presentationTypefaceFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var issues: [LampPresentationDeckIssue] {
        deck.map(LampPresentationDeckValidator.validate) ?? []
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
                HSplitView {
                    slideNavigator(deck: deckBinding)
                        .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
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
        .task(id: request) { loadInitialDeck() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refreshDecksFromDisk()
            }
        }
        .onChange(of: selectedDeckID) { _, deckID in selectDeck(deckID) }
        .onChange(of: deck) { _, updatedDeck in scheduleAutosave(updatedDeck) }
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
            saveTask?.cancel()
            saveNow()
        }
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
            Button("Import Deck…", systemImage: "square.and.arrow.down") { importDeck() }
                .help("Import a .lampdeck document")
            Button("Export Deck…", systemImage: "square.and.arrow.up") { exportDeck() }
                .disabled(deck == nil || hasErrors)
                .help("Export the editable deck document")
            Button("Delete Deck", systemImage: "trash", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(deck == nil)
            .help("Delete this deck")
            Divider()
            Button("Save", systemImage: "checkmark.circle") { saveNow() }
                .disabled(deck == nil || hasErrors || !hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: .command)
            Button(
                remoteHost.connectedClientNames.isEmpty ? "Pair Remote" : "Remote Connected",
                systemImage: remoteHost.connectedClientNames.isEmpty ? "qrcode" : "iphone.and.arrow.forward"
            ) {
                remoteHost.start()
                showingRemotePairing = true
            }
            .popover(isPresented: $showingRemotePairing, arrowEdge: .bottom) {
                SlideRemotePairingView(pairingCode: remoteHost.pairingCode)
            }
            .help("Pair an iPhone or iPad before presenting")
            Button("Play", systemImage: "play.fill") { presentDeck() }
                .buttonStyle(.borderedProminent)
                .disabled(deck == nil || hasErrors)
                .help("Present this deck")
        }
    }

    private func slideNavigator(
        deck deckBinding: Binding<LampPresentationDeck>
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Deck", selection: $selectedDeckID) {
                    ForEach(decks) { candidate in
                        Text(candidate.title).tag(Optional(candidate.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .padding(10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(deckBinding.slides.wrappedValue.enumerated()), id: \.element.id) { index, slide in
                        Button {
                            selectedSlideID = slide.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    LampPresentationSlideCanvas(
                                        slide: slide,
                                        deck: deckBinding.wrappedValue,
                                        compact: true
                                    )
                                    .aspectRatio(deckBinding.wrappedValue.aspectRatio.ratio, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(
                                                selectedSlideID == slide.id
                                                    ? Color.accentColor : Color.secondary.opacity(0.25),
                                                lineWidth: selectedSlideID == slide.id ? 3 : 1
                                            )
                                    }

                                    if slide.isHidden {
                                        Image(systemName: "eye.slash.fill")
                                            .font(.caption2)
                                            .padding(5)
                                            .background(.ultraThinMaterial, in: Circle())
                                            .padding(4)
                                    }
                                }
                                Text("\(index + 1). \(slide.displayTitle)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Duplicate") { duplicateSlide(slide.id) }
                            Button(slide.isHidden ? "Show Slide" : "Hide Slide") {
                                toggleHidden(slide.id)
                            }
                            Divider()
                            Button("Delete Slide", role: .destructive) { deleteSlide(slide.id) }
                                .disabled(deckBinding.slides.wrappedValue.count == 1)
                        }
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Button("Add Slide", systemImage: "plus") { addSlide() }
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
            HSplitView {
                VStack(spacing: 0) {
                    ZStack {
                        Color(nsColor: .underPageBackgroundColor)
                        if let slide = selectedSlide {
                            LampPresentationSlideCanvas(
                                slide: slide,
                                deck: deckBinding.wrappedValue
                            )
                            .aspectRatio(deckBinding.wrappedValue.aspectRatio.ratio, contentMode: .fit)
                            .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
                            .padding(44)
                        }
                    }
                    .frame(minHeight: 440)

                    Divider()
                    speakerNotesEditor
                        .frame(minHeight: 135, idealHeight: 170, maxHeight: 240)
                }

                inspector(deck: deckBinding)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 430)
            }

            Divider()
            validationBar
        }
    }

    @ViewBuilder
    private func inspector(deck deckBinding: Binding<LampPresentationDeck>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Deck") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Title", text: deckBinding.title)
                        Picker("Aspect", selection: deckBinding.aspectRatio) {
                            ForEach(LampPresentationAspectRatio.allCases) { ratio in
                                Text(ratio.displayName).tag(ratio)
                            }
                        }
                        Picker("Theme", selection: Binding(
                            get: { deckBinding.wrappedValue.theme.id },
                            set: { applyTheme($0) }
                        )) {
                            Text("Lamp Dark").tag(LampPresentationTheme.lampDark.id)
                            Text("Parchment").tag(LampPresentationTheme.parchment.id)
                            if ![LampPresentationTheme.lampDark.id, LampPresentationTheme.parchment.id]
                                .contains(deckBinding.wrappedValue.theme.id) {
                                Text(deckBinding.wrappedValue.theme.id).tag(deckBinding.wrappedValue.theme.id)
                            }
                        }
                        Picker("Typeface", selection: Binding(
                            get: { deckBinding.wrappedValue.theme.typeface ?? "" },
                            set: { deckBinding.theme.typeface.wrappedValue = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Lamp Rounded").tag("")
                            Text("System Sans").tag("system-sans")
                            Text("System Serif").tag("system-serif")
                            Divider()
                            ForEach(presentationTypefaceFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                if let slideBinding = bindingToSelectedSlide {
                    GroupBox("Slide") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Layout", selection: slideBinding.layout) {
                                ForEach(LampPresentationSlideLayout.allCases) { layout in
                                    Text(layout.displayName).tag(layout)
                                }
                            }
                            Toggle("Skip while presenting", isOn: slideBinding.isHidden)
                        }
                        .padding(.top, 4)
                    }

                    GroupBox("Content") {
                        VStack(spacing: 12) {
                            ForEach(slideBinding.blocks) { $block in
                                LampSlideBlockEditor(
                                    block: $block,
                                    updateCitation: { citation in
                                        updateScriptureCitation(citation, after: block.id)
                                    },
                                    remove: { removeBlock(block.id) }
                                )
                                if block.id != slideBinding.blocks.wrappedValue.last?.id {
                                    Divider()
                                }
                            }

                            Menu("Add Content", systemImage: "plus") {
                                ForEach(LampPresentationBlockKind.allCases) { kind in
                                    Button(kind.displayName) { addBlock(kind) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var speakerNotesEditor: some View {
        if let slideBinding = bindingToSelectedSlide {
            VStack(alignment: .leading, spacing: 6) {
                Label("Presenter Notes", systemImage: "person.crop.rectangle.badge.plus")
                    .font(.headline)
                TextEditor(text: slideBinding.speakerNotes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.secondary.opacity(0.2))
                    }
            }
            .padding(12)
        }
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
            Text("\(deck?.slides.count ?? 0) slides")
                .foregroundStyle(.secondary)
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
            let requestedDeck: LampPresentationDeck?
            if let deckID = request.deckID {
                requestedDeck = decks.first { $0.id == deckID }
            } else if let devotionalID = request.devotionalID {
                requestedDeck = decks.first {
                    $0.source?.kind == .devotional && $0.source?.id == devotionalID
                }
            } else {
                requestedDeck = decks.first
            }

            if let requestedDeck {
                applySelection(requestedDeck)
            } else {
                let newDeck = starterDeck(devotionalID: request.devotionalID)
                try store.save(newDeck)
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

    private func refreshDecksFromDisk() {
        guard !isLoading else { return }
        do {
            let refreshed = try store.decks()
            guard refreshed != decks else { return }
            if let selectedDeckID,
               let diskDeck = refreshed.first(where: { $0.id == selectedDeckID }),
               deck == savedDeck,
               diskDeck != savedDeck {
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

    private func starterDeck(devotionalID: String?) -> LampPresentationDeck {
        guard let devotionalID,
              let devotional = model.devotionals.first(where: { $0.id == devotionalID }) else {
            return .starter()
        }
        return .starter(
            title: devotional.title,
            subtitle: devotional.subtitle ?? devotional.author,
            source: .init(kind: .devotional, id: devotional.id)
        )
    }

    private func applySelection(_ selected: LampPresentationDeck) {
        deck = selected
        savedDeck = selected
        selectedDeckID = selected.id
        selectedSlideID = selected.slides.first?.id
        statusMessage = "Saved"
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

    private func saveNow() {
        saveTask?.cancel()
        guard let deck, deck != savedDeck else { return }
        let validationErrors = LampPresentationDeckValidator.errors(in: deck)
        guard validationErrors.isEmpty else {
            statusMessage = "Fix validation errors to save"
            return
        }
        do {
            try store.save(deck)
            savedDeck = deck
            if let index = decks.firstIndex(where: { $0.id == deck.id }) {
                decks[index] = deck
            } else {
                decks.append(deck)
            }
            decks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            statusMessage = "Saved"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedDeck() {
        guard let deck else { return }
        saveTask?.cancel()
        do {
            try store.delete(id: deck.id)
            decks.removeAll { $0.id == deck.id }
            if let next = decks.first {
                applySelection(next)
            } else {
                let replacement = LampPresentationDeck.starter()
                try store.save(replacement)
                decks = [replacement]
                applySelection(replacement)
            }
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

    private func addBlock(_ kind: LampPresentationBlockKind) {
        guard let slideID = selectedSlide?.id,
              let index = deck?.slides.firstIndex(where: { $0.id == slideID }) else { return }
        let block: LampPresentationBlock
        if kind == .image {
            block = .init(
                kind: .image,
                assetPath: "assets/image.jpg",
                altText: "Describe the image"
            )
        } else {
            block = .init(kind: kind, text: kind == .title ? "New Title" : "New content")
        }
        deck?.slides[index].blocks.append(block)
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

    private func applyTheme(_ themeID: String) {
        let typeface = deck?.theme.typeface
        var newTheme: LampPresentationTheme
        switch themeID {
        case LampPresentationTheme.parchment.id:
            newTheme = .parchment
        default:
            newTheme = .lampDark
        }
        newTheme.typeface = typeface
        deck?.theme = newTheme
    }

    private func presentDeck() {
        saveNow()
        guard let deck, LampPresentationDeckValidator.errors(in: deck).isEmpty else { return }
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
            try store.encoded(deck).write(to: destination, options: [.atomic])
            statusMessage = "Exported \(destination.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
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
    @Binding var block: LampPresentationBlock
    let updateCitation: (String) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("Role", selection: $block.kind) {
                    ForEach(LampPresentationBlockKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                Spacer()
                Button("Remove Content", systemImage: "minus.circle", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }

            if block.kind == .image {
                TextField("Asset path", text: Binding(
                    get: { block.assetPath ?? "" },
                    set: { block.assetPath = $0 }
                ))
                TextField("Accessibility description", text: Binding(
                    get: { block.altText ?? "" },
                    set: { block.altText = $0 }
                ))
            } else {
                if block.kind == .body {
                    Picker("Body format", selection: $block.listStyle) {
                        Text("Text").tag(nil as LampPresentationListStyle?)
                        ForEach(LampPresentationListStyle.allCases) { style in
                            Text(style.displayName).tag(Optional(style))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if block.listStyle != nil {
                        Text("Enter one list item per line.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if block.kind == .scripture {
                    LampSlideScripturePicker(
                        block: $block,
                        updateCitation: updateCitation
                    )
                }

                TextEditor(text: $block.text)
                    .font(.body)
                    .frame(minHeight: block.kind == .body ? 90 : 52)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
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
        _isExpanded = State(initialValue: reference == nil)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Translation", selection: $translationID) {
                    ForEach(model.translations) { translation in
                        Text(translation.abbreviation ?? translation.name)
                            .tag(translation.id)
                    }
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
                .buttonStyle(.borderedProminent)
                .disabled(selectedVerses.isEmpty)
            }
            .padding(.top, 8)
        } label: {
            Label("Choose Scripture", systemImage: "quote.opening")
                .font(.callout.weight(.medium))
        }
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
        guard translationID.isEmpty
                || !model.translations.contains(where: { $0.id == translationID }) else { return }
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
        let translation = model.translations.first { $0.id == translationID }
        let translationName = translation?.abbreviation ?? translation?.name ?? translationID
        let verseRange = startVerse == endVerse
            ? startVerse.formatted()
            : "\(startVerse.formatted())–\(endVerse.formatted())"

        block.scriptureReference = reference
        block.text = selectedVerses.map(\.text).joined(separator: " ")
        updateCitation("\(selectedBook.name) \(chapterNumber):\(verseRange) (\(translationName))")
    }
}

struct LampPresentationSlideCanvas: View {
    let slide: LampPresentationSlide
    let deck: LampPresentationDeck
    var compact = false

    private var foreground: Color { Color(lampHex: deck.theme.foregroundColor) ?? .white }
    private var accent: Color { Color(lampHex: deck.theme.accentColor) ?? .orange }

    var body: some View {
        GeometryReader { geometry in
            let unit = min(
                geometry.size.width / (deck.aspectRatio == .widescreen ? 1_600 : 1_200),
                geometry.size.height / 900
            )
            ZStack {
                Color(lampHex: deck.theme.backgroundColor) ?? .black
                slideContent(unit: unit)
                    .padding(.horizontal, 96 * unit)
                    .padding(.vertical, 72 * unit)
            }
            .clipped()
        }
        .background(Color(lampHex: deck.theme.backgroundColor) ?? .black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slide.displayTitle)
    }

    @ViewBuilder
    private func slideContent(unit: CGFloat) -> some View {
        switch slide.layout {
        case .title, .closing:
            VStack(spacing: 24 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 76 * unit, weight: .bold, alignment: .center)
                }
                if let subtitle = block(for: .subtitle) ?? block(for: .body) {
                    slideBlockText(
                        subtitle,
                        size: 32 * unit,
                        weight: .regular,
                        alignment: .center,
                        color: accent
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .titleAndBody:
            VStack(alignment: .leading, spacing: 34 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 58 * unit, weight: .bold)
                    Rectangle().fill(accent).frame(width: 120 * unit, height: 6 * unit)
                }
                if let body = block(for: .body) ?? firstContentBlock {
                    slideBlockText(body, size: 32 * unit, weight: .regular)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .scripture, .quotation:
            VStack(alignment: .leading, spacing: 30 * unit) {
                if let quotation = block(for: slide.layout == .scripture ? .scripture : .quotation)
                    ?? block(for: .body) ?? firstContentBlock {
                    slideBlockText(quotation, size: 42 * unit, weight: .regular)
                }
                if let citation = block(for: .citation) {
                    slideBlockText(citation, size: 25 * unit, weight: .medium, color: accent)
                }
            }
            .padding(.leading, 34 * unit)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3 * unit)
                    .fill(accent)
                    .frame(width: 6 * unit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .twoColumn:
            VStack(alignment: .leading, spacing: 28 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 52 * unit, weight: .bold)
                }
                let columns = slide.blocks.filter { $0.kind == .body && !$0.text.isEmpty }
                HStack(alignment: .top, spacing: 50 * unit) {
                    slideBlockText(
                        columns.first ?? LampPresentationBlock(kind: .body, text: "First idea"),
                        size: 29 * unit,
                        weight: .regular
                    )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Rectangle().fill(accent.opacity(0.45)).frame(width: 2 * unit)
                    slideBlockText(
                        columns.dropFirst().first
                            ?? LampPresentationBlock(kind: .body, text: "Second idea"),
                        size: 29 * unit,
                        weight: .regular
                    )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .image:
            VStack(spacing: 22 * unit) {
                if let title = block(for: .title) {
                    slideBlockText(title, size: 48 * unit, weight: .bold)
                }
                RoundedRectangle(cornerRadius: 18 * unit)
                    .fill(foreground.opacity(0.09))
                    .overlay {
                        VStack(spacing: 10 * unit) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 70 * unit, weight: .light))
                            Text(slide.blocks.first { $0.kind == .image }?.assetPath ?? "Image")
                                .font(.system(size: 20 * unit))
                                .lineLimit(1)
                        }
                        .foregroundStyle(foreground.opacity(0.7))
                    }
                if let caption = block(for: .caption) {
                    slideBlockText(caption, size: 22 * unit, weight: .regular, alignment: .center)
                }
            }

        case .blank:
            VStack(alignment: .leading, spacing: 18 * unit) {
                ForEach(slide.blocks) { block in
                    if block.kind != .image {
                        slideBlockText(block, size: 31 * unit, weight: .regular)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func block(for kind: LampPresentationBlockKind) -> LampPresentationBlock? {
        slide.blocks.first { $0.kind == kind && !$0.text.isEmpty }
    }

    private var firstContentBlock: LampPresentationBlock? {
        slide.blocks.first { ![.title, .subtitle, .image].contains($0.kind) && !$0.text.isEmpty }
    }

    @ViewBuilder
    private func slideBlockText(
        _ block: LampPresentationBlock,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment = .leading,
        color: Color? = nil
    ) -> some View {
        if let listStyle = block.listStyle,
           block.kind == .body,
           !listItems(in: block.text).isEmpty {
            let items = listItems(in: block.text)
            VStack(alignment: .leading, spacing: size * 0.22) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: size * 0.28) {
                        Text(listMarker(for: listStyle, index: index))
                            .font(presentationFont(size: size, weight: weight))
                            .frame(
                                minWidth: size * (listStyle == .ordered ? 1.05 : 0.55),
                                alignment: .trailing
                            )
                        styledText(
                            item,
                            size: size,
                            weight: weight,
                            alignment: alignment,
                            color: color ?? foreground
                        )
                    }
                }
            }
            .foregroundStyle(color ?? foreground)
        } else {
            styledText(
                block.text,
                size: size,
                weight: weight,
                alignment: alignment,
                color: color ?? foreground
            )
        }
    }

    private func styledText(
        _ value: String,
        size: CGFloat,
        weight: Font.Weight,
        alignment: TextAlignment,
        color: Color
    ) -> some View {
        Text(value)
            .font(presentationFont(size: size, weight: weight))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .lineSpacing(size * 0.12)
            .minimumScaleFactor(0.45)
            .lineLimit(compact ? 4 : nil)
    }

    private func presentationFont(size: CGFloat, weight: Font.Weight) -> Font {
        let resolvedSize = max(size, compact ? 4 : 10)
        switch deck.theme.typeface?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "system-sans":
            return .system(size: resolvedSize, weight: weight)
        case "system-serif":
            return .system(size: resolvedSize, weight: weight, design: .serif)
        case .some(let family) where !family.isEmpty:
            return .custom(family, size: resolvedSize).weight(weight)
        default:
            return .system(size: resolvedSize, weight: weight, design: .rounded)
        }
    }

    private func listItems(in value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func listMarker(for style: LampPresentationListStyle, index: Int) -> String {
        switch style {
        case .unordered: "•"
        case .ordered: "\(index + 1)."
        }
    }
}
