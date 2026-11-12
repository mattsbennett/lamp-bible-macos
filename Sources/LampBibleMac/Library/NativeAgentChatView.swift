import AppKit
import Combine
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI
import SwiftyChat

enum AgentSessionDisplayMode: String, CaseIterable, Identifiable {
    case native
    case terminal

    var id: Self { self }

    var title: String {
        switch self {
        case .native: "Chat"
        case .terminal: "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .native: "bubble.left.and.bubble.right"
        case .terminal: "terminal"
        }
    }
}

extension AIProviderCLI {
    var supportsBrowserAuthentication: Bool { self != .openCode }

    var authenticationArguments: [String] {
        switch self {
        case .codex: ["login"]
        case .claude: ["auth", "login"]
        case .openCode: ["auth", "login"]
        }
    }

    var wireProvider: AgentChatWireProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .openCode: .openCode
        }
    }
}

struct AgentCLIProcessResult: Sendable {
    let exitCode: Int32
    let output: String
    let launchError: String?
}

final class AgentCLIProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?

    /// Runs the provider, handing `onLine` each line of its output as it
    /// arrives. `onLine` is called off the main thread, in the order the lines
    /// came, and the whole output is still returned at the end: what a run is
    /// judged by has not changed, only when a pane can see it.
    func run(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> AgentCLIProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: runSynchronously(
                    executableName: executableName,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    onLine: onLine
                ))
            }
        }
    }

    func cancel() {
        lock.lock()
        let process = activeProcess
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func runSynchronously(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> AgentCLIProcessResult {
        do {
            let executableURL = try resolveExecutable(named: executableName)
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = output
            process.standardError = output
            // Without this the child inherits Lamp's own stdin, and
            // `codex exec` announces "Reading additional input from stdin…"
            // and blocks on it forever — the chat pane spinning with no reply.
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            // As a shell would. OpenCode takes its project from `PWD`, and
            // Lamp's own may name another directory entirely — in which case
            // `opencode run --session` waits forever on a session it can't see.
            environment["PWD"] = workingDirectory.path
            process.environment = environment

            lock.lock()
            activeProcess = process
            lock.unlock()
            defer {
                lock.lock()
                if activeProcess === process { activeProcess = nil }
                lock.unlock()
            }

            try process.run()
            // Read the pipe as it fills rather than at the end. Reading to the
            // end of the file first is what left a chat with nothing to show
            // but its spinner: every event had already happened by the time
            // anything was parsed.
            let handle = output.fileHandleForReading
            var collected = Data()
            var reader = AgentChatLineReader()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected += chunk
                guard let onLine else { continue }
                for line in reader.lines(from: chunk) { onLine(line) }
            }
            if let onLine, let last = reader.flush() { onLine(last) }
            process.waitUntilExit()
            return AgentCLIProcessResult(
                exitCode: process.terminationStatus,
                output: String(decoding: collected, as: UTF8.self),
                launchError: nil
            )
        } catch {
            return AgentCLIProcessResult(exitCode: -1, output: "", launchError: error.localizedDescription)
        }
    }

    /// The major version the installed CLI reports, or nil when it will not
    /// say. Asked once per executable for the app's run: a CLI does not change
    /// under a running app, and this is a process launch per chat message
    /// otherwise.
    func majorVersion(ofExecutableNamed name: String) -> Int? {
        Self.versionLock.lock()
        let known = Self.versionsByName[name]
        Self.versionLock.unlock()
        if let known { return known }
        guard let url = try? resolveExecutable(named: name) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let major = AgentChatCLIVersion.major(
            fromVersionOutput: String(decoding: data, as: UTF8.self)
        )
        Self.versionLock.lock()
        Self.versionsByName[name] = major
        Self.versionLock.unlock()
        return major
    }

    // Shared across runners — a reader chat and a writing chat each have their
    // own — so it is guarded. Two chats answering at once would otherwise be
    // writing this dictionary from two threads.
    private nonisolated(unsafe) static var versionsByName: [String: Int?] = [:]
    private static let versionLock = NSLock()

    private func resolveExecutable(named name: String) throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v \(name)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0,
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "\(name) is not installed or is not available in your login shell.",
            ])
        }
        return URL(fileURLWithPath: path)
    }
}

private struct NativeAgentChatUser: ChatUser {
    let id: String
    let userName: String
    let avatar: PlatformImage?
    let avatarURL: URL? = nil

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// An agent's reply, carried whole so the bubble can render it as Markdown and
/// the transcript can still read back what was said.
///
/// SwiftyChat's `.text` kind holds a plain `String`, which is why a reply full
/// of fenced code and lists arrived on screen as characters. `.custom` carries
/// this instead, and the cell registered below draws it.
struct AgentMessageContent {
    let markdown: String
}

/// A reply while it is still arriving, held by reference.
///
/// Replacing the message in the array for each new fragment leaves the chat
/// unscrollable: SwiftyChat measures a row when it first draws it and keeps
/// that height when the same message is replaced, so a reply that grew from
/// one line to a page was drawn at its full height inside a scroll view that
/// still thought it was one line tall. Nothing could reach the rest of it
/// until something else rebuilt the list. Watching one object instead leaves
/// `messages` untouched while the reply arrives, and the row measures itself
/// as it grows.
final class StreamingAgentMessage: ObservableObject {
    @Published var markdown: String

    init(markdown: String = "") {
        self.markdown = markdown
    }
}

/// What the person typed. Lamp draws it rather than SwiftyChat, whose text cell
/// can't be selected.
struct PersonMessageContent {
    let text: String
}

private struct NativeAgentChatMessage: ChatMessage {
    let id: UUID
    let user: NativeAgentChatUser
    let messageKind: ChatMessageKind
    let isSender: Bool
    let date: Date

    /// The message as written: Markdown for the agent's replies.
    var text: String? {
        switch messageKind {
        case .text(let value):
            value
        case .custom(let payload):
            // A reply still arriving has no text here on purpose: the
            // transcript is written from what a finished run said, and a
            // half-written reply must never be mistaken for one.
            (payload as? AgentMessageContent)?.markdown ?? (payload as? PersonMessageContent)?.text
        default:
            nil
        }
    }
}

/// What the running reply is doing, in a line under the header.
///
/// The steps are the provider's own, read from its event stream: a tool call
/// with the passage or query it was given, a thinking block, the reply being
/// written. A chat that shows only a spinner leaves a reader wondering whether
/// a long audit is working or hung, and these are the same steps the CLI's own
/// interface shows.
private struct AgentActivityLine: View {
    let activity: AgentChatActivity

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 16, height: 14)
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The summary is already cut to a line's worth, and cut from
                // the end a path is read from, so what is left is read
                // left to right.
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(summary)
    }

    private var symbol: String {
        switch activity {
        case .thinking: "bubble.left.and.text.bubble.right"
        case .toolStarted, .tool: "wrench.and.screwdriver"
        case .toolFinished: "ellipsis"
        case .writing: "text.append"
        }
    }

    /// The thinking blocks arrive with their text empty, so a thinking step
    /// can only be reported as one. Saying how big it is, where the provider
    /// estimates that, at least distinguishes a long think from a stall.
    private var summary: String {
        switch activity {
        case .thinking(let estimatedTokens):
            if let estimatedTokens {
                "Thinking… (about \(estimatedTokens) tokens)"
            } else {
                "Thinking…"
            }
        case .toolStarted(let name):
            "\(AgentChatToolDescription.label(for: name))…"
        case .tool(let name, let summary):
            if let summary {
                "\(AgentChatToolDescription.label(for: name)) — \(summary)"
            } else {
                AgentChatToolDescription.label(for: name)
            }
        case .toolFinished:
            "Working…"
        case .writing:
            "Writing the reply…"
        }
    }
}

/// A reply, set on the page rather than in a bubble.
///
/// The way Claude's and ChatGPT's own apps set an answer: the person's words
/// sit in a bubble, and the reply is the page. Boxed, a reply in a pane this
/// narrow lost a fifth of its width to the bubble's border and padding, and
/// a long answer became a tall grey slab.
///
/// Shared by the finished reply and the one still arriving, so the words do
/// not move when the last fragment lands and the message is replaced by the
/// run's own reading of its output.
private struct AgentReplyBubble: View {
    let markdown: String

    var body: some View {
        AgentMarkdownMessageView(markdown: markdown)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.vertical, 6)
            .modifier(CopyableMessage(text: markdown))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
    }
}

/// The same bubble, watching a reply that is still arriving.
private struct StreamingAgentReplyBubble: View {
    @ObservedObject var content: StreamingAgentMessage

    var body: some View {
        AgentReplyBubble(markdown: content.markdown)
            .background { ChatScrollOvershootGuard(length: content.markdown.utf16.count) }
    }
}

/// Keeps the chat from scrolling past its end while a reply grows.
///
/// SwiftyChat lists its messages in a lazy stack anchored at the bottom. As
/// the reply grows, the stack re-estimates the rows above it that it has
/// put away, and the content can come out shorter than the place it is
/// scrolled to: the whole pane went blank part way through a long reply, and
/// came back only when the pane was rebuilt (user, 2026-11-05). In a harness
/// with a 6,000-character history, the view stood wholly past the end by
/// 4,900 characters of reply; with this, never.
///
/// It moves the view only when it is past the end, and only as far back as
/// the end, so a reader who has scrolled up to read is left where they are.
/// It lives in the arriving reply, so it acts only while there is one.
private struct ChatScrollOvershootGuard: NSViewRepresentable {
    /// Changes as the reply does, which is when to look.
    let length: Int

    func makeNSView(context: Context) -> OvershootGuardView { OvershootGuardView() }

    func updateNSView(_ view: OvershootGuardView, context: Context) {
        view.clampSoon()
    }

    final class OvershootGuardView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            clampSoon()
        }

        /// After the pass that grew the reply, once the list has laid out.
        func clampSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView,
                      let document = scrollView.documentView else { return }
                let clip = scrollView.contentView
                let end = max(document.frame.height - clip.bounds.height, 0)
                guard clip.bounds.origin.y > end + 0.5 else { return }
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: end))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }
}

private enum MessageClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Puts a copy button on a message while the pointer is over it.
///
/// A message's text can be selected, but a reply's code sits in panels of its
/// own, and selecting copies what is shown rather than the Markdown written.
/// Copying the whole message needs a control of its own, and a right-click menu
/// alone would hide it — on the text itself, the menu is the text's.
///
/// The button sits on the bubble's corner, clear of the text: a reply's prose
/// is an AppKit text view, which takes any click on it before SwiftUI drawn
/// over it can, and a reply that opens with code has the code's own button
/// in that corner.
private struct CopyableMessage: ViewModifier {
    let text: String
    @State private var isHoveringMessage = false
    @State private var isHoveringButton = false
    @State private var didCopy = false

    func body(content: Content) -> some View {
        content
            .onHover { isHoveringMessage = $0 }
            .overlay(alignment: .topTrailing) {
                if isHoveringMessage || isHoveringButton || didCopy {
                    Button {
                        MessageClipboard.copy(text)
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            didCopy = false
                        }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .help(didCopy ? "Copied" : "Copy message")
                    .accessibilityLabel("Copy message")
                    .onHover { isHoveringButton = $0 }
                    // Its lower edge meets the top of the text, inside the
                    // bubble's 12-point padding.
                    .offset(x: 10, y: -10)
                }
            }
            .accessibilityAction(named: "Copy message") { MessageClipboard.copy(text) }
    }
}

/// The person's message, styled as SwiftyChat styles outgoing text but
/// selectable.
private struct PersonMessageView: View {
    let text: String

    private var bubble: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: 16,
            bottomTrailingRadius: 16,
            topTrailingRadius: 5
        )
    }

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(2)
            .textSelection(.enabled)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(bubble.fill(LampChatSurface.personBubble))
            .modifier(CopyableMessage(text: text))
            .frame(maxWidth: 520, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
            .padding(.trailing, 14)
            .padding(.vertical, 4)
    }
}

/// A tool call the reply is waiting on, put to the person: what the agent
/// wants to do, in full, and whether to let it.
private struct AgentToolApprovalCard: View {
    let request: AgentToolApprovalRequest
    let providerName: String
    let waitingCount: Int
    let answer: (AgentToolApprovalAnswer) -> Void

    var body: some View {
        let summary = AgentToolApprovalSummary.of(request)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("\(providerName) wants to \(summary.title.lowercasedFirst)", systemImage: "hand.raised")
                    .font(.callout.weight(.semibold))
                Spacer()
                if waitingCount > 1 {
                    Text("1 of \(waitingCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let detail = summary.detail {
                ScrollView {
                    Text(detail)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            if let rule = request.alwaysAllowRule {
                // Said in full, since it outlasts this chat.
                Text("Always Allow saves permission for \(rule.description) in this writing, on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Deny") { answer(.deny) }
                if let rule = request.alwaysAllowRule {
                    Button("Always Allow") { answer(.alwaysAllow(rule)) }
                        .help("Saves \(rule.ruleText) to this writing's settings")
                }
                Button("Allow") { answer(.allow) }
                    .buttonStyle(.borderedProminent)
                    .help("Allow this once")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.5)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(providerName) is asking permission")
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

private struct NativeAgentChatInputView: View {
    @Binding var message: String
    let placeholder: String
    let onCommit: (String) -> Bool

    private var canSubmit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One rounded field with Send inside it, as Messages and ChatGPT draw
    /// theirs. Send is drawn as an outline until there is something to
    /// send, so an empty field shows where to type rather than a pale
    /// button that looked broken.
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $message, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit(submit)
                .padding(.leading, 14)
                .padding(.vertical, 9)

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSubmit ? SwiftUI.Color.white : SwiftUI.Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        canSubmit ? SwiftUI.Color.accentColor : SwiftUI.Color.primary.opacity(0.07),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .disabled(!canSubmit)
            .help("Send message")
            .padding(.trailing, 6)
            .padding(.bottom, 5)
        }
        .background(
            RoundedRectangle(cornerRadius: 19)
                .fill(SwiftUI.Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19)
                .stroke(SwiftUI.Color.primary.opacity(0.13), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(LampChatSurface.conversation)
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedMessage = message
        if onCommit(submittedMessage) { message = "" }
    }
}

/// Reader chats, kept past their pane.
///
/// The reader's chat pane comes and goes: it is closed, swapped for Study, and
/// emptied while another section is shown. A conversation owned by the pane
/// went with it, and going stopped the reply it was waiting on, saving it half
/// written; the next message's agent said its last reply had never arrived
/// (user, 2026-11-05). Kept here, a pane that comes back finds the
/// conversation as it was, a reply still arriving included.
///
/// One per provider and workspace, which is one per window and provider, and
/// only for this run of the app: the transcript on disk is what lasts.
@MainActor
private enum KeptAgentChats {
    private static var models: [String: NativeAgentChatModel] = [:]

    static func model(
        provider: AIProviderCLI,
        workspace: URL,
        mode: AgentChatMode
    ) -> NativeAgentChatModel {
        let key = "\(provider.rawValue)|\(workspace.standardizedFileURL.path)"
        if let model = models[key] { return model }
        let model = NativeAgentChatModel(provider: provider, workspace: workspace, mode: mode)
        models[key] = model
        return model
    }
}

@MainActor
private final class NativeAgentChatModel: ObservableObject {
    @Published var messages: [NativeAgentChatMessage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    /// Set when a run failed at something only the provider's own interface can
    /// answer — signing in, or a first-run prompt — so the pane can offer the
    /// Terminal session rather than just reporting an exit status.
    @Published private(set) var needsProviderSetup = false
    /// Set while the conversation is being carried on from a recap rather than a
    /// resumed provider session, so it's clear why the agent may know less of it.
    @Published private(set) var continuityNotice: String?
    /// Set when a reply ended because it was stopped rather than because
    /// anything went wrong, so the pane can say so without the language — or
    /// the colour — of a failure.
    @Published private(set) var stoppedNotice: String?
    /// Tool calls the running reply is waiting on the person for, oldest
    /// first. Only a Claude writing chat asks; see `ClaudePermissionHook`.
    @Published private(set) var pendingApprovals: [AgentToolApprovalRequest] = []
    /// What the running reply is doing — thinking, a tool call, writing — for
    /// the pane to show while it does it. Cleared when the run ends. Claude
    /// only: the other providers' streams don't say, and `AgentChatWireParser`
    /// invents nothing for them.
    @Published private(set) var activity: AgentChatActivity?

    let provider: AIProviderCLI
    private let workspace: URL
    private let mode: AgentChatMode
    private let runner = AgentCLIProcessRunner()
    private let installID = LampInstallIdentity.current()
    private var sessionID: String?
    private var conversationID: UUID?
    private var conversationStartedAt: Date?
    private var didLoad = false
    /// The transcript as this chat last read or wrote it. Others write it too —
    /// sync bringing in another Mac's turns, a Terminal session's captured ones —
    /// and a difference from this is how their changes are noticed rather than
    /// overwritten.
    private var knownTranscript: AgentChatTranscript?
    /// Everything that has happened in this conversation, which is what the
    /// transcript keeps. The messages below are what is drawn; these are the
    /// record a turn can be undone or forked from.
    @State private var events: [AgentChatTranscript.Event] = []
    /// The turn being recorded: the id of the user message that began it.
    @State private var recordingTurn: UUID?
    private var knownModificationDate: Date?
    private var cancelRequested = false
    private var loadingMessageID: UUID?
    private var approvalChannel: AgentToolApprovalChannel?
    /// The reply as it arrives, and as much of it as the pane has been shown.
    /// Shown on a timer rather than per fragment: a reply arrives as hundreds
    /// of small deltas, and redrawing the transcript for each one would put
    /// that work on every one of them.
    private var streamedReply = ""
    private var shownStreamedReply = ""
    private var streamTask: Task<Void, Never>?
    /// The bubble the arriving reply is written into. One object for the run,
    /// put in the message once; see `StreamingAgentMessage`.
    private var streamingMessage: StreamingAgentMessage?

    private let person = NativeAgentChatUser(
        id: "lamp-user",
        userName: "You",
        avatar: NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
    )

    init(provider: AIProviderCLI, workspace: URL, mode: AgentChatMode) {
        self.provider = provider
        self.workspace = workspace
        self.mode = mode
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true
        knownModificationDate = transcriptModificationDate()
        show(AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace))
    }

    /// Picks up a transcript changed by something other than this chat. Cheap
    /// when nothing has: only the file's modification date is read.
    func reloadIfChangedOnDisk() {
        guard didLoad, !isRunning else { return }
        let modified = transcriptModificationDate()
        guard modified != knownModificationDate else { return }
        knownModificationDate = modified
        let onDisk = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        if onDisk != knownTranscript { show(onDisk) }
    }

    private func show(_ transcript: AgentChatTranscript) {
        knownTranscript = transcript
        events = transcript.events ?? []
        conversationID = transcript.conversationID
        conversationStartedAt = transcript.startedAt
        // A session held by another Mac — or set aside when sync merged in turns
        // it never saw — can't be resumed here. The next message carries the
        // conversation on from a recap instead.
        sessionID = transcript.resumableSessionID(forInstall: installID)
        let loading = messages.filter { $0.id == loadingMessageID }
        messages = transcript.messages.map(makeChatMessage) + loading
        continuityNotice = transcript.sessionID != nil && sessionID == nil
            ? "This chat continues from an earlier session that can’t be resumed on this Mac. \(provider.shortName) will be given a recap of the conversation."
            : nil
    }

    private func transcriptModificationDate() -> Date? {
        let url = AgentChatTranscriptStore.url(providerID: provider.rawValue, in: workspace)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func send(_ rawPrompt: String, contextualPrompt: String) async {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        // Turns from Terminal or another Mac may have arrived since this chat
        // last looked; the message carries on from them.
        reloadIfChangedOnDisk()
        errorMessage = nil
        needsProviderSetup = false
        stoppedNotice = nil
        isRunning = true
        cancelRequested = false
        // Resuming a session this Mac holds means the recap is behind us: the
        // provider has the whole conversation again. The notice stays up through
        // the reply to the recap itself, which is where it explains something.
        if sessionID != nil { continuityNotice = nil }

        let earlier = transcriptMessages()
        if earlier.isEmpty, conversationID == nil {
            conversationID = UUID()
            conversationStartedAt = Date()
        }

        let userMessage = NativeAgentChatMessage(
            id: UUID(),
            user: person,
            messageKind: .custom(PersonMessageContent(text: prompt)),
            isSender: true,
            date: Date()
        )
        messages.append(userMessage)
        recordingTurn = userMessage.id
        record(
            AgentChatTranscript.Event.said, role: .user,
            text: prompt, at: userMessage.date
        )
        let loadingID = UUID()
        loadingMessageID = loadingID
        messages.append(NativeAgentChatMessage(
            id: loadingID,
            user: agentUser,
            messageKind: .loading,
            isSender: false,
            date: Date()
        ))
        persistTranscript()

        streamTask?.cancel()
        streamTask = showReplyAsItArrives()

        let firstPrompt = sessionID == nil
            ? AgentChatContinuation.prompt(continuing: earlier, with: contextualPrompt)
            : contextualPrompt
        var outcome = await run(prompt: firstPrompt, resuming: sessionID)

        if outcome.resumedSessionID != nil,
           !cancelRequested,
           outcome.failedBeforeResponding(provider: provider.wireProvider),
           AgentChatResumeFailure.indicatesMissingSession(in: outcome.result.output) {
            // The provider no longer has this session: pruned, or kept on a Mac
            // this transcript has since left. Retrying it would fail on every
            // message from here on, so carry the conversation on from a recap.
            sessionID = nil
            continuityNotice = "The earlier \(provider.shortName) session is no longer available, so this chat continues from a recap of the conversation."
            outcome = await run(
                prompt: AgentChatContinuation.prompt(continuing: earlier, with: contextualPrompt),
                resuming: nil
            )
        }
        finish(outcome)
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        runner.cancel()
    }

    func clearConversation() {
        guard !isRunning else { return }
        // A new identity, so the clear reaches other Macs rather than being
        // undone by their copies of the conversation it replaced.
        conversationID = UUID()
        conversationStartedAt = Date()
        sessionID = nil
        messages = []
        errorMessage = nil
        continuityNotice = nil
        persistTranscript()
    }

    private var agentUser: NativeAgentChatUser {
        NativeAgentChatUser(
            id: "lamp-agent-\(provider.rawValue)",
            userName: provider.shortName,
            avatar: NSImage(systemSymbolName: provider.systemImage, accessibilityDescription: nil)
        )
    }

    private struct RunOutcome {
        let result: AgentCLIProcessResult
        let proposedSessionID: String?
        let resumedSessionID: String?

        func failedBeforeResponding(provider: AgentChatWireProvider) -> Bool {
            guard result.launchError == nil else { return false }
            let summary = AgentChatRunSummary.summarize(output: result.output, provider: provider)
            return summary.response.isEmpty && (result.exitCode != 0 || summary.failure != nil)
        }
    }

    private func run(prompt: String, resuming resumedSessionID: String?) async -> RunOutcome {
        // Each attempt shows its own progress: a run retried after a session
        // could not be resumed starts from nothing, as it does.
        streamedReply = ""
        shownStreamedReply = ""
        streamingMessage = nil
        activity = nil
        let proposedSessionID = provider == .claude && resumedSessionID == nil
            ? UUID().uuidString.lowercased() : nil
        // Without a channel the run goes ahead as before: a call its
        // permissions don't allow is denied without asking.
        let channel = provider == .claude && !mode.isReadOnly
            ? try? AgentToolApprovalChannel.makeForRun() : nil
        approvalChannel = channel
        let watching = channel.map { watchForApprovals(in: $0) }
        defer {
            watching?.cancel()
            channel?.close()
            approvalChannel = nil
            pendingApprovals = []
        }
        let wire = provider.wireProvider
        let chatChoices = AgentChatChoicesStore.load(in: workspace)
        // Through a stream rather than a task per line: separate tasks are not
        // ordered, and a reply whose fragments arrive out of order is a reply
        // with its words shuffled. Each line is parsed on the thread that read
        // it, so the main actor only applies what came of it.
        let (events, lines) = AsyncStream.makeStream(of: [AgentChatWireEvent].self)
        let absorbing = Task { @MainActor [weak self] in
            for await batch in events {
                guard let self else { return }
                self.absorb(batch)
            }
        }
        let result = await runner.run(
            executableName: provider.executable,
            arguments: AgentChatLaunchArguments.make(
                provider: wire,
                prompt: prompt,
                sessionID: resumedSessionID,
                proposedSessionID: proposedSessionID,
                mode: mode,
                permissionHookSettings: channel.map { ClaudePermissionHook.settingsJSON(for: $0) },
                // Read as the run starts rather than held on the model: the
                // picker writes straight to this chat's own choices, and a
                // chat left open while they changed would otherwise keep
                // launching the old one. This chat's choice first, so that two
                // windows on two models each run theirs, and what the app
                // remembers only where this chat has pinned nothing.
                model: chatChoices.value(
                    for: AgentChatModelChoice.defaultsKey(wire),
                    orAppDefault: UserDefaults.standard.string(
                        forKey: AgentChatModelChoice.defaultsKey(wire)
                    )
                ),
                effort: chatChoices.value(
                    for: AgentChatEffortChoice.defaultsKey(wire),
                    orAppDefault: UserDefaults.standard.string(
                        forKey: AgentChatEffortChoice.defaultsKey(wire)
                    )
                ),
                providerMajorVersion: runner.majorVersion(ofExecutableNamed: provider.executable)
            ),
            workingDirectory: workspace,
            onLine: { line in
                let parsed = AgentChatWireParser.parse(line, provider: wire)
                guard !parsed.isEmpty else { return }
                lines.yield(parsed)
            }
        )
        // Everything the run said is taken in before the run is read for what
        // it amounts to, so nothing arrives after the reply has replaced it.
        lines.finish()
        await absorbing.value
        return RunOutcome(
            result: result,
            proposedSessionID: proposedSessionID,
            resumedSessionID: resumedSessionID
        )
    }

    /// Looks for new requests a few times a second while the reply runs. The
    /// folder is read off the main thread; only a change is published.
    private func watchForApprovals(in channel: AgentToolApprovalChannel) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let pending = await Task.detached { channel.pendingRequests() }.value
                guard let self, !Task.isCancelled else { return }
                if pending != self.pendingApprovals { self.pendingApprovals = pending }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Live events from the running provider.
    ///
    /// Nothing here decides anything: the reply, the session and the failure
    /// are all read from the whole output when the run ends, which is also how
    /// a stopped or failed run is read. This is what the person sees meanwhile.
    private func absorb(_ events: [AgentChatWireEvent]) {
        for event in events {
            switch event {
            case .activity(let value):
                // Only where it changed: a run reports the same thing many
                // times a second, and a record of that is noise, not a
                // record.
                if activity != value { record(value) }
                activity = activity?.succeeded(by: value) ?? value
            case .textFragment(let text):
                streamedReply += text
            case .sessionStarted, .finalText, .failure:
                break
            }
        }
    }

    /// Puts what has arrived of the reply into the message the loader
    /// occupies, about ten times a second, so a reply reads as it is written
    /// instead of appearing whole at the end.
    private func showReplyAsItArrives() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.showStreamedReply()
            }
        }
    }

    private func showStreamedReply() {
        guard let loadingMessageID, streamedReply != shownStreamedReply else { return }
        shownStreamedReply = streamedReply
        let markdown = streamedReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return }
        if let streamingMessage {
            // The array is not touched again while the reply arrives: the cell
            // is watching this.
            streamingMessage.markdown = markdown
            return
        }
        guard let index = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        // The loader becomes the reply it was standing in for, once.
        let arriving = StreamingAgentMessage(markdown: markdown)
        streamingMessage = arriving
        messages[index] = NativeAgentChatMessage(
            id: loadingMessageID,
            user: agentUser,
            messageKind: .custom(arriving),
            isSender: false,
            date: messages[index].date
        )
    }

    /// Gives the waiting hook the person's answer.
    func answer(_ request: AgentToolApprovalRequest, with answer: AgentToolApprovalAnswer) {
        guard let approvalChannel else { return }
        do {
            try approvalChannel.answer(request.id, with: answer)
        } catch let error as AgentToolApprovalChannel.AnswerError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Could not give \(provider.shortName) your answer: \(error.localizedDescription)"
        }
        pendingApprovals.removeAll { $0.id == request.id }
    }

    private func finish(_ outcome: RunOutcome) {
        let result = outcome.result
        isRunning = false
        streamTask?.cancel()
        streamTask = nil
        activity = nil
        streamedReply = ""
        shownStreamedReply = ""
        streamingMessage = nil
        // Whatever the loader became — a partial reply, or the loader still —
        // goes, and the run's own reading of its output takes its place.
        if let loadingMessageID {
            messages.removeAll { $0.id == loadingMessageID }
        }
        loadingMessageID = nil

        let wasStopped = cancelRequested
        cancelRequested = false
        let summary = AgentChatRunSummary.summarize(
            output: result.output,
            provider: provider.wireProvider
        )
        let disposition = AgentChatRunDisposition.of(
            output: result.output,
            exitCode: result.exitCode,
            launchError: result.launchError,
            wasStopped: wasStopped,
            provider: provider.wireProvider,
            providerName: provider.shortName
        )

        // A stopped run keeps its session too. The provider recorded the
        // prompt before it was stopped, so the next message resumes from
        // there; if it was stopped before getting that far, resuming fails in
        // the one way this already recovers from — carrying on from a recap.
        if result.exitCode == 0 || wasStopped, result.launchError == nil {
            sessionID = summary.sessionID
                ?? outcome.resumedSessionID
                ?? outcome.proposedSessionID
                ?? (wasStopped ? sessionID : nil)
        }

        switch disposition {
        case .replied(let reply):
            appendAgentMarkdown(reply)
        case .stopped(let partialReply):
            if !partialReply.isEmpty { appendAgentMarkdown(partialReply) }
            stoppedNotice = partialReply.isEmpty
                ? "That reply was stopped. \(provider.shortName) still has the conversation, so your next message carries on from it."
                : "That reply was stopped partway through."
        case .failed(let failure):
            record(AgentChatTranscript.Event.failed, text: failure)
            let setupVerdict = AgentChatSetupRequirement.verdict(
                output: result.output,
                failure: failure,
                sessionID: summary.sessionID,
                exitCode: result.exitCode
            )
            // The way out is offered whenever the failure could be a prompt
            // nobody answered; it is only called one when the output says so,
            // because a network error is not a sign-in problem.
            needsProviderSetup = setupVerdict != .none
            errorMessage = setupVerdict == .indicated
                ? "\(AgentChatSetupRequirement.message(provider: provider.shortName)) \(failure)"
                : failure
            appendAgentMarkdown("I couldn\u{2019}t complete that request. \(failure)")
        case .silent(let notice):
            errorMessage = notice
            appendAgentMarkdown(notice)
        }
        persistTranscript()
        // The turn is over. What happens before the next question is the
        // app's business, not the conversation's.
        recordingTurn = nil
    }

    private func appendAgentMarkdown(_ markdown: String) {
        let id = UUID()
        let date = Date()
        messages.append(NativeAgentChatMessage(
            id: id,
            user: agentUser,
            messageKind: .custom(AgentMessageContent(markdown: markdown)),
            isSender: false,
            date: date
        ))
        // Under the same id the drawn message has, so what is written down
        // and what is on screen are the same thing rather than two readings
        // of it.
        recordSaid(id: id, role: .assistant, text: markdown, at: date)
    }

    private func makeChatMessage(_ message: AgentChatTranscript.Message) -> NativeAgentChatMessage {
        let isSender = message.role == .user
        return NativeAgentChatMessage(
            id: message.id,
            user: isSender ? person : agentUser,
            // The person typed theirs; the agent wrote Markdown.
            messageKind: isSender
                ? .custom(PersonMessageContent(text: message.text))
                : .custom(AgentMessageContent(markdown: message.text)),
            isSender: isSender,
            date: message.date
        )
    }

    /// Writes down one thing that happened, against the turn in progress.
    ///
    /// Outside a turn there is nothing to hang it on, so nothing is kept —
    /// which is right: what happens between turns is the app's, not the
    /// conversation's.
    private func record(
        _ kind: String,
        role: AgentChatTranscript.Role? = nil,
        name: String? = nil,
        text: String? = nil,
        at date: Date = Date()
    ) {
        guard let recordingTurn else { return }
        events.append(AgentChatTranscript.Event(
            id: kind == AgentChatTranscript.Event.said && role == .user ? recordingTurn : UUID(),
            turn: recordingTurn, date: date, kind: kind, role: role, name: name, text: text
        ))
    }

    /// Something said, under the id the drawn message carries.
    private func recordSaid(
        id: UUID, role: AgentChatTranscript.Role, text: String, at date: Date
    ) {
        guard let recordingTurn else { return }
        events.append(AgentChatTranscript.Event(
            id: id, turn: recordingTurn, date: date,
            kind: AgentChatTranscript.Event.said, role: role, text: text
        ))
    }

    /// One step of a run, written down as the kind of thing it was.
    ///
    /// A tool call is kept by name, because what the agent *did* is the part
    /// a reader wants afterwards. Thinking and writing are kept as activity:
    /// they say the run was alive, which is worth having when a turn is read
    /// back and worth nothing in the middle of it.
    private func record(_ step: AgentChatActivity) {
        switch step {
        case .toolStarted(let name), .tool(let name, _):
            var summary: String?
            if case .tool(_, let value) = step { summary = value }
            record(
                AgentChatTranscript.Event.tool,
                name: AgentChatToolDescription.label(for: name),
                text: summary
            )
        case .thinking:
            record(AgentChatTranscript.Event.activity, text: "Thinking")
        case .writing:
            record(AgentChatTranscript.Event.activity, text: "Writing")
        case .toolFinished:
            break
        }
    }

    private func transcriptMessages() -> [AgentChatTranscript.Message] {
        messages.compactMap { message in
            // Every kind carries the words; only the drawing differs.
            guard let text = message.text else { return nil }
            return AgentChatTranscript.Message(
                id: message.id,
                role: message.isSender ? .user : .assistant,
                text: text,
                date: message.date
            )
        }
    }

    private func persistTranscript() {
        var transcript = AgentChatTranscript(
            conversationID: conversationID,
            startedAt: conversationStartedAt,
            sessionID: sessionID,
            sessionInstallID: sessionID == nil ? nil : installID,
            messages: transcriptMessages(),
            events: events.isEmpty ? knownTranscript?.events : events
        )
        let onDisk = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        if onDisk != knownTranscript {
            // Changed elsewhere while this reply ran. Merged as sync merges two
            // Macs' copies, so neither side's turns are lost.
            transcript = AgentChatTranscriptMerge.merge(local: transcript, incoming: onDisk)
            show(transcript)
        }
        do {
            try AgentChatTranscriptStore.save(transcript, providerID: provider.rawValue, in: workspace)
            knownTranscript = transcript
            knownModificationDate = transcriptModificationDate()
        } catch {
            errorMessage = "Could not save the chat transcript: \(error.localizedDescription)"
        }
    }
}

struct NativeAgentChatView: View {
    let provider: AIProviderCLI
    let mode: AgentChatMode
    let canSend: Bool
    /// The message as the provider is to be sent it. Begun at Send, on the
    /// main actor, so what it reads of the app is read then; it may then
    /// wait, to read the library.
    let preparePrompt: (String) async throws -> String
    /// Reports whether a reply is in flight. A container that can take this
    /// view off screen needs to know: tearing it down stops the run.
    let onRunningChanged: (Bool) -> Void
    /// Whether the conversation outlives this view, so that taking the view
    /// away leaves a reply running and a new view shows it. See
    /// `KeptAgentChats`.
    let outlivesView: Bool

    @StateObject private var model: NativeAgentChatModel
    @State private var draft = ""
    @State private var scrollToBottom = false
    @State private var connectionState = AIProviderConnectionState.checking
    @State private var authenticationProvider: AIProviderCLI?
    @State private var terminalRequest: AIProviderTerminalRequest?
    @State private var showingClearConfirmation = false
    @State private var submissionError: String?
    /// A message is being prepared, between Send and the run starting.
    @State private var isPreparing = false

    init(
        provider: AIProviderCLI,
        workspace: URL,
        mode: AgentChatMode = .writing,
        canSend: Bool = true,
        preparePrompt: @escaping (String) async throws -> String = { $0 },
        onRunningChanged: @escaping (Bool) -> Void = { _ in },
        outlivesView: Bool = false
    ) {
        self.provider = provider
        self.mode = mode
        self.canSend = canSend
        self.preparePrompt = preparePrompt
        self.onRunningChanged = onRunningChanged
        self.outlivesView = outlivesView
        _model = StateObject(wrappedValue: outlivesView
            ? KeptAgentChats.model(provider: provider, workspace: workspace, mode: mode)
            : NativeAgentChatModel(provider: provider, workspace: workspace, mode: mode))
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            if let error = submissionError ?? model.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if model.needsProviderSetup {
                        Button("Set Up \(provider.shortName) in Terminal", systemImage: "terminal") {
                            terminalRequest = AIProviderTerminalRequest(
                                provider: provider,
                                title: "Set Up \(provider.name)",
                                command: provider.executable
                            )
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = model.continuityNotice {
                Label(notice, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = model.stoppedNotice {
                Label(notice, systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isRunning, let activity = model.activity {
                AgentActivityLine(activity: activity)
            }
            // Under the header, beside Stop, rather than in the chat's input
            // slot: SwiftyChat lays that out at the input's own height.
            if let request = model.pendingApprovals.first {
                AgentToolApprovalCard(
                    request: request,
                    providerName: provider.shortName,
                    waitingCount: model.pendingApprovals.count
                ) { answer in
                    model.answer(request, with: answer)
                }
            }
            Divider()
            ZStack {
                ChatView(messages: $model.messages, scrollToBottom: $scrollToBottom) {
                    NativeAgentChatInputView(
                        message: $draft,
                        placeholder: model.isRunning ? "\(provider.shortName) is working…" : "Message \(provider.shortName)"
                    ) { prompt in
                        guard !isPreparing else { return false }
                        isPreparing = true
                        // Started now, and on the main actor until it first
                        // waits, so the reader's place is read at Send and not
                        // after a navigation.
                        Task {
                            defer { isPreparing = false }
                            do {
                                let contextualPrompt = try await preparePrompt(prompt)
                                submissionError = nil
                                isPreparing = false
                                await model.send(prompt, contextualPrompt: contextualPrompt)
                                scrollToBottom = true
                            } catch {
                                submissionError = error.localizedDescription
                                // The message goes back where it was written.
                                if draft.isEmpty { draft = prompt }
                            }
                        }
                        return true
                    }
                    .disabled(!canSend || isPreparing || model.isRunning || connectionState != .connected)
                }
                // SwiftyChat gives every message its own right-click menu,
                // which hides the one selected text would have.
                .messageCellContextMenu { message in
                    if let text = message.text {
                        Button("Copy Message", systemImage: "doc.on.doc") {
                            MessageClipboard.copy(text)
                        }
                    }
                }
                .registerCustomCell { payload in
                    if let content = payload as? PersonMessageContent {
                        PersonMessageView(text: content.text)
                    } else if let content = payload as? AgentMessageContent {
                        AgentReplyBubble(markdown: content.markdown)
                    } else if let content = payload as? StreamingAgentMessage {
                        StreamingAgentReplyBubble(content: content)
                    }
                }
                .environment(\.chatStyle, chatStyle)
                // Lines scrolled up under the header fade out rather than
                // being cut through the middle of a word.
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [LampChatSurface.conversation, LampChatSurface.conversation.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 18)
                    .allowsHitTesting(false)
                }

                if connectionState != .connected || model.messages.isEmpty {
                    emptyState
                }
            }
        }
        .background(LampChatSurface.conversation)
        .task(id: provider.id) {
            model.load()
            await refreshConnectionState()
        }
        .task(id: provider.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.reloadIfChangedOnDisk()
            }
        }
        .onChange(of: model.isRunning, initial: true) { _, running in
            onRunningChanged(running)
        }
        .onDisappear {
            if !outlivesView { model.cancel() }
            onRunningChanged(false)
        }
        .sheet(item: $authenticationProvider, onDismiss: {
            Task { await refreshConnectionState() }
        }) { provider in
            AIProviderBrowserAuthenticationView(provider: provider)
        }
        .sheet(item: $terminalRequest, onDismiss: {
            Task { await refreshConnectionState() }
        }) { request in
            AIProviderAuthenticationTerminal(request: request)
        }
        .confirmationDialog(
            "Start a new \(provider.shortName) chat?",
            isPresented: $showingClearConfirmation
        ) {
            Button("New Chat", role: .destructive) {
                model.clearConversation()
            }
        } message: {
            Text("The current transcript will be removed from Lamp. Provider session history is not deleted.")
        }
    }

    private var isReaderChat: Bool {
        if case .reader = mode { return true }
        return false
    }

    private var chatHeader: some View {
        HStack(spacing: 8) {
            // The reader's pane names its provider in its own menu just
            // above; said again here it read as a second header.
            if !isReaderChat {
                Label(provider.shortName, systemImage: provider.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Label(connectionState.label, systemImage: connectionState.systemImage)
                .font(.caption)
                .foregroundStyle(connectionState.color)
            Spacer()
            if connectionState != .connected && connectionState != .checking {
                Button("Connect", systemImage: "person.badge.key") { connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if model.isRunning {
                Button("Stop", systemImage: "stop.fill") { model.cancel() }
                    .controlSize(.small)
            }
            Button("New Chat", systemImage: "square.and.pencil") {
                showingClearConfirmation = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.messages.isEmpty || model.isRunning)
            .help("Start a new chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var emptyState: some View {
        if connectionState == .checking {
            ProgressView("Checking \(provider.shortName)…")
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if connectionState != .connected {
            VStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Connect \(provider.name)")
                    .font(.headline)
                Text(connectionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Connect", systemImage: "safari") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connectionState == .notInstalled)
                if connectionState == .notInstalled {
                    Link("Open installation guide", destination: provider.documentationURL)
                        .font(.caption)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else if model.messages.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(mode.isReadOnly ? "Chat about scripture" : "Ask \(provider.shortName) to help with this writing")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(mode.isReadOnly
                    ? "Ask about the chapter you’re reading, or mention any passage. Explore your translations, commentaries, dictionaries, and other modules together."
                    : "The agent can read your context and Lamp modules. Its changes appear in the writing editor automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(24)
            .allowsHitTesting(false)
        }
    }

    private var connectionHelp: String {
        if connectionState == .notInstalled {
            return "Install the \(provider.shortName) CLI before starting a native session."
        }
        return provider.supportsBrowserAuthentication
            ? "Lamp will open your browser so you can sign in without using a terminal."
            : "OpenCode supports many providers, so its provider and credential selection opens in the built-in terminal."
    }

    private var chatStyle: ChatMessageCellStyle {
        ChatMessageCellStyle(
            incomingTextStyle: TextCellStyle(
                textStyle: CommonTextStyle(textColor: .primary, font: .body),
                textPadding: 12,
                cellBackgroundColor: LampChatSurface.agentBubble,
                cellCornerRadius: 14,
                cellBorderColor: LampChatSurface.agentBubbleBorder,
                cellBorderWidth: 1,
                cellShadowRadius: 0,
                cellRoundedCorners: [.topRight, .bottomRight, .bottomLeft]
            ),
            outgoingTextStyle: TextCellStyle(
                // Tinted rather than filled: a saturated bubble beside a muted
                // code panel reads as two different designs, and white on
                // accent is the one text here that cannot be themed.
                textStyle: CommonTextStyle(textColor: .primary, font: .body),
                textPadding: 12,
                cellBackgroundColor: LampChatSurface.personBubble,
                cellCornerRadius: 14,
                cellBorderColor: LampChatSurface.personBubbleBorder,
                cellBorderWidth: 1,
                cellShadowRadius: 0,
                cellRoundedCorners: [.topLeft, .bottomRight, .bottomLeft]
            ),
            incomingAvatarStyle: AvatarStyle(imageStyle: CommonImageStyle(imageSize: .zero)),
            outgoingAvatarStyle: AvatarStyle(imageStyle: CommonImageStyle(imageSize: .zero))
        )
    }

    private func connect() {
        if provider.supportsBrowserAuthentication {
            authenticationProvider = provider
        } else {
            terminalRequest = AIProviderTerminalRequest(
                provider: provider,
                title: "Connect \(provider.name)",
                command: provider.loginCommand
            )
        }
    }

    @MainActor
    private func refreshConnectionState() async {
        connectionState = .checking
        connectionState = await AIProviderCommandRunner.connectionState(for: provider)
    }
}

@MainActor
private final class AIProviderBrowserAuthenticationModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var didSucceed = false
    @Published private(set) var errorMessage: String?

    private let runner = AgentCLIProcessRunner()
    private var didStart = false

    func start(provider: AIProviderCLI) async {
        guard !didStart else { return }
        didStart = true
        isRunning = true
        let result = await runner.run(
            executableName: provider.executable,
            arguments: provider.authenticationArguments,
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
        isRunning = false
        didSucceed = result.exitCode == 0
        if !didSucceed {
            errorMessage = result.launchError
                ?? readableCLIError(in: result.output)
                ?? "\(provider.shortName) sign-in exited with status \(result.exitCode)."
        }
    }

    func cancel() { runner.cancel() }
}

struct AIProviderBrowserAuthenticationView: View {
    let provider: AIProviderCLI

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AIProviderBrowserAuthenticationModel()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: model.didSucceed ? "checkmark.circle.fill" : "person.badge.key")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(model.didSucceed ? .green : SwiftUI.Color.accentColor)
            Text(model.didSucceed ? "\(provider.shortName) is connected" : "Connect \(provider.name)")
                .font(.title2.bold())
            if model.isRunning {
                ProgressView()
                Text("Finish signing in in the browser window. Lamp will detect when you’re done.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 390)
            } else if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            } else if model.didSucceed {
                Text("You can close this window and start chatting.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if model.isRunning {
                    Button("Cancel", role: .cancel) {
                        model.cancel()
                        dismiss()
                    }
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(30)
        .frame(width: 520, height: 330)
        .task { await model.start(provider: provider) }
        .onDisappear { model.cancel() }
    }
}

private func readableCLIError(in output: String) -> String? {
    AgentChatRunDisposition.readableCLIError(in: output)
}
