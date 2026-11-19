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
    /// The writing's workspace, set up for an agent and holding the writing
    /// as it is now: its draft, its brief, and the helper that gives the
    /// agent Lamp's modules under `policy`.
    ///
    /// On the main actor, for now, which is what keeps it from overlapping
    /// anything else that writes the same files. It writes the policy, the
    /// helper's configuration, the skills and the instructions — 25 to 33 ms
    /// on a fresh workspace, measured in Debug — and nothing about that work
    /// is safe to interleave: the skills catalogue is copied, the
    /// instructions and provider configurations rewritten whole, and the
    /// context, the brief and a skill edit write the same files from the
    /// pane's own actions. One writing can be open in two panes, and a
    /// phone's turn is a third caller.
    ///
    /// Asynchronous so that moving it off the main actor changes no caller:
    /// that wants one actor owning every writer of a workspace's files, not
    /// just this one, or the race comes back through the others.
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
            applicationSupportURL: LampAgentDescriptorStore.defaultApplicationSupportURL(),
            reviewStore: WritingReviewMarks.store(libraryRootURL: libraryRootURL)
        )
    }

    // MARK: - What a message is sent with

    /// A message as the provider is sent it: what the editor had open and
    /// selected, what of the writing is still marked for the writer to read,
    /// and the message.
    ///
    /// The marks are said so the agent can leave alone what the writer has
    /// already read: a change there is marked again, and read again. Said
    /// only where there are marks, and at most `reviewPassageLimit` of them,
    /// each shortened, since the agent can read the whole file.
    static func prompt(
        for message: String, focus: WritingEditorFocus, review: LampWritingReview?, writing: String
    ) -> String {
        guard let note = reviewNote(review, in: writing) else { return focus.prompt(for: message) }
        return "\(focus.contextText)\n\n\(note)\n\nThe user's message:\n\(message)"
    }

    static let reviewPassageLimit = 20
    static let reviewPassageCharacters = 160

    static func reviewNote(_ review: LampWritingReview?, in writing: String) -> String? {
        guard let review else { return nil }
        let source = writing as NSString
        let passages = review.highlightedRanges(in: writing).filter { $0.length > 0 }
        let removals = review.highlightedRanges(in: writing).count - passages.count
        guard !passages.isEmpty || removals > 0 else {
            return """
                The writer reads through each change you make and clears it. Everything in the \
                writing has been read and cleared: change only what the message asks for, and \
                leave the rest as it is.
                """
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
        return lines.joined(separator: "\n")
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

    /// The stored version of each writing an editor last loaded or saved.
    private static var revisions: [String: Date] = [:]

    /// Said by the editor as it loads a writing and after each save: the
    /// `lastModified` of the copy it now holds.
    static func noteRevision(_ revision: Date?, of writingID: String) {
        revisions[writingID] = revision
    }

    /// The stored version the window watching a writing holds, or nil if no
    /// window watches it or none was said. A turn asked on a newer copy than
    /// this would have the agent edit the window's older draft, which the
    /// window then saves over the newer. Stored dates are whole seconds,
    /// while a save says its own to the fraction, so compare to the second.
    static func watchedRevision(_ writingID: String) -> Date? {
        isWatched(writingID) ? revisions[writingID] : nil
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
        let outcome = try reconciler(writingID: writingID, workspace: workspace, libraryRootURL: root)
            .prepare(writing: current, turnID: turnID)
        if case .take(let draft) = outcome, draft != current {
            try await save(draft, as: writing, in: libraryModel)
        }
        return outcome
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
        let outcome = try reconciler(writingID: writingID, workspace: workspace, libraryRootURL: root)
            .reconcileUnwatched(writing: current, turnID: turnID)
        if case .take(let draft) = outcome, draft != current {
            try await save(draft, as: writing, in: libraryModel)
        }
        return outcome
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
        try await libraryModel.savePersonalDevotional(writing.replacingBody(body))
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
