import Foundation
import LampCore
import LampModuleKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

/// One writing turn, the same wherever it is asked from: the writing's own
/// window, or a paired phone (`AgentRemoteHost`). How the writing's
/// workspace is made ready, what each message is sent with, and how what the
/// agent wrote reaches the writing — recorded in its history under the turn,
/// and marked for review where the writer keeps marks.
///
/// The window watches its workspace and takes the agent's draft in as it
/// lands. A turn nobody has a window open on is taken in by `collect`, which
/// asks the same reconciler the same question: a turn from the phone gets
/// the same history, the same undo and the same marks as one asked at the
/// Mac.
@MainActor
enum WritingChatTurns {
    /// What the check before an OpenCode writing turn found
    /// (`checkOpenCode`).
    enum OpenCodeCheck: Equatable {
        case clear
        /// Settings Lamp can't vouch for, not yet approved.
        case unapproved([AgentTerminalLaunchCheck.Finding])
        /// It couldn't check, or couldn't put Lamp's own files back.
        case refused(String)
    }

    /// Checks a writing's settings before an OpenCode turn, as before a
    /// Terminal opens (`decisions/0043`). OpenCode reads its project settings
    /// from the writing's folder and every folder above it, again at each
    /// request, and documents no way to be told not to; another provider's
    /// agent in the writing could have written them. Lamp's own files are
    /// written again whole, then what OpenCode reads is scanned, and anything
    /// Lamp can't vouch for is put to the person; the answers are the
    /// Terminal's, held per writing by the same fingerprints.
    ///
    /// Clear, it is noted against the turns begun so far, and the chat's
    /// send checks that nothing began since (`KeptAgentChats.takeOpenCodeCheck`).
    static func checkOpenCode(in workspace: URL) async -> OpenCodeCheck {
        // Counted before anything is looked at, so a turn begun while the
        // check runs makes it stale.
        let generation = KeptAgentChats.turnsBegun(in: workspace)
        // A Terminal's agent writes while it runs, and OpenCode rereads its
        // settings at every request.
        if AgentTerminalHolds.shared.hasTerminal(in: workspace) {
            return .refused("OpenCode wasn’t started: a Terminal session is open in this writing. End it, then send again.")
        }
        // Nor while any chat's agent is at work in it, OpenCode's own turn
        // from another pane included: it could change what is checked here
        // and finish before the send looks.
        if KeptAgentChats.isRunning(in: workspace) {
            return .refused("OpenCode wasn’t started: another chat is answering in this writing. Send it again when that has finished.")
        }
        let lampServer = mcpConfiguration(forWorkspace: workspace)
        if let lampServer {
            do {
                try await DevotionalAgentWorkspaceStore.restoreProviderFiles(in: workspace, configuration: lampServer)
            } catch {
                return .refused("Lamp didn’t start OpenCode: \(error.localizedDescription)")
            }
        }
        let scanned = await DevotionalAgentWorkspaceStore.openCodeScan(in: workspace, lampServer: lampServer)
        let above = await Task.detached(priority: .userInitiated) {
            AgentTerminalLaunchCheck.openCodeAncestorFindings(of: workspace)
        }.value
        let findings = scanned.findings.filter(AgentTerminalLaunchCheck.openCodeReads) + above
        if let unchecked = findings.first(where: \.isIncomplete) {
            return .refused("Lamp didn’t start OpenCode: it couldn’t check all of what OpenCode reads in this writing (\(unchecked.detail)).")
        }
        // Answers for what this check looked at and found gone are let go, so
        // a setting removed and put back is asked about again.
        AgentTerminalLaunchCheck.keepApprovals(onlyFor: findings, for: workspace, inScope: { path in
            path.hasPrefix("../") || AgentTerminalLaunchCheck.openCodeScope(path)
        })
        if !findings.isEmpty, !AgentTerminalLaunchCheck.isApproved(findings, for: workspace) {
            return .unapproved(AgentTerminalLaunchCheck.unapproved(findings, for: workspace))
        }
        KeptAgentChats.noteOpenCodeChecked(in: workspace, at: generation)
        return .clear
    }

    /// The writing's workspace, set up for an agent and holding the writing
    /// as it is now: its draft, its brief, and the helper that gives the
    /// agent Lamp's modules under `policy`.
    ///
    /// On `WritingWorkspaceFiles`, which owns every writer of these files,
    /// so this cannot overlap a skill edit, a context write or a second
    /// pane's preparation. It writes the policy, the helper's configuration,
    /// the skills and the instructions — 25 to 33 ms on a fresh workspace,
    /// measured in Debug — and none of that is safe to interleave: the
    /// skills catalogue is copied, and the instructions and provider
    /// configurations are rewritten whole.
    @WritingWorkspaceFiles
    static func prepare(
        writingID: String,
        draft: String,
        context: String,
        policy: LampAgentAccessPolicy,
        libraryRootURL: URL,
        bundledModulesArchiveURL: URL?
    ) async throws -> URL {
        try prepareNow(
            writingID: writingID, draft: draft, context: context, policy: policy,
            libraryRootURL: libraryRootURL, bundledModulesArchiveURL: bundledModulesArchiveURL
        )
    }

    @WritingWorkspaceFiles
    private static func prepareNow(
        writingID: String,
        draft: String,
        context: String,
        policy: LampAgentAccessPolicy,
        libraryRootURL: URL,
        bundledModulesArchiveURL: URL?
    ) throws -> URL {
        guard let helperExecutableURL = AgentModuleAccessPreferences.mcpHelperExecutableURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The bundled Lamp module helper is unavailable.",
            ])
        }
        let policyURL = try AgentModuleAccessPreferences.writePolicy(policy, libraryRootURL: libraryRootURL)
        let mcpConfiguration = LampAgentMCPConfiguration(
            helperExecutableURL: helperExecutableURL,
            libraryRootURL: libraryRootURL,
            bundledModulesArchiveURL: bundledModulesArchiveURL,
            policyURL: policyURL,
            // So the agent can read what changed in the writing rather than
            // keeping copies of `draft.md` to compare for itself. The path
            // is derived the same way `prepare` derives it, below.
            workspaceURL: DevotionalAgentWorkspaceStore.workspaceURL(
                libraryRootURL: libraryRootURL,
                devotionalID: writingID
            )
        )
        let workspace = try DevotionalAgentWorkspaceStore.prepare(
            libraryRootURL: libraryRootURL,
            devotionalID: writingID,
            initialDraft: draft,
            contextDocument: context,
            mcpConfiguration: mcpConfiguration
        )
        try DevotionalAgentWorkspaceStore.writeContext(context, to: workspace)
        return workspace
    }

    /// Lamp's server for the writing whose workspace is `workspace`, made as
    /// `prepare` makes it, from what Lamp knows: the helper in the app, the
    /// library the workspace sits in (`<library>/AgentWorkspaces/Writing/…`,
    /// as `LampWritingWorkspace.root` places it), its access policy and the
    /// bundled modules. Nil for a folder that is not a writing's workspace.
    static func mcpConfiguration(
        forWorkspace workspace: URL,
        helperExecutableURL: URL? = AgentModuleAccessPreferences.mcpHelperExecutableURL
    ) -> LampAgentMCPConfiguration? {
        let writing = workspace.deletingLastPathComponent()
        let workspaces = writing.deletingLastPathComponent()
        guard writing.lastPathComponent == "Writing", workspaces.lastPathComponent == "AgentWorkspaces",
              let helperExecutableURL
        else { return nil }
        let libraryRootURL = workspaces.deletingLastPathComponent()
        return LampAgentMCPConfiguration(
            helperExecutableURL: helperExecutableURL,
            libraryRootURL: libraryRootURL,
            bundledModulesArchiveURL: Bundle.main.url(forResource: "bundled_modules.db", withExtension: "zlib"),
            policyURL: AgentModuleAccessPreferences.accessPolicyURL(libraryRootURL: libraryRootURL),
            workspaceURL: workspace
        )
    }

    /// The chat on a writing's workspace: the same model its window shows,
    /// if one is open.
    static func model(provider: AIProviderCLI, workspace: URL) -> NativeAgentChatModel {
        KeptAgentChats.model(provider: provider, workspace: workspace, mode: .writing)
    }

    /// The reconciler for a writing's workspace, marking what it takes in
    /// where the writer keeps marks.
    static func reconciler(writingID: String, workspace: URL, libraryRootURL: URL) -> DevotionalAgentDraftReconciler {
        DevotionalAgentDraftReconciler(
            workspace: workspace,
            writingID: writingID,
            applicationSupportURL: LampAgentDescriptorStore.defaultApplicationSupportURL()
        )
    }

    /// Makes the marks a pass asked for, where the writer keeps marks.
    static func reviewChanges(writingID: String, libraryRootURL: URL) -> WritingReviewChanges {
        WritingReviewChanges(
            writingID: writingID, store: WritingReviewMarks.store(libraryRootURL: libraryRootURL)
        )
    }

    // MARK: - What a message is sent with

    /// A message as the provider is sent it: what the editor had open and
    /// selected, what of the writing is still marked for the writer to read,
    /// and the message.
    ///
    /// The marks are said so the agent can leave alone what the writer has
    /// already read: a change there is marked again, and read again. `note`
    /// is `reviewNote`, nil only while marks are off.
    static func prompt(for message: String, focus: WritingEditorFocus, note: String?) -> String {
        guard let note else { return focus.prompt(for: message) }
        return "\(focus.contextText)\n\n\(note)\n\nThe user's message:\n\(message)"
    }

    nonisolated static let reviewPassageLimit = 20
    nonisolated static let reviewPassageCharacters = 160

    /// Said while marks are on but what is marked is not known: before the
    /// marks file is first read, or when it cannot be. Never nothing, which
    /// the agent is told means marks are off.
    nonisolated static let unreadReviewNote = """
        The writer reads through each change you make and clears it, but Lamp has not been able to \
        read which passages are still marked: change only what the message asks for, and leave the \
        rest as it is.
        """

    /// What the agent is told of the marks in `writing`, the draft it will
    /// read: nil while marks are off, `unreadReviewNote` for a review that
    /// could not be read. The stored marks are carried into `writing` from
    /// the texts this Mac has seen (`WritingReviewTexts`), as the editor
    /// draws them, so a mark typed into since the last save is still said.
    /// Compares whole drafts, so it is for off the main actor.
    nonisolated static func reviewNote(
        _ review: LampWritingReview?, marksAreOn: Bool, in writing: String, known: [String]
    ) -> String? {
        guard marksAreOn else { return nil }
        guard let review else { return unreadReviewNote }
        let live = review.carryingToText(writing, from: known)
        return reviewNote(
            ranges: live.highlightedRanges(in: writing), in: writing,
            restorations: live.restorations
        )
    }

    /// The note from what is marked in `writing`, as the editor draws it:
    /// said only where there are marks, at most `reviewPassageLimit` of
    /// them, each shortened, since the agent can read the whole file.
    nonisolated static func reviewNote(
        ranges: [NSRange], in writing: String,
        restorations: [LampWritingReview.Restoration] = []
    ) -> String {
        let source = writing as NSString
        let passages = ranges.filter { $0.length > 0 }
        let removals = ranges.count - passages.count
        guard !passages.isEmpty || removals > 0 else {
            return [
                """
                The writer reads through each change you make and clears it. Everything in the \
                writing has been read and cleared: change only what the message asks for, and \
                leave the rest as it is.
                """,
                restorationLines(restorations),
            ].compactMap { $0 }.joined(separator: "\n")
        }
        var lines = [
            "The writer reads through each change you make and clears it. These passages of the writing are still marked as not yet read:",
        ]
        for range in passages.prefix(reviewPassageLimit) {
            let text = source.substring(with: range).replacingOccurrences(of: "\n", with: " ")
            let shown = text.count > reviewPassageCharacters
                ? String(text.prefix(reviewPassageCharacters)) + "…"
                : text
            lines.append("- \"\(shown)\"")
        }
        if passages.count > reviewPassageLimit {
            lines.append("- and \(passages.count - reviewPassageLimit) more")
        }
        if removals > 0 {
            lines.append("- and \(removals) place\(removals == 1 ? "" : "s") where words were taken out")
        }
        lines.append(
            "Everything else has been read and cleared: change it only where the message asks you to, since anything you change there is marked for the writer to read again."
        )
        if let restored = restorationLines(restorations) { lines.append(restored) }
        return lines.joined(separator: "\n")
    }

    /// What the agent is told of the marks in the documents beside the
    /// writing, each named.
    ///
    /// Without this an agent is told of the prose's marks alone and reads
    /// the rest as cleared, so it rewrites passages the writer has not
    /// looked at yet — and anything it is told without a name it takes
    /// for the writing's own, which is worse than silence: it would look
    /// for those words in the draft and not find them.
    ///
    /// Each document is its own record, read and carried as the prose's
    /// is. Nil where no document has a mark, so nothing is said of a
    /// writing whose documents are all clear.
    nonisolated static func documentReviewNotes(
        _ documents: [(name: String, review: LampWritingReview, text: String, known: [String])]
    ) -> String? {
        var lines: [String] = []
        for document in documents.sorted(by: { $0.name < $1.name }) {
            let live = document.review.carryingToText(document.text, from: document.known)
            let ranges = live.highlightedRanges(in: document.text)
            guard !ranges.isEmpty else { continue }
            let source = document.text as NSString
            let passages = ranges.filter { $0.length > 0 }
            let removals = ranges.count - passages.count
            lines.append("In \(document.name), these are still marked as not yet read:")
            for range in passages.prefix(reviewPassageLimit) {
                let text = source.substring(with: range).replacingOccurrences(of: "\n", with: " ")
                let shown = text.count > reviewPassageCharacters
                    ? String(text.prefix(reviewPassageCharacters)) + "…"
                    : text
                lines.append("- \"\(shown)\"")
            }
            if passages.count > reviewPassageLimit {
                lines.append("- and \(passages.count - reviewPassageLimit) more")
            }
            if removals > 0 {
                lines.append("- and \(removals) place\(removals == 1 ? "" : "s") where words were taken out")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    nonisolated static let restorationLimit = 10

    /// What the writer has lately put back, which nothing else here says.
    ///
    /// A mark says what the assistant changed and has not been read. A
    /// change the writer put back leaves no mark at all — the passage is
    /// theirs again, read — so without this the assistant would make the
    /// same change next turn, and mark it again, as often as the writer
    /// undid it. Nil where there is nothing to say.
    nonisolated static func restorationLines(
        _ restorations: [LampWritingReview.Restoration]
    ) -> String? {
        // Only while it is news. A restore is told so the assistant does
        // not make the same change again on the turns just after it; an
        // old one says nothing about this turn, and a record that reached
        // this device late should not reopen it.
        let since = Date().addingTimeInterval(-LampWritingReview.restorationWindow)
        let recent = restorations.filter { $0.restoredAt >= since }
            .sorted { $0.restoredAt > $1.restoredAt }
        guard !recent.isEmpty else { return nil }
        var lines = [
            "The writer has put their own wording back where you had changed these, so leave them as they stand unless the message asks for them:",
        ]
        for restoration in recent.prefix(restorationLimit) {
            let back = shortened(restoration.restored)
            let gone = shortened(restoration.discarded)
            if back.isEmpty {
                lines.append("- took out \"\(gone)\", which you had put in")
            } else if gone.isEmpty {
                lines.append("- put \"\(back)\" back, which you had taken out")
            } else {
                lines.append("- \"\(back)\" again, in place of your \"\(gone)\"")
            }
        }
        if recent.count > restorationLimit {
            lines.append("- and \(recent.count - restorationLimit) more")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func shortened(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > reviewPassageCharacters else { return flat }
        return String(flat.prefix(reviewPassageCharacters)) + "…"
    }

    // MARK: - Taking a turn in

    // MARK: - Whether a window has the writing

    /// The writings a window is open on, and how many.
    private static var watchers: [String: Int] = [:]

    /// Says a window is open on the writing, for as long as the watch lasts.
    ///
    /// A window keeps its draft level with the editor's live text, which the
    /// library holds only once the autosave lands, a second and a half
    /// later. Run against the library's copy meanwhile, `begin` would put
    /// the older text back into the draft and the window would take it,
    /// losing what was just typed; `collect` would read the window's typing
    /// as the writing moving and file the agent's work away. The window's
    /// own preparation and poll do this work against its live text, so
    /// while one is open both leave it to the window.
    static func watch(writingID: String) -> WritingWatch {
        watchers[writingID, default: 0] += 1
        return WritingWatch(writingID: writingID)
    }

    static func isWatched(_ writingID: String) -> Bool {
        (watchers[writingID] ?? 0) > 0
    }

    /// The copy each open editor holds of each writing, one hold per editor.
    private static var holds: [ObjectIdentifier: (writingID: String, revision: Date, digest: String?)] = [:]

    /// Said by an editor for as long as it holds a copy of a writing, and
    /// said again after each save: the copy's `lastModified`, and its
    /// digest (`LampAgentRemoteWritingRevision.digest(of:)`).
    static func hold(_ writingID: String, revision: Date, digest: String?) -> WritingHold {
        let hold = WritingHold()
        holds[ObjectIdentifier(hold)] = (writingID, revision, digest)
        return hold
    }

    fileprivate static func update(_ hold: WritingHold, revision: Date, digest: String?) {
        guard let held = holds[ObjectIdentifier(hold)] else { return }
        holds[ObjectIdentifier(hold)] = (held.writingID, revision, digest)
    }

    fileprivate static func release(_ hold: WritingHold) {
        holds[ObjectIdentifier(hold)] = nil
    }

    /// The oldest copy of a writing any open editor holds, or nil where none
    /// does. A turn asked on a newer copy than this would have the agent edit
    /// an older draft, which that editor then saves over the newer. Stored
    /// dates are whole seconds, while a save says its own to the fraction, so
    /// compare to the second, and by digest where the seconds agree.
    static func watched(_ writingID: String) -> (revision: Date, digest: String?)? {
        holds.values.filter { $0.writingID == writingID }
            .min { $0.revision < $1.revision }
            .map { ($0.revision, $0.digest) }
    }

    /// Every copy of a writing the open editors hold, one for each. Two
    /// editors can hold different bodies dated the same second, and no one
    /// date stands for both: a turn is to be checked against each.
    static func watchedCopies(_ writingID: String) -> [(revision: Date, digest: String?)] {
        holds.values.filter { $0.writingID == writingID }
            .map { ($0.revision, $0.digest) }
            .sorted { $0.revision < $1.revision }
    }

    /// The oldest revision any open editor holds of a writing.
    static func watchedRevision(_ writingID: String) -> Date? {
        watched(writingID)?.revision
    }

    fileprivate static func unwatch(_ writingID: String) {
        guard let count = watchers[writingID] else { return }
        watchers[writingID] = count > 1 ? count - 1 : nil
    }

    /// Brings the writing's draft level with the writing before a turn no
    /// window is watching, as a window does when it opens: the writing may
    /// have moved since — edited on the phone and synced here — and an agent
    /// given the older draft would edit what is no longer there. Call it
    /// after `prepare` and before sending.
    ///
    /// What a run that outlived its window left in the draft is taken in
    /// here too, under `turnID`, and saved as the writing.
    @discardableResult
    static func begin(
        writingID: String, turnID: UUID?, libraryModel: LibraryModel
    ) async throws -> DevotionalAgentDraftReconciler.Outcome {
        guard !isWatched(writingID) else { return .unchanged }
        let (writing, workspace, root) = try located(writingID, in: libraryModel)
        let current = writing.displayMarkdown
        let pass = try await reconciler(writingID: writingID, workspace: workspace, libraryRootURL: root)
            .prepare(writing: current, turnID: turnID)
        var taking: String?
        if case .take(let draft) = pass.outcome, draft != current { taking = draft }
        // The marks, then the save, with nothing awaited between them: a
        // save reserved after them saved the draft's text and runs after,
        // and one reserved before saved what came before it. See
        // `DevotionalAgentDraftReconciler.ReviewChange`.
        reviewChanges(writingID: writingID, libraryRootURL: root).make(pass.reviewChanges)
        if let taking {
            try await save(taking, as: writing, in: libraryModel)
        }
        return pass.outcome
    }

    /// Takes in what a turn wrote to the writing's draft when no window is
    /// watching it, and saves it as the writing: recorded in the history
    /// under `turnID`, and marked for review where the writer keeps marks.
    ///
    /// The same reconciler a window asks, so a window opened on the writing
    /// meanwhile finds the work already accounted for, and one already open
    /// takes the text up rather than recording it a second time.
    ///
    /// Only the agent's own writing is saved. A window's `.adopt` — the
    /// draft and its mark agree, the writing does not — means another
    /// window wrote it, whose own save will follow; here, with none, it is
    /// as likely the writing moved under a draft nobody touched, by an edit
    /// synced in from the phone, and saving the draft would put that edit
    /// back. So it is left, and the next `begin` levels the draft instead.
    /// Where the writing moved and the agent wrote too, the writer's words
    /// stay and the agent's draft goes to the history, as it does in a
    /// window when both sides moved.
    @discardableResult
    static func collect(
        writingID: String, turnID: UUID?, libraryModel: LibraryModel
    ) async throws -> DevotionalAgentDraftReconciler.Outcome {
        guard !isWatched(writingID) else { return .unchanged }
        let (writing, workspace, root) = try located(writingID, in: libraryModel)
        let current = writing.displayMarkdown
        let pass = try await reconciler(writingID: writingID, workspace: workspace, libraryRootURL: root)
            .reconcileUnwatched(writing: current, turnID: turnID)
        var taking: String?
        if case .take(let draft) = pass.outcome, draft != current { taking = draft }
        // The marks, then the save, with nothing awaited between them: a
        // save reserved after them saved the draft's text and runs after,
        // and one reserved before saved what came before it. See
        // `DevotionalAgentDraftReconciler.ReviewChange`.
        reviewChanges(writingID: writingID, libraryRootURL: root).make(pass.reviewChanges)
        if let taking {
            try await save(taking, as: writing, in: libraryModel)
        }
        return pass.outcome
    }

    private static func located(
        _ writingID: String, in libraryModel: LibraryModel
    ) throws -> (LampDevotional, URL, URL) {
        let root = libraryModel.library.rootURL
        guard let writing = libraryModel.devotionals.first(where: { $0.id == writingID }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "That writing isn't on this Mac."])
        }
        return (writing, DevotionalAgentWorkspaceStore.workspaceURL(libraryRootURL: root, devotionalID: writingID), root)
    }

    private static func save(_ draft: String, as writing: LampDevotional, in libraryModel: LibraryModel) async throws {
        let body = try await storedBody(
            markdown: draft, originalJSON: writing.contentJSON,
            originalPlainContent: writing.content, bodyChanged: true
        )
        // Its marks are anchored in the draft, so they are carried from it.
        try await libraryModel.savePersonalDevotional(writing.replacingBody(body), reviewTexts: [draft])
    }

    // MARK: - The writing's brief and body

    /// The brief the agent reads beside the draft, from the writing's own
    /// fields.
    static func contextDocument(for writing: LampDevotional) -> String {
        contextDocument(
            title: writing.title, subtitle: writing.subtitle ?? "", author: writing.author ?? "",
            date: writing.date ?? "", category: writing.category ?? "",
            tags: writing.tags.joined(separator: ", "),
            seriesName: writing.seriesName ?? "", seriesOrder: writing.seriesOrder ?? 1,
            keyScriptures: writing.keyScriptures, summary: writing.summary ?? "",
            footnotes: writing.footnotes ?? ""
        )
    }

    /// The brief, from fields as an editor holds them.
    static func contextDocument(
        title: String, subtitle: String, author: String, date: String, category: String,
        tags: String, seriesName: String, seriesOrder: Int, keyScriptures: [LampScriptureLink],
        summary: String, footnotes: String
    ) -> String {
        let scriptureList = keyScriptures.isEmpty
            ? "- None selected"
            : keyScriptures.map { "- \($0.displayDescription)" }.joined(separator: "\n")
        let tagList = tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : tags
        return """
        # Devotional brief

        - Title: \(title.isEmpty ? "Untitled" : title)
        - Subtitle: \(subtitle.isEmpty ? "None" : subtitle)
        - Author: \(author.isEmpty ? "Unknown" : author)
        - Date: \(date)
        - Category: \(LampWritingCategory.displayName(category) ?? "None")
        - Tags: \(tagList)
        - Series: \(seriesName.isEmpty ? "None" : "\(seriesName), item \(seriesOrder)")

        ## Key scripture

        \(scriptureList)

        ## Summary or intent

        \(summary.isEmpty ? "No summary has been written yet." : summary)

        ## Existing footnotes

        \(footnotes.isEmpty ? "No footnotes have been written yet." : footnotes)
        """ + "\n"
    }

    /// A writing's body as it will be stored: the Markdown projected back
    /// into the rich JSON it came from, where there is any, and the plain text
    /// the library searches.
    ///
    /// Worked out off the main actor. Projecting a talk-length manuscript back
    /// into its JSON costs about twenty milliseconds on a Release build —
    /// measured on nine thousand words — and it used to run on the keystroke
    /// thread every time the autosave landed, which is what the writer felt as
    /// the editor hesitating. `Task { }` on its own is no help here: a view is
    /// main-isolated, so everything it starts stays on the main thread unless
    /// it is detached.
    static func storedBody(
        markdown: String,
        originalJSON: String?,
        originalPlainContent: String,
        bodyChanged: Bool
    ) async throws -> StoredWritingBody {
        guard bodyChanged else {
            return StoredWritingBody(
                contentJSON: originalJSON,
                plainContent: originalJSON == nil ? markdown : originalPlainContent
            )
        }
        guard let originalJSON else {
            return StoredWritingBody(contentJSON: nil, plainContent: markdown)
        }
        return try await Task.detached(priority: .userInitiated) {
            // JSON that is only a carrier for Markdown has nothing structured
            // to keep, so the writing itself is the body.
            guard LampPortableDevotionalMedia.plainMarkdown(from: originalJSON) == nil else {
                return StoredWritingBody(contentJSON: nil, plainContent: markdown)
            }
            let json = try LampPortableDevotionalContent.replacingMarkdown(
                markdown, in: originalJSON
            )
            return StoredWritingBody(
                contentJSON: json,
                plainContent: LampPortableDevotionalContent.plainText(from: json) ?? ""
            )
        }.value
    }
}

/// A window's claim on a writing (`WritingChatTurns.watch`), ended when the
/// window goes. Ended once; a second end does nothing.
@MainActor
final class WritingWatch {
    let writingID: String
    private var ended = false

    fileprivate init(writingID: String) {
        self.writingID = writingID
    }

    func end() {
        guard !ended else { return }
        ended = true
        WritingChatTurns.unwatch(writingID)
    }
}

/// An editor's claim on the copy of a writing it holds
/// (`WritingChatTurns.hold`), updated as it saves and given up as it goes.
@MainActor
final class WritingHold {
    func update(revision: Date, digest: String?) {
        WritingChatTurns.update(self, revision: revision, digest: digest)
    }

    func release() {
        WritingChatTurns.release(self)
    }
}

struct StoredWritingBody: Sendable {
    let contentJSON: String?
    let plainContent: String
}

private extension LampDevotional {
    /// The same writing with a new body, saved now.
    func replacingBody(_ body: StoredWritingBody) -> LampDevotional {
        LampDevotional(
            id: id, moduleID: moduleID, moduleName: moduleName, title: title, subtitle: subtitle,
            author: author, date: date, tags: tags, category: category, seriesName: seriesName,
            seriesOrder: seriesOrder, keyScriptures: keyScriptures, summary: summary,
            content: body.plainContent, contentJSON: body.contentJSON, footnotes: footnotes,
            mediaJSON: mediaJSON, created: created, lastModified: Date(), isEditable: isEditable
        )
    }
}
