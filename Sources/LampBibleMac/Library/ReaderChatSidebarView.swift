import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

struct ReaderChatSidebarView: View {
    @EnvironmentObject private var libraryModel: LibraryModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("reader.chat.provider") private var providerID = AIProviderCLI.codex.rawValue
    @AppStorage("agent.moduleAccess.enabled") private var moduleAccessEnabled = true
    @AppStorage("agent.moduleAccess.scope")
    private var moduleAccessScope = AgentModuleAccessScope.enabledModules.rawValue
    @AppStorage("agent.moduleAccess.personal") private var personalContentEnabled = false
    @State private var configuration: LampAgentMCPConfiguration?
    @State private var preparationError: String?
    /// What this window's chat is set to run with, read from beside its own
    /// transcript. `providerID` above is what the app remembers, which is the
    /// default a new chat opens on.
    @State private var chatChoices = AgentChatChoices()

    /// Which chat this pane is on. Handed in by the window, which took it up
    /// from the library; see `OpenReaderChats`.
    let chatID: UUID
    /// Puts this tab on another chat, or on a new one for nil. The window
    /// owns the move, since it is the tab's chat that changes.
    let resume: (UUID?) -> Void
    @State private var forkError: String?
    /// A writing about to be started from this chat, while the reader
    /// confirms it.
    @State private var writingToStart: WritingFromChat?
    @State private var writingError: String?
    /// The writings started from this chat, read from beside its transcript.
    @State private var startedWritings: [ReaderChatWritingCopy.Started] = []
    @State private var isReplying = false
    let close: () -> Void
    /// The reader of the tab this chat belongs to. A question is prepared
    /// with that tab's place when it is sent, which for a queued one is
    /// after it was asked: read from the window's current reader, a question
    /// queued in one tab and sent after a switch carried the other tab's
    /// chapter.
    @ObservedObject var reader: ReaderWorkspace

    @State private var isChoosingChat = false

    private var provider: AIProviderCLI {
        AIProviderCLI(
            rawValue: chatChoices.value(for: AgentChatChoices.providerKey, orAppDefault: providerID) ?? providerID
        ) ?? .codex
    }

    /// Picking a provider sets this chat's, and what the app remembers, so the
    /// next window opens on it. Windows already open keep their own.
    private var providerSelection: Binding<String> {
        Binding(
            get: { provider.rawValue },
            set: { chosen in
                var updated = chatChoices
                updated.set(chosen, for: AgentChatChoices.providerKey)
                try? AgentChatChoicesStore.save(updated, in: workspace)
                chatChoices = updated
                providerID = chosen
            }
        )
    }

    /// Takes the conversation up to a turn into a chat of its own and opens
    /// it, leaving this one where it was.
    ///
    /// The tab moves to the fork, because the reader asked to follow the
    /// tangent; the thread it came from is in the chat list, where every
    /// other conversation is.
    private func forkFromTurn(_ turn: UUID) {
        do {
            guard let forked = try ReaderChatWorkspaceStore.fork(
                chat: chatID, at: turn, providerID: provider.rawValue,
                libraryRootURL: libraryModel.library.rootURL
            ) else {
                forkError = "That turn is no longer part of this conversation."
                return
            }
            resume(forked)
        } catch {
            forkError = "Could not start a chat from that turn: \(error.localizedDescription)"
        }
    }

    /// Offers to start a writing from the conversation, up to `turn` or the
    /// whole of it.
    ///
    /// What the sheet shows is read here, as it opens, and handed in: see
    /// the chat chooser's popover for why it is not read from this view's
    /// state inside the sheet.
    private func offerWriting(upTo turn: UUID?) {
        let transcript = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        let turns = transcript.turns.filter { $0.question != nil }
        writingToStart = WritingFromChat(
            turn: turn,
            title: (turn.flatMap { id in turns.first { $0.id == id }?.question } ?? turns.first?.question)
                .map { ReaderChatWorkspaceStore.label($0) } ?? "",
            hasConversation: !turns.isEmpty
        )
    }

    /// Starts the writing, copies the conversation into it and opens it with
    /// its chat showing.
    private func startWriting(_ request: WritingFromChat, title: String) {
        writingToStart = nil
        // Whether a reply has begun since the sheet opened is asked by
        // `startWriting` itself, just before it copies, which is the only
        // place the answer cannot go stale.
        Task {
            do {
                let saved = try await libraryModel.startWriting(
                    title: title,
                    fromReaderChat: request.hasConversation ? chatID : nil,
                    upTo: request.turn,
                    providerID: provider.rawValue
                )
                if !request.hasConversation {
                    // Nothing to copy, but still this chat's writing.
                    try? ReaderChatWritingCopy.recordStarted(
                        .init(writingID: saved.id, title: saved.title),
                        chat: chatID, libraryRootURL: libraryModel.library.rootURL
                    )
                }
                loadStartedWritings()
                open(writingID: saved.id)
            } catch {
                writingError = error.localizedDescription
            }
        }
    }

    private func open(writingID: String) {
        openWindow(
            id: "devotional-editor",
            value: DevotionalEditorRequest(devotionalID: writingID, opensAgentPane: true)
        )
    }

    private func loadStartedWritings() {
        let started = ReaderChatWritingCopy.started(
            chat: chatID, libraryRootURL: libraryModel.library.rootURL
        )
        if started != startedWritings { startedWritings = started }
    }

    private var workspace: URL {
        ReaderChatWorkspaceStore.workspaceURL(
            libraryRootURL: libraryModel.library.rootURL, chatID: chatID
        )
    }

    private var accessPolicy: LampAgentAccessPolicy {
        // Reader research used to span the whole installed library whatever the
        // Module Access scope said, on the grounds that research wants breadth.
        // But the scope exists so the reader decides, a module may be hidden
        // for privacy rather than tidiness, and Settings offers it as one
        // choice over agents with nothing to say this pane is exempt.
        AgentModuleAccessPreferences.policy(
            isEnabled: moduleAccessEnabled,
            scope: AgentModuleAccessScope(rawValue: moduleAccessScope) ?? .enabledModules,
            includesPersonalContent: personalContentEnabled,
            modules: libraryModel.modules,
            hiddenModuleIDs: libraryModel.hiddenModuleIDs
        )
    }

    /// What the chat can reach, in the words the setting uses.
    private var moduleAccessDescription: String {
        guard moduleAccessEnabled else { return "Module access is off in AI & Agents settings" }
        let scope = AgentModuleAccessScope(rawValue: moduleAccessScope) ?? .enabledModules
        let modules = scope == .enabledModules ? "Enabled modules" : "All installed modules"
        return personalContentEnabled ? "\(modules) and personal study content" : modules
    }

    private var context: ReaderChatContext? { capture()?.context(notes: []) }

    /// What a message is sent with that can be read from the reader at once.
    /// The reader's notes are read from the library after, by `notes(on:)`.
    private struct Capture {
        let reference: String
        let translationID: String
        let translationName: String
        let selectedVerse: String?
        let selection: ReaderChatContext.Selection?
        let sharesPersonalStudy: Bool
        let highlights: [ReaderChatContext.Highlight]
        let noteReferences: [Int]

        func context(notes: [ReaderChatContext.Note]) -> ReaderChatContext {
            ReaderChatContext(
                reference: reference,
                translationID: translationID,
                translationName: translationName,
                selectedVerse: selectedVerse,
                selection: selection,
                personalStudy: sharesPersonalStudy
                    ? .shared(notes: notes, highlights: highlights)
                    : .notShared
            )
        }
    }

    private func capture() -> Capture? {
        guard let book = reader.selectedBook,
              let translation = libraryModel.translations.first(where: { $0.id == reader.selectedTranslationID })
        else { return nil }
        let chapter = reader.selectedChapterNumber
        let inChapter = { (reference: Int) in
            reference / 1_000 == book.id * 1_000 + chapter
        }
        let sharesPersonalStudy = ReaderChatContext.sharesPersonalStudy(under: accessPolicy)
        let selection = reader.textSelection.current.map { passage in
            ReaderChatContext.Selection(
                text: passage.text,
                reference: passage.reference,
                translationName: passage.translationID.map { id in
                    libraryModel.modules.first { $0.id == id }?.name ?? id
                } ?? translation.name
            )
        }
        return Capture(
            reference: "\(book.name) \(chapter)",
            translationID: translation.id,
            translationName: translation.name,
            selectedVerse: reader.selectedVerseReference.flatMap { reference in
                inChapter(reference)
                    ? LampBibleReferenceFormatter.describeRange(from: reference, to: reference)
                    : nil
            },
            selection: selection,
            sharesPersonalStudy: sharesPersonalStudy,
            highlights: sharesPersonalStudy
                ? personalHighlights(in: translation.id, where: inChapter)
                : [],
            noteReferences: sharesPersonalStudy
                ? libraryModel.noteReferences.filter(inChapter).sorted()
                : []
        )
    }

    /// The reader's own highlights in the chapter, with the words each marks:
    /// this tab's chapter and translation, which by the time a queued
    /// question is sent need not be the library's.
    private func personalHighlights(
        in translationID: String,
        where inChapter: @escaping (Int) -> Bool
    ) -> [ReaderChatContext.Highlight] {
        let verses = Dictionary(
            (reader.contents.chapter?.verses ?? []).map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
        return libraryModel.highlightsByReference.keys.filter(inChapter).sorted().flatMap { reference in
            libraryModel.personalHighlights(for: reference, in: translationID).map { highlight in
                ReaderChatContext.Highlight(
                    reference: LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                    color: highlight.color.map(Self.colorName),
                    style: Self.styleName(highlight.style),
                    words: verses[reference].flatMap { Self.words(of: highlight, in: $0) }
                )
            }
        }
    }

    /// The words a highlight marks, or nil when it marks the whole verse or
    /// its offsets no longer fit the verse.
    private static func words(of highlight: LampVerseHighlight, in text: String) -> String? {
        let start = max(highlight.startOffset, 0)
        let end = min(highlight.endOffset, text.count)
        guard end > start, start > 0 || end < text.count else { return nil }
        let characters = Array(text)
        return String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func colorName(_ hex: String) -> String {
        let stored = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return StudyHighlightPalette.colors
            .first { $0.hex.caseInsensitiveCompare(stored) == .orderedSame }?
            .name.lowercased() ?? hex
    }

    private static func styleName(_ style: LampHighlightStyle) -> String? {
        switch style {
        case .highlight: nil
        case .underlineSolid: "underlined"
        case .underlineDashed: "dashed underline"
        case .underlineDotted: "dotted underline"
        }
    }

    /// The reader's own notes on these verses, each once: a note on several
    /// verses is found from each of them.
    private func notes(on references: [Int]) async -> [ReaderChatContext.Note] {
        var seen: Set<String> = []
        var notes: [ReaderChatContext.Note] = []
        for reference in references {
            guard let note = try? await libraryModel.personalNote(for: reference),
                  seen.insert(note.id).inserted else { continue }
            // Verse 0 is the chapter's own note, which "Genesis 1:0" would
            // not say.
            let verses = ([reference] + note.verseReferences).filter { $0 % 1_000 != 0 }
            let chapter = reference - reference % 1_000
            notes.append(ReaderChatContext.Note(
                reference: verses.isEmpty
                    ? LampBibleReferenceFormatter.describeRange(from: chapter + 1, to: chapter + 999)
                        + " (the whole chapter)"
                    : LampBibleReferenceFormatter.describeRange(
                        from: verses.min() ?? reference, to: verses.max() ?? reference
                    ),
                title: note.title,
                content: note.content
            ))
        }
        return notes
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                    Text("Reader Chat")
                        .font(.headline)
                    Spacer()
                    Button("Start a Writing", systemImage: "square.and.pencil") {
                        offerWriting(upTo: nil)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ChatControlButtonStyle())
                    .disabled(isReplying)
                    .help("Start a writing from this conversation")
                    Button("Chats", systemImage: "clock.arrow.circlepath") {
                        isChoosingChat = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ChatControlButtonStyle())
                    .help("Start a new chat, or go back to one")
                    .popover(isPresented: $isChoosingChat, arrowEdge: .bottom) {
                        // Built from a reading taken here, as the popover
                        // opens, and handed in. Read from this view's own
                        // `@State` instead and the list came up empty: the
                        // content closure is called with a copy of the view
                        // whose state is not the one the button wrote to, so
                        // what it saw was the initial value.
                        ReaderChatChooser(
                            chats: ReaderChatWorkspaceStore
                                .chats(libraryRootURL: libraryModel.library.rootURL)
                                .filter { $0.id != chatID },
                            inUse: OpenReaderChats.inUse,
                            libraryRootURL: libraryModel.library.rootURL
                        ) { chosen in
                            isChoosingChat = false
                            resume(chosen)
                        }
                    }
                    Button("Close Chat", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(ChatControlButtonStyle())
                        .help("Close reader chat")
                }

                // Who answers, with what, in one quiet row of menus that each
                // say their whole choice. Bordered pop-ups side by side in a
                // pane this narrow cut "Default model" to "Defa…model".
                HStack(spacing: 2) {
                    Menu {
                        Picker("Provider", selection: providerSelection) {
                            ForEach(AIProviderCLI.allCases) { provider in
                                Text(provider.shortName).tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        ChatControlMenuLabel(title: provider.shortName, systemImage: provider.systemImage)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(ChatControlButtonStyle())
                    .fixedSize()
                    .accessibilityLabel("Provider")
                    .accessibilityValue(provider.shortName)
                    .help("Which AI answers in this chat")

                    AgentChatProviderChoice(
                        kind: .model, provider: provider, workspace: workspace,
                        chatChoices: $chatChoices
                    )
                    AgentChatProviderChoice(
                        kind: .effort, provider: provider, workspace: workspace,
                        chatChoices: $chatChoices
                    )
                    Spacer(minLength: 0)
                }
                .padding(.leading, -6)

                contextCard
                startedWritingsLine
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
            Divider()

            // Only a configuration made for **this** chat. The pane is kept
            // when its tab moves to another chat, and a chat mounted with the
            // last one's configuration would hand its helper the wrong chat
            // — a writing asked for in it would take that other conversation.
            if let configuration, configuration.readerChatID == chatID {
                NativeAgentChatView(
                    provider: provider,
                    workspace: workspace,
                    mode: .reader(configuration),
                    canSend: context != nil,
                    preparePrompt: { question in
                        guard let capture = capture() else {
                            throw CocoaError(.fileReadUnknown, userInfo: [
                                NSLocalizedDescriptionKey: "Choose a chapter in the reader first.",
                            ])
                        }
                        try writeAccessPolicy()
                        let notes = await notes(on: capture.noteReferences)
                        return capture.context(notes: notes).prompt(for: question)
                    },
                    onRunningChanged: { running in
                        if isReplying != running { isReplying = running }
                    },
                    forkFromTurn: forkFromTurn,
                    startWritingFromTurn: { offerWriting(upTo: $0) }
                )
                .id("\(provider.rawValue)|\(workspace.path)")
            } else if let preparationError {
                ContentUnavailableView {
                    Label("Chat Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text(preparationError)
                } actions: {
                    Button("Try Again", action: prepareWorkspace)
                }
            } else {
                ProgressView("Preparing Chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .alert(
            "Could not start a chat from that turn",
            isPresented: Binding(
                get: { forkError != nil },
                set: { if !$0 { forkError = nil } }
            ),
            presenting: forkError
        ) { _ in
            Button("OK", role: .cancel) { forkError = nil }
        } message: { reason in
            Text(reason)
        }
        .alert(
            "Could not start the writing",
            isPresented: Binding(
                get: { writingError != nil },
                set: { if !$0 { writingError = nil } }
            ),
            presenting: writingError
        ) { _ in
            Button("OK", role: .cancel) { writingError = nil }
        } message: { reason in
            Text(reason)
        }
        .sheet(item: $writingToStart) { request in
            StartWritingFromChatSheet(request: request) { title in
                startWriting(request, title: title)
            } cancel: {
                writingToStart = nil
            }
        }
        .onAppear {
            prepareWorkspace()
            loadStartedWritings()
        }
        // A writing an agent asked for in this chat is started when its
        // reply finishes, by the library, which hears that from the chat
        // whether or not this pane is open; and tried again here, for one
        // left waiting.
        .task { await libraryModel.takeInRequestedWritings() }
        .onChange(of: libraryModel.startedWritingsRevision) { _, _ in loadStartedWritings() }
        .onChange(of: chatID) { _, _ in
            prepareWorkspace()
            loadStartedWritings()
        }
        .onChange(of: provider) { _, _ in loadChoices() }
        .onChange(of: accessPolicy) { _, _ in
            do {
                try writeAccessPolicy()
            } catch {
                preparationError = error.localizedDescription
                configuration = nil
            }
        }
    }

    /// What each message is sent with, gathered in one card: the passage and
    /// translation, what else rides along, and what the chat may read. It
    /// was four loose lines of grey, which read as debugging output.
    @ViewBuilder
    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let capture = capture() {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "book")
                        .foregroundStyle(.secondary)
                    Text(capture.reference)
                        .fontWeight(.semibold)
                    Text(capture.translationName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(capture.translationName)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                ReaderChatAttachmentsLine(
                    selection: reader.textSelection,
                    selectedVerse: capture.selectedVerse,
                    personalStudy: capture.sharesPersonalStudy
                        ? .shared(
                            notedVerses: capture.noteReferences.count,
                            highlights: capture.highlights.count
                        )
                        : .notShared
                )
            } else {
                Text("Choose a chapter in the reader to begin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("Read-only", systemImage: "lock")
                Text("·").foregroundStyle(.tertiary)
                Text(moduleAccessDescription)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(moduleAccessDescription)
                Spacer(minLength: 4)
                // To AI & Agents, where this pane's settings are — the
                // provider accounts, module access, and how long chats are
                // kept. `SettingsLink` opens the window wherever it was last
                // left, which from here is almost never where the reader
                // meant to go.
                Button {
                    SettingsDestination.shared.section = .aiAndAgents
                    SettingsDestination.shared.anchor = .readerChats
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("AI provider, module access, and chat settings")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.lampCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.lampCardStroke)
        }
    }

    /// The writings started from this chat that are still in the library,
    /// each a way to it. The chat says where its conversation went, and only
    /// that: the writing's chat is its own from the moment it was copied.
    @ViewBuilder
    private var startedWritingsLine: some View {
        let present = startedWritings.filter { started in
            libraryModel.devotionals.contains { $0.id == started.writingID }
        }
        if !present.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(present) { started in
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(.secondary)
                        Text("Started \u{201C}\(started.title)\u{201D}")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help("A writing started from this chat. It has its own copy of the conversation.")
                        Spacer(minLength: 4)
                        Button("Open") { open(writingID: started.writingID) }
                            .buttonStyle(.link)
                    }
                }
            }
            .font(.caption)
        }
    }

    private var policyURL: URL { workspace.appendingPathComponent(".lamp/module-policy.json") }

    private func writeAccessPolicy() throws {
        try FileManager.default.createDirectory(
            at: policyURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(accessPolicy).write(to: policyURL, options: .atomic)
    }

    private func loadChoices() {
        chatChoices = AgentChatOwnChoices.pinned(in: workspace, appProviderID: providerID)
    }

    private func prepareWorkspace() {
        // Before the chat pane is given a configuration to mount with, so it
        // is never built against a provider this chat is not on.
        loadChoices()
        do {
            guard let helper = AgentModuleAccessPreferences.mcpHelperExecutableURL else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "The Lamp module helper is unavailable. Rebuild or reinstall Lamp Bible to restore chat access to your library.",
                ])
            }
            let configuration = ReaderChatWorkspaceStore.configuration(
                helperExecutableURL: helper,
                libraryRootURL: libraryModel.library.rootURL,
                bundledModulesArchiveURL: Bundle.main.url(
                    forResource: "bundled_modules.db", withExtension: "zlib"
                ),
                policyURL: policyURL,
                workspace: workspace
            )
            try writeAccessPolicy()
            try ReaderChatWorkspaceStore.prepare(
                workspace: workspace,
                configuration: configuration,
                bundledSkillsCatalog: LampBundledSkills.catalogURL
            )
            self.configuration = configuration
            preparationError = nil
        } catch {
            preparationError = error.localizedDescription
        }
    }
}

/// A writing to be started from a reader chat: up to which turn, what to
/// call it, and whether there is any conversation to bring.
private struct WritingFromChat: Identifiable {
    let id = UUID()
    /// Nil for the whole conversation.
    let turn: UUID?
    let title: String
    let hasConversation: Bool
}

/// Asks before starting a writing from a chat, and says what doing so means:
/// a copy, made once, after which the two conversations are separate.
private struct StartWritingFromChatSheet: View {
    let request: WritingFromChat
    let start: (String) -> Void
    let cancel: () -> Void
    @State private var title: String

    init(request: WritingFromChat, start: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        self.start = start
        self.cancel = cancel
        _title = State(initialValue: request.title)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.turn == nil ? "Start a Writing from This Chat" : "Start a Writing from Here")
                .font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmedTitle.isEmpty { start(trimmedTitle) } }
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start Writing") { start(trimmedTitle) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var explanation: String {
        guard request.hasConversation else {
            return "Nothing has been said in this chat yet, so the writing starts with an empty chat of its own."
        }
        let what = request.turn == nil
            ? "this conversation is"
            : "this conversation, up to the question you chose, is"
        return "A new writing is made and \(what) copied into its chat, where you can carry it on. "
            + "It is copied once: nothing said afterwards in either chat reaches the other, "
            + "and this chat stays as it is."
    }
}

/// A new chat, and the conversations there are to go back to.
///
/// Handed its list rather than reading one from state: see the popover that
/// presents it. A conversation open in another tab is shown and not offered,
/// since two panes writing one transcript is worse than starting a second.
private struct ReaderChatChooser: View {
    let chats: [ReaderChatWorkspaceStore.Chat]
    let inUse: Set<UUID>
    /// Where to look for words said in any chat. Nil where the list is all
    /// there is to search.
    var libraryRootURL: URL?
    let pick: (UUID?) -> Void

    /// Beyond this many, the list scrolls rather than growing the popover.
    private static let shownWhole = 6

    @State private var query = ""
    @State private var matches: [ReaderChatWorkspaceStore.Match] = []
    @State private var searching: Task<Void, Never>?

    /// A chat is found by what was said in it, not only by how it opened.
    /// The list reads by its opening line, which answers "where was that
    /// conversation about Romans 8" only when the conversation began with
    /// it — and it rarely did.
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { pick(nil) } label: {
                Label("New Chat", systemImage: "plus.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if libraryRootURL != nil {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search what was said", text: $query)
                        .textFieldStyle(.plain)
                    if isSearching {
                        Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onChange(of: query) { _, _ in runSearch() }
            }

            Divider()

            if isSearching {
                searchResults
            } else if chats.isEmpty {
                // Said rather than left blank, so the list looks the same
                // whether or not there is anything in it yet.
                VStack(alignment: .leading, spacing: 3) {
                    Text("No chats to go back to")
                    Text(
                        """
                        Conversations you have here are kept, and listed \
                        for as long as AI & Agents settings say.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if chats.count <= Self.shownWhole {
                // Laid out plainly, so the popover takes its height from the
                // rows themselves. A `ScrollView` has no ideal height to
                // offer, and one here stood at nothing until it had been
                // measured — which is after the popover has taken its size.
                rows
            } else {
                ScrollView { rows }
                    .frame(height: 360)
            }
        }
        .frame(width: 320)
    }

    /// Searched off the main actor, a moment after the typing stops.
    ///
    /// Every chat's transcripts are decoded for a search, which is over a
    /// second for a couple of hundred chats; run on each keystroke, on the
    /// main actor, that is typing that stops while it works.
    private func runSearch() {
        searching?.cancel()
        guard let libraryRootURL, isSearching else {
            matches = []
            return
        }
        let wanted = query
        searching = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            // The scan itself is cancelled, not merely its result
            // discarded: it reads every transcript, and several of those
            // running at once because the typing paused is the cost this
            // was moved off the main actor to avoid.
            let scan = Task.detached(priority: .userInitiated) {
                ReaderChatWorkspaceStore.search(wanted, libraryRootURL: libraryRootURL)
            }
            let found = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, wanted == query else { return }
            matches = found
        }
    }

    @ViewBuilder private var searchResults: some View {
        if matches.isEmpty {
            Text("Nothing said in any chat matches that.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            let list = VStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { match in
                    Button { pick(match.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.snippet)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                // Whose words these are, because finding
                                // your own question and finding the answer
                                // to it are different findings.
                                Text(match.saidByReader ? "You" : "Reply")
                                if let lastSpoken = match.lastSpoken {
                                    Text("·")
                                    Text(lastSpoken.formatted(.relative(presentation: .named)))
                                }
                                if inUse.contains(match.id) {
                                    Text("·")
                                    Text("Open in another tab")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(inUse.contains(match.id))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if match.id != matches.last?.id { Divider().padding(.leading, 12) }
                }
            }
            if matches.count <= Self.shownWhole {
                list
            } else {
                ScrollView { list }.frame(height: 360)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chats, id: \.id) { chat in
                row(chat)
                if chat.id != chats.last?.id { Divider().padding(.leading, 12) }
            }
        }
    }

    @ViewBuilder private func row(_ chat: ReaderChatWorkspaceStore.Chat) -> some View {
        let elsewhere = inUse.contains(chat.id)
        Button { pick(chat.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.opening ?? "Nothing said yet")
                    .lineLimit(2)
                    .foregroundStyle(chat.opening == nil ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let lastSpoken = chat.lastSpoken {
                        Text(lastSpoken.formatted(.relative(presentation: .named)))
                    }
                    if elsewhere { Text("Open in another tab") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(elsewhere)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Which chat each open tab is on.
///
/// A reader chat lasts as long as its transcript, not as long as the tab that
/// opened it: a tab remembers the one it was on and takes it up again, and any
/// other is chosen from the list. Held only for this run of the app, to keep
/// two tabs off one conversation — two views of one transcript, each writing
/// it, is worse than opening a new one.
@MainActor
enum OpenReaderChats {
    private static var held: Set<UUID> = []

    /// The chats open in some tab right now, for a list to show as in use and
    /// for a scrub to leave alone.
    static var inUse: Set<UUID> { held }

    /// Takes up a chat already in the library — remembered by a tab, or picked
    /// from the list — and says whether it was free to take.
    ///
    /// A chat another tab holds is refused rather than shared, and a chat that
    /// is no longer on disk is refused too: a scrub may have taken it while
    /// the tab that remembered it sat closed.
    static func take(_ id: UUID, libraryRootURL: URL) -> Bool {
        guard !held.contains(id) else { return false }
        let workspace = ReaderChatWorkspaceStore.workspaceURL(
            libraryRootURL: libraryRootURL, chatID: id
        )
        guard FileManager.default.fileExists(atPath: workspace.path) else { return false }
        held.insert(id)
        return true
    }

    /// A conversation of its own for a tab that has none, its workspace made
    /// so there is somewhere for the chat to be.
    ///
    /// Called when the pane is opened, never when a tab is made: a tab nobody
    /// chats in should leave nothing behind in the library.
    static func start(libraryRootURL: URL) -> UUID {
        let id = UUID()
        held.insert(id)
        try? FileManager.default.createDirectory(
            at: ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: libraryRootURL, chatID: id),
            withIntermediateDirectories: true
        )
        return id
    }

    static func release(_ id: UUID) {
        held.remove(id)
    }
}

/// The letting go of old chats, which belongs to the launch rather than to a
/// window.
///
/// Done once, by whichever window reads the library first, and never again
/// while the app runs: a chat removed mid-run could be one a tab is about to
/// take up from its saved identifier, or one being read in a window that has
/// not finished opening. Nothing is lost by waiting for the next launch.
@MainActor
enum ReaderChatHousekeeping {
    private static var done = false

    /// - Returns: the chats that went, for a caller that wants to say so.
    @discardableResult
    static func letGoOfOldChats(libraryRootURL: URL) -> [UUID] {
        guard !done else { return [] }
        done = true
        return ReaderChatWorkspaceStore.scrub(
            libraryRootURL: libraryRootURL,
            retention: ReaderChatWorkspaceStore.Retention.chosen(),
            heldBy: OpenReaderChats.inUse
        )
    }
}

/// Which tab session each open window is on.
///
/// The window's tabs are kept under it, and it is taken up again at the next
/// launch, which is how a window comes back to what it was reading. Separate
/// from the chats since a chat belongs to a tab: one window holds one session
/// and as many conversations as it has tabs with the pane opened.
@MainActor
enum OpenReaderWindows {
    private static var held: Set<UUID> = []

    /// - Returns: the session this window keeps its tabs under, and whether it
    ///   is picking up where the app left off — true when no other window held
    ///   one, which is what a launch looks like, and a lone window being
    ///   opened again. Only then are the last window's tabs a fallback.
    static func claim(defaults: UserDefaults = ReaderTabSessionStore.store) -> (session: UUID, resuming: Bool) {
        let resuming = held.isEmpty
        let id = ReaderTabSessionStore.claimingSession(
            from: ReaderTabSessionStore.sessions(defaults: defaults), heldBy: held
        ) ?? UUID()
        held.insert(id)
        return (id, resuming)
    }

    static func release(_ id: UUID) {
        held.remove(id)
    }
}

/// What each message is sent with besides the chapter, said where the
/// reader can see it before sending: the chat being told of a selection or a
/// note should never be a surprise.
private struct ReaderChatAttachmentsLine: View {
    enum PersonalStudy {
        case notShared
        case shared(notedVerses: Int, highlights: Int)
    }

    @ObservedObject var selection: ReaderTextSelectionStore
    let selectedVerse: String?
    let personalStudy: PersonalStudy

    private var parts: [String] {
        var parts: [String] = []
        if let passage = selection.current {
            parts.append("Selection: \(passage.reference)")
        } else if let selectedVerse {
            parts.append(selectedVerse)
        }
        switch personalStudy {
        case .notShared:
            parts.append("notes and highlights not shared")
        case .shared(0, 0):
            parts.append("no notes or highlights here")
        case .shared(let notedVerses, let highlights):
            var counts: [String] = []
            if notedVerses > 0 { counts.append(notedVerses == 1 ? "1 note" : "\(notedVerses) notes") }
            if highlights > 0 { counts.append(highlights == 1 ? "1 highlight" : "\(highlights) highlights") }
            parts.append("your " + counts.joined(separator: ", "))
        }
        return parts
    }

    private var help: String {
        var help = "Each message is sent with the chapter, the verse marked in the reader"
        help += ", any text selected in it"
        switch personalStudy {
        case .notShared:
            help += ". Your notes and highlights are not, because personal study content is off in AI & Agents settings."
        case .shared:
            help += ", and your own notes and highlights in the chapter."
        }
        if let passage = selection.current {
            help += "\n\nSelected: “\(passage.text.prefix(300))\(passage.text.count > 300 ? "…" : "")”"
        }
        return help
    }

    var body: some View {
        Label(parts.joined(separator: " · "), systemImage: "paperclip")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(help)
    }
}

/// The text selected in the reader, as the reader chat is told it.
///
/// One selection across the reader, as there is one in a document: each
/// paragraph is its own text view, and each keeps its own selection, so
/// selecting in one clears the one before. Told only of the reader's own
/// selecting; see `ReaderTextView.setSelectedRanges`.
@MainActor
final class ReaderTextSelectionStore: ObservableObject {
    @Published private(set) var selection: ReaderSelectedPassage?
    private weak var holder: NSTextView?

    /// The selection, while the text it was made in is still on screen. A
    /// chapter left, or text scrolled far enough away to be put away, takes
    /// its selection with it, as it does from sight.
    var current: ReaderSelectedPassage? {
        holder?.window == nil ? nil : selection
    }

    func textView(_ textView: NSTextView, selected passage: ReaderSelectedPassage?) {
        let previous = holder
        holder = passage == nil ? nil : textView
        if let previous, previous !== textView {
            previous.setSelectedRange(NSRange(location: previous.selectedRange().location, length: 0))
        }
        if selection != passage { selection = passage }
    }
}

private struct ReaderTextSelectionKey: EnvironmentKey {
    static let defaultValue: ReaderTextSelectionStore? = nil
}

extension EnvironmentValues {
    var readerTextSelection: ReaderTextSelectionStore? {
        get { self[ReaderTextSelectionKey.self] }
        set { self[ReaderTextSelectionKey.self] = newValue }
    }
}
