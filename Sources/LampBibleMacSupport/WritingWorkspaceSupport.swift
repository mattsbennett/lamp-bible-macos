import Foundation
import LampModuleKit

/// Where a writing's agent workspace lives, and what is in it.
///
/// The app has always known this; the helper now needs it too, because a tool
/// names a writing by its identifier and has to find the folder itself. The
/// derivation lives here so there is exactly one of it: two copies of a
/// path-deriving hash would not fail, they would quietly point at a different
/// folder, and the symptom would be a writing that appears to have no
/// workspace while its workspace sits beside it under another name.
///
/// A tool names a writing by identifier and never by path, which is what keeps
/// an outside app from reaching a file of its own choosing.
public enum LampWritingWorkspace {
    public static let draftFilename = "draft.md"
    public static let contextFilename = "DEVOTIONAL_CONTEXT.md"
    public static let identifierFilename = "DEVOTIONAL_ID"

    /// `<library>/AgentWorkspaces/Writing/<folder>`.
    public static func url(libraryRootURL: URL, writingID: String) -> URL {
        root(libraryRootURL: libraryRootURL)
            .appendingPathComponent(directoryName(for: writingID), isDirectory: true)
    }

    /// `<library>/AgentWorkspaces/Writing`, where every writing's workspace
    /// is, and the one place that says so: the app, its sync and the helper
    /// all ask here.
    ///
    /// It was `AgentWorkspaces/Devotionals` until writing was renamed with
    /// sync's bundle format 4, and the first ask in each process moves an
    /// earlier library's folder (`moveEarlierFolder`), so nothing that finds
    /// a workspace can look before the move.
    public static func root(libraryRootURL: URL, fileManager: FileManager = .default) -> URL {
        let workspaces = libraryRootURL.appendingPathComponent("AgentWorkspaces", isDirectory: true)
        let root = workspaces.appendingPathComponent("Writing", isDirectory: true)
        moveEarlierFolder(
            from: workspaces.appendingPathComponent("Devotionals", isDirectory: true), to: root,
            fileManager: fileManager
        )
        return root
    }

    /// One move at a time in this process, held for the whole of it, so no
    /// caller is handed the new folder while the old is still being moved
    /// into it.
    private static let moving = NSLock()

    /// Moves `AgentWorkspaces/Devotionals` to `AgentWorkspaces/Writing` by
    /// renaming it, which keeps every file and the context files' hard links
    /// as they are. Where both are there, each workspace the new folder lacks
    /// is moved in, and one in both is left where it was rather than merged:
    /// nothing is deleted. The old folder goes only once it is empty, by a
    /// removal that refuses a folder anything was written into meanwhile. A
    /// symbolic link is never followed.
    ///
    /// Asked on every call, at the cost of one look for the old folder, so a
    /// move that failed is tried again, and a folder that appears later, from
    /// an older Lamp or a restore, is moved too. Never throws.
    static func moveEarlierFolder(from old: URL, to new: URL, fileManager: FileManager) {
        func isFolder(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard isFolder(old) else { return }
        moving.lock()
        defer { moving.unlock() }
        guard isFolder(old) else { return }
        if !fileManager.fileExists(atPath: new.path) {
            try? fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fileManager.moveItem(at: old, to: new)) != nil { return }
        }
        guard isFolder(new),
              let workspaces = try? fileManager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
        else { return }
        for workspace in workspaces where workspace.lastPathComponent != ".DS_Store" {
            let destination = new.appendingPathComponent(workspace.lastPathComponent, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: workspace, to: destination)
        }
        guard let left = try? fileManager.contentsOfDirectory(atPath: old.path),
              left.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? fileManager.removeItem(at: old.appendingPathComponent(".DS_Store"))
        // `rmdir` removes only an empty folder.
        _ = old.withUnsafeFileSystemRepresentation { $0.map { rmdir($0) } }
    }

    /// A folder name from an identifier, by core's rule, which the phone
    /// names a writing's documents' folder by too. A stored format: see
    /// `LampWritingWorkspaceLayout.directoryName(for:)`.
    public static func directoryName(for identifier: String) -> String {
        LampWritingWorkspaceLayout.directoryName(for: identifier)
    }

    /// Whether this writing has a workspace at all.
    ///
    /// A writing that has never been opened in its agent pane has none, and
    /// one is not made here: scaffolding a workspace means writing the context
    /// document and the agent instructions as Lamp writes them, which is Lamp's
    /// to do and cannot be done well while Lamp is closed.
    public static func exists(
        libraryRootURL: URL,
        writingID: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let draft = url(libraryRootURL: libraryRootURL, writingID: writingID)
            .appendingPathComponent(draftFilename)
        return fileManager.fileExists(atPath: draft.path)
    }

    /// A writing that has a workspace, as a tool reports it.
    public struct Listed: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        /// The draft's first heading, or its first line of prose. Lamp keeps
        /// the authoritative title in the library; this is what the draft
        /// itself says, which is what an agent about to edit it should match.
        public let title: String?
        public let draftCharacters: Int
        public let hasContext: Bool
        public let changedAt: Date?
    }

    /// Every writing with a workspace, newest change first.
    ///
    /// Read from the folders rather than from the library, because having a
    /// workspace is exactly what makes a writing reachable by these tools, and
    /// the folder is what decides that. Each one records its own writing's
    /// identifier, so no name has to be derived backwards out of a folder.
    public static func listed(
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) -> [Listed] {
        let root = root(libraryRootURL: libraryRootURL, fileManager: fileManager)
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var writings: [Listed] = []
        for folder in folders {
            let draft = folder.appendingPathComponent(draftFilename)
            guard fileManager.fileExists(atPath: draft.path),
                  let identifier = try? String(
                      contentsOf: folder.appendingPathComponent(identifierFilename),
                      encoding: .utf8
                  ).trimmingCharacters(in: .whitespacesAndNewlines),
                  !identifier.isEmpty
            else { continue }
            let text = (try? String(contentsOf: draft, encoding: .utf8)) ?? ""
            writings.append(Listed(
                id: identifier,
                title: title(ofDraft: text),
                draftCharacters: text.count,
                hasContext: fileManager.fileExists(
                    atPath: folder.appendingPathComponent(contextFilename).path
                ),
                changedAt: LampFileModification.date(of: draft)
            ))
        }
        return writings.sorted {
            ($0.changedAt ?? .distantPast) > ($1.changedAt ?? .distantPast)
        }
    }

    /// The draft's own title: its first Markdown heading, else its first line
    /// with words in it.
    public static func title(ofDraft draft: String) -> String? {
        for line in draft.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? nil : heading
            }
            return trimmed
        }
        return nil
    }

    public static func readDraft(
        libraryRootURL: URL,
        writingID: String
    ) throws -> String {
        try String(
            contentsOf: url(libraryRootURL: libraryRootURL, writingID: writingID)
                .appendingPathComponent(draftFilename),
            encoding: .utf8
        )
    }

    /// The context document Lamp wrote for the agent, when there is one. Absent
    /// rather than an error: a workspace without one is usable.
    public static func readContext(
        libraryRootURL: URL,
        writingID: String
    ) -> String? {
        try? String(
            contentsOf: url(libraryRootURL: libraryRootURL, writingID: writingID)
                .appendingPathComponent(contextFilename),
            encoding: .utf8
        )
    }
}

/// What the writing editor has open and selected, as the writing chat is
/// told it.
///
/// A Chat message is sent with it. A Terminal session is handed it with each
/// message by a hook (see `AgentTerminalLaunchPlanner.contextCommand`), which
/// reads it from `stateURL(in:)`, where the editor keeps it current.
public struct WritingEditorFocus: Equatable, Sendable {
    /// The file, from the workspace: `draft.md` for the writing's own prose.
    public var documentPath: String
    /// What the editor calls it: "Main Prose", or the file's name.
    public var documentName: String
    public var isVisual: Bool
    public var selectedText: String?
    /// Where the selection is, by line, on the Markdown surface. The visual
    /// editor shows no lines.
    public var selectedLines: ClosedRange<Int>?

    public init(
        documentPath: String,
        documentName: String,
        isVisual: Bool,
        selectedText: String? = nil,
        selectedLines: ClosedRange<Int>? = nil
    ) {
        self.documentPath = documentPath
        self.documentName = documentName
        self.isVisual = isVisual
        self.selectedText = selectedText.flatMap { $0.isEmpty ? nil : $0 }
        self.selectedLines = selectedLines
    }

    /// The Markdown surface, from its text and selection. Nothing is counted
    /// unless something is selected, so a caret moving as the writer types
    /// costs nothing.
    public static func markdown(
        documentPath: String,
        documentName: String,
        text: String,
        selection: NSRange
    ) -> WritingEditorFocus {
        let string = text as NSString
        let range = NSIntersectionRange(selection, NSRange(location: 0, length: string.length))
        guard range.length > 0 else {
            return WritingEditorFocus(documentPath: documentPath, documentName: documentName, isVisual: false)
        }
        func line(at location: Int) -> Int {
            string.substring(to: location).utf16.lazy.filter { $0 == 0x0A }.count + 1
        }
        let first = line(at: range.location)
        let last = line(at: NSMaxRange(range) - 1)
        return WritingEditorFocus(
            documentPath: documentPath,
            documentName: documentName,
            isVisual: false,
            selectedText: string.substring(with: range),
            selectedLines: first...last
        )
    }

    /// The most of a selection the chat is sent. The agent can read the file.
    static let maximumSelectionCharacters = 8_000

    public var contextText: String {
        let surface = isVisual ? "the visual editor" : "the Markdown editor"
        var lines = [
            "Lamp's writing editor, as it was when this message was sent:",
            "Open: `\(documentPath)` (\(documentName)), in \(surface).",
        ]
        guard let selectedText else {
            lines.append("Nothing is selected.")
            return lines.joined(separator: "\n")
        }
        if let selectedLines {
            let place = selectedLines.count == 1
                ? "line \(selectedLines.lowerBound)"
                : "lines \(selectedLines.lowerBound)–\(selectedLines.upperBound)"
            lines.append("Selected, \(place) as the editor has it:")
        } else {
            lines.append("Selected, as the visual editor shows it (without its Markdown marks):")
        }
        let shown = selectedText.count > Self.maximumSelectionCharacters
            ? String(selectedText.prefix(Self.maximumSelectionCharacters))
                + "… (the selection runs on; the file has the rest)"
            : selectedText
        lines.append("\"\"\"\n\(shown)\n\"\"\"")
        return lines.joined(separator: "\n")
    }

    /// A Chat message as the provider is sent it.
    public func prompt(for message: String) -> String {
        "\(contextText)\n\nThe user's message:\n\(message)"
    }

    /// Where the editor keeps this for a Terminal session to be handed.
    /// Under `.lamp`, which sync leaves alone and Lamp does not open as a tab.
    public static func stateURL(in workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".lamp", isDirectory: true)
            .appendingPathComponent("editor.md")
    }

    /// What `stateURL(in:)` holds: this, and after it what of the writing is
    /// still marked for the writer to read (`reviewNote`, nil while marks
    /// are off). A Terminal session is told the marks only from here, as a
    /// Chat message is told them with the message.
    public func stateText(reviewNote: String? = nil) -> String {
        guard let reviewNote else { return contextText + "\n" }
        return "\(contextText)\n\n\(reviewNote)\n"
    }

    public func write(to workspace: URL, reviewNote: String? = nil) throws {
        let url = Self.stateURL(in: workspace)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try stateText(reviewNote: reviewNote).write(to: url, atomically: true, encoding: .utf8)
    }
}

/// When a file or folder last changed, read from the file system each time.
///
/// A URL's resource values are kept on the URL once read, so asking the same
/// URL again answers from that, however the file has changed since: four
/// thousand writes in a row read back one date. Every check of whether
/// something moved reads through here, so a URL kept and asked again, now or
/// after a later change, still sees the file as it is.
public enum LampFileModification {
    public static func date(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Lamp's own record of its chats — reader chats and writings' assistant
/// chats — for an agent asked about another conversation.
///
/// Read from Lamp's transcripts, whichever provider carried each chat, so
/// asking works the same from every provider and never touches a CLI's own
/// session files. Chats are personal, so the tools that use this answer to
/// the same setting as personal writing.
///
/// Self-contained, because the helper's own build compiles this file and
/// not the chat stores: it reads Lamp's transcript files with a decoder of
/// its own, and `LampAgentChatHistoryTests` writes them with the real store
/// so the two cannot drift apart unnoticed.
public enum LampAgentChatHistory {
    /// Where `AgentChatTranscriptStore` keeps a workspace's transcripts and
    /// how it names them, and where reader chats' workspaces are.
    static let transcriptFolder = ".lamp"
    static let transcriptPrefix = "native-chat-"
    static let readerFolder = "AgentWorkspaces/Reader"

    private struct StoredTranscript: Decodable {
        struct Message: Decodable {
            let role: String
            let text: String
            let date: Date
        }
        let messages: [Message]
    }
    public struct Summary: Codable, Equatable, Sendable {
        /// `reader:<id>` or `writing:<writing id>`: what `read_chat` takes.
        public let chatID: String
        public let kind: String
        /// How the reader would know it: a reader chat by its opening
        /// question, a writing's chat by the writing's title.
        public let title: String
        public let providers: [String]
        public let messageCount: Int
        public let lastSpoken: Date?
        /// The chat this question is being asked in.
        public let isThisChat: Bool

        // In the tools' own spelling: `read_chat` takes a `chat_id`.
        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id", kind, title, providers
            case messageCount = "message_count", lastSpoken = "last_spoken", isThisChat = "is_this_chat"
        }
    }

    public struct Line: Codable, Equatable, Sendable {
        public let role: String
        public let text: String
        public let date: Date
    }

    public struct Reading: Codable, Equatable, Sendable {
        public let chatID: String
        public let title: String
        public let provider: String
        public let providers: [String]
        public let totalMessages: Int
        /// Where `messages` starts in the conversation, counted from its
        /// first message; ask again with a smaller offset for earlier ones.
        public let offset: Int
        public let messages: [Line]

        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id", title, provider, providers
            case totalMessages = "total_messages", offset, messages
        }
    }

    public enum Failure: Error, Equatable {
        case unknownChat(String)
        case noSuchProvider(String)
    }

    /// The longest a single message is given back, so one long reply can't
    /// crowd out the rest of the window.
    static let longestMessage = 4000

    public static func list(
        libraryRootURL: URL,
        thisReaderChat: UUID? = nil,
        thisWorkspace: URL? = nil,
        kind: String? = nil,
        limit: Int = 30
    ) -> [Summary] {
        var summaries: [Summary] = []
        if kind == nil || kind == "reader" {
            let folder = libraryRootURL.appendingPathComponent(readerFolder, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                guard let id = UUID(uuidString: name) else { continue }
                let transcripts = transcripts(in: folder.appendingPathComponent(name, isDirectory: true))
                guard !transcripts.isEmpty else { continue }
                summaries.append(Summary(
                    chatID: "reader:\(id.uuidString)",
                    kind: "reader",
                    title: opening(of: transcripts) ?? "Reader chat",
                    providers: transcripts.map(\.provider),
                    messageCount: transcripts.reduce(0) { $0 + $1.transcript.messages.count },
                    lastSpoken: transcripts.compactMap { $0.transcript.messages.last?.date }.max(),
                    isThisChat: id == thisReaderChat
                ))
            }
        }
        if kind == nil || kind == "writing" {
            for writing in LampWritingWorkspace.listed(libraryRootURL: libraryRootURL) {
                let workspace = LampWritingWorkspace.url(libraryRootURL: libraryRootURL, writingID: writing.id)
                let transcripts = transcripts(in: workspace)
                guard !transcripts.isEmpty else { continue }
                summaries.append(Summary(
                    chatID: "writing:\(writing.id)",
                    kind: "writing",
                    title: writing.title ?? "Untitled writing",
                    providers: transcripts.map(\.provider),
                    messageCount: transcripts.reduce(0) { $0 + $1.transcript.messages.count },
                    lastSpoken: transcripts.compactMap { $0.transcript.messages.last?.date }.max(),
                    isThisChat: thisWorkspace.map {
                        $0.standardizedFileURL.path == workspace.standardizedFileURL.path
                    } ?? false
                ))
            }
        }
        return Array(summaries.sorted {
            ($0.lastSpoken ?? .distantPast) > ($1.lastSpoken ?? .distantPast)
        }.prefix(max(1, limit)))
    }

    /// A window of one chat's conversation with one provider: by default the
    /// most recent messages, or from `offset` counted from the first.
    public static func read(
        chatID: String,
        provider: String? = nil,
        libraryRootURL: URL,
        offset: Int? = nil,
        limit: Int = 30
    ) throws -> Reading {
        guard let workspace = workspace(for: chatID, libraryRootURL: libraryRootURL) else {
            throw Failure.unknownChat(chatID)
        }
        let transcripts = transcripts(in: workspace)
        guard !transcripts.isEmpty else { throw Failure.unknownChat(chatID) }
        let chosen: (provider: String, transcript: StoredTranscript)
        if let provider {
            guard let match = transcripts.first(where: { $0.provider == provider }) else {
                throw Failure.noSuchProvider(provider)
            }
            chosen = match
        } else {
            // The provider spoken with last, when the reader doesn't say.
            chosen = transcripts.max {
                ($0.transcript.messages.last?.date ?? .distantPast) < ($1.transcript.messages.last?.date ?? .distantPast)
            }!
        }
        let messages = chosen.transcript.messages
        let size = min(max(1, limit), 100)
        let start = min(max(0, offset ?? max(0, messages.count - size)), messages.count)
        let window = messages[start..<min(messages.count, start + size)]
        return Reading(
            chatID: chatID,
            title: title(chatID: chatID, libraryRootURL: libraryRootURL, transcripts: transcripts),
            provider: chosen.provider,
            providers: transcripts.map(\.provider),
            totalMessages: messages.count,
            offset: start,
            messages: window.map { message in
                Line(
                    role: message.role,
                    text: message.text.count > longestMessage
                        ? String(message.text.prefix(longestMessage)) + " …"
                        : message.text,
                    date: message.date
                )
            }
        )
    }

    /// The workspace a chat ID names, or nil when it names none. Reader
    /// chats by a UUID, writings by an identifier the writing workspaces
    /// list, so no caller can steer this at an arbitrary folder.
    static func workspace(for chatID: String, libraryRootURL: URL) -> URL? {
        if chatID.hasPrefix("reader:"), let id = UUID(uuidString: String(chatID.dropFirst("reader:".count))) {
            return libraryRootURL.appendingPathComponent(readerFolder, isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        }
        if chatID.hasPrefix("writing:") {
            let writingID = String(chatID.dropFirst("writing:".count))
            guard LampWritingWorkspace.listed(libraryRootURL: libraryRootURL).contains(where: { $0.id == writingID })
            else { return nil }
            return LampWritingWorkspace.url(libraryRootURL: libraryRootURL, writingID: writingID)
        }
        return nil
    }

    private static func title(
        chatID: String, libraryRootURL: URL,
        transcripts: [(provider: String, transcript: StoredTranscript)]
    ) -> String {
        if chatID.hasPrefix("writing:") {
            let writingID = String(chatID.dropFirst("writing:".count))
            return LampWritingWorkspace.listed(libraryRootURL: libraryRootURL)
                .first { $0.id == writingID }?.title ?? "Untitled writing"
        }
        return opening(of: transcripts) ?? "Reader chat"
    }

    /// The first thing the reader said, over every provider's transcript.
    private static func opening(of transcripts: [(provider: String, transcript: StoredTranscript)]) -> String? {
        transcripts.flatMap(\.transcript.messages)
            .filter { $0.role == "user" }.min { $0.date < $1.date }
            .map { String($0.text.prefix(120)) }
    }

    /// Each provider's transcript in a workspace that holds any messages.
    private static func transcripts(in workspace: URL) -> [(provider: String, transcript: StoredTranscript)] {
        let folder = workspace.appendingPathComponent(transcriptFolder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(transcriptPrefix) && $0.hasSuffix(".json") }.sorted().compactMap { name in
            let provider = String(name.dropFirst(transcriptPrefix.count).dropLast(".json".count))
            // A provider name of letters, digits, hyphens and underscores,
            // as the store writes them.
            guard !provider.isEmpty, provider.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let transcript = try? JSONDecoder().decode(StoredTranscript.self, from: data),
                  !transcript.messages.isEmpty
            else { return nil }
            return (provider, transcript)
        }
    }
}
