import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

struct ReaderChatSidebarView: View {
    @EnvironmentObject private var libraryModel: LibraryModel
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
    let close: () -> Void

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
        guard let book = libraryModel.selectedBook,
              let translation = libraryModel.selectedTranslation else { return nil }
        let chapter = libraryModel.selectedChapterNumber
        let inChapter = { (reference: Int) in
            reference / 1_000 == book.id * 1_000 + chapter
        }
        let sharesPersonalStudy = ReaderChatContext.sharesPersonalStudy(under: accessPolicy)
        let selection = libraryModel.readerTextSelection.current.map { passage in
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
            selectedVerse: libraryModel.selectedVerseReference.flatMap { reference in
                inChapter(reference)
                    ? LampBibleReferenceFormatter.describeRange(from: reference, to: reference)
                    : nil
            },
            selection: selection,
            sharesPersonalStudy: sharesPersonalStudy,
            highlights: sharesPersonalStudy
                ? personalHighlights(where: inChapter)
                : [],
            noteReferences: sharesPersonalStudy
                ? libraryModel.noteReferences.filter(inChapter).sorted()
                : []
        )
    }

    /// The reader's own highlights in the chapter, with the words each marks.
    private func personalHighlights(where inChapter: @escaping (Int) -> Bool) -> [ReaderChatContext.Highlight] {
        let verses = Dictionary(
            (libraryModel.chapter?.verses ?? []).map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
        return libraryModel.highlightsByReference.keys.filter(inChapter).sorted().flatMap { reference in
            libraryModel.personalHighlights(for: reference).map { highlight in
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
                HStack {
                    Label("Reader Chat", systemImage: "bubble.left.and.bubble.right")
                        .font(.headline)
                    Spacer()
                    Button("Close Chat", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Close reader chat")
                }

                HStack {
                    Picker("Provider", selection: providerSelection) {
                        ForEach(AIProviderCLI.allCases) { provider in
                            Text(provider.shortName).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    Spacer()
                    Label("Read-only", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // On their own line: this pane is as narrow as 364pt, and a
                // qualified model name beside the provider and the badge left
                // all three of them truncated to their first few letters.
                HStack {
                    AgentChatProviderChoice(
                        kind: .model, provider: provider, workspace: workspace,
                        chatChoices: $chatChoices
                    )
                    AgentChatProviderChoice(
                        kind: .effort, provider: provider, workspace: workspace,
                        chatChoices: $chatChoices
                    )
                    Spacer()
                }

                if let capture = capture() {
                    Label(capture.reference, systemImage: "book")
                        .font(.subheadline.weight(.medium))
                    Text(capture.translationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(capture.translationName)
                    ReaderChatAttachmentsLine(
                        selection: libraryModel.readerTextSelection,
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

                HStack(alignment: .firstTextBaseline) {
                    Text(moduleAccessDescription)
                    Spacer(minLength: 4)
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("AI provider and module access settings")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if let configuration {
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
                    // The pane is closed, swapped for Study and emptied out of
                    // sight; none of those should end the conversation in it.
                    outlivesView: true
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
        .onAppear(perform: prepareWorkspace)
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

/// Which chat each open window is on.
///
/// A reader chat lasts as long as its transcript, not as long as the window
/// that opened it, so a window takes one up rather than making one. Held only
/// for this run of the app: at launch nothing is held, and the first window to
/// open takes up the most recent conversation in the library.
@MainActor
enum OpenReaderChats {
    private static var held: Set<UUID> = []

    static func claim(libraryRootURL: URL) -> UUID {
        let id = ReaderChatWorkspaceStore.claiming(
            from: ReaderChatWorkspaceStore.chats(libraryRootURL: libraryRootURL),
            heldBy: held
        ) ?? UUID()
        held.insert(id)
        return id
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
