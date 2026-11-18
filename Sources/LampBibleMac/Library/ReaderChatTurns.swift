import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

/// How a reader chat is made ready and what each of its turns is sent with:
/// the access policy, the chat's workspace and helper configuration, and the
/// passage being read. One place for both the reader chat pane and a paired
/// phone, so a turn is sent the same way whichever of them sent it.
@MainActor
enum ReaderChatTurns {
    // MARK: - The chat

    /// The provider a reader chat is on: its own pinned choice, else the
    /// app's.
    static func provider(chatChoices: AgentChatChoices, appDefault: String) -> AIProviderCLI {
        AIProviderCLI(
            rawValue: chatChoices.value(for: AgentChatChoices.providerKey, orAppDefault: appDefault) ?? appDefault
        ) ?? .codex
    }

    /// The app's choice of provider for reader chats.
    static var appProviderID: String {
        UserDefaults.standard.string(forKey: "reader.chat.provider") ?? AIProviderCLI.codex.rawValue
    }

    /// What reader chats may reach, by the AI & Agents settings.
    ///
    /// Reader research used to span the whole installed library whatever the
    /// Module Access scope said, on the grounds that research wants breadth.
    /// But the scope exists so the reader decides, a module may be hidden for
    /// privacy rather than tidiness, and Settings offers it as one choice over
    /// agents with nothing to say a reader chat is exempt.
    static func accessPolicy(
        moduleAccessEnabled: Bool,
        moduleAccessScope: String,
        personalContentEnabled: Bool,
        libraryModel: LibraryModel
    ) -> LampAgentAccessPolicy {
        AgentModuleAccessPreferences.policy(
            isEnabled: moduleAccessEnabled,
            scope: AgentModuleAccessScope(rawValue: moduleAccessScope) ?? .enabledModules,
            includesPersonalContent: personalContentEnabled,
            modules: libraryModel.modules,
            hiddenModuleIDs: libraryModel.hiddenModuleIDs
        )
    }

    /// The same, read from the settings as they stand: for a turn sent with
    /// no pane to hold them.
    static func currentAccessPolicy(libraryModel: LibraryModel) -> LampAgentAccessPolicy {
        let defaults = UserDefaults.standard
        return accessPolicy(
            moduleAccessEnabled: defaults.object(forKey: "agent.moduleAccess.enabled") as? Bool ?? true,
            moduleAccessScope: defaults.string(forKey: "agent.moduleAccess.scope")
                ?? AgentModuleAccessScope.enabledModules.rawValue,
            personalContentEnabled: defaults.object(forKey: "agent.moduleAccess.personal") as? Bool ?? false,
            libraryModel: libraryModel
        )
    }

    static func policyURL(workspace: URL) -> URL {
        workspace.appendingPathComponent(".lamp/module-policy.json")
    }

    static func writeAccessPolicy(_ policy: LampAgentAccessPolicy, workspace: URL) throws {
        let url = policyURL(workspace: workspace)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(policy).write(to: url, options: .atomic)
    }

    /// Makes a reader chat's workspace ready and returns the configuration
    /// its helper runs with: before a chat is mounted or sent to, so it is
    /// never run against another chat's files.
    static func prepare(
        workspace: URL,
        policy: LampAgentAccessPolicy,
        libraryRootURL: URL
    ) throws -> LampAgentMCPConfiguration {
        guard let helper = AgentModuleAccessPreferences.mcpHelperExecutableURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The Lamp module helper is unavailable. Rebuild or reinstall Lamp Bible to restore chat access to your library.",
            ])
        }
        let configuration = ReaderChatWorkspaceStore.configuration(
            helperExecutableURL: helper,
            libraryRootURL: libraryRootURL,
            bundledModulesArchiveURL: Bundle.main.url(
                forResource: "bundled_modules.db", withExtension: "zlib"
            ),
            policyURL: policyURL(workspace: workspace),
            workspace: workspace
        )
        try writeAccessPolicy(policy, workspace: workspace)
        try ReaderChatWorkspaceStore.prepare(
            workspace: workspace,
            configuration: configuration,
            bundledSkillsCatalog: LampBundledSkills.catalogURL
        )
        return configuration
    }

    // MARK: - A turn

    /// What a message is sent with that can be read from the reader at once.
    /// The reader's notes are read from the library after, by `notes(on:)`.
    struct Capture {
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

    /// A chapter being read, in a translation, with the verse chosen in it
    /// and any words selected, as a turn is sent with it.
    static func capture(
        book: LampTranslationBook,
        chapter: Int,
        translation: LampInstalledModule,
        selectedVerse: Int?,
        selection: ReaderChatContext.Selection?,
        chapterVerses: [LampVerse],
        policy: LampAgentAccessPolicy,
        libraryModel: LibraryModel
    ) -> Capture {
        let inChapter = { (reference: Int) in
            reference / 1_000 == book.id * 1_000 + chapter
        }
        let sharesPersonalStudy = ReaderChatContext.sharesPersonalStudy(under: policy)
        return Capture(
            reference: "\(book.name) \(chapter)",
            translationID: translation.id,
            translationName: translation.name,
            selectedVerse: selectedVerse.flatMap { reference in
                inChapter(reference)
                    ? LampBibleReferenceFormatter.describeRange(from: reference, to: reference)
                    : nil
            },
            selection: selection,
            sharesPersonalStudy: sharesPersonalStudy,
            highlights: sharesPersonalStudy
                ? personalHighlights(
                    in: translation.id, verses: chapterVerses, libraryModel: libraryModel, where: inChapter
                )
                : [],
            noteReferences: sharesPersonalStudy
                ? libraryModel.noteReferences.filter(inChapter).sorted()
                : []
        )
    }

    /// The reader's own highlights in the chapter, with the words each marks:
    /// the chapter and translation the turn is about, which by the time a
    /// queued question is sent need not be the library's.
    private static func personalHighlights(
        in translationID: String,
        verses chapterVerses: [LampVerse],
        libraryModel: LibraryModel,
        where inChapter: @escaping (Int) -> Bool
    ) -> [ReaderChatContext.Highlight] {
        let verses = Dictionary(
            chapterVerses.map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
        return libraryModel.highlightsByReference.keys.filter(inChapter).sorted().flatMap { reference in
            libraryModel.personalHighlights(for: reference, in: translationID).map { highlight in
                ReaderChatContext.Highlight(
                    reference: LampBibleReferenceFormatter.describeRange(from: reference, to: reference),
                    color: highlight.color.map(colorName),
                    style: styleName(highlight.style),
                    words: verses[reference].flatMap { words(of: highlight, in: $0) }
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
    static func notes(on references: [Int], libraryModel: LibraryModel) async -> [ReaderChatContext.Note] {
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
}
