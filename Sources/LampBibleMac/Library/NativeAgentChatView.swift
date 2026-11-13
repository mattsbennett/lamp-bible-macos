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

    /// Stopped in the moment before the provider was launched, so it never
    /// ran at all. Read as a stop rather than a failure: nothing went
    /// wrong, and nothing was done.
    static let stoppedBeforeStarting = AgentCLIProcessResult(
        exitCode: 0, output: "", launchError: nil
    )
}

final class AgentCLIProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancelled = false

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
        // Recorded as well as acted on. Resolving the executable takes a
        // moment, and for that moment there is no process to terminate — so
        // a Stop pressed then found nothing, and the run started afterwards
        // and did whatever it had been asked to do. For a writing agent
        // that is work on the person's draft after they said stop.
        cancelled = true
        let process = activeProcess
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    /// Readies the runner for a run, clearing the last one's stop.
    ///
    /// Done by the caller **before** the work is scheduled. Cleared inside
    /// the worker instead, a Stop pressed between scheduling and the worker
    /// starting was wiped by the run it was meant to stop.
    func prepareForRun() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    /// Whether this runner has been stopped, read at each point a run can
    /// still be abandoned cheaply.
    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func runSynchronously(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> AgentCLIProcessResult {
        do {
            let executableURL = try resolveExecutable(named: executableName)
            guard !isCancelled else { return .stoppedBeforeStarting }
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

            guard !isCancelled else { return .stoppedBeforeStarting }
            try process.run()
            // And once more, now there is something to terminate. Stop
            // between the guard above and this line found an assigned but
            // unstarted process and killed nothing, so the provider ran on
            // — doing, for a writing agent, work on the person's draft
            // after they had said stop.
            if isCancelled { process.terminate() }
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

struct NativeAgentChatUser: ChatUser {
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

/// What the agent did during one turn, for reading the conversation back.
///
/// A turn's tool calls were shown while it ran and then gone. A week
/// later the conversation said what was asked and what came back, and
/// nothing about where the answer came from — whether it had read the
/// passage, searched, or answered from the model alone. For study that is
/// the difference between a claim and a cited one.
struct TurnStepsContent {
    let steps: [String]
}

/// What the person typed. Lamp draws it rather than SwiftyChat, whose text cell
/// can't be selected.
struct PersonMessageContent {
    let text: String
}

struct NativeAgentChatMessage: ChatMessage {
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

/// A quiet line saying what the agent did for a turn.
private struct TurnStepsRow: View {
    let steps: [String]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption2)
            Text(steps.joined(separator: " · "))
                .font(.caption)
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help("What \(steps.count == 1 ? "tool" : "tools") this answer used")
    }
}

/// What is waiting to be sent, above the composer.
///
/// Shown rather than merely held: a message the reader cannot see is one
/// they cannot change their mind about, and the commonest thing to want
/// with a queued thought is to reword it once the reply has arrived.
private struct QueuedMessagesView: View {
    let messages: [AgentChatQueue.Message]
    /// Whether a message has been handed over and can no longer be changed.
    let isReserved: (UUID) -> Bool
    let edit: (UUID, String) -> Void
    let remove: (UUID) -> Void
    let moveUp: (UUID) -> Void

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(messages.count == 1 ? "1 message waiting" : "\(messages.count) messages waiting")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    QueuedMessageRow(
                        message: message,
                        sending: isReserved(message.id),
                        canMoveUp: index > 0,
                        edit: { edit(message.id, $0) },
                        remove: { remove(message.id) },
                        moveUp: { moveUp(message.id) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LampChatSurface.conversation)
        }
    }
}

private struct QueuedMessageRow: View {
    let message: AgentChatQueue.Message
    let sending: Bool
    let canMoveUp: Bool
    let edit: (String) -> Void
    let remove: () -> Void
    let moveUp: () -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if sending {
                Text(message.text)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Sending…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isEditing {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($editing)
                    .onSubmit(commit)
            } else {
                Text(message.text)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = message.text
                        isEditing = true
                        editing = true
                    }
            }
            if sending {
                EmptyView()
            } else if isEditing {
                Button("Done", action: commit)
                    .buttonStyle(.plain)
                    .font(.caption)
            } else {
                if canMoveUp {
                    Button("Send Sooner", systemImage: "arrow.up", action: moveUp)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Send this one before the others")
                }
                Button("Remove", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Take this message out of the queue")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SwiftUI.Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private func commit() {
        isEditing = false
        editing = false
        edit(draft)
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
/// One chat model per provider and workspace, for the life of the app.
///
/// A pane comes and goes — closed, swapped for Study, emptied while
/// another section is shown, hidden behind a Terminal — and a conversation
/// owned by the pane went with it, stopping the reply it was waiting on
/// and saving it half written (user, 2026-11-05).
///
/// It is also what makes a chat's queue and its reservation mean
/// something. The same writing can be open in two panes, and two models
/// over the same two files could each believe they owned the queue.
enum KeptAgentChats {
    private static var models: [String: NativeAgentChatModel] = [:]

    /// Lets go of a chat nobody will ask for again — a reader tab closed,
    /// a writing's workspace removed.
    ///
    /// Kept chats are held for the life of the process on purpose: a run
    /// has to outlive the pane that started it, and a second pane on the
    /// same workspace must find the *same* conversation rather than open a
    /// second one over the same files. The cost is that nothing was ever
    /// let go, so a long session with many tabs kept every transcript,
    /// every event and every process runner it had ever opened.
    ///
    /// **Refused while it is still in use**, and the request is remembered
    /// rather than dropped: a chat with a reply arriving finishes it, a
    /// chat with a pane still on screen keeps it, and the letting-go
    /// happens as soon as both are true. So this is called once and needs
    /// no retrying.
    static func release(provider: AIProviderCLI, workspace: URL) {
        existing(provider: provider, workspace: workspace)?.requestRelease()
    }

    /// Takes a model out, by identity rather than by key, so a chat that
    /// has since been replaced under the same key is left alone.
    static func drop(_ model: NativeAgentChatModel) {
        if let key = models.first(where: { $0.value === model })?.key {
            models.removeValue(forKey: key)
        }
    }

    /// The chat already running on this workspace, if any, without
    /// starting one.
    ///
    /// For a host that needs to know which turn is in progress *before*
    /// its chat pane has mounted and registered to be told — which is
    /// exactly when a pane reopens on a run that outlived it.
    static func existing(provider: AIProviderCLI, workspace: URL) -> NativeAgentChatModel? {
        models["\(provider.rawValue)|\(workspace.standardizedFileURL.path)"]
    }

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
final class NativeAgentChatModel: ObservableObject {
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
    private(set) var conversationID: UUID?
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
    /// Plain storage on the model. These were `@State`, which does nothing
    /// in a class — SwiftUI installs no storage for it, so every recording
    /// call returned at the guard and the whole record stayed empty. The
    /// compiler says so in as many words; I filtered the build to errors
    /// and never read it.
    @Published private(set) var events: [AgentChatTranscript.Event] = []
    /// The turns undone here, kept because removal is the one thing the
    /// union that reconciles two copies of a transcript cannot express.
    /// Held on the model as well as in the file so that a copy arriving
    /// from another Mac — which may have been written by a Lamp that drops
    /// what it has no name for — does not put them back.
    private var removedTurns: [UUID] = []
    /// When a turn was last undone here. Held beside the list for the
    /// same reason, and written out with it: built in `revert` and left
    /// out of the save, the whole record of *when* an undo happened
    /// lasted until the next write, which is to say no time at all.
    private var removedAt: Date?
    /// Messages written while a reply was still arriving, in the order they
    /// will be sent.
    @Published private(set) var queued: [AgentChatQueue.Message] = []
    /// The turn being recorded: the id of the user message that began it.
    private var recordingTurn: UUID?
    /// The queued message being sent right now, held so that a second pane
    /// cannot take the one after it while this is still being prepared.
    /// Not persisted: an unfinished reservation is simply a message still
    /// waiting the next time the app opens, which is what it is.
    private var reservedQueued: UUID?
    /// The identity each turn's steps row is drawn under, kept so it is the
    /// same row across redraws.
    private var stepsRowIDs: [UUID: UUID] = [:]
    /// Told when the queue has been read from disk, one per pane.
    ///
    /// An owner token fixed the worst of this — a pane going away used to
    /// clear a *different* pane's closure, and the closure held that pane
    /// and through it the reader of the tab it was in. What a single
    /// owner cannot do is hand the job back: with two panes open, the
    /// second to appear owned it, and when that one went the first was
    /// left with nothing listening, though it was still on screen. Keyed
    /// per pane, like the turn observers, there is nothing to hand back.
    private var queueObservers: [AnyHashable: () -> Void] = [:]

    func observeQueueReady(for token: AnyHashable, _ observe: @escaping () -> Void) {
        queueObservers[token] = observe
    }

    func stopObservingQueueReady(for token: AnyHashable) {
        queueObservers.removeValue(forKey: token)
    }
    /// Told which turn is being recorded, so a workspace can mark what the
    /// agent changes with the turn that asked for it.
    ///
    /// One per pane, not one in all. The model is shared between every pane
    /// on a workspace, and each of those panes records what the agent
    /// changes; a single closure meant the last pane to appear was the only
    /// one told, so another pane's recording — the same files, from the
    /// same run — was filed under no turn at all, and under the duplicate
    /// rule that untagged record is the one that stands.
    private var turnObservers: [AnyHashable: (UUID?) -> Void] = [:]

    /// Registers a pane's observer and tells it where the conversation
    /// stands, rather than only about the next change. A pane opened during
    /// a run would otherwise believe nothing was running until it ended.
    func observeTurn(for token: AnyHashable, _ observe: @escaping (UUID?) -> Void) {
        turnObservers[token] = observe
        observe(recordingTurn)
    }

    func stopObservingTurn(for token: AnyHashable) {
        turnObservers.removeValue(forKey: token)
        // The last pane may have just gone, which is one of the two things
        // a pending release was waiting for.
        letGoIfFinishedWith()
    }

    /// Asked to let this chat go once it is no longer in use.
    func requestRelease() {
        releaseRequested = true
        letGoIfFinishedWith()
    }

    /// A chat is in use while a reply is arriving or a pane is showing it.
    /// Both have to be over, and the observers are the panes: each
    /// registers on appearing and goes on disappearing.
    private func letGoIfFinishedWith() {
        guard releaseRequested, !isRunning, turnObservers.isEmpty else { return }
        KeptAgentChats.drop(self)
    }

    /// The turn that has just ended and may not have been seen.
    ///
    /// SwiftUI coalesces state changes between updates: a turn that
    /// begins and ends before the next one is delivered to a host as its
    /// net change — which is to say, not at all. Measured, not assumed; a
    /// hosted-view probe heard nothing for a pair set in one tick, and
    /// both for the same pair a cycle apart.
    ///
    /// A run cannot finish that fast, but a **pane opening** as one ends
    /// can: it is told the running turn on registering and nil
    /// immediately after, and those two coalesce. The host would then
    /// never flush for that turn, and its last write — the one that lands
    /// just before a run exits — would be recorded belonging to nothing.
    ///
    /// So the host pulls this as well as being pushed to. Taken once:
    /// whoever asks is about to account for what that turn left.
    private var endedTurn: UUID?
    /// Somebody has done with this chat, and it goes as soon as it is no
    /// longer in use.
    private var releaseRequested = false

    #if DEBUG
    /// Drives the turn from a test, which otherwise cannot: a real one is
    /// set by a run starting and cleared by it ending.
    func setCurrentTurnForTesting(_ turn: UUID?) { currentTurn = turn }
    #endif

    /// The turn a change found on disk now should be recorded under.
    func takeTurnForAttribution() -> UUID? {
        if let recordingTurn { return recordingTurn }
        defer { endedTurn = nil }
        return endedTurn
    }

    /// The turn in progress, nil between turns.
    private(set) var currentTurn: UUID? {
        get { recordingTurn }
        set {
            if newValue == nil, let ending = recordingTurn {
                endedTurn = ending
            } else if newValue != nil {
                endedTurn = nil
            }
            recordingTurn = newValue
            for observe in turnObservers.values { observe(newValue) }
        }
    }
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
        var waiting = AgentChatQueueStore.load(providerID: provider.rawValue, in: workspace)
        // Anything already in the conversation was sent before the app
        // closed, however it closed. The question carries the queued
        // message's own id, so this is an answer rather than a guess.
        let before = waiting.messages.count
        let stored = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        waiting.removeAlreadySaid(in: stored)
        // And anything written to a conversation that has since been put
        // away somewhere else. A New Chat here throws the queue away; one
        // that arrives through sync had nothing here to throw it away, so
        // the messages were drained into a conversation they were never
        // written to.
        waiting.removeWrittenElsewhere(than: stored.conversationID)
        if waiting.messages.count != before {
            try? AgentChatQueueStore.save(waiting, providerID: provider.rawValue, in: workspace)
        }
        queued = waiting.messages
        // What was restored may be waiting with nothing about to run, and
        // the queue is otherwise drained only by a reply landing. Without
        // this, messages recovered at launch sat there until the next one.
        for observe in queueObservers.values { observe() }
        adopt(AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace))
    }

    /// Picks up a transcript changed by something other than this chat. Cheap
    /// when nothing has: only the file's modification date is read.
    func reloadIfChangedOnDisk() {
        guard didLoad, !isRunning else { return }
        let modified = transcriptModificationDate()
        guard modified != knownModificationDate else { return }
        knownModificationDate = modified
        let onDisk = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        if onDisk != knownTranscript { adopt(onDisk) }
    }

    /// Takes up a transcript from disk, and writes it back where showing it
    /// changed it.
    ///
    /// A copy rewritten by a Lamp that has no name for the record of what
    /// was undone brings those turns back with it. Shown without them is
    /// half the answer: held only in memory, the undo would last until the
    /// app next opened. So the file is put right at the same time.
    private func adopt(_ onDisk: AgentChatTranscript) {
        show(onDisk)
        guard knownTranscript != onDisk else {
            knownModificationDate = transcriptModificationDate()
            return
        }
        persistTranscript()
    }

    private func show(_ transcript: AgentChatTranscript) {
        // What this chat knows to have been undone is applied to whatever
        // arrives, so a copy written without it — by sync, or by a Lamp
        // that has no name for the record — does not bring the turns back.
        // Only within the same conversation: a cleared one is a new
        // conversation, and what was undone in its predecessor says
        // nothing about it.
        let undone = transcript.conversationID == conversationID ? removedTurns : []
        let transcript = transcript.removing(
            turns: undone,
            at: transcript.conversationID == conversationID ? removedAt : nil
        )
        removedTurns = transcript.removedTurns ?? []
        removedAt = transcript.removedAt
        knownTranscript = transcript
        events = transcript.events ?? []
        conversationID = transcript.conversationID
        conversationStartedAt = transcript.startedAt
        // A session held by another Mac — or set aside when sync merged in turns
        // it never saw — can't be resumed here. The next message carries the
        // conversation on from a recap instead.
        sessionID = transcript.resumableSessionID(forInstall: installID)
        let loading = messages.filter { $0.id == loadingMessageID }
        messages = rows(of: transcript) + loading
        continuityNotice = transcript.sessionID != nil && sessionID == nil
            ? "This chat continues from an earlier session that can’t be resumed on this Mac. \(provider.shortName) will be given a recap of the conversation."
            : nil
    }

    private func transcriptModificationDate() -> Date? {
        let url = AgentChatTranscriptStore.url(providerID: provider.rawValue, in: workspace)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Sends a message, saying whether it was taken.
    ///
    /// `messageID` is the queued message's own id where this came from the
    /// queue, so that the conversation itself records which queued message
    /// it was. That is the only durable answer to "was this one already
    /// sent?" — a reservation lives in memory and dies with the app, and a
    /// message whose text reached the transcript under some unrelated id
    /// could be found waiting again after a quit and sent twice.
    ///
    /// `inConversation` is the conversation the caller meant. Preparing a
    /// prompt waits, and New Chat is allowed during that wait, so without
    /// this a question asked of the old conversation lands in its
    /// replacement.
    @discardableResult
    func send(
        _ rawPrompt: String,
        contextualPrompt: String,
        messageID: UUID? = nil,
        inConversation expected: UUID? = nil
    ) async -> Bool {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return false }
        // Turns from Terminal, another pane or another Mac may have arrived
        // while this prompt was being prepared, so the conversation is read
        // from disk **before** it is judged against the one the caller
        // meant. Judged against the copy in memory, a clear that had
        // already happened on disk was invisible and the message landed in
        // the conversation that replaced it.
        reloadIfChangedOnDisk()
        guard expected == conversationID else { return false }
        // Already in the conversation, so it has been sent — by this pane
        // before a crash, or by another pane sharing this workspace, which
        // a writing window can have open at the same time. Its queue entry
        // is stale rather than waiting.
        if let messageID, knownTranscript?.messages.contains(where: { $0.id == messageID }) == true {
            completeQueued(messageID)
            return false
        }
        errorMessage = nil
        needsProviderSetup = false
        stoppedNotice = nil
        isRunning = true
        cancelRequested = false
        // Before the work is scheduled: cleared inside the worker, a Stop
        // pressed in between was wiped by the run it was meant to stop.
        runner.prepareForRun()
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
            id: messageID ?? UUID(),
            user: person,
            messageKind: .custom(PersonMessageContent(text: prompt)),
            isSender: true,
            date: Date()
        )
        messages.append(userMessage)
        currentTurn = userMessage.id
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
        // Only once the question is **safely** written down does it stop
        // waiting. The save reports failure rather than throwing, so
        // completing regardless could take a message off the queue that a
        // full disk had kept out of the transcript — gone from both.
        let written = persistTranscript()
        if let messageID, written { completeQueued(messageID) }

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
        return true
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
        // The record goes with the conversation it was a record of. Left
        // behind, it was written back under the new conversation's id and
        // the cleared questions returned on the next load.
        events = []
        // With the conversation they named. A list of undone turns outlives
        // the turns, not the conversation.
        removedTurns = []
        removedAt = nil
        currentTurn = nil
        stepsRowIDs = [:]
        // The waiting messages were written to **this** conversation, and
        // it is being put away. Sending them into its replacement would be
        // answering a question nobody asked here; keeping them while the
        // transcript that recorded their having been sent is cleared is how
        // one of them gets sent a second time.
        if !queued.isEmpty { changeQueue { $0 = AgentChatQueue() } }
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
        // A reservation outlives nothing. If the save that should have
        // completed the receipt failed earlier, the message is still held
        // — unsendable, unremovable, and uneditable — while the reply it
        // asked for has already arrived. The transcript is the receipt, so
        // it is asked now: in the conversation means sent, and absent
        // means it goes back to waiting.
        if let reserved = reservedQueued {
            if knownTranscript?.messages.contains(where: { $0.id == reserved }) == true {
                completeQueued(reserved)
            } else {
                releaseQueued(reserved)
            }
        }
        // A reply arriving was the other thing a pending release waited
        // for, and this is where it stops arriving.
        defer { letGoIfFinishedWith() }
        // The turn is over. What happens before the next question is the
        // app's business, not the conversation's.
        currentTurn = nil
        // Drawn again from what was just written, so the turn gains its
        // line of steps now rather than at the next load — which, for a
        // pane that keeps its model across closes, could be the next
        // launch.
        redrawFromRecord()
    }

    /// Rebuilds the rows from the events and messages now held.
    ///
    /// Only between turns: a redraw mid-run would take away the loader or
    /// the reply being streamed into it, both of which live in `messages`
    /// and in neither record.
    private func redrawFromRecord() {
        guard !isRunning, loadingMessageID == nil else { return }
        messages = rows(of: AgentChatTranscript(
            conversationID: conversationID,
            startedAt: conversationStartedAt,
            sessionID: sessionID,
            sessionInstallID: sessionID == nil ? nil : installID,
            messages: transcriptMessages(),
            events: events
        ))
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

    /// The conversation as rows: each question, what the agent did, and what
    /// it said.
    ///
    /// A transcript from before events has no steps to show and reads as it
    /// always did.
    private func rows(of transcript: AgentChatTranscript) -> [NativeAgentChatMessage] {
        // Every identity the conversation itself uses, so a steps row is
        // never given one of them.
        let taken = Set(transcript.turns.flatMap(\.events).map(\.id))
            .union(transcript.messages.map(\.id))
        return transcript.turns.flatMap { turn -> [NativeAgentChatMessage] in
            var rows: [NativeAgentChatMessage] = []
            for event in turn.events {
                guard event.kind == AgentChatTranscript.Event.said,
                      let role = event.role, let text = event.text
                else { continue }
                rows.append(makeChatMessage(AgentChatTranscript.Message(
                    id: event.id, role: role, text: text, date: event.date
                )))
                // The steps go under the question, where they happened,
                // rather than under the answer they produced.
                if role == .user, !turn.toolsUsed.isEmpty {
                    rows.append(NativeAgentChatMessage(
                        // Its own identity. The question's event is stored
                        // under the turn's id, so giving the steps row the
                        // same one put two rows with one id into the list
                        // SwiftyChat draws and scrolls by.
                        id: stepsRowID(for: turn.id, avoiding: taken),
                        user: agentUser,
                        messageKind: .custom(TurnStepsContent(steps: turn.toolsUsed)),
                        isSender: false,
                        date: event.date
                    ))
                }
            }
            return rows
        }
    }

    /// A turn's steps row, the same across redraws and never another
    /// row's.
    ///
    /// It was derived by flipping a bit of the turn's own id, which shares
    /// a namespace with real message ids: a message whose id was a turn's
    /// with that bit flipped would collide, and in a list SwiftUI draws and
    /// scrolls by identity, two rows with one id is a row that cannot be
    /// reached. Nothing produced such a pair, which is a reason it had not
    /// happened rather than a reason it could not.
    ///
    /// Given out once per turn and remembered instead, avoiding every id
    /// the conversation already uses. Remembering is what makes it stable;
    /// avoiding is what makes it safe.
    private func stepsRowID(for turn: UUID, avoiding taken: Set<UUID>) -> UUID {
        if let known = stepsRowIDs[turn], !taken.contains(known) { return known }
        var candidate = UUID()
        while taken.contains(candidate) || stepsRowIDs.values.contains(candidate) {
            candidate = UUID()
        }
        stepsRowIDs[turn] = candidate
        return candidate
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

    // MARK: - Waiting messages

    /// The queue's own rules live in `AgentChatQueue`; this keeps it on
    /// screen and on disk.
    /// Whether anything is waiting that nothing is sending yet.
    var hasWaitingMessage: Bool { reservedQueued == nil && !queued.isEmpty }

    private func changeQueue(_ change: (inout AgentChatQueue) -> Void) {
        var queue = AgentChatQueue(messages: queued)
        change(&queue)
        queued = queue.messages
        try? AgentChatQueueStore.save(queue, providerID: provider.rawValue, in: workspace)
    }

    func enqueue(_ text: String) {
        changeQueue { [conversationID] in $0.add(text, conversation: conversationID) }
    }

    /// Whether this waiting message still belongs to the conversation it
    /// was written to.
    ///
    /// Asked again at the moment of sending, not only when the queue was
    /// read: a New Chat can arrive from another Mac while a message is
    /// being prepared, and the retry that follows would otherwise pick up
    /// the new conversation as though the message had always been meant
    /// for it.
    func stillBelongs(_ message: AgentChatQueue.Message) -> Bool {
        guard let written = message.conversation, let conversationID else { return true }
        return written == conversationID
    }

    /// Takes out what was written to a conversation that has since been
    /// put away somewhere else.
    func dropMessagesWrittenElsewhere() {
        guard let conversationID else { return }
        guard queued.contains(where: { $0.conversation.map { $0 != conversationID } ?? false })
        else { return }
        changeQueue { $0.removeWrittenElsewhere(than: conversationID) }
    }
    /// Refused for a message already being sent: taking it out of the
    /// queue would not take it out of the conversation.
    func removeQueued(_ id: UUID) {
        guard !isReserved(id) else { return }
        changeQueue { $0.remove(id) }
    }

    func updateQueued(_ id: UUID, text: String) {
        guard !isReserved(id) else { return }
        changeQueue { $0.update(id, text: text) }
    }
    func sendQueuedSooner(_ id: UUID) { changeQueue { $0.sendSooner(id) } }

    /// The next message waiting, **reserved rather than removed**.
    ///
    /// It stays on disk until it is in the transcript. Taken out first, a
    /// quit during the moment between — preparing the prompt reads the
    /// reader's place and can wait — lost it from the queue and from the
    /// conversation both, which is losing the person's words.
    ///
    /// The reservation is the model's, not a view's, and the model outlives
    /// the pane. Two views each with their own `isPreparing` both drained:
    /// close the pane mid-preparation and reopen it, and the second view
    /// took the next message while the first was still working, so one of
    /// them was refused by the running guard after its queue entry had
    /// already gone.
    func reserveNextQueued() -> AgentChatQueue.Message? {
        guard reservedQueued == nil else { return nil }
        // Checked here, every time, rather than once when the queue was
        // read. A New Chat can arrive from another Mac while a message is
        // being prepared; the send is refused, the message goes back to
        // waiting, and the next attempt would otherwise take the new
        // conversation as the one it had always been meant for.
        dropMessagesWrittenElsewhere()
        guard let next = queued.first, stillBelongs(next) else { return nil }
        reservedQueued = next.id
        return next
    }

    /// Whether a waiting message has been handed over and can no longer be
    /// changed.
    ///
    /// Its words were taken by value when it was reserved, so an edit made
    /// afterwards would be dropped silently: the old text sent, the new
    /// text deleted by the completion that follows. The row says so
    /// instead.
    func isReserved(_ id: UUID) -> Bool { reservedQueued == id }

    /// The reserved message reached the conversation, so it stops waiting.
    func completeQueued(_ id: UUID) {
        reservedQueued = nil
        changeQueue { $0.remove(id) }
    }

    /// It did not. It goes back to waiting, in its place, to be tried again.
    func releaseQueued(_ id: UUID) {
        guard reservedQueued == id else { return }
        reservedQueued = nil
    }

    /// Undoes a turn: it and everything after it leave the conversation,
    /// and the provider session with them.
    ///
    /// The files are the caller's to put back — this is the conversation's
    /// half. Returns false where the turn is no longer there, or a reply is
    /// arriving, which is not a moment to rewrite what it is replying to.
    /// Takes **these** turns out, and nothing else.
    ///
    /// The list is the one the host was given and has just put the writing
    /// back for. Worked out again here, it could have grown: a turn can
    /// arrive from another Mac between the two, and trimming from the
    /// named turn would then take that one too — removing work nobody
    /// checked and nothing put back. An undo removes what was agreed.
    func revert(turns: [UUID]) -> Bool {
        guard !isRunning, !turns.isEmpty else { return false }
        let base = knownTranscript
            ?? AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        let names = base.names(of: Set(turns))
        guard !names.isEmpty else { return false }
        // Dated, because undoing a turn is activity in this conversation:
        // without it the conversation reads as older than before, and a
        // clear from another Mac then wins or loses by merge order alone.
        show(base.removing(turns: names, at: Date()))
        return persistTranscript()
    }

    /// Whether undoing this turn is something that can be done now.
    ///
    /// Asked **before** anything is written, because the first half of an
    /// undo is the host putting the writing back: a check made after that
    /// is a check made after the only destructive step. A reply arriving is
    /// not a moment to rewrite what it is replying to, and a turn that has
    /// already gone — undone in another pane, or trimmed by a copy that
    /// synced in — is not one to put anything back for.
    func canRevert(turn: UUID) -> Bool {
        guard !isRunning else { return false }
        // Read, rather than trust what is held. Sync can have installed
        // another Mac's copy — or a conversation cleared there — since
        // this pane last looked, and the turn being undone may not be in
        // it any more. Found out afterwards, the draft would already have
        // been put back for a turn the conversation no longer had.
        let onDisk = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        if onDisk != knownTranscript { adopt(onDisk) }
        return canFork(from: turn)
    }

    /// The turns an undo of this one would take with it.
    func turnsUndoneBy(_ turn: UUID) -> [UUID] {
        knownTranscript?.turnsFrom(turn) ?? []
    }

    /// Whether this message begins a turn the conversation still holds, so
    /// a fork taken from it has something to keep.
    func canFork(from turn: UUID) -> Bool {
        events.contains { $0.turn == turn }
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

    @discardableResult
    private func persistTranscript() -> Bool {
        // A session this Mac cannot resume is still somebody's session.
        // `sessionID` here is what *this* install may hand back to its
        // provider, which is nil for a session another Mac holds — so
        // writing that out replaced a session that Mac is still in the
        // middle of with nothing, and its next message started from a
        // recap for no reason. Kept as it was read, within the same
        // conversation; a cleared one is a different conversation and
        // takes no session with it.
        let held = knownTranscript.flatMap { known -> AgentChatTranscript? in
            guard sessionID == nil, known.sessionID != nil,
                  known.conversationID == conversationID
            else { return nil }
            return known
        }
        var transcript = AgentChatTranscript(
            conversationID: conversationID,
            startedAt: conversationStartedAt,
            sessionID: sessionID ?? held?.sessionID,
            sessionInstallID: sessionID == nil ? held?.sessionInstallID : installID,
            messages: transcriptMessages(),
            // No falling back to what was on disk: after New Chat the
            // events are empty *because the conversation was cleared*, and
            // reaching for the old ones wrote the cleared questions back
            // under a new conversation's id.
            events: events,
            removedTurns: removedTurns.isEmpty ? nil : removedTurns,
            removedAt: removedAt
        )
        let onDisk = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        if onDisk != knownTranscript {
            // Changed elsewhere while this reply ran. Merged as sync merges two
            // Macs' copies, so neither side's turns are lost.
            transcript = AgentChatTranscriptMerge.merge(local: transcript, incoming: onDisk)
        }
        do {
            try AgentChatTranscriptStore.save(transcript, providerID: provider.rawValue, in: workspace)
            // Shown only once it is saved. Adopted before the write, a
            // failed save left this pane describing a conversation that is
            // not on disk — and the receipt check reads what this pane
            // believes.
            show(transcript)
            knownTranscript = transcript
            knownModificationDate = transcriptModificationDate()
            return true
        } catch {
            errorMessage = "Could not save the chat transcript: \(error.localizedDescription)"
            return false
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
    /// Starts a conversation of its own from a turn, where the host has
    /// somewhere to put one. Nil in a pane that cannot open another chat,
    /// where the menu item is simply not offered.
    let forkFromTurn: ((UUID) -> Void)?
    /// Undoes what these turns did, saying whether it could. Nil in a pane
    /// with nothing to put back, where the menu item is simply not offered.
    ///
    /// **All** of them: the turn the reader named and everything after it,
    /// since all of that is about to leave the conversation. Given only the
    /// named one, the host put the draft back to before it and left the
    /// later turns' work in the writing with nothing left to account for
    /// it.
    ///
    /// Answering matters too: the host refuses what it cannot put back
    /// whole, and a conversation trimmed after such a refusal would have
    /// taken away the questions and kept their work.
    let revertTurn: (([UUID]) -> Bool)?
    /// Told which turn is running, for a pane that marks its own records
    /// with it.
    let onTurnChanged: ((UUID?) -> Void)?
    /// Where this chat works, which the header names.
    private let workspaceFolder: URL

    @StateObject private var model: NativeAgentChatModel
    @State private var draft = ""
    @State private var scrollToBottom = false
    @State private var connectionState = AIProviderConnectionState.checking
    @State private var authenticationProvider: AIProviderCLI?
    @State private var terminalRequest: AIProviderTerminalRequest?
    @State private var showingClearConfirmation = false
    /// A turn the reader has asked to undo, held while they confirm.
    @State private var turnToUndo: UUID?
    /// This pane's name among the panes sharing one chat, so that each is
    /// told which turn is running rather than only the last to appear.
    @State private var paneToken = UUID()
    /// The turn the shared chat is on, as this pane last heard it.
    @State private var observedTurn: UUID?
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
        forkFromTurn: ((UUID) -> Void)? = nil,
        revertTurn: (([UUID]) -> Bool)? = nil,
        onTurnChanged: ((UUID?) -> Void)? = nil
    ) {
        self.provider = provider
        self.mode = mode
        self.canSend = canSend
        self.preparePrompt = preparePrompt
        self.onRunningChanged = onRunningChanged
        self.forkFromTurn = forkFromTurn
        self.revertTurn = revertTurn
        self.onTurnChanged = onTurnChanged
        self.workspaceFolder = workspace
        // **One model per provider and workspace, for every pane.** A
        // writing pane used to build its own, and the same writing can be
        // open twice — its own window, and that writing opened from the
        // library. Two models owning the same two files meant one pane
        // could send a message the other still showed as waiting, and an
        // edit made in one could be deleted by the other's receipt without
        // ever being sent. The queue and the reservation are the model's,
        // so sharing the model is what makes them cover both panes.
        _model = StateObject(wrappedValue: KeptAgentChats.model(
            provider: provider, workspace: workspace, mode: mode
        ))
    }

    /// Sends the next waiting message, if this pane is free to.
    private func drainQueue() {
        guard !isPreparing, !model.isRunning, model.hasWaitingMessage else { return }
        guard let next = model.reserveNextQueued() else { return }
        startSending(next.text, queued: next.id)
    }

    /// Sends a message now, which is also how a message that was waiting is
    /// sent when the reply before it lands.
    @discardableResult
    private func startSending(_ prompt: String, queued: UUID? = nil) -> Bool {
        guard !isPreparing else {
            if let queued { model.releaseQueued(queued) }
            return false
        }
        isPreparing = true
        // The conversation this message was written in. Preparing waits,
        // and New Chat is allowed during that wait.
        let conversation = model.conversationID
        // Started now, and on the main actor until it first waits, so the
        // reader's place is read at Send and not after a navigation.
        Task {
            defer { isPreparing = false }
            do {
                let contextualPrompt = try await preparePrompt(prompt)
                submissionError = nil
                isPreparing = false
                let taken = await model.send(
                    prompt, contextualPrompt: contextualPrompt,
                    messageID: queued, inConversation: conversation
                )
                // Taken means it is in the transcript, which is where the
                // model takes it out of the queue. Refused — the pane was
                // reopened and something else is running, or New Chat
                // happened while this was being prepared — it goes back to
                // waiting rather than being dropped as sent.
                if !taken {
                    if let queued {
                        // Back to waiting — and tried again now, since
                        // nothing else will: the queue is drained by a run
                        // finishing, and no run started.
                        model.releaseQueued(queued)
                        isPreparing = false
                        drainQueue()
                    } else {
                        // A message typed straight in, refused because the
                        // conversation changed while it was being prepared.
                        // The composer cleared it when it was accepted, so
                        // without this it is simply gone.
                        submissionError = "That message was not sent: the conversation changed while it was being prepared."
                        if draft.isEmpty { draft = prompt }
                    }
                }
                scrollToBottom = true
            } catch {
                submissionError = error.localizedDescription
                // A queued message goes back to waiting, in its place,
                // rather than into a draft field the reader may be typing
                // in — which is where it used to vanish, since it was only
                // put back when the field happened to be empty.
                if let queued {
                    model.releaseQueued(queued)
                } else if draft.isEmpty {
                    draft = prompt
                }
            }
        }
        return true
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
            QueuedMessagesView(
                messages: model.queued,
                isReserved: { model.isReserved($0) },
                edit: { model.updateQueued($0, text: $1) },
                remove: { model.removeQueued($0) },
                moveUp: { model.sendQueuedSooner($0) }
            )
            ZStack {
                ChatView(messages: $model.messages, scrollToBottom: $scrollToBottom) {
                    NativeAgentChatInputView(
                        message: $draft,
                        placeholder: model.isRunning ? "\(provider.shortName) is working…" : "Message \(provider.shortName)"
                    ) { prompt in
                        // While a reply is arriving the message waits its
                        // turn rather than being refused. A thought that
                        // arrives mid-answer usually arrives *because* of
                        // the answer, and making the reader hold it until
                        // the reply lands is how a question gets lost.
                        if model.isRunning {
                            model.enqueue(prompt)
                            return true
                        }
                        return startSending(prompt)
                    }
                    .disabled(!canSend || isPreparing || connectionState != .connected)
                }
                // SwiftyChat gives every message its own right-click menu,
                // which hides the one selected text would have.
                .messageCellContextMenu { message in
                    if let text = message.text {
                        Button("Copy Message", systemImage: "doc.on.doc") {
                            MessageClipboard.copy(text)
                        }
                    }
                    // Offered on what the reader asked, because a turn is
                    // named by its question: forking from an answer would
                    // mean forking from the question above it, which is not
                    // what the menu would appear to say.
                    if let forkFromTurn, message.isSender, model.canFork(from: message.id) {
                        Button("Fork From Here", systemImage: "arrow.branch") {
                            forkFromTurn(message.id)
                        }
                    }
                    if revertTurn != nil, message.isSender, model.canFork(from: message.id) {
                        Button("Undo This Turn…", systemImage: "arrow.uturn.backward") {
                            turnToUndo = message.id
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
                    } else if let content = payload as? TurnStepsContent {
                        TurnStepsRow(steps: content.steps)
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
        .onAppear {
            model.observeQueueReady(for: paneToken) { drainQueue() }
            // Into state, not straight on to the host. A closure
            // registered here keeps the view struct it was made with, and
            // a plain `let` in that struct — the draft the writing held
            // when this pane opened — never changes again. Through
            // `@State` and `onChange`, the host is called by the view as
            // it is now.
            model.observeTurn(for: paneToken) { observedTurn = $0 }
        }
        .onChange(of: observedTurn) { _, turn in
            onTurnChanged?(turn)
        }
        .onChange(of: model.isRunning, initial: true) { _, running in
            onRunningChanged(running)
            // The reply has landed, so the next message waiting goes. One at
            // a time, because each has to be prepared with the reader's
            // place as it is *now* — a queued question about this chapter
            // was written about this chapter.
            guard !running else { return }
            drainQueue()
        }
        .onDisappear {
            model.stopObservingTurn(for: paneToken)
            model.stopObservingQueueReady(for: paneToken)
            // And told so. A host that goes on holding the turn it was last
            // told about would mark everything written afterwards — by a run
            // that outlives this pane, or by the person — as that turn's
            // doing.
            observedTurn = nil
            onTurnChanged?(nil)
            // Not stopped. The model is shared now, so a pane going away
            // may not be the only one holding it — and stopping a run
            // because one view of it closed is what the reader's pane was
            // changed away from, for the same reason: going stopped the
            // reply it was waiting on and saved it half written.
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
            "Undo this turn?",
            isPresented: Binding(
                get: { turnToUndo != nil },
                set: { if !$0 { turnToUndo = nil } }
            ),
            titleVisibility: .visible,
            presenting: turnToUndo
        ) { turn in
            Button("Undo", role: .destructive) {
                turnToUndo = nil
                // Asked before anything is written: a reply arriving, or a
                // turn that has since gone, is a refusal, and a refusal
                // after the draft has been put back is a refusal that came
                // too late to refuse anything.
                guard model.canRevert(turn: turn) else { return }
                let going = model.turnsUndoneBy(turn)
                guard !going.isEmpty else { return }
                // One agreed list: what the host puts back is what the
                // conversation loses.

                // Then the draft, and only then the conversation. Putting
                // the writing back is the half that can fail; trimmed
                // first, a failure would leave the question gone and its
                // work still in the draft, with nothing left to undo it
                // from.
                guard revertTurn?(going) == true else { return }
                _ = model.revert(turns: going)
            }
            Button("Cancel", role: .cancel) { turnToUndo = nil }
        } message: { _ in
            Text("The draft goes back to what it said before this turn, and this turn and everything after it leave the conversation. Anything you have written since is replaced — the restore is recorded in the writing’s history, so you can put it back.")
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

    /// The folder this chat works in, by the name a person would know it
    /// by rather than its path.
    private var workspaceName: String {
        workspaceFolder.lastPathComponent
    }

    private var chatHeader: some View {
        HStack(spacing: 8) {
            // The reader's pane names its provider in its own menu just
            // above; said again here it read as a second header.
            if !isReaderChat {
                Label(provider.shortName, systemImage: provider.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                // What this agent may do, and where. The reader's pane says
                // so in its own context card; a writing workspace said
                // nothing at all, and this is the one that can **write** —
                // the person should know whose folder it is working in
                // before they send, not after.
                Label(workspaceName, systemImage: mode.isReadOnly ? "lock" : "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(mode.isReadOnly
                        ? "Reads \(workspaceName). It cannot change anything."
                        : "Reads and edits the files in \(workspaceName).")
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
        runner.prepareForRun()
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
