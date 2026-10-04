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

    func run(
        executableName: String,
        arguments: [String],
        workingDirectory: URL
    ) async -> AgentCLIProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: runSynchronously(
                    executableName: executableName,
                    arguments: arguments,
                    workingDirectory: workingDirectory
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
        workingDirectory: URL
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
            process.environment = ProcessInfo.processInfo.environment

            lock.lock()
            activeProcess = process
            lock.unlock()
            defer {
                lock.lock()
                if activeProcess === process { activeProcess = nil }
                lock.unlock()
            }

            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return AgentCLIProcessResult(
                exitCode: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self),
                launchError: nil
            )
        } catch {
            return AgentCLIProcessResult(exitCode: -1, output: "", launchError: error.localizedDescription)
        }
    }

    private func resolveExecutable(named name: String) throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v \(name)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
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

private struct NativeAgentChatMessage: ChatMessage {
    let id: UUID
    let user: NativeAgentChatUser
    let messageKind: ChatMessageKind
    let isSender: Bool
    let date: Date
}

private struct NativeAgentChatInputView: View {
    @Binding var message: String
    let placeholder: String
    let onCommit: (String) -> Bool

    private var canSubmit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField(placeholder, text: $message, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit(submit)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(SwiftUI.Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.secondary.opacity(0.14), lineWidth: 1)
                )

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        canSubmit
                            ? SwiftUI.Color.accentColor
                            : SwiftUI.Color.secondary.opacity(0.35),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .disabled(!canSubmit)
            .help("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            SwiftUI.Color(nsColor: .windowBackgroundColor)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
        )
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedMessage = message
        if onCommit(submittedMessage) { message = "" }
    }
}

@MainActor
private final class NativeAgentChatModel: ObservableObject {
    @Published var messages: [NativeAgentChatMessage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    /// Set while the conversation is being carried on from a recap rather than a
    /// resumed provider session, so it's clear why the agent may know less of it.
    @Published private(set) var continuityNotice: String?

    let provider: AIProviderCLI
    private let workspace: URL
    private let mode: AgentChatMode
    private let runner = AgentCLIProcessRunner()
    private let installID = LampInstallIdentity.current()
    private var sessionID: String?
    private var conversationID: UUID?
    private var conversationStartedAt: Date?
    private var didLoad = false
    private var cancelRequested = false
    private var loadingMessageID: UUID?

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
        let transcript = AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
        conversationID = transcript.conversationID
        conversationStartedAt = transcript.startedAt
        // A session held by another Mac — or set aside when sync merged in turns
        // it never saw — can't be resumed here. The next message carries the
        // conversation on from a recap instead.
        sessionID = transcript.resumableSessionID(forInstall: installID)
        messages = transcript.messages.map(makeChatMessage)
        if transcript.sessionID != nil, sessionID == nil {
            continuityNotice = "This chat continues from an earlier session that can’t be resumed on this Mac. \(provider.shortName) will be given a recap of the conversation."
        }
    }

    func send(_ rawPrompt: String, contextualPrompt: String) async {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        errorMessage = nil
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
            messageKind: .text(prompt),
            isSender: true,
            date: Date()
        )
        messages.append(userMessage)
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
        let proposedSessionID = provider == .claude && resumedSessionID == nil
            ? UUID().uuidString.lowercased() : nil
        let result = await runner.run(
            executableName: provider.executable,
            arguments: AgentChatLaunchArguments.make(
                provider: provider.wireProvider,
                prompt: prompt,
                sessionID: resumedSessionID,
                proposedSessionID: proposedSessionID,
                mode: mode
            ),
            workingDirectory: workspace
        )
        return RunOutcome(
            result: result,
            proposedSessionID: proposedSessionID,
            resumedSessionID: resumedSessionID
        )
    }

    private func finish(_ outcome: RunOutcome) {
        let result = outcome.result
        isRunning = false
        if let loadingMessageID {
            messages.removeAll { $0.id == loadingMessageID }
        }
        loadingMessageID = nil

        let summary = AgentChatRunSummary.summarize(
            output: result.output,
            provider: provider.wireProvider
        )

        if result.exitCode == 0, result.launchError == nil {
            sessionID = summary.sessionID ?? outcome.resumedSessionID ?? outcome.proposedSessionID
        }

        if !summary.response.isEmpty {
            messages.append(NativeAgentChatMessage(
                id: UUID(),
                user: agentUser,
                messageKind: .text(summary.response),
                isSender: false,
                date: Date()
            ))
        } else if result.exitCode != 0 || result.launchError != nil || summary.failure != nil {
            let failure = result.launchError
                ?? summary.failure
                ?? readableCLIError(in: result.output)
                ?? "\(provider.shortName) exited with status \(result.exitCode)."
            errorMessage = failure
            messages.append(NativeAgentChatMessage(
                id: UUID(),
                user: agentUser,
                messageKind: .text("I couldn’t complete that request. \(failure)"),
                isSender: false,
                date: Date()
            ))
        } else {
            let failure = "\(provider.shortName) finished without returning a message."
            errorMessage = failure
            messages.append(NativeAgentChatMessage(
                id: UUID(),
                user: agentUser,
                messageKind: .text(failure),
                isSender: false,
                date: Date()
            ))
        }
        persistTranscript()
    }

    private func makeChatMessage(_ message: AgentChatTranscript.Message) -> NativeAgentChatMessage {
        let isSender = message.role == .user
        return NativeAgentChatMessage(
            id: message.id,
            user: isSender ? person : agentUser,
            messageKind: .text(message.text),
            isSender: isSender,
            date: message.date
        )
    }

    private func transcriptMessages() -> [AgentChatTranscript.Message] {
        messages.compactMap { message in
            guard case .text(let text) = message.messageKind else { return nil }
            return AgentChatTranscript.Message(
                id: message.id,
                role: message.isSender ? .user : .assistant,
                text: text,
                date: message.date
            )
        }
    }

    private func persistTranscript() {
        let transcript = AgentChatTranscript(
            conversationID: conversationID,
            startedAt: conversationStartedAt,
            sessionID: sessionID,
            sessionInstallID: sessionID == nil ? nil : installID,
            messages: transcriptMessages()
        )
        do {
            try AgentChatTranscriptStore.save(transcript, providerID: provider.rawValue, in: workspace)
        } catch {
            errorMessage = "Could not save the chat transcript: \(error.localizedDescription)"
        }
    }
}

struct NativeAgentChatView: View {
    let provider: AIProviderCLI
    let mode: AgentChatMode
    let canSend: Bool
    let preparePrompt: (String) throws -> String

    @StateObject private var model: NativeAgentChatModel
    @State private var draft = ""
    @State private var scrollToBottom = false
    @State private var connectionState = AIProviderConnectionState.checking
    @State private var authenticationProvider: AIProviderCLI?
    @State private var terminalRequest: AIProviderTerminalRequest?
    @State private var showingClearConfirmation = false
    @State private var submissionError: String?

    init(
        provider: AIProviderCLI,
        workspace: URL,
        mode: AgentChatMode = .writing,
        canSend: Bool = true,
        preparePrompt: @escaping (String) throws -> String = { $0 }
    ) {
        self.provider = provider
        self.mode = mode
        self.canSend = canSend
        self.preparePrompt = preparePrompt
        _model = StateObject(wrappedValue: NativeAgentChatModel(
            provider: provider, workspace: workspace, mode: mode
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            if let error = submissionError ?? model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
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
            Divider()
            ZStack {
                ChatView(messages: $model.messages, scrollToBottom: $scrollToBottom) {
                    NativeAgentChatInputView(
                        message: $draft,
                        placeholder: model.isRunning ? "\(provider.shortName) is working…" : "Message \(provider.shortName)"
                    ) { prompt in
                        do {
                            // Prepare synchronously before starting the task: the current
                            // chapter must be captured at Send, not after navigation.
                            let contextualPrompt = try preparePrompt(prompt)
                            submissionError = nil
                            Task {
                                await model.send(prompt, contextualPrompt: contextualPrompt)
                                scrollToBottom = true
                            }
                            return true
                        } catch {
                            submissionError = error.localizedDescription
                            return false
                        }
                    }
                    .disabled(!canSend || model.isRunning || connectionState != .connected)
                }
                .environment(\.chatStyle, chatStyle)

                if connectionState != .connected || model.messages.isEmpty {
                    emptyState
                }
            }
        }
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .task(id: provider.id) {
            model.load()
            await refreshConnectionState()
        }
        .onDisappear { model.cancel() }
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

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Label(provider.shortName, systemImage: provider.systemImage)
                .font(.subheadline.weight(.semibold))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                Text(mode.isReadOnly ? "Chat about scripture" : "Ask \(provider.shortName) to help with this devotional")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(mode.isReadOnly
                    ? "Ask about the chapter you’re reading, or mention any passage. Explore your translations, commentaries, dictionaries, and other modules together."
                    : "The agent can read your context and Lamp modules. Its changes appear in the devotional editor automatically.")
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
                cellBackgroundColor: SwiftUI.Color(nsColor: .controlBackgroundColor),
                cellCornerRadius: 14,
                cellBorderColor: .secondary.opacity(0.16),
                cellBorderWidth: 1,
                cellShadowRadius: 0,
                cellRoundedCorners: [.topRight, .bottomRight, .bottomLeft]
            ),
            outgoingTextStyle: TextCellStyle(
                textStyle: CommonTextStyle(textColor: .white, font: .body),
                textPadding: 12,
                cellBackgroundColor: .accentColor,
                cellCornerRadius: 14,
                cellBorderWidth: 0,
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
    let ansiPattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
    let cleaned = output.replacingOccurrences(
        of: ansiPattern,
        with: "",
        options: .regularExpression
    )
    let lines = cleaned.split(whereSeparator: \.isNewline).map(String.init)
    let humanLines = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("{")
    }
    guard !humanLines.isEmpty else { return nil }
    return humanLines.suffix(4).joined(separator: "\n")
}
