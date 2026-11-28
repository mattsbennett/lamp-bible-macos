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
    var supportsBrowserAuthentication: Bool { self != .openCode && self != .antigravity }

    var authenticationArguments: [String] {
        switch self {
        case .codex: ["login"]
        case .claude: ["auth", "login"]
        case .openCode: ["auth", "login"]
        case .antigravity: ["acp", "--login"]
        }
    }

    var wireProvider: AgentChatWireProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .openCode: .openCode
        case .antigravity: .antigravity
        }
    }
}

/// Every CLI process Lamp has running — chat runs and the helpers that ask
/// a CLI something (usage, sign-in, versions) — so quitting can end the
/// ones nothing else stops. A helper's own timeout is a timer in Lamp, and
/// gone with it.
enum AgentHelperProcesses {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var running: [ObjectIdentifier: AgentSpawnedProcess] = [:]
    private nonisolated(unsafe) static var shuttingDown = false

    /// Launches a process and takes it into the registry in one step, under
    /// the lock quitting takes: once quitting has begun nothing launches, and
    /// nothing launched can be missed by it.
    static func launch(_ process: AgentSpawnedProcess) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !shuttingDown else { throw CocoaError(.userCancelled) }
        try process.run()
        running[ObjectIdentifier(process)] = process
    }

    /// Keeps a write to a process that has exited from raising SIGPIPE,
    /// which would end Lamp: the write fails instead, and is handled.
    static func refuseSIGPIPE(_ pipe: Pipe) {
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    static func untrack(_ process: AgentSpawnedProcess) {
        lock.lock()
        running[ObjectIdentifier(process)] = nil
        lock.unlock()
    }

    /// Ends every one still running, with what it started, and refuses any
    /// launched after. Waits up to a second for each to go before killing
    /// what is left: called while quitting, after the chats have stopped.
    static func terminateAll() {
        lock.lock()
        shuttingDown = true
        let processes = Array(running.values)
        running = [:]
        lock.unlock()
        end(processes)
    }

    /// Asks each one's whole group to stop, then kills the group if the
    /// process has not gone within a second. A group's other members are
    /// killed either way: nothing a helper started outlives it.
    static func end(_ processes: [AgentSpawnedProcess]) {
        // Every group, whether or not its process has exited: what it
        // started may not have. A group whose process has been reaped is
        // left alone by `signalGroup` itself, since its number may since
        // belong to another.
        guard !processes.isEmpty else { return }
        processes.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while processes.contains(where: \.isRunning), Date() < deadline { usleep(20_000) }
        processes.forEach { $0.signalGroup(SIGKILL) }
    }
}

struct AgentCLIProcessResult: Sendable {
    let exitCode: Int32
    let output: String
    let launchError: String?
    /// Lamp stopped it for saying nothing for too long.
    var stalled = false

    /// Stopped in the moment before the provider was launched, so it never
    /// ran at all. Read as a stop rather than a failure: nothing went
    /// wrong, and nothing was done.
    static let stoppedBeforeStarting = AgentCLIProcessResult(
        exitCode: 0, output: "", launchError: nil
    )
}

/// The last few kilobytes a Codex server wrote to stderr, read on its own
/// thread.
private final class AgentCodexErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()

    func append(_ chunk: Data) {
        lock.lock()
        tail += chunk
        if tail.count > 4096 { tail = Data(tail.suffix(4096)) }
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

final class AgentCLIProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: AgentSpawnedProcess?
    private var cancelled = false
    /// When the running provider last said anything.
    private var lastOutput = Date()
    /// Whether the running reply is waiting on the person, to answer a tool
    /// call, which is not stalling however long it takes.
    private var waitingOnPerson = false
    private var stalled = false
    /// Set while an ACP turn runs: how to ask the agent to stop, which is
    /// its own `session/cancel` rather than a signal.
    private var acpCancel: (() -> Void)?
    /// Set while a Codex app-server or Antigravity turn runs: how the card's
    /// answer reaches the request waiting on it.
    /// Answers a waiting request: its key, the answer, and whether it is
    /// allowed for the chat too (`AgentChatCommandGrants`).
    private var runnerAnswer: ((String, AgentToolApprovalAnswer, Bool) -> Bool)?

    /// How long a run may say nothing before Lamp stops it. A provider in
    /// trouble — retrying an overloaded API, or held at a usage limit — can
    /// otherwise keep a reply spinning for hours.
    static let stallMinutes = 10
    /// How long a stopped provider has to exit on its own before it and
    /// everything it started are killed.
    static let stopGraceSeconds = 5.0
    /// How long an ACP agent has to end a cancelled prompt before it is
    /// stopped as any CLI is. With `stopGraceSeconds` after it, the worst
    /// case stays inside what quitting waits for.
    static let acpCancelGraceSeconds = 2.0

    func setWaitingOnPerson(_ waiting: Bool) {
        lock.lock()
        // Only as it changes: asked four times a second while nothing is
        // pending, resetting the clock every time kept a silent run looking
        // busy for ever.
        if waitingOnPerson != waiting { lastOutput = Date() }
        waitingOnPerson = waiting
        lock.unlock()
    }

    /// Kills whatever is left of a run's group once the run is over, stopped
    /// or not: a tool's process that outlived the CLI could otherwise go on
    /// writing the draft after the turn was collected, or after an undo.
    /// Nothing a turn starts is meant to outlive it; what is (OpenCode's
    /// background server) leaves the group on its own.
    private func endWhatTheRunLeft(_ process: AgentSpawnedProcess) {
        process.signalGroup(SIGKILL)
        // And what left the group: see `AgentRunMembers`.
        members(of: process, clearing: true)?.endAll()
    }

    /// Every process the running run has started, including those that
    /// left its group, with the process it belongs to; see
    /// `AgentRunMembers`.
    private var runMembers: (process: AgentSpawnedProcess, members: AgentRunMembers)?

    /// The record of `process`'s run, never another's: a stop that fires
    /// late, after the next run began, must not end the next run's tools.
    private func members(of process: AgentSpawnedProcess, clearing: Bool = false) -> AgentRunMembers? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = runMembers, current.process === process else { return nil }
        if clearing { runMembers = nil }
        return current.members
    }

    /// Starts recording a run's processes, every two seconds until the run
    /// ends.
    private func recordMembers(of process: AgentSpawnedProcess) -> DispatchSourceTimer {
        let members = AgentRunMembers(rootPID: process.processIdentifier)
        lock.lock()
        runMembers = (process, members)
        lock.unlock()
        // Often, since a command started and orphaned between two looks is
        // never seen; one look at the process table is a few milliseconds.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.2, repeating: 0.5)
        timer.setEventHandler { members.sample() }
        timer.resume()
        return timer
    }

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
        let askToStop = acpCancel
        lock.unlock()
        if let askToStop {
            // Off the caller's thread: it writes to the agent's input, and a
            // Stop pressed on the main thread must never wait on a pipe.
            DispatchQueue.global(qos: .userInitiated).async { askToStop() }
        } else if let process {
            // Whether or not the provider itself is still running: a child
            // it left can be, holding the output open or editing files.
            stop(process)
        }
    }

    /// Asks the provider's whole group to stop, then kills the group if the
    /// provider has not exited a few seconds later. The ask comes first so a
    /// CLI can save its session, which the next message resumes. What is
    /// left of the group is also killed as the run ends; see
    /// `endWhatTheRunLeft`.
    private func stop(_ process: AgentSpawnedProcess) {
        let members = members(of: process)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.stopGraceSeconds) {
            // Whether or not the provider has exited: a child that ignored
            // the ask and holds the output open would otherwise keep the run
            // from ever ending. Once the run has released the process, this
            // does nothing; the recorded members are checked by identity.
            process.signalGroup(SIGKILL)
            members?.endAll()
        }
    }

    /// Readies the runner for a run, clearing the last one's stop.
    ///
    /// Done by the caller **before** the work is scheduled. Cleared inside
    /// the worker instead, a Stop pressed between scheduling and the worker
    /// starting was wiped by the run it was meant to stop.
    /// The chat whose allowed commands this run answers without asking
    /// (`AgentChatCommandGrants`), set before each run.
    private var chatGrantKey: String?

    func useChatGrants(_ key: String?) {
        lock.lock()
        chatGrantKey = key
        lock.unlock()
    }

    /// Whether this request was allowed for the chat already: the same
    /// command, byte for byte, in the same folder.
    fileprivate func isAllowedForChat(_ request: AgentToolApprovalRequest) -> Bool {
        lock.lock()
        let key = chatGrantKey
        lock.unlock()
        guard let key, let grant = request.chatGrant else { return false }
        return AgentChatCommandGrants.shared.contains(grant, for: key)
    }

    func prepareForRun() {
        lock.lock()
        cancelled = false
        stalled = false
        waitingOnPerson = false
        lastOutput = Date()
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
            let process = AgentSpawnedProcess()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = output
            process.standardError = output
            // No stdin (`/dev/null`): inheriting Lamp's own, `codex exec`
            // announces "Reading additional input from stdin…" and blocks on
            // it forever — the chat pane spinning with no reply.
            process.standardInput = nil
            var environment = AgentProcessEnvironment.cleaned(ProcessInfo.processInfo.environment)
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
            try AgentHelperProcesses.launch(process)
            let recording = recordMembers(of: process)
            defer { recording.cancel() }
            // And once more, now there is something to terminate. Stop
            // between the guard above and this line found an assigned but
            // unstarted process and killed nothing, so the provider ran on
            // — doing, for a writing agent, work on the person's draft
            // after they had said stop.
            if isCancelled { stop(process) }
            let watchdog = watchForStall(in: process)
            defer { watchdog.cancel() }
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
                lock.lock()
                lastOutput = Date()
                lock.unlock()
                collected += chunk
                guard let onLine else { continue }
                for line in reader.lines(from: chunk) { onLine(line) }
            }
            if let onLine, let last = reader.flush() { onLine(last) }
            process.waitUntilExit()
            endWhatTheRunLeft(process)
            AgentHelperProcesses.untrack(process)
            process.release()
            lock.lock()
            let wasStalled = stalled
            lock.unlock()
            return AgentCLIProcessResult(
                exitCode: process.terminationStatus,
                output: String(decoding: collected, as: UTF8.self),
                launchError: nil,
                stalled: wasStalled
            )
        } catch {
            return AgentCLIProcessResult(exitCode: -1, output: "", launchError: error.localizedDescription)
        }
    }

    /// One Antigravity turn over `agy acp`; see `AgentACPRun`. The whole
    /// conversation — what the agent sent, and its answers to Lamp — is the
    /// output, line by line, which `AgentChatWireParser` reads as for any
    /// provider. Lamp's own requests are not in it.
    func runACP(
        executableName: String,
        workingDirectory: URL,
        mode: AgentChatMode,
        writingServer: LampAgentMCPConfiguration? = nil,
        sessionID: String?,
        model: String?,
        effort: String?,
        prompt: String,
        answerSeconds: Double = AgentCodexRun.answerSeconds,
        onLine: (@Sendable (String) -> Void)? = nil,
        onApprovals: (@Sendable ([AgentToolApprovalRequest]) -> Void)? = nil
    ) async -> AgentCLIProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: runACPSynchronously(
                    executableName: executableName, workingDirectory: workingDirectory, mode: mode,
                    writingServer: writingServer,
                    sessionID: sessionID, model: model, effort: effort, prompt: prompt,
                    answerSeconds: answerSeconds, onLine: onLine, onApprovals: onApprovals
                ))
            }
        }
    }

    private func runACPSynchronously(
        executableName: String,
        workingDirectory: URL,
        mode: AgentChatMode,
        writingServer: LampAgentMCPConfiguration?,
        sessionID resumed: String?,
        model: String?,
        effort: String?,
        prompt: String,
        answerSeconds: Double,
        onLine: (@Sendable (String) -> Void)?,
        onApprovals: (@Sendable ([AgentToolApprovalRequest]) -> Void)?
    ) -> AgentCLIProcessResult {
        if mode.isReadOnly {
            let settings = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/settings.json")
            if let refusal = AgentACPRun.readerRefusal(settings: try? Data(contentsOf: settings)) {
                return AgentCLIProcessResult(exitCode: 1, output: "", launchError: refusal)
            }
        }
        do {
            let executableURL = try resolveExecutable(named: executableName)
            guard !isCancelled else { return .stoppedBeforeStarting }
            let process = AgentSpawnedProcess()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = AgentChatLaunchArguments.make(
                provider: .antigravity, prompt: prompt, sessionID: resumed, proposedSessionID: nil, mode: mode
            )
            process.currentDirectoryURL = workingDirectory
            AgentHelperProcesses.refuseSIGPIPE(input)
            process.standardInput = input
            process.standardOutput = output
            // Its own logs, not the conversation.
            process.standardError = nil
            var environment = AgentProcessEnvironment.cleaned(ProcessInfo.processInfo.environment)
            environment["PWD"] = workingDirectory.path
            process.environment = environment

            // Two locks: one keeps lines whole on the agent's input, the
            // other guards what a Stop on another thread reads. Holding one
            // while taking the other again is how the prompt never went.
            let writeLock = NSLock()
            let stateLock = NSLock()
            func send(_ message: [String: Any]) {
                sendDecided { message }
            }
            /// Writes what `make` decides, deciding it only once the write is
            /// Lamp's to make, so a Stop pressed while it waited is seen.
            /// `make` returning nil writes nothing: decided, under the lock,
            /// that nothing is to go.
            @discardableResult
            func sendDecided(_ make: () -> [String: Any]?) -> Bool {
                writeLock.lock()
                defer { writeLock.unlock() }
                guard var message = make() else { return false }
                message["jsonrpc"] = "2.0"
                guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
                return (try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))) != nil
            }

            var session: String?
            var promptID: Int?
            var cancelSent = false
            var stopped = false
            let replies = DispatchQueue(label: "lamp.acp.replies")
            // Commands on the card, by Lamp's key: the agent's own id to
            // answer with, its request (for the options), and as shown.
            var waiting: [(key: String, id: Any, params: [String: Any], request: AgentToolApprovalRequest)] = []
            func publish() {
                // Called with `stateLock` held, so the list goes out in order.
                onApprovals?(waiting.map(\.request))
                setWaitingOnPerson(!waiting.isEmpty)
            }
            /// Answers one waiting command, once. After Stop it is cancelled,
            /// whatever the answer, as ACP answers an outstanding request
            /// then.
            func settle(_ key: String, _ answer: AgentToolApprovalAnswer, _ forChat: Bool = false) -> Bool {
                stateLock.lock()
                guard let index = waiting.firstIndex(where: { $0.key == key }) else {
                    stateLock.unlock()
                    return false
                }
                let entry = waiting.remove(at: index)
                let outcome: [String: Any] = AgentACPRun.outcome(for: answer, permission: entry.params)
                self.forgetReply(entry.key)
                publish()
                // Queued under the same lock that took it off the card, so a
                // Stop's cancel can't be queued ahead of it; written off the
                // caller's thread, the card's being the main one; and judged
                // again as it is written, so one pressed just before Stop is
                // cancelled after all. Said to have gone only once written.
                replies.async {
                    var asAnswered = false
                    var takeBack: (() -> Void)?
                    let wrote = sendDecided {
                        stateLock.lock()
                        let late = stopped
                        stateLock.unlock()
                        let refused = late || self.isCancelled
                        asAnswered = !refused || answer == .deny
                        if !refused, answer == .allow, forChat { takeBack = self.keepGrant(for: entry.request) }
                        return ["id": entry.id, "result": ["outcome": refused ? ["outcome": "cancelled"] : outcome]]
                    }
                    if !wrote { takeBack?() }
                    self.noteReply(entry.key, asAnswered: wrote && asAnswered)
                }
                stateLock.unlock()
                return true
            }
            func declineAll() {
                stateLock.lock()
                let keys = waiting.map(\.key)
                stateLock.unlock()
                for key in keys { _ = settle(key, .deny) }
            }
            lock.lock()
            activeProcess = process
            runnerAnswer = { settle($0, $1, $2) }
            acpCancel = { [weak self] in
                // Nothing waiting is allowed after Stop. Then it is asked of
                // the agent while it is answering, which ends the prompt as
                // cancelled and lets it save; and if it does not end, the
                // process and what it started are stopped.
                stateLock.lock()
                stopped = true
                let sessionToCancel = promptID != nil ? session : nil
                let first = !cancelSent
                cancelSent = true
                stateLock.unlock()
                if let sessionToCancel, first {
                    // Armed before any write, which can block on a full pipe
                    // if the agent has stopped reading: the answers to what
                    // waits on the card, then the cancel.
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.acpCancelGraceSeconds) {
                        self?.stop(process)
                    }
                    declineAll()
                    // After the replies, through the same writer, so none is
                    // overtaken by the cancel.
                    replies.async { send(["method": "session/cancel", "params": ["sessionId": sessionToCancel]]) }
                } else {
                    self?.stop(process)
                    declineAll()
                }
            }
            lock.unlock()
            defer {
                lock.lock()
                if activeProcess === process { activeProcess = nil }
                acpCancel = nil
                runnerAnswer = nil
                lock.unlock()
            }

            guard !isCancelled else { return .stoppedBeforeStarting }
            try AgentHelperProcesses.launch(process)
            let recording = recordMembers(of: process)
            defer { recording.cancel() }
            if isCancelled { stop(process) }
            let watchdog = watchForStall(in: process)
            defer { watchdog.cancel() }

            let home = FileManager.default.homeDirectoryForCurrentUser
            var nextID = 1
            var pending: [Int: String] = [:]
            func request(_ method: String, _ params: [String: Any]) -> Int {
                let id = nextID
                nextID += 1
                pending[id] = method
                send(["id": id, "method": method, "params": params])
                return id
            }
            _ = request("initialize", AgentACPRun.initialize())
            var configurationQueue: [(method: String, params: [String: Any])] = []
            var refusal: String?
            var answered = false
            var failed = false

            let handle = output.fileHandleForReading
            var collected = Data()
            var reader = AgentChatLineReader()
            reading: while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                lastOutput = Date()
                lock.unlock()
                for line in reader.lines(from: chunk) {
                    let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    // The answer to setting the model or thinking level is
                    // Lamp's business: refused, the turn goes on with the
                    // default, and it is not read as the run failing.
                    let isSettingAnswer = message.flatMap { $0["id"] as? Int }
                        .flatMap { pending[$0] }
                        .map { ["session/set_mode", "session/set_config_option"].contains($0) } ?? false
                    if !isSettingAnswer {
                        collected += Data(line.utf8) + Data([0x0A])
                        onLine?(line)
                    }
                    guard let message else { continue }
                    if let method = message["method"] as? String, let id = message["id"] {
                        // A request from the agent.
                        if method == "session/request_permission", let params = message["params"] as? [String: Any],
                           let ask = AgentACPRun.commandRequest(
                               permission: params, readOnly: mode.isReadOnly, id: "agy-\(UUID().uuidString)",
                               sessionFolder: workingDirectory.path
                           ) {
                            // Keyed by a name of Lamp's own, never the agent's
                            // id: "1" and 1 spell the same, and an id used
                            // again after its answer would meet the old
                            // request's timer. The agent's id answers it.
                            // A command, put to the person; see `commandRequest`.
                            // One allowed for this chat already is answered as
                            // Allow once, unasked (`decisions/0044`).
                            let allowedForChat = isAllowedForChat(ask)
                            stateLock.lock()
                            let refuse = stopped || isCancelled
                            if !refuse, !allowedForChat {
                                waiting.append((ask.id, id, params, ask))
                                publish()
                            }
                            stateLock.unlock()
                            if refuse {
                                send(["id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                            } else if allowedForChat {
                                // Through the writer the card's answers take,
                                // and judged as it is written, so a Stop
                                // pressed meanwhile still wins, and a grant
                                // removed meanwhile puts it on the card.
                                replies.async {
                                    // Looked at again under the writer's
                                    // lock, as the answer is decided.
                                    var revoked = false
                                    sendDecided {
                                        stateLock.lock()
                                        let late = stopped
                                        stateLock.unlock()
                                        if !late, !self.isCancelled, !self.isAllowedForChat(ask) {
                                            revoked = true
                                            return nil
                                        }
                                        let outcome: [String: Any] = late || self.isCancelled
                                            ? ["outcome": "cancelled"] : AgentACPRun.outcome(for: .allow, permission: params)
                                        return ["id": id, "result": ["outcome": outcome]]
                                    }
                                    guard revoked else { return }
                                    stateLock.lock()
                                    let refuse = stopped || self.isCancelled
                                    if !refuse { waiting.append((ask.id, id, params, ask)); publish() }
                                    stateLock.unlock()
                                    if refuse { send(["id": id, "result": ["outcome": ["outcome": "cancelled"]]]) }
                                    else {
                                        DispatchQueue.global().asyncAfter(deadline: .now() + answerSeconds) { _ = settle(ask.id, .deny) }
                                    }
                                }
                            } else {
                                DispatchQueue.global().asyncAfter(deadline: .now() + answerSeconds) {
                                    _ = settle(ask.id, .deny)
                                }
                            }
                        } else if method == "session/request_permission", let params = message["params"] as? [String: Any] {
                            stateLock.lock()
                            let currentSession = session
                            stateLock.unlock()
                            // After Stop nothing more is approved: ACP answers an
                            // outstanding request with `cancelled` then.
                            let choice = isCancelled ? nil : AgentACPRun.decide(
                                permission: params, readOnly: mode.isReadOnly, workspace: workingDirectory,
                                home: home, sessionID: currentSession
                            )
                            let outcome: [String: Any] = choice.map { ["outcome": "selected", "optionId": $0] }
                                ?? ["outcome": "cancelled"]
                            send(["id": id, "result": ["outcome": outcome]])
                        } else {
                            send(["id": id, "error": ["code": -32601, "message": "Lamp does not provide \(method)."]])
                        }
                        continue
                    }
                    guard let id = message["id"] as? Int, let method = pending.removeValue(forKey: id) else { continue }
                    // A model or level Antigravity does not know is said (the
                    // error is in the output) and the turn goes on without it;
                    // any other error ends the turn.
                    if message["error"] != nil, method == "session/set_mode", mode.isReadOnly {
                        // Without the asking mode, actions the session's own
                        // mode approves would never reach Lamp's rule.
                        refusal = "Antigravity wouldn’t switch to asking before it acts, so Lamp didn’t send this reader question."
                        failed = true
                        break reading
                    }
                    if message["error"] != nil, !["session/set_mode", "session/set_config_option"].contains(method) {
                        failed = true
                        break reading
                    }
                    let result = message["result"] as? [String: Any] ?? [:]
                    switch method {
                    case "initialize":
                        let open = AgentACPRun.open(
                            sessionID: resumed, workspace: workingDirectory,
                            mcpServers: AgentACPRun.mcpServers(mode: mode, writingServer: writingServer)
                        )
                        _ = request(open.method, open.params)
                    case "session/new", "session/resume":
                        guard let sessionID = result["sessionId"] as? String ?? resumed else {
                            failed = true
                            break reading
                        }
                        stateLock.lock(); session = sessionID; stateLock.unlock()
                        configurationQueue = AgentACPRun.configuration(sessionID: sessionID, model: model, effort: effort)
                        if isCancelled { break reading }
                        if !configurationQueue.isEmpty {
                            let next = configurationQueue.removeFirst()
                            _ = request(next.method, next.params)
                        } else {
                            let id = request("session/prompt", AgentACPRun.prompt(sessionID: sessionID, text: prompt)); stateLock.lock(); promptID = id; stateLock.unlock()
                        }
                    case "session/set_mode", "session/set_config_option":
                        guard let sessionID = session else { break }
                        if isCancelled { break reading }
                        if !configurationQueue.isEmpty {
                            let next = configurationQueue.removeFirst()
                            _ = request(next.method, next.params)
                        } else {
                            let id = request("session/prompt", AgentACPRun.prompt(sessionID: sessionID, text: prompt)); stateLock.lock(); promptID = id; stateLock.unlock()
                        }
                    case "session/prompt":
                        answered = true
                        break reading
                    default:
                        break
                    }
                }
            }
            if let onLine, let last = reader.flush() { onLine(last) }
            // Nothing outlives the turn on the card.
            stateLock.lock(); stopped = true; stateLock.unlock()
            declineAll()
            // Every reply written before the input closes.
            replies.sync {}
            // The turn is over: closing its input ends `agy acp`, which then
            // saves and exits; one that does not is stopped.
            try? input.fileHandleForWriting.close()
            if !process.waitUntilExit(within: Self.stopGraceSeconds) {
                stop(process)
                process.waitUntilExit()
            }
            endWhatTheRunLeft(process)
            AgentHelperProcesses.untrack(process)
            process.release()
            lock.lock()
            let wasStalled = stalled
            lock.unlock()
            return AgentCLIProcessResult(
                exitCode: answered && !failed ? 0 : 1,
                output: String(decoding: collected, as: UTF8.self),
                launchError: refusal,
                stalled: wasStalled
            )
        } catch {
            return AgentCLIProcessResult(exitCode: -1, output: "", launchError: error.localizedDescription)
        }
    }

    /// One Codex writing turn over `codex app-server`; see `AgentCodexRun`.
    /// What Codex sent, but for its commentary, is the output, line by line,
    /// as for any provider. A command it asks to run outside its sandbox is
    /// handed to `onApprovals` for the card, and answered by
    /// `answerApproval`; unanswered, it is declined after
    /// `AgentCodexRun.answerSeconds`, and on Stop, never allowed.
    func runCodexAppServer(
        executableName: String,
        workingDirectory: URL,
        writingServer: LampAgentMCPConfiguration?,
        threadID: String?,
        model: String?,
        effort: String?,
        prompt: String,
        answerSeconds: Double = AgentCodexRun.answerSeconds,
        onLine: (@Sendable (String) -> Void)? = nil,
        onApprovals: (@Sendable ([AgentToolApprovalRequest]) -> Void)? = nil
    ) async -> AgentCLIProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: runCodexAppServerSynchronously(
                    executableName: executableName, workingDirectory: workingDirectory,
                    writingServer: writingServer, threadID: threadID, model: model, effort: effort,
                    prompt: prompt, answerSeconds: answerSeconds, onLine: onLine, onApprovals: onApprovals
                ))
            }
        }
    }

    /// What was written for each answered card, by its key: true where it
    /// was the answer given, false where Stop turned it to a refusal first.
    private var repliesSent: [String: Bool] = [:]

    fileprivate func forgetReply(_ key: String) {
        lock.lock()
        repliesSent[key] = nil
        lock.unlock()
    }

    fileprivate func noteReply(_ key: String, asAnswered: Bool) {
        lock.lock()
        repliesSent[key] = asAnswered
        lock.unlock()
    }

    /// Whether the reply to a card answered with `answerApproval` went as
    /// answered, once it has been written; false if it is not written within
    /// `seconds`, or Stop turned an Allow to a refusal first.
    func replyWentAsAnswered(_ key: String, seconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock()
            let sent = repliesSent[key]
            lock.unlock()
            if let sent { return sent }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Gives a waiting Codex request the person's answer. False when it is
    /// no longer waiting: answered by its timeout, or ended with the turn.
    ///
    /// `forChat`: remembered for the chat as well, when it is allowed. The
    /// grant is kept before the answer is written, so a provider asking again
    /// the moment it reads it finds it, and taken back if the write failed.
    @discardableResult
    func answerApproval(_ id: String, with answer: AgentToolApprovalAnswer, forChat: Bool = false) -> Bool {
        lock.lock()
        let answering = runnerAnswer
        lock.unlock()
        return answering?(id, answer, forChat) ?? false
    }

    /// Keeps a grant for the running chat, returning what to take back if
    /// the answer is never written.
    fileprivate func keepGrant(for request: AgentToolApprovalRequest) -> (() -> Void)? {
        lock.lock()
        let key = chatGrantKey
        lock.unlock()
        guard let key, let grant = request.chatGrant else { return nil }
        let had = AgentChatCommandGrants.shared.contains(grant, for: key)
        AgentChatCommandGrants.shared.add(grant, for: key)
        return had ? {} : { AgentChatCommandGrants.shared.remove(grant, for: key) }
    }

    private func runCodexAppServerSynchronously(
        executableName: String,
        workingDirectory: URL,
        writingServer: LampAgentMCPConfiguration?,
        threadID resumed: String?,
        model: String?,
        effort: String?,
        prompt: String,
        answerSeconds: Double,
        onLine: (@Sendable (String) -> Void)?,
        onApprovals: (@Sendable ([AgentToolApprovalRequest]) -> Void)?
    ) -> AgentCLIProcessResult {
        do {
            let executableURL = try resolveExecutable(named: executableName)
            guard !isCancelled else { return .stoppedBeforeStarting }
            let process = AgentSpawnedProcess()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = AgentCodexRun.launchArguments(writingServer: writingServer, effort: effort)
            process.currentDirectoryURL = workingDirectory
            AgentHelperProcesses.refuseSIGPIPE(input)
            process.standardInput = input
            process.standardOutput = output
            // Its own logs, not the conversation; but where it ends before
            // the protocol could say why, the reason is only there, so the
            // last of it is kept.
            let errors = Pipe()
            process.standardError = errors
            let errorTail = AgentCodexErrorTail()
            let readingErrors = DispatchGroup()
            var environment = AgentProcessEnvironment.cleaned(ProcessInfo.processInfo.environment)
            environment["PWD"] = workingDirectory.path
            process.environment = environment

            // As in `runACPSynchronously`: one lock keeps lines whole on the
            // server's input, the other guards what Stop and the card read.
            let writeLock = NSLock()
            let stateLock = NSLock()
            func send(_ message: [String: Any]) {
                sendDecided { message }
            }
            /// As for Antigravity: decided once the write is Lamp's to make.
            @discardableResult
            func sendDecided(_ make: () -> [String: Any]?) -> Bool {
                writeLock.lock()
                defer { writeLock.unlock() }
                // Slashes as written, so a method reads as itself in a log.
                guard let message = make(),
                      let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
                else { return false }
                return (try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))) != nil
            }

            var thread: String?
            var turn: String?
            var interruptSent = false
            var stopped = false
            let replies = DispatchQueue(label: "lamp.codex.replies")
            // Requests on the card, by Lamp's key: Codex's own id, to answer
            // with, and the request as shown.
            var waiting: [(key: String, id: Any, request: AgentToolApprovalRequest)] = []
            func publish() {
                // Called with `stateLock` held, so the list goes out in order.
                onApprovals?(waiting.map(\.request))
                setWaitingOnPerson(!waiting.isEmpty)
            }
            /// Answers one waiting request, once. After Stop, nothing is
            /// allowed, whatever the answer: read from the runner's own
            /// flag, which Stop sets before anything else, as well as this
            /// turn's, set a moment later on another thread.
            func settle(_ key: String, _ answer: AgentToolApprovalAnswer, _ forChat: Bool = false) -> Bool {
                stateLock.lock()
                guard let index = waiting.firstIndex(where: { $0.key == key }) else {
                    stateLock.unlock()
                    return false
                }
                let entry = waiting.remove(at: index)
                self.forgetReply(entry.key)
                publish()
                // Queued under the lock, written off the caller's thread, and
                // judged again as it is written, as for Antigravity.
                replies.async {
                    var asAnswered = false
                    var takeBack: (() -> Void)?
                    let wrote = sendDecided {
                        stateLock.lock()
                        let late = stopped
                        stateLock.unlock()
                        let refused = late || self.isCancelled
                        asAnswered = !refused || answer == .deny
                        if !refused, answer == .allow, forChat { takeBack = self.keepGrant(for: entry.request) }
                        return ["id": entry.id, "result": AgentCodexRun.decision(refused ? .deny : answer)]
                    }
                    if !wrote { takeBack?() }
                    self.noteReply(entry.key, asAnswered: wrote && asAnswered)
                }
                stateLock.unlock()
                return true
            }
            func declineAll() {
                stateLock.lock()
                let keys = waiting.map(\.key)
                stateLock.unlock()
                for key in keys { _ = settle(key, .deny) }
            }

            lock.lock()
            activeProcess = process
            runnerAnswer = { settle($0, $1, $2) }
            acpCancel = { [weak self] in
                // Nothing waiting is allowed after Stop; then the turn is
                // interrupted, which lets Codex save, and a server that does
                // not end is stopped with what it started.
                stateLock.lock()
                stopped = true
                let toInterrupt = thread.flatMap { thread in turn.map { (thread, $0) } }
                let first = !interruptSent
                interruptSent = true
                stateLock.unlock()
                if let toInterrupt, first {
                    // Armed before any write, which can block on a full pipe.
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.acpCancelGraceSeconds) {
                        self?.stop(process)
                    }
                    declineAll()
                    replies.async {
                        send(["id": 1_000_000, "method": "turn/interrupt",
                              "params": AgentCodexRun.interrupt(threadID: toInterrupt.0, turnID: toInterrupt.1)])
                    }
                } else {
                    self?.stop(process)
                    declineAll()
                }
            }
            lock.unlock()
            defer {
                lock.lock()
                if activeProcess === process { activeProcess = nil }
                acpCancel = nil
                runnerAnswer = nil
                lock.unlock()
            }

            guard !isCancelled else { return .stoppedBeforeStarting }
            try AgentHelperProcesses.launch(process)
            // Read once it runs: launching closes this end's writer, so the
            // reader ends with the server, and one started for a launch that
            // never happened would wait for ever.
            readingErrors.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readingErrors.leave() }
                let handle = errors.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }
                    errorTail.append(chunk)
                }
            }
            let recording = recordMembers(of: process)
            defer { recording.cancel() }
            if isCancelled { stop(process) }
            let watchdog = watchForStall(in: process)
            defer { watchdog.cancel() }

            var nextID = 1
            var pending: [Int: String] = [:]
            func request(_ method: String, _ params: [String: Any]) {
                let id = nextID
                nextID += 1
                pending[id] = method
                send(["id": id, "method": method, "params": params])
            }
            request("initialize", AgentCodexRun.initialize())
            var answered = false
            var failed = false
            // Whether Codex said what went wrong, in the protocol.
            var explained = false
            var commentary = AgentCodexRun.Commentary()

            let handle = output.fileHandleForReading
            var collected = Data()
            var reader = AgentChatLineReader()
            reading: while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                lastOutput = Date()
                lock.unlock()
                for line in reader.lines(from: chunk) {
                    let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    if let message, AgentCodexRun.isUnread(message) || commentary.isCommentary(message) { continue }
                    collected += Data(line.utf8) + Data([0x0A])
                    onLine?(line)
                    guard let message else { continue }
                    let params = message["params"] as? [String: Any] ?? [:]
                    if let method = message["method"] as? String, let id = message["id"] {
                        // A request from Codex.
                        guard let key = AgentCodexRun.requestKey(id) else { continue }
                        switch AgentCodexRun.reply(to: method, params: params, id: key) {
                        case .ask(let approval):
                            // One allowed for this chat already is accepted,
                            // once, unasked (`decisions/0044`).
                            let allowedForChat = isAllowedForChat(approval)
                            stateLock.lock()
                            let refuse = stopped || isCancelled
                            if !refuse, !allowedForChat {
                                waiting.append((key, id, approval))
                                publish()
                            }
                            stateLock.unlock()
                            if refuse {
                                send(["id": id, "result": AgentCodexRun.decision(.deny)])
                            } else if allowedForChat {
                                replies.async {
                                    // A grant removed meanwhile puts it on
                                    // the card after all: looked at again
                                    // under the writer's lock.
                                    var revoked = false
                                    sendDecided {
                                        stateLock.lock()
                                        let late = stopped
                                        stateLock.unlock()
                                        if !late, !self.isCancelled, !self.isAllowedForChat(approval) {
                                            revoked = true
                                            return nil
                                        }
                                        return ["id": id, "result": AgentCodexRun.decision(late || self.isCancelled ? .deny : .allow)]
                                    }
                                    guard revoked else { return }
                                    stateLock.lock()
                                    let refuse = stopped || self.isCancelled
                                    if !refuse { waiting.append((key, id, approval)); publish() }
                                    stateLock.unlock()
                                    if refuse { send(["id": id, "result": AgentCodexRun.decision(.deny)]) }
                                    else {
                                        DispatchQueue.global().asyncAfter(deadline: .now() + answerSeconds) { _ = settle(key, .deny) }
                                    }
                                }
                            } else {
                                DispatchQueue.global().asyncAfter(deadline: .now() + answerSeconds) {
                                    _ = settle(key, .deny)
                                }
                            }
                        case .answer(let result):
                            send(["id": id, "result": result])
                        case .refuse(let reason):
                            send(["id": id, "error": ["code": -32601, "message": reason]])
                        }
                        continue
                    }
                    if let method = message["method"] as? String {
                        switch method {
                        case "serverRequest/resolved":
                            // Settled by Codex itself, the turn ending: the
                            // card goes.
                            if let id = params["requestId"], let key = AgentCodexRun.requestKey(id) {
                                stateLock.lock()
                                waiting.removeAll { $0.key == key }
                                publish()
                                stateLock.unlock()
                            }
                        case "turn/started":
                            if let id = (params["turn"] as? [String: Any])?["id"] as? String {
                                stateLock.lock(); turn = id; stateLock.unlock()
                            }
                        case "turn/completed":
                            let status = (params["turn"] as? [String: Any])?["status"] as? String
                            answered = status == "completed"
                            failed = status == "failed"
                            explained = true
                            break reading
                        case "error":
                            explained = true
                        default:
                            break
                        }
                        continue
                    }
                    guard let id = message["id"] as? Int, let method = pending.removeValue(forKey: id) else { continue }
                    if message["error"] != nil {
                        failed = true
                        explained = true
                        break reading
                    }
                    let result = message["result"] as? [String: Any] ?? [:]
                    switch method {
                    case "initialize":
                        send(["method": "initialized"])
                        let open = AgentCodexRun.open(threadID: resumed, workspace: workingDirectory, model: model)
                        request(open.method, open.params)
                    case "thread/start", "thread/resume":
                        guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
                            failed = true
                            break reading
                        }
                        stateLock.lock(); thread = id; stateLock.unlock()
                        if isCancelled { break reading }
                        request("turn/start", AgentCodexRun.turn(threadID: id, text: prompt))
                    case "turn/start":
                        if let id = (result["turn"] as? [String: Any])?["id"] as? String {
                            stateLock.lock(); turn = id; stateLock.unlock()
                        }
                        // Stop pressed before the turn had a name to
                        // interrupt it by.
                        if isCancelled { acpCancel?() }
                    default:
                        break
                    }
                }
            }
            if let onLine, let last = reader.flush() { onLine(last) }
            // Nothing outlives the turn on the card.
            stateLock.lock(); stopped = true; stateLock.unlock()
            declineAll()
            // Every reply written before the input closes.
            replies.sync {}
            try? input.fileHandleForWriting.close()
            if !process.waitUntilExit(within: Self.stopGraceSeconds) {
                stop(process)
                process.waitUntilExit()
            }
            endWhatTheRunLeft(process)
            readingErrors.wait()
            AgentHelperProcesses.untrack(process)
            process.release()
            lock.lock()
            let wasStalled = stalled
            lock.unlock()
            // Ended without a word from the protocol, and not by Stop: what
            // Codex printed is the only account of why ("Codex exited with
            // status 1" says nothing).
            let unexplained = !answered && !explained && !isCancelled && !wasStalled
            let printed = String(decoding: errorTail.value, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentCLIProcessResult(
                exitCode: answered && !failed ? 0 : 1,
                output: String(decoding: collected, as: UTF8.self),
                launchError: unexplained && !printed.isEmpty ? "Codex stopped before answering: \(printed)" : nil,
                stalled: wasStalled
            )
        } catch {
            return AgentCLIProcessResult(exitCode: -1, output: "", launchError: error.localizedDescription)
        }
    }

    /// Ends a helper launch that has not finished in `seconds`, so reading
    /// its output returns.
    private static func giveUp(on process: AgentSpawnedProcess, after seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            // `end` leaves alone a process that has already finished.
            AgentHelperProcesses.end([process])
        }
    }

    /// Stops the run once it has said nothing for `stallMinutes`, except
    /// while it waits on the person.
    private func watchForStall(in process: AgentSpawnedProcess) -> DispatchSourceTimer {
        lock.lock()
        lastOutput = Date()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.waitingOnPerson { self.lastOutput = Date() }
            let quiet = Date().timeIntervalSince(self.lastOutput)
            let stall = !self.stalled && quiet > Double(Self.stallMinutes * 60)
            if stall { self.stalled = true }
            self.lock.unlock()
            if stall { self.stop(process) }
        }
        timer.resume()
        return timer
    }

    /// The major version the installed CLI reports, or nil when it will not
    /// say. Asked once per executable for the app's run: a CLI does not change
    /// under a running app, and this is a process launch per chat message
    /// otherwise.
    func majorVersion(ofExecutableNamed name: String) -> Int? {
        guard let url = try? resolveExecutable(named: name) else { return nil }
        // Kept by the program itself, as `helpLists` keeps its answers: one
        // updated while Lamp is open is asked again.
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let identity = "\(url.path) \(info.st_ino) \(info.st_mtimespec.tv_sec) \(info.st_size)"
        Self.versionLock.lock()
        let known = Self.versionsByName[identity]
        Self.versionLock.unlock()
        if let known { return known }
        let process = AgentSpawnedProcess()
        let output = Pipe()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = output
        guard (try? AgentHelperProcesses.launch(process)) != nil else { return nil }
        Self.giveUp(on: process, after: 20)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        AgentHelperProcesses.untrack(process)
        process.release()
        let major = AgentChatCLIVersion.major(
            fromVersionOutput: String(decoding: data, as: UTF8.self)
        )
        Self.versionLock.lock()
        Self.versionsByName[identity] = major
        Self.versionLock.unlock()
        return major
    }

    /// Whether `codex exec --help` lists `flag`, asked once per executable
    /// and kept; nil where the help could not be read.
    func codexExecTakes(_ flag: String, executableNamed name: String) -> Bool? {
        helpLists(flag, executableNamed: name, asking: ["exec", "--help"])
    }

    /// Whether a CLI's help, asked with `asking`, lists `flag`; asked once
    /// per executable and kept, nil where the help could not be read.
    func helpLists(_ flag: String, executableNamed name: String, asking: [String] = ["--help"]) -> Bool? {
        guard let url = try? resolveExecutable(named: name) else { return nil }
        // Kept by the program itself, as it is now: one updated or replaced
        // while Lamp is open is asked again.
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let identity = "\(url.path) \(info.st_ino) \(info.st_mtimespec.tv_sec) \(info.st_size)"
        let key = "\(identity) \(asking.joined(separator: " ")) \(flag)"
        Self.versionLock.lock()
        let known = Self.flagsByKey[key]
        Self.versionLock.unlock()
        if let known { return known }
        let process = AgentSpawnedProcess()
        let output = Pipe()
        process.executableURL = url
        process.arguments = asking
        process.standardOutput = output
        guard (try? AgentHelperProcesses.launch(process)) != nil else { return nil }
        Self.giveUp(on: process, after: 20)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        AgentHelperProcesses.untrack(process)
        process.release()
        let text = String(decoding: data, as: UTF8.self)
        let takes: Bool? = text.isEmpty ? nil : text.contains(flag)
        Self.versionLock.lock()
        Self.flagsByKey[key] = takes
        Self.versionLock.unlock()
        return takes
    }

    private nonisolated(unsafe) static var flagsByKey: [String: Bool?] = [:]

    // Shared across runners — a reader chat and a writing chat each have their
    // own — so it is guarded. Two chats answering at once would otherwise be
    // writing this dictionary from two threads.
    private nonisolated(unsafe) static var versionsByName: [String: Int?] = [:]
    private static let versionLock = NSLock()

    func resolveExecutable(named name: String) throws -> URL {
        try resolveExecutable(named: name, lookingUp: resolveThroughLoginShell(named:))
    }

    /// As `resolveExecutable(named:)`, with how a name is looked for given:
    /// a test's own, which counts.
    func resolveExecutable(named name: String, lookingUp lookUp: (String) throws -> URL) throws -> URL {
        // A path is already resolved; a login shell has nothing to add, and
        // a startup file that prints would only garble it.
        if name.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: name) {
            return URL(fileURLWithPath: name)
        }
        // Found once and kept, while the file is still there: a login shell
        // runs the reader's startup files, 0.7 to 1.3 seconds of them on the
        // owner's Mac, and was asked again before every turn of every chat.
        // A program moved or removed is looked for afresh; one not found is
        // not kept, so installing it later is seen at once.
        Self.resolvedLock.lock()
        let known = Self.resolvedByName[name]
        Self.resolvedLock.unlock()
        if let known, FileManager.default.isExecutableFile(atPath: known.path) { return known }
        let found = try lookUp(name)
        Self.resolvedLock.lock()
        Self.resolvedByName[name] = found
        Self.resolvedLock.unlock()
        return found
    }

    private nonisolated(unsafe) static var resolvedByName: [String: URL] = [:]

    /// Looks for a CLI afresh, as a connection check does, so the program a
    /// chat runs is the one the check found.
    static func forgetResolved(named name: String) {
        resolvedLock.lock()
        resolvedByName[name] = nil
        resolvedLock.unlock()
    }
    private static let resolvedLock = NSLock()

    /// Finds a CLI ahead of its first use, off the main thread, so the first
    /// message to a chat doesn't wait on the login shell either.
    static func warmUp(executableNamed name: String) {
        DispatchQueue.global(qos: .utility).async {
            let runner = AgentCLIProcessRunner()
            _ = try? runner.resolveExecutable(named: name)
            _ = runner.majorVersion(ofExecutableNamed: name)
        }
    }

    private func resolveThroughLoginShell(named name: String) throws -> URL {
        let process = AgentSpawnedProcess()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v \(name)"]
        process.standardOutput = output
        try AgentHelperProcesses.launch(process)
        // A login shell runs the reader's own startup files, and one that
        // waits on something would hold every chat to that provider.
        Self.giveUp(on: process, after: 20)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationStatus
        AgentHelperProcesses.untrack(process)
        process.release()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0,
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

/// Where a conversation copied from a reader chat ends and the writing's own
/// chat begins. See `ReaderChatWritingCopy.copiedEventKind`.
struct CopiedConversationContent {
    let copiedAt: Date
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

/// What the running reply is doing, in the header beside Stop.
///
/// On a row of its own it made the header twice as tall for one short line,
/// so it shares the row with the buttons and gives way to them: a long step
/// is cut at the end rather than pushing Stop out of reach.
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
        }
        .help(summary)
        .accessibilityElement(children: .ignore)
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
            .background { ChatScrollEndKeeping(length: content.markdown.utf16.count) }
    }
}

/// The row that stands for a reply until its first words arrive.
struct AgentWaitingContent {}

/// Three dots in the reply's bubble, as SwiftyChat's loading row draws them,
/// but Lamp's own so it can carry `ChatEndPin`. SwiftyChat scrolls to a new
/// row as soon as it is added, while the lazy stack still has its height as
/// an estimate; where the row came out taller the scroll stopped short, and
/// the dots sat half under the message field (owner, 2026-11-25, not every
/// time).
private struct AgentWaitingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = 0
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14)
    }

    var body: some View {
        // A line of a message's text, unseen, with the dots on it: the
        // bubble is then a one-line message's, its padding a message's
        // (PersonMessageView). It had far more room round the dots, then
        // far less (owner, 2026-11-26).
        Text(" ")
            .font(.system(size: 14))
            .hidden()
            .frame(width: 34)
            .overlay {
                // Each dot its own size, with a gap: left to fill a shared
                // width, the three ran together into one bar.
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.primary)
                            .opacity(reduceMotion || lit == index ? 1 : 0.5)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
        .background(shape.fill(LampChatSurface.agentBubble))
        .overlay(shape.stroke(LampChatSurface.agentBubbleBorder, lineWidth: 1))
        .onReceive(tick) { _ in
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.5)) { lit = (lit + 1) % 3 }
        }
        .background {
            ChatEndPin()
            ChatScrollEndKeeping()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .accessibilityElement()
        .accessibilityLabel("Waiting for the reply")
    }
}

/// Scrolls the chat to its true end once the row it sits in has been laid
/// out, and again after SwiftyChat's own 0.2 s scroll has finished, which
/// was aimed at the estimate. The end is the clip view's own limit, so it
/// counts the message field's inset. It acts when the row appears, which is
/// just after a message is sent, so a reader who scrolls up while the reply
/// is awaited is left where they are.
private struct ChatEndPin: NSViewRepresentable {
    func makeNSView(context: Context) -> PinView { PinView() }
    func updateNSView(_ view: PinView, context: Context) {}

    final class PinView: NSView {
        /// Set once the reader scrolls, which ends the pinning: the second
        /// pin is for SwiftyChat's scroll, not for a reader who has moved.
        private var readerScrolled = false
        private var scrollObservers: [NSObjectProtocol] = []

        deinit {
            scrollObservers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scrollObservers.forEach(NotificationCenter.default.removeObserver)
            scrollObservers = []
            guard window != nil else { return }
            readerScrolled = false
            // A trackpad starts a live scroll; a legacy mouse wheel only
            // reports one in progress.
            scrollObservers = [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: enclosingScrollView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readerScrolled = true }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.pin() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.pin() }
        }

        private func pin() {
            guard !readerScrolled, let scrollView = enclosingScrollView,
                  let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            // Asked for the document's foot and given back the furthest the
            // view may go, insets counted. A huge number in its place came
            // back as 0, the top: precision lost in the clamp.
            var far = clip.bounds
            far.origin.y = document.frame.maxY
            let end = clip.constrainBoundsRect(far).origin.y
            guard abs(clip.bounds.origin.y - end) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: end))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

/// Has the chat's scroll view kept from standing past its end, from the row
/// it sits in; see `ChatScrollEndKeeper`. In the arriving reply it also looks
/// each time the reply grows.
private struct ChatScrollEndKeeping: NSViewRepresentable {
    /// Changes as the reply does, which is when to look again.
    var length = 0

    func makeNSView(context: Context) -> KeepingView { KeepingView() }

    func updateNSView(_ view: KeepingView, context: Context) {
        view.keeper?.clampSoon()
    }

    final class KeepingView: NSView {
        private(set) var keeper: ChatScrollEndKeeper?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            keeper = ChatScrollEndKeeper.keeper(for: scrollView)
            keeper?.clampSoon()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            keeper?.clampSoon()
        }
    }
}

/// Keeps the chat from standing past its end.
///
/// SwiftyChat lists its messages in a lazy stack anchored at the bottom. As
/// a reply grows, and as a message is sent and the chat scrolled to it, the
/// stack re-estimates the rows it has put away, and the content can come out
/// shorter than the place it is scrolled to: the whole pane goes blank until
/// the reader scrolls (user, 2026-11-05, part way through a long reply;
/// owner, 2026-11-26, sometimes just after sending).
///
/// It belongs to the scroll view rather than to a row. It was a row's, the
/// arriving reply's, and a lazy stack draws only the rows in view: once the
/// view stood past the end there was no row drawn to bring it back, and
/// after a send it had no reply row yet at all. So it watches the list's own
/// height and the view's place, and lives as long as the scroll view does.
///
/// It moves the view only when it is past the end, and only as far back as
/// the end, insets counted, so a reader who has scrolled up is left where
/// they are; and not while they are scrolling, so an overscroll still
/// springs back on its own.
@MainActor
final class ChatScrollEndKeeper: NSObject {
    /// Held by the scroll view itself, so it goes when the scroll view does.
    private static let key = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    static func keeper(for scrollView: NSScrollView) -> ChatScrollEndKeeper {
        if let keeper = objc_getAssociatedObject(scrollView, key) as? ChatScrollEndKeeper { return keeper }
        let keeper = ChatScrollEndKeeper(scrollView)
        objc_setAssociatedObject(scrollView, key, keeper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return keeper
    }

    private weak var scrollView: NSScrollView?
    private weak var watchedDocument: NSView?
    private var observers: [NSObjectProtocol] = []
    private var documentObserver: NSObjectProtocol?
    private var readerIsScrolling = false
    private var clampIsQueued = false

    private init(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()
        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        // Where the view stands, and how tall it is: a card arriving above
        // the chat shortens it mid-reply.
        observers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
            center.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clampSoon() }
            }
        } + [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readerIsScrolling = true }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readerIsScrolling = false
                    self?.clampSoon()
                }
            },
        ]
        watchDocument()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        documentObserver.map(NotificationCenter.default.removeObserver)
    }

    /// The list's height, which is what shrinks under the view. The
    /// document is looked for again each time, in case SwiftUI replaced it.
    private func watchDocument() {
        guard let document = scrollView?.documentView, document !== watchedDocument else { return }
        documentObserver.map(NotificationCenter.default.removeObserver)
        document.postsFrameChangedNotifications = true
        watchedDocument = document
        documentObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: document, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampSoon() }
        }
    }

    /// After the pass that changed the list, once it has laid out; one look
    /// however many changes ask in the same turn of the run loop.
    func clampSoon() {
        guard !clampIsQueued else { return }
        clampIsQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.clampIsQueued = false
                self?.clamp()
            }
        }
    }

    private func clamp() {
        watchDocument()
        guard !readerIsScrolling, let scrollView, scrollView.window != nil else { return }
        let clip = scrollView.contentView
        // The clip view's own limit for where it stands now, so the message
        // field's inset is counted as the end's, not as past it.
        let allowed = clip.constrainBoundsRect(clip.bounds)
        guard clip.bounds.origin.y > allowed.origin.y + 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: allowed.origin.y))
        scrollView.reflectScrolledClipView(clip)
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
    /// Allow for This Chat, where the request offers it.
    var allowForChat: (() -> Void)? = nil
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
            if let note = summary.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rule = request.alwaysAllowRule {
                // Said in full, since it outlasts this chat.
                Text("Always Allow saves permission for \(rule.description) in this writing, on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if allowForChat != nil {
                // What is remembered, exactly, where it isn't what is shown
                // above: the shell Codex runs it in is part of it.
                if let grant = request.chatGrant, grant.commandText != request.toolInput["command"] as? String {
                    Text("Exactly: \(grant.commandText)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Said whole, since what it allows outlasts this answer, and
                // runs outside any sandbox.
                Text("Allow for This Chat runs this exact command in this folder again without asking, until you start a new chat. Lamp doesn’t check what the command’s files hold by then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Deny") { answer(.deny) }
                if let allowForChat {
                    Button("Allow for This Chat", action: allowForChat)
                        .help("Allow this command in this folder for the rest of this chat")
                }
                if let rule = request.alwaysAllowRule {
                    Button("Always Allow") { answer(.alwaysAllow(rule)) }
                        .help("Saves \(rule.ruleText) to this writing's settings")
                }
                Button("Allow") { answer(.allow) }
                    .buttonStyle(.lampProminent)
                    .controlSize(.small)
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

/// What Always Allow kept for a writing, each with its Remove.
private struct SavedPermissionsList: View {
    let rules: [String]
    let replying: Bool
    let remove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved for this writing").font(.headline)
            Text("Claude may do these here without asking, on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if replying {
                // The running reply was started with them.
                Text("Removing one takes effect from the next message. To end this reply's use of it now, press Stop.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rules, id: \.self) { rule in
                HStack {
                    Text(rule)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Button("Remove", role: .destructive) { remove(rule) }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// What Allow for This Chat remembered, each with its Remove.
private struct ChatCommandGrantsList: View {
    let grants: [AgentChatCommandGrant]
    let remove: (AgentChatCommandGrant) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allowed for this chat").font(.headline)
            Text("These run again without asking, exactly as shown and in this folder, until you start a new chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(grants, id: \.self) { grant in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Whole, both: two grants can differ anywhere.
                        Text(grant.commandText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("in \(grant.folderText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { remove(grant) }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// Text a message will be sent with: where it is from, and its words.
struct ChatAttachment: Equatable {
    /// Where it was selected: "Genesis 1:1", "Main Prose".
    var place: String
    var text: String
}

/// The selection the next message goes with, over the message field. The
/// chats were sent it all along, but the only word of it was a line behind
/// the reader chat's setup row, and none in the writing chat, so a reader
/// who clicked into the chat and saw the page's highlight fade took it to
/// be gone (owner, 2026-11-25).
private struct ChatAttachmentChip: View {
    let attachment: ChatAttachment
    let dismiss: (() -> Void)?

    /// The words on one line, as far as they fit.
    private var excerpt: String {
        attachment.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Kept before the words, but cut in the middle where a long file
            // name would push the button out of a narrow pane.
            Text(attachment.place)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text("\u{201C}\(excerpt)\u{201D}")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let dismiss {
                Button("Send Without the Selection", systemImage: "xmark.circle.fill", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Send the next message without the selection")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.lampCardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.lampCardStroke)
        }
        .help("Sent with your next message: \(attachment.place), \u{201C}\(attachment.text.prefix(300))\(attachment.text.count > 300 ? "\u{2026}" : "")\u{201D}")
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sent with your next message: \(attachment.place)")
    }
}

private struct NativeAgentChatInputView: View {
    @Binding var message: String
    let placeholder: String
    /// Typing goes on, but nothing is sent: a Claude Terminal holds the
    /// writing's chats (`AgentTerminalHolds`).
    var isHeld = false
    let onCommit: (String) -> Bool

    private var canSubmit: Bool {
        !isHeld && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

/// The line under a conversation copied in from a reader chat, saying that it
/// was a copy and that the two chats go their own ways from here.
private struct CopiedConversationRow: View {
    let copiedAt: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Label {
                Text("Copied from a reader chat on \(copiedAt.formatted(date: .abbreviated, time: .omitted))")
            } icon: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help("This conversation was copied once. Nothing said here goes back to the reader chat, and nothing said there comes here.")
        .accessibilityElement(children: .combine)
    }
}

/// Why a message wasn't sent, said where the chat says it.
struct AgentChatSendRefusal: LocalizedError {
    let message: String
    /// The message is kept on the chat, waiting, not handed back.
    var kept = false
    var errorDescription: String? { message }
}

/// Over the composer while a Claude Terminal runs in the writing: why
/// nothing sends, and the way out (`AgentTerminalHolds`). Ending sends
/// nothing: the Terminal's last turns come into the chat first, for the
/// person to read before their message goes on top.
private struct TerminalHoldNotice: View {
    let end: () -> Void
    let show: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude is running in this writing’s Terminal. Chats here wait until that session ends.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("End Terminal Session", action: end)
                    .buttonStyle(.lampProminent)
                if let show {
                    Button("Show Terminal", action: show)
                        .buttonStyle(.lampSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
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

    /// Set as Lamp begins to quit, after which no chat starts a reply. A
    /// quit is never cancelled, so it is never cleared.
    @MainActor
    static var isQuitting = false

    /// Whether any kept chat has a reply running.
    @MainActor
    static var anyRunning: Bool { models.values.contains { $0.isRunning } }

    /// Stops every reply still running, as Stop does, and waits until each
    /// has ended or `seconds` pass. For quitting: a headless run otherwise
    /// goes on working, and spending, after Lamp has gone. Through Stop, so a
    /// writing turn ends the way it always does. Returns the chats it
    /// stopped, so what a writing turn wrote can be collected.
    @MainActor
    @discardableResult
    static func stopEveryReply(within seconds: Double) async -> [NativeAgentChatModel] {
        let running = models.values.filter(\.isRunning)
        running.forEach { $0.cancel() }
        let deadline = Date().addingTimeInterval(seconds)
        while running.contains(where: \.isRunning), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return running
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

    /// Whether a reply is arriving in any provider's chat on this workspace.
    static func isRunning(in workspace: URL) -> Bool {
        AIProviderCLI.allCases.contains { existing(provider: $0, workspace: workspace)?.isRunning == true }
    }

    /// The turns being prepared or run on each workspace, from any pane or
    /// device: between Send and the model saying it runs, a turn is already
    /// bound to its provider's model, so the chat may not be moved to
    /// another provider under it (`AgentRemoteHost.setChoices`).
    @MainActor
    private static var turnsInHand: [String: Int] = [:]

    @MainActor
    static func beginTurn(in workspace: URL) {
        turnsInHand[workspace.standardizedFileURL.path, default: 0] += 1
        noteTurnBegun(in: workspace)
    }

    /// The turns begun on each writing when its settings were last found
    /// clear for OpenCode (`WritingChatTurns.checkOpenCode`).
    @MainActor
    private static var openCodeChecked: [String: Int] = [:]

    /// `generation`: the turns begun when the check began.
    @MainActor
    static func noteOpenCodeChecked(in workspace: URL, at generation: Int) {
        openCodeChecked[workspace.standardizedFileURL.path] = generation
    }

    /// Whether the writing was found clear for OpenCode with no turn begun
    /// since, from any pane, the phone or a Terminal: once only, so each
    /// turn is checked for itself.
    @MainActor
    static func takeOpenCodeCheck(in workspace: URL) -> Bool {
        let key = workspace.standardizedFileURL.path
        defer { openCodeChecked[key] = nil }
        return openCodeChecked[key] == turnsBegun(in: workspace)
    }

    /// How many turns are in hand on this workspace.
    @MainActor
    static func turnsInHand(in workspace: URL) -> Int {
        turnsInHand[workspace.standardizedFileURL.path] ?? 0
    }

    @MainActor
    static func endTurn(in workspace: URL) {
        let key = workspace.standardizedFileURL.path
        guard let count = turnsInHand[key] else { return }
        turnsInHand[key] = count > 1 ? count - 1 : nil
    }

    /// How many turns each writing has begun, from any pane or the phone:
    /// a Terminal launch reads it before its last check and again as it
    /// hands the Terminal its command, and checks again if it moved, so no
    /// chat's turn falls between the check and the hand-over (`decisions/0038`).
    private static var turnsBegun: [String: Int] = [:]

    @MainActor
    static func turnsBegun(in workspace: URL) -> Int {
        turnsBegun[workspace.standardizedFileURL.path] ?? 0
    }

    @MainActor
    static func noteTurnBegun(in workspace: URL) {
        turnsBegun[workspace.standardizedFileURL.path, default: 0] += 1
    }

    /// A turn is being prepared or a reply is arriving on this workspace.
    @MainActor
    static func isBusy(in workspace: URL) -> Bool {
        turnsInHand[workspace.standardizedFileURL.path] != nil || isRunning(in: workspace)
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
        // A Claude Terminal began before this chat was loaded: what it had
        // waiting on disk waits for the person's next Send.
        if queueHoldsPending.remove(key) != nil { model.holdQueue() }
        return model
    }

    /// Chats not loaded when a Claude Terminal began in their writing, whose
    /// waiting messages are held once they are (`AgentTerminalHolds`).
    @MainActor
    private static var queueHoldsPending: Set<String> = []

    /// Holds every chat's waiting messages in this writing, loaded or not.
    @MainActor
    static func holdQueues(in workspace: URL) {
        for provider in AIProviderCLI.allCases {
            if let model = existing(provider: provider, workspace: workspace) {
                if model.hasWaitingMessage { model.holdQueue() }
            } else {
                queueHoldsPending.insert("\(provider.rawValue)|\(workspace.standardizedFileURL.path)")
            }
        }
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
    /// first. A writing chat asks: Claude through `ClaudePermissionHook`,
    /// Codex and Antigravity through their runners. A paired device may
    /// answer too (`AgentRemoteHost`, `decisions/0040`).
    @Published private(set) var pendingApprovals: [AgentToolApprovalRequest] = [] {
        didSet {
            noticeWait(was: !oldValue.isEmpty)
            // Said as the turn's step, so wherever the turn is watched — a
            // pane, or the phone that asked, which has no card — it reads
            // as waiting on the person, not as working.
            guard isRunning else { return }
            guard let first = pendingApprovals.first else {
                // Answered: back to what the turn was doing, which is what
                // goes on now, the command it was waiting to run.
                if case .tool(name: Self.waitingStepName, _) = activity { activity = activityBeforeWaiting }
                return
            }
            let step = AgentChatActivity.tool(name: Self.waitingStepName, summary: AgentToolApprovalSummary.of(first).title)
            if activity != step {
                if case .tool(name: Self.waitingStepName, _) = activity {} else { activityBeforeWaiting = activity }
                record(step)
                activity = step
            }
        }
    }
    private static let waitingStepName = "Waiting for your answer on the Mac"
    private var activityBeforeWaiting: AgentChatActivity?
    /// What the running reply is doing — thinking, a tool call, writing — for
    /// the pane to show while it does it. Cleared when the run ends. Claude
    /// only: the other providers' streams don't say, and `AgentChatWireParser`
    /// invents nothing for them.
    @Published private(set) var activity: AgentChatActivity?
    /// The reply so far while it arrives, as the pane shows it: for a paired
    /// phone following this chat (`AgentRemoteHost`). Empty between runs.
    @Published private(set) var arrivingReply = ""
    /// Set when the provider reports this chat is billed to an API key,
    /// charged by the token, rather than the subscription the reader signed
    /// in with. Stays up while that is so.
    @Published private(set) var billingNotice: String?
    /// Where the account last stood against a usage limit, as the provider
    /// reported it during a run. Claude only.
    @Published private(set) var usageLimit: AgentChatUsageLimit?
    /// Set while waiting messages are held back after a run that failed or
    /// that Lamp stopped, so a usage limit or a lapsed sign-in does not send
    /// every one of them to fail in turn. Sending a message lets them go.
    @Published private(set) var queueHeld = false

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

    /// Whose turn this is and where it leads, for the notification a turn
    /// sends when it ends unwatched (`AgentTurnNotifications`). Set by the
    /// host and kept when its pane goes, since a reply outlives its pane.
    var notificationContext: AgentTurnNotificationContext?
    /// The panes showing this chat, each able to say whether it is seen
    /// (`PaneVisibility`). Per pane, as the observers are.
    private var panes: [AnyHashable: PaneVisibility] = [:]
    /// Whether the run in progress should say when it ends: not one a phone
    /// asked for, whose person is on the phone.
    private var notifiesThisRun = true
    /// How the last turn ended, as a notification would say it, or nil for
    /// one the reader stopped. Read by the phone's host once its turn's send
    /// returns, to tell a phone that has gone to sleep (`AgentTurnPush`).
    private(set) var lastTurnOutcome: AgentTurnNotifications.Outcome?

    func showsIn(_ visibility: PaneVisibility, for token: AnyHashable) {
        panes[token] = visibility
    }

    func stopShowing(for token: AnyHashable) {
        panes[token] = nil
    }

    /// Whether anyone is looking at this chat now, asked as its turn ends.
    private var isWatched: Bool { panes.values.contains { $0.isWatched } }

    /// Whether this turn's wait was told by a notification, to take back.
    private var waitNoticed = false

    /// Tells the person on this Mac, as a turn's end does, that a turn they
    /// started and aren't watching waits on their answer, and takes it back
    /// once it doesn't (`decisions/0045`). Not for a phone's turn, whose
    /// phone is told; the end's notice takes this one's place.
    private func noticeWait(was wasWaiting: Bool) {
        switch AgentTurnPush.change(wasWaiting: wasWaiting, isWaiting: !pendingApprovals.isEmpty) {
        case .tell:
            guard isRunning, notifiesThisRun, !isWatched, let notificationContext else { return }
            // Only one posted is taken back: the end of an earlier turn may
            // be showing under the same name.
            waitNoticed = AgentTurnNotifications.post(
                .notice("\(provider.shortName) is waiting for your answer."), context: notificationContext,
                waitingProvider: provider.rawValue
            )
        case .clear:
            guard waitNoticed, let notificationContext else { return }
            waitNoticed = false
            AgentTurnNotifications.withdraw(context: notificationContext, provider: provider.rawValue)
        case .none:
            break
        }
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
    /// The message being prepared and its loader, shown as Send is pressed
    /// and never written down: a writing's preparation can wait seconds on
    /// its workspace (the draft saved, its context and settings written,
    /// behind a sync pass), and the pane showed nothing through it, as if
    /// Send had not been pressed (owner, 2026-11-26). Kept out of `messages`,
    /// which the transcript is made from; `send` takes their places.
    @Published private(set) var sendingPlaceholder: [NativeAgentChatMessage] = []
    /// Which submission the placeholder is: two panes can share this chat,
    /// and each consumes or clears only its own.
    private var placeholderToken: UUID?

    /// Shows `text` as being sent, and names it for `clearSending` and
    /// `send`; nil when another submission already shows.
    @discardableResult
    func showSending(_ text: String) -> UUID? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, placeholderToken == nil else { return nil }
        let token = UUID()
        placeholderToken = token
        defer { _ = token }
        sendingPlaceholder = [
            NativeAgentChatMessage(id: UUID(), user: person, messageKind: .custom(PersonMessageContent(text: prompt)), isSender: true, date: Date()),
            NativeAgentChatMessage(id: UUID(), user: agentUser, messageKind: .custom(AgentWaitingContent()), isSender: false, date: Date()),
        ]
        return token
    }

    /// The message was not sent after all: it goes back where it came from.
    func clearSending(_ token: UUID?) {
        guard let token, token == placeholderToken else { return }
        placeholderToken = nil
        sendingPlaceholder = []
    }

    /// Whether the card's requests are a Codex or Antigravity turn's,
    /// answered over its protocol rather than through a hook's folder.
    private var runnerApprovals = false
    /// Always Allow answers given and not yet known to be taken by the hook.
    private var grantsAwaitingTheHook: [(id: String, rule: AgentToolAlwaysAllowRule)] = []
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
        // Found now, while the person types, rather than after Send.
        AgentCLIProcessRunner.warmUp(executableNamed: provider.executable)
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
        return LampFileModification.date(of: url)
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
        inConversation expected: UUID? = nil,
        notifiesWhenDone: Bool = true,
        placeholder: UUID? = nil
    ) async -> Bool {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing new starts once Lamp is quitting: a message queued behind
        // the reply being stopped would otherwise go the moment it stopped,
        // as a run nobody is left to stop. Refused here, it stays queued.
        guard !prompt.isEmpty, !isRunning, !KeptAgentChats.isQuitting else { return false }
        // The last line before a run: nothing starts in a writing a Claude
        // Terminal holds, from whichever pane or device asked.
        guard !AgentTerminalHolds.shared.isHeld(in: workspace) else { return false }
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
        // An OpenCode writing turn runs only on settings checked for it, with
        // nothing begun since (`decisions/0043`).
        if provider == .openCode, !mode.isReadOnly, !KeptAgentChats.takeOpenCodeCheck(in: workspace) {
            errorMessage = "OpenCode wasn’t started: this writing’s settings weren’t checked for this message, or something began in it meanwhile. Send it again."
            return false
        }
        // An OpenCode writing turn runs alone in its writing: OpenCode rereads
        // its settings at every request, so another agent writing them as it
        // runs would change what it does (`decisions/0043`).
        if !mode.isReadOnly {
            let othersRunning = AIProviderCLI.allCases.contains {
                $0 != provider && KeptAgentChats.existing(provider: $0, workspace: workspace)?.isRunning == true
            }
            if provider == .openCode, othersRunning || AgentTerminalHolds.shared.hasTerminal(in: workspace) {
                errorMessage = "OpenCode wasn’t started: another chat or a Terminal is at work in this writing. Send it again when that has finished."
                return false
            }
            if provider != .openCode, KeptAgentChats.existing(provider: .openCode, workspace: workspace)?.isRunning == true {
                errorMessage = "OpenCode is answering in this writing. Send this when it has finished."
                return false
            }
        }
        errorMessage = nil
        needsProviderSetup = false
        stoppedNotice = nil
        notifiesThisRun = notifiesWhenDone
        lastTurnOutcome = nil
        isRunning = true
        // Counted for a Terminal launch checking this writing; see
        // `KeptAgentChats.turnsBegun`.
        KeptAgentChats.noteTurnBegun(in: workspace)
        cancelRequested = false
        stoppedByLamp = nil
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
        // This conversation's allowed commands, whoever started the turn.
        runner.useChatGrants(chatGrantKey)

        // What the pane showed while the message was being prepared is
        // replaced by the real thing, under the same identities, so the
        // bubbles stay where they are.
        // Only this submission's: another pane's is left to it.
        let shown = placeholder != nil && placeholder == placeholderToken ? sendingPlaceholder : []
        if !shown.isEmpty {
            placeholderToken = nil
            sendingPlaceholder = []
        }
        let userMessage = NativeAgentChatMessage(
            id: messageID ?? shown.first?.id ?? UUID(),
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
        let loadingID = shown.count == 2 ? shown[1].id : UUID()
        loadingMessageID = loadingID
        messages.append(NativeAgentChatMessage(
            id: loadingID,
            user: agentUser,
            messageKind: .custom(AgentWaitingContent()),
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

    /// Stops the reply the way Stop does, so a writing turn still ends
    /// through the same collection of what it wrote, and says why.
    private func stopForLamp(because reason: String) {
        guard isRunning, stoppedByLamp == nil else { return }
        stoppedByLamp = reason
        cancel()
    }

    /// Lets messages held back after a failure go, as sending one does.
    func releaseQueue() {
        queueHeld = false
        heldForTheirWord = false
    }

    /// Held by Lamp for the person's word (a Claude Terminal, a refused
    /// check), which no turn's end lets go: only their Send does.
    private var heldForTheirWord = false

    /// Holds the waiting messages until the person sends, as a failure does:
    /// a Claude Terminal held them (`AgentTerminalHolds`).
    func holdQueue() {
        heldForTheirWord = true
        if !queueHeld { queueHeld = true }
    }

    /// Why Lamp, rather than the person, stopped the running reply.
    private var stoppedByLamp: String?
    /// Counts runs, so an answer that arrives late is applied only to the
    /// run that asked for it.
    private var runGeneration = 0

    /// The folder this chat runs in.
    var workspaceURL: URL { workspace }
    /// Whether this chat writes, as a writing's assistant does.
    var isWritingChat: Bool { !mode.isReadOnly }

    /// This chat's commands allowed for it (`AgentChatCommandGrants`): by
    /// conversation, so a new chat has none.
    var chatGrantKey: String? {
        AgentChatCommandGrants.key(provider: provider.rawValue, workspace: workspace, conversation: conversationID ?? unnamedConversation)
    }

    /// The name a conversation saved before conversations had ids goes by
    /// here, for its grants alone; a new chat is given another.
    private var unnamedConversation = UUID()

    func clearConversation() {
        guard !isRunning else { return }
        // What was allowed for the chat goes with it.
        if let chatGrantKey { AgentChatCommandGrants.shared.removeAll(for: chatGrantKey) }
        unnamedConversation = UUID()
        // A message still being prepared belongs to the conversation going.
        placeholderToken = nil
        sendingPlaceholder = []
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
        arrivingReply = ""
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
            // Always Allow answers the hook took, kept before the channel's
            // folder, and the hook's marks in it, go.
            if let channel {
                for waiting in answersAwaitingTheHook where channel.waitUntilTaken(waiting.id, answer: waiting.answer, seconds: 0) {
                    answersTakenAtTheEnd.insert(waiting.id)
                }
                for grant in grantsAwaitingTheHook where channel.waitUntilTaken(grant.id, answer: .alwaysAllow(grant.rule), seconds: 0) {
                    do {
                        try AgentToolAllowRules.add(grant.rule.rules, for: workspace)
                    } catch {
                        errorMessage = "Lamp allowed this, but could not keep the rule for next time: \(error.localizedDescription)"
                    }
                }
            }
            grantsAwaitingTheHook = []
            channel?.close()
            approvalChannel = nil
            pendingApprovals = []
            runner.setWaitingOnPerson(false)
        }
        let wire = provider.wireProvider
        // Codex does not say in its stream how it is billed; its login status
        // does. Asked on every run, since the account can change between
        // them, and alongside the run rather than ahead of it.
        runGeneration += 1
        let generation = runGeneration
        let billingRunner = AgentCLIProcessRunner()
        // Not known again until the check answers: a notice from before an
        // account change must not stand meanwhile, or for good if the
        // check says nothing Lamp recognises.
        if provider == .codex { billingNotice = nil }
        let billingCheck: Task<Void, Never>? = provider == .codex ? Task { [weak self, workspace] in
            let status = await billingRunner.run(
                executableName: AIProviderCLI.codex.executable,
                arguments: ["login", "status"],
                workingDirectory: workspace
            )
            // Only for the run that asked: a slow answer from an earlier
            // run must not overwrite a later one's.
            guard !Task.isCancelled, let self, self.runGeneration == generation,
                  let billing = AgentChatBilling.codex(loginStatus: status.output)
            else { return }
            self.absorb([.billing(billing)])
        } : nil
        defer {
            billingCheck?.cancel()
            billingRunner.cancel()
        }
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
        // Asked off the main thread. The first time for each CLI it finds the
        // executable through the login shell, which launches zsh with the
        // reader's startup files: about two seconds, measured, during which
        // the whole window froze on the first message to that provider.
        let executable = provider.executable
        let runner = self.runner
        // Asked side by side: each is a process the first time for a CLI,
        // and none needs another's answer.
        async let majorVersion = Task.detached {
            runner.majorVersion(ofExecutableNamed: executable)
        }.value
        // A Codex older than `--ignore-rules` refuses it and every reader
        // chat with it; unknown is taken as the current Codex, which has it.
        let asksIgnoreRules = wire == .codex && mode.isReadOnly
        async let ignoresRules = Task.detached {
            asksIgnoreRules ? runner.codexExecTakes("--ignore-rules", executableNamed: executable) ?? true : true
        }.value
        // Claude Code before 2.1.257 has no prompt snapshot to turn off, and
        // refuses the flag, and every writing chat with it; unknown is taken
        // as the current one, which has it.
        let asksSnapshots = wire == .claude && mode == .writing
        async let snapshots = Task.detached {
            asksSnapshots ? runner.helpLists("--system-prompt-snapshot", executableNamed: executable) ?? true : true
        }.value
        let providerMajorVersion = await majorVersion
        let codexIgnoresRules = await ignoresRules
        let claudeSnapshots = await snapshots
        // Read as the run starts rather than held on the model: the picker
        // writes straight to this chat's own choices, and a chat left open
        // while they changed would otherwise keep launching the old one. This
        // chat's choice first, so that two windows on two models each run
        // theirs, and what the app remembers only where this chat has pinned
        // nothing.
        let chosenModel = chatChoices.value(
            for: AgentChatModelChoice.defaultsKey(wire),
            orAppDefault: UserDefaults.standard.string(forKey: AgentChatModelChoice.defaultsKey(wire))
        )
        let chosenEffort = chatChoices.value(
            for: AgentChatEffortChoice.defaultsKey(wire),
            orAppDefault: UserDefaults.standard.string(forKey: AgentChatEffortChoice.defaultsKey(wire))
        )
        let onLine: @Sendable (String) -> Void = { line in
            let parsed = AgentChatWireParser.parse(line, provider: wire)
            guard !parsed.isEmpty else { return }
            lines.yield(parsed)
        }
        // What the workspace's `CLAUDE.md` says, made afresh for a Claude
        // writing run, which no longer reads the workspace's own files; in a
        // file of Lamp's for the run, outside every workspace.
        // Without it the run would be told nothing at all, so the turn stops
        // and says why.
        var writingInstructionsFile: URL?
        if wire == .claude, mode == .writing {
            do {
                writingInstructionsFile = try AgentChatInstructionFiles.write(
                    await DevotionalAgentWorkspaceStore.chatInstructions(in: workspace)
                )
            } catch {
                // The stream the run's lines would have come through ends
                // here too, so nothing is left waiting on it.
                lines.finish()
                await absorbing.value
                return RunOutcome(
                    result: AgentCLIProcessResult(
                        exitCode: -1, output: "",
                        launchError: "Lamp could not write this chat's instructions, so it did not start Claude: \(error.localizedDescription)"
                    ),
                    proposedSessionID: proposedSessionID,
                    resumedSessionID: resumedSessionID
                )
            }
        }
        defer { writingInstructionsFile.map(AgentChatInstructionFiles.remove) }
        // The hook and the rules kept for this writing, in a file of Lamp's,
        // which `--settings` takes as well as JSON.
        // Without it Claude would start with neither Lamp's approval hook nor
        // the writing's rules, so the turn stops and says why.
        var writingSettingsFile: URL?
        if let channel {
            do {
                writingSettingsFile = try AgentChatInstructionFiles.write(
                    ClaudePermissionHook.settingsJSON(for: channel, allowing: AgentToolAllowRules.rules(for: workspace)),
                    extension: "json"
                )
            } catch {
                lines.finish()
                await absorbing.value
                return RunOutcome(
                    result: AgentCLIProcessResult(
                        exitCode: -1, output: "",
                        launchError: "Lamp could not write this chat's settings, so it did not start Claude: \(error.localizedDescription)"
                    ),
                    proposedSessionID: proposedSessionID,
                    resumedSessionID: resumedSessionID
                )
            }
        }
        defer { writingSettingsFile.map(AgentChatInstructionFiles.remove) }
        let result: AgentCLIProcessResult
        if wire == .codex, !mode.isReadOnly {
            // In order, on the main thread: each list replaces the last.
            let showApprovals: @Sendable ([AgentToolApprovalRequest]) -> Void = { [weak self] pending in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning else { return }
                        if pending != self.pendingApprovals { self.pendingApprovals = pending }
                    }
                }
            }
            runnerApprovals = true
            result = await runner.runCodexAppServer(
                executableName: provider.executable,
                workingDirectory: workspace,
                writingServer: WritingChatTurns.mcpConfiguration(forWorkspace: workspace),
                threadID: resumedSessionID,
                model: chosenModel,
                effort: chosenEffort,
                prompt: prompt,
                onLine: onLine,
                onApprovals: showApprovals
            )
            runnerApprovals = false
        } else if provider == .antigravity {
            let showApprovals: @Sendable ([AgentToolApprovalRequest]) -> Void = { [weak self] pending in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning else { return }
                        if pending != self.pendingApprovals { self.pendingApprovals = pending }
                    }
                }
            }
            runnerApprovals = true
            defer { runnerApprovals = false }
            result = await runner.runACP(
                executableName: provider.executable,
                workingDirectory: workspace,
                mode: mode,
                // Made by Lamp, never read from the workspace.
                writingServer: mode == .writing ? WritingChatTurns.mcpConfiguration(forWorkspace: workspace) : nil,
                sessionID: resumedSessionID,
                model: chosenModel,
                effort: chosenEffort,
                prompt: prompt,
                onLine: onLine,
                onApprovals: showApprovals
            )
        } else {
            result = await runner.run(
                executableName: provider.executable,
                arguments: AgentChatLaunchArguments.make(
                    provider: wire,
                    prompt: prompt,
                    sessionID: resumedSessionID,
                    proposedSessionID: proposedSessionID,
                    mode: mode,
                    permissionHookSettings: writingSettingsFile?.path,
                    model: chosenModel,
                    effort: chosenEffort,
                    providerMajorVersion: providerMajorVersion,
                    codexIgnoresRules: codexIgnoresRules,
                    // Made by Lamp from the workspace's path, never read
                    // from a file the agent can change.
                    writingServer: mode == .writing ? WritingChatTurns.mcpConfiguration(forWorkspace: workspace) : nil,
                    writingInstructionsFile: writingInstructionsFile,
                    claudeSnapshots: claudeSnapshots
                ),
                workingDirectory: workspace,
                onLine: onLine
            )
        }
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
                // A reply waiting on the person's answer is not a stalled one.
                self.runner.setWaitingOnPerson(!pending.isEmpty)
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
            case .billing(let billing):
                billingNotice = billing.isAPIKey
                    ? "\(provider.shortName) reports this chat uses an API key (\(billing.source)), so it is billed by the token rather than to your subscription."
                    : nil
            case .usageLimit(let limit):
                usageLimit = limit
                if limit.status == .rejected {
                    // Claude holds a limited turn open until the window
                    // reopens, which can be hours of a spinner.
                    stopForLamp(because: AgentChatUsageLimitText.reached(limit, provider: provider.shortName))
                }
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
        arrivingReply = markdown
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

    /// Gives the waiting hook, or the waiting Codex request, the person's
    /// answer. Always Allow's rules are kept for this writing's next runs.
    /// Whether Stop has been pressed on the running turn: nothing waiting is
    /// then allowed, so a device's answer is too late.
    var isStopping: Bool { cancelRequested }

    /// Whether the run has taken an answer given with `answer(_:with:)`:
    /// at once for Codex and Antigravity, whose runners take it as it is
    /// given; for Claude, once its hook has read it, which it may not before
    /// it gives up waiting.
    func answerTaken(_ request: AgentToolApprovalRequest, answer: AgentToolApprovalAnswer) async -> Bool {
        if runnerApprovals { return await runner.replyWentAsAnswered(request.id) }
        guard let approvalChannel else { return answersTakenAtTheEnd.contains(request.id) }
        answersAwaitingTheHook.append((request.id, answer))
        let taken = await Task.detached { approvalChannel.waitUntilTaken(request.id, answer: answer) }.value
        answersAwaitingTheHook.removeAll { $0.id == request.id }
        // The run may have ended, and its channel gone, between the hook
        // taking it and the wait looking again: settled then.
        return taken || answersTakenAtTheEnd.contains(request.id)
    }

    /// A device's answers to Claude still being confirmed, and those the
    /// hook had taken when the run ended and its channel went.
    private var answersAwaitingTheHook: [(id: String, answer: AgentToolApprovalAnswer)] = []
    private var answersTakenAtTheEnd: Set<String> = []

    /// Gives a waiting request the person's answer. False where it was no
    /// longer waiting, or the answer could not be given; said in the pane
    /// unless `saysWhy` is false, as for a device, which is told itself
    /// rather than have every follower shown the Mac's notice.
    ///
    /// `forChat`: Allow for This Chat (`decisions/0044`), for a request that
    /// offers it: allowed once, as Allow is, and remembered for the chat only
    /// once that answer went as given, so one pressed as Stop refused it
    /// remembers nothing.
    @discardableResult
    func answer(
        _ request: AgentToolApprovalRequest, with answer: AgentToolApprovalAnswer, saysWhy: Bool = true,
        forChat: Bool = false
    ) -> Bool {
        if runnerApprovals {
            let taken = runner.answerApproval(request.id, with: answer, forChat: forChat && request.chatGrant != nil)
            if !taken, saysWhy {
                errorMessage = "That request had already ended, and the command did not run."
            }
            pendingApprovals.removeAll { $0.id == request.id }
            return taken
        }
        guard let approvalChannel else { return false }
        var taken = true
        do {
            try approvalChannel.answer(request.id, with: answer)
            // Kept only once the hook has taken the answer: one that timed
            // out first denied the call, and nothing is saved for it.
            if case .alwaysAllow(let rule) = answer {
                // Settled when the run ends too, before its channel goes, so
                // an answer taken just before is not lost with it.
                grantsAwaitingTheHook.append((request.id, rule))
                let workspace = workspace
                Task { [weak self] in
                    let taken = await Task.detached { approvalChannel.waitUntilTaken(request.id, answer: answer) }.value
                    guard let self else { return }
                    // Settled already, as the run ended.
                    guard self.grantsAwaitingTheHook.contains(where: { $0.id == request.id }) else { return }
                    self.grantsAwaitingTheHook.removeAll { $0.id == request.id }
                    guard taken else {
                        self.errorMessage = "That request had already timed out, so nothing was allowed or kept."
                        return
                    }
                    do {
                        try AgentToolAllowRules.add(rule.rules, for: workspace)
                    } catch {
                        self.errorMessage = "Lamp allowed this, but could not keep the rule for next time: \(error.localizedDescription)"
                    }
                }
            }
        } catch let error as AgentToolApprovalChannel.AnswerError {
            taken = false
            if saysWhy { errorMessage = error.localizedDescription }
        } catch {
            taken = false
            if saysWhy { errorMessage = "Could not give \(provider.shortName) your answer: \(error.localizedDescription)" }
        }
        pendingApprovals.removeAll { $0.id == request.id }
        return taken
    }

    private func finish(_ outcome: RunOutcome) {
        let result = outcome.result
        isRunning = false
        streamTask?.cancel()
        streamTask = nil
        activity = nil
        streamedReply = ""
        shownStreamedReply = ""
        arrivingReply = ""
        streamingMessage = nil
        // Whatever the loader became — a partial reply, or the loader still —
        // goes, and the run's own reading of its output takes its place.
        if let loadingMessageID {
            messages.removeAll { $0.id == loadingMessageID }
        }
        loadingMessageID = nil

        let lampReason = stoppedByLamp
            ?? (result.stalled ? "No word from \(provider.shortName) for \(AgentCLIProcessRunner.stallMinutes) minutes, so Lamp stopped the reply." : nil)
        stoppedByLamp = nil
        let wasStopped = cancelRequested || result.stalled
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
        // An Antigravity session that opened is kept even when its prompt
        // then failed: it holds the turn's tool history, and a recap would
        // lose it. A session that can't be resumed is found out by resuming.
        let openedACPSession = provider == .antigravity && summary.sessionID != nil
        if result.exitCode == 0 || wasStopped || openedACPSession, result.launchError == nil {
            sessionID = summary.sessionID
                ?? outcome.resumedSessionID
                ?? outcome.proposedSessionID
                ?? (wasStopped ? sessionID : nil)
        }

        // What the notification would say, if nobody is watching. Not for
        // a Stop the reader pressed: they were there to press it.
        let notified: AgentTurnNotifications.Outcome? = switch disposition {
        case .replied(let reply): .replied(reply)
        case .stopped: lampReason.map { .stoppedByLamp($0) }
        case .failed(let failure): .failed(failure)
        case .silent(let notice): .notice(notice)
        }
        lastTurnOutcome = notified
        if let notified, notifiesThisRun, !isWatched, let notificationContext {
            AgentTurnNotifications.post(notified, context: notificationContext)
        }
        notifiesThisRun = true

        switch disposition {
        case .replied(let reply):
            // A reply that began and then failed — a lapsed sign-in, a spent
            // budget, a crash — is still a failed run, and what waits behind
            // it would fail the same way.
            queueHeld = heldForTheirWord || result.exitCode != 0 || summary.failure != nil
            appendAgentMarkdown(reply)
        case .stopped(let partialReply):
            if !partialReply.isEmpty { appendAgentMarkdown(partialReply) }
            if let lampReason {
                record(AgentChatTranscript.Event.failed, text: lampReason)
                errorMessage = lampReason
                queueHeld = true
            } else {
                stoppedNotice = partialReply.isEmpty
                    ? "That reply was stopped. \(provider.shortName) still has the conversation, so your next message carries on from it."
                    : "That reply was stopped partway through."
            }
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
            queueHeld = true
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
        // Said by the chat rather than its pane, because a reply outlives
        // its pane: closed while the agent was answering, the pane is not
        // there to hear the turn end, and a writing the reply asked for
        // would wait for the next launch.
        if case .reader = mode {
            NotificationCenter.default.post(name: .lampReaderChatTurnFinished, object: workspace)
        }
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
                if event.kind == ReaderChatWritingCopy.copiedEventKind {
                    rows.append(NativeAgentChatMessage(
                        id: event.id,
                        user: agentUser,
                        messageKind: .custom(CopiedConversationContent(copiedAt: event.date)),
                        isSender: false,
                        date: event.date
                    ))
                    continue
                }
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

    @discardableResult
    func enqueue(_ text: String) -> UUID? {
        let before = Set(queued.map(\.id))
        changeQueue { [conversationID] in $0.add(text, conversation: conversationID) }
        return queued.first { !before.contains($0.id) }?.id
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
        guard reservedQueued == nil, !KeptAgentChats.isQuitting else { return nil }
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
    /// Starts a writing from the conversation up to a turn, where the host
    /// can make one. Nil elsewhere, where the item is not offered.
    let startWritingFromTurn: ((UUID) -> Void)?
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
    /// Puts the draft back, and says whether it managed to. Asynchronous
    /// because the draft belongs to `WritingWorkspaceFiles` and the pane
    /// puts this behind its own queued work; the order it is awaited in is
    /// what the undo below depends on.
    let revertTurn: (([UUID]) async -> Bool)?
    /// Told which turn is running, for a pane that marks its own records
    /// with it.
    let onTurnChanged: ((UUID?) -> Void)?
    /// Where this chat works, which the header names.
    private let workspaceFolder: URL
    /// The name the header gives the workspace, where the host
    /// knows a better one than its folder's (a writing's title, not its id).
    private var workspaceTitle: String?
    /// Told whether the provider is connected, for a host that
    /// shows its setup when it is not.
    private var onConnectionChanged: ((AIProviderConnectionState) -> Void)?
    /// Whose this chat is and where a notification of its turn leads; see
    /// `NativeAgentChatModel.notificationContext`.
    private var notificationContext: AgentTurnNotificationContext?
    /// The host's own row names the agent, the writing and the
    /// connection, so this header keeps only its buttons, and only when it
    /// has one to offer.
    private var hostNamesIdentity = false
    /// The host's own row has the New Chat button; see
    /// `newChatShownByHost(asked:available:)`.
    private var newChatAsked: Binding<Bool>?
    private var newChatAvailable: ((Bool) -> Void)?
    /// What the next message is sent with beside its words, shown over the
    /// field; see `attachment(_:dismiss:)`.
    private var attachment: ChatAttachment?
    private var dismissAttachment: (() -> Void)?

    @StateObject private var model: NativeAgentChatModel
    /// Claude sessions running in Terminals, which hold a writing's chats.
    @ObservedObject private var terminalHolds = AgentTerminalHolds.shared
    /// Shows the writing's Terminal, where the host has one.
    private var showTerminal: (() -> Void)?
    @State private var draft = ""
    /// The settings that stopped an OpenCode turn, for Show in Finder beside
    /// the words.
    @State private var refusedSettings: [URL] = []
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
    /// Whether this pane is seen, for a turn that ends while it is not.
    @State private var visibility = PaneVisibility()
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
        startWritingFromTurn: ((UUID) -> Void)? = nil,
        revertTurn: (([UUID]) async -> Bool)? = nil,
        onTurnChanged: ((UUID?) -> Void)? = nil
    ) {
        self.provider = provider
        self.mode = mode
        self.canSend = canSend
        self.preparePrompt = preparePrompt
        self.onRunningChanged = onRunningChanged
        self.forkFromTurn = forkFromTurn
        self.startWritingFromTurn = startWritingFromTurn
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

    @State private var savedPermissions: [String] = []
    @State private var showingSavedPermissions = false
    @State private var chatGrants: [AgentChatCommandGrant] = []
    @State private var showingChatGrants = false

    /// The conversation, and after it the message being prepared, if one
    /// is; only the conversation is ever written back.
    private var shownMessages: Binding<[NativeAgentChatMessage]> {
        Binding(
            get: { model.messages + model.sendingPlaceholder },
            set: { [model] new in
                let placeholders = Set(model.sendingPlaceholder.map(\.id))
                model.messages = new.filter { !placeholders.contains($0.id) }
            }
        )
    }

    /// What Always Allow kept for this writing, for a Claude writing chat.
    private func loadSavedPermissions() {
        let rules = provider.wireProvider == .claude && !mode.isReadOnly
            ? AgentToolAllowRules.rules(for: workspaceFolder) : []
        if rules != savedPermissions { savedPermissions = rules }
        if rules.isEmpty { showingSavedPermissions = false }
    }

    /// Sends the next waiting message, if this pane is free to.
    private func drainQueue() {
        // Held by a Claude Terminal, the queue waits for the person's next
        // Send once it has ended; it isn't tried again until then.
        guard !isPreparing, !model.isRunning, !model.queueHeld, !KeptAgentChats.isQuitting,
              model.hasWaitingMessage else { return }
        // Held on the chat itself, which outlives this pane: a pane opened
        // after the Terminal has ended would otherwise send it unasked.
        if AgentTerminalHolds.shared.isHeld(in: workspaceFolder) {
            model.holdQueue()
            return
        }
        guard let next = model.reserveNextQueued() else { return }
        startSending(next.text, queued: next.id)
    }

    /// Sends a message now, which is also how a message that was waiting is
    /// sent when the reply before it lands.
    @discardableResult
    private func startSending(_ prompt: String, queued: UUID? = nil) -> Bool {
        // A message the person sends is their word to carry on, so whatever
        // was held back after a failure goes after it.
        if queued == nil { model.releaseQueue() }
        guard !isPreparing, !AgentTerminalHolds.shared.isHeld(in: workspaceFolder) else {
            if let queued { model.releaseQueued(queued) }
            return false
        }
        isPreparing = true
        // Held for the whole turn, so a phone can't move the chat to another
        // provider while this one is being prepared for the model it has.
        KeptAgentChats.beginTurn(in: workspaceFolder)
        // The conversation this message was written in. Preparing waits,
        // and New Chat is allowed during that wait.
        let conversation = model.conversationID
        // Shown at once, while the prompt is prepared; see `sendingPlaceholder`.
        let placeholder = model.showSending(prompt)
        scrollToBottom = true
        // Started now, and on the main actor until it first waits, so the
        // reader's place is read at Send and not after a navigation.
        Task { [workspaceFolder, preparePrompt] in
            defer { isPreparing = false }
            defer { KeptAgentChats.endTurn(in: workspaceFolder) }
            do {
                let contextualPrompt = try await preparePrompt(prompt)
                // The last thing before the send, which runs with nothing
                // awaited from its own check of what was checked here.
                if provider == .openCode, model.isWritingChat {
                    if case .refused(let words, let paths, _) = await WritingChatTurns.checkOpenCode(in: workspaceFolder) {
                        // Kept on the chat, held, not in this pane's field,
                        // which may be gone by now: Send Them sends it on.
                        var kept = queued
                        if kept == nil, conversation == model.conversationID {
                            kept = model.enqueue(prompt)
                        }
                        // Held only for a message still this chat's: a New
                        // Chat meanwhile isn't paused by one that wasn't.
                        if kept != nil { model.holdQueue() }
                        // From the writing as it resolves, as the scan named
                        // what is above it.
                        let base = workspaceFolder.resolvingSymlinksInPath()
                        refusedSettings = paths.prefix(5).map { base.appendingPathComponent($0).standardizedFileURL }
                        throw AgentChatSendRefusal(message: words, kept: kept != nil)
                    }
                }
                submissionError = nil
                refusedSettings = []
                isPreparing = false
                let taken = await model.send(
                    prompt, contextualPrompt: contextualPrompt,
                    messageID: queued, inConversation: conversation,
                    placeholder: placeholder
                )
                if !taken { model.clearSending(placeholder) }
                // Taken means it is in the transcript, which is where the
                // model takes it out of the queue. Refused — the pane was
                // reopened and something else is running, or New Chat
                // happened while this was being prepared — it goes back to
                // waiting rather than being dropped as sent.
                if !taken {
                    if let queued {
                        // Back to waiting — and tried again now, since
                        // nothing else will: the queue is drained by a run
                        // finishing, and no run started. Refused with a
                        // reason (another chat at work in the writing), it is
                        // held for the person's word instead, rather than
                        // tried again and again until that chat ends.
                        model.releaseQueued(queued)
                        isPreparing = false
                        if model.errorMessage != nil { model.holdQueue() } else { drainQueue() }
                    } else {
                        // A message typed straight in, refused because the
                        // conversation changed while it was being prepared,
                        // or a Claude Terminal began meanwhile. The composer
                        // cleared it when it was accepted, so without this it
                        // is simply gone.
                        submissionError = AgentTerminalHolds.shared.isHeld(in: workspaceFolder)
                            ? "That message was not sent: Claude is running in this writing’s Terminal."
                            : model.errorMessage != nil ? nil
                            : "That message was not sent: the conversation changed while it was being prepared."
                        // Refused with a reason, in the conversation it was
                        // written in: kept on the chat, held, as a refused
                        // check keeps it, not in a field that may go.
                        if model.errorMessage != nil, conversation == model.conversationID, model.enqueue(prompt) != nil {
                            model.holdQueue()
                        } else if draft.isEmpty {
                            draft = prompt
                        }
                    }
                }
                scrollToBottom = true
            } catch {
                model.clearSending(placeholder)
                submissionError = error.localizedDescription
                // A queued message goes back to waiting, in its place,
                // rather than into a draft field the reader may be typing
                // in — which is where it used to vanish, since it was only
                // put back when the field happened to be empty.
                if let queued {
                    model.releaseQueued(queued)
                    // Held, with Send Them to go on, rather than tried again
                    // unasked or left with no way on.
                    model.holdQueue()
                } else if (error as? AgentChatSendRefusal)?.kept == true {
                    // Waiting on the chat already.
                } else if draft.isEmpty {
                    draft = prompt
                }
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !hostNamesIdentity || headerHasActions {
                chatHeader
            }
            if let error = submissionError ?? model.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if !refusedSettings.isEmpty, submissionError != nil {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting(refusedSettings)
                        }
                        .buttonStyle(.lampSecondary)
                    }
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
            if let notice = model.billingNotice {
                Label(notice, systemImage: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let limit = model.usageLimit,
               let warning = AgentChatUsageLimitText.warning(limit, provider: provider.shortName) {
                Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.queueHeld, model.hasWaitingMessage, !model.isRunning {
                HStack(spacing: 8) {
                    Label("Waiting messages are held after that.", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Send Them") {
                        model.releaseQueue()
                        drainQueue()
                    }
                    .buttonStyle(.lampSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            // Under the header, beside Stop, rather than in the chat's input
            // slot: SwiftyChat lays that out at the input's own height.
            if let request = model.pendingApprovals.first {
                AgentToolApprovalCard(
                    request: request,
                    providerName: provider.shortName,
                    waitingCount: model.pendingApprovals.count,
                    allowForChat: request.chatGrant != nil && model.chatGrantKey != nil
                        ? { model.answer(request, with: .allow, forChat: true) } : nil
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
                ChatView(messages: shownMessages, scrollToBottom: $scrollToBottom) {
                    VStack(spacing: 0) {
                        if let attachment {
                            ChatAttachmentChip(attachment: attachment, dismiss: dismissAttachment)
                        }
                        if isHeldByTerminal {
                            TerminalHoldNotice(
                                end: { terminalHolds.end(in: workspaceFolder) },
                                show: showTerminal
                            )
                        }
                        NativeAgentChatInputView(
                            message: $draft,
                            placeholder: model.isRunning ? "\(provider.shortName) is working…" : "Message \(provider.shortName)",
                            isHeld: isHeldByTerminal
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
                    // Not while a reply is arriving: copied now, the
                    // conversation would end without it.
                    if let startWritingFromTurn, message.isSender, !model.isRunning,
                       model.canFork(from: message.id) {
                        Button("Start a Writing from Here…", systemImage: "square.and.pencil") {
                            startWritingFromTurn(message.id)
                        }
                        .buttonStyle(.lampSecondary)
                        .controlSize(.small)
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
                    } else if payload is AgentWaitingContent {
                        AgentWaitingBubble()
                    } else if let content = payload as? TurnStepsContent {
                        TurnStepsRow(steps: content.steps)
                    } else if let content = payload as? CopiedConversationContent {
                        CopiedConversationRow(copiedAt: content.copiedAt)
                    }
                }
                .environment(\.chatStyle, chatStyle)
                // Lines scrolled up under the header fade out rather than
                // being cut through the middle of a word.
                //
                // Done by fading the lines themselves rather than by laying a
                // strip of the ground's colour over them: the conversation no
                // longer has a colour to lay, since it shows whatever pane it
                // is in, and a strip of any named colour would be a block of
                // the wrong shade.
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 18)
                        Rectangle()
                    }
                }

                if connectionState != .connected || (model.messages.isEmpty && model.sendingPlaceholder.isEmpty) {
                    emptyState
                }
            }
        }
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
            model.showsIn(visibility, for: paneToken)
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
        // Where its notification leads, and whether anyone is looking: a
        // turn that ends in a pane on screen in the key window says nothing.
        .onChange(of: notificationContext, initial: true) { _, context in
            if let context { model.notificationContext = context }
        }
        .reportsVisibility(to: visibility)
        .onAppear {
            loadSavedPermissions()
            loadChatGrants()
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentToolAllowRules.changed)) { _ in loadSavedPermissions() }
        .onChange(of: model.pendingApprovals.count) { _, _ in
            loadSavedPermissions()
            loadChatGrants()
        }
        .onChange(of: model.isRunning) { _, _ in loadChatGrants() }
        // A new chat arriving from another Mac has none of these.
        .onChange(of: model.chatGrantKey) { _, _ in loadChatGrants() }
        .onReceive(NotificationCenter.default.publisher(for: AgentChatCommandGrants.changed)) { _ in loadChatGrants() }
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
            model.stopShowing(for: paneToken)
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
                // from. The draft is awaited for that reason: a
                // button's action cannot wait, so the two halves are kept
                // in order inside one task rather than started side by
                // side.
                Task {
                    guard await revertTurn?(going) == true else { return }
                    _ = model.revert(turns: going)
                }
            }
            Button("Cancel", role: .cancel) { turnToUndo = nil }
        } message: { _ in
            Text("The draft goes back to what it said before this turn, and this turn and everything after it leave the conversation. Anything you have written since is replaced — the restore is recorded in the writing’s history, so you can put it back.")
        }
        .onChange(of: newChatAsked?.wrappedValue == true) { _, asked in
            guard asked else { return }
            newChatAsked?.wrappedValue = false
            if canStartNewChat { showingClearConfirmation = true }
        }
        .onChange(of: canStartNewChat, initial: true) { _, can in newChatAvailable?(can) }
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
        workspaceTitle.flatMap { $0.isEmpty ? nil : $0 } ?? workspaceFolder.lastPathComponent
    }

    /// See `notificationContext`.
    func turnNotifications(title: String, route: AgentTurnRoute) -> NativeAgentChatView {
        var copy = self
        copy.notificationContext = AgentTurnNotificationContext(title: title, route: route)
        return copy
    }

    /// See `workspaceTitle`.
    func workspaceTitle(_ title: String?) -> NativeAgentChatView {
        var copy = self
        copy.workspaceTitle = title
        return copy
    }

    /// Shows what the next message will be sent with, the text selected in
    /// the reader or the writing, over the field it is written in, with a
    /// button to send without it. The host decides what is sent: dismissing
    /// asks it to leave the selection out.
    /// Where Show Terminal leads, in a pane that holds a Terminal.
    func showsTerminal(_ show: (() -> Void)?) -> NativeAgentChatView {
        var copy = self
        copy.showTerminal = show
        return copy
    }

    /// Whether a Claude Terminal holds this chat's writing now.
    private var isHeldByTerminal: Bool {
        !terminalHolds.launches.isEmpty && terminalHolds.isHeld(in: workspaceFolder)
    }

    func attachment(_ attachment: ChatAttachment?, dismiss: (() -> Void)?) -> NativeAgentChatView {
        var copy = self
        copy.attachment = attachment
        copy.dismissAttachment = dismiss
        return copy
    }

    /// See `hostNamesIdentity`.
    func identityShownByHost() -> NativeAgentChatView {
        var copy = self
        copy.hostNamesIdentity = true
        return copy
    }

    /// The host's row offers New Chat instead of this header, which then
    /// shows only while there is something else to offer: a header row
    /// holding that one button stood under the host's own (owner,
    /// 2026-11-26). `asked` is set by the host's button and put back here;
    /// `available` is told whether a new chat can be started now.
    func newChatShownByHost(asked: Binding<Bool>, available: @escaping (Bool) -> Void) -> NativeAgentChatView {
        var copy = self
        copy.newChatAsked = asked
        copy.newChatAvailable = available
        return copy
    }

    private var hostShowsNewChat: Bool { newChatAsked != nil }

    private var canStartNewChat: Bool { !model.messages.isEmpty && !model.isRunning }

    /// Whether the header has a button to show.
    private var headerHasActions: Bool {
        (connectionState != .connected && connectionState != .checking) || model.isRunning
            || (!hostShowsNewChat && !model.messages.isEmpty) || !savedPermissions.isEmpty || !chatGrants.isEmpty
    }

    /// What Allow for This Chat remembered for this conversation.
    private func loadChatGrants() {
        let grants = model.chatGrantKey.map(AgentChatCommandGrants.shared.list(for:)) ?? []
        if grants != chatGrants { chatGrants = grants }
        if grants.isEmpty { showingChatGrants = false }
    }

    /// See `onConnectionChanged`.
    func onConnectionChanged(_ action: @escaping (AIProviderConnectionState) -> Void) -> NativeAgentChatView {
        var copy = self
        copy.onConnectionChanged = action
        return copy
    }

    private var chatHeader: some View {
        HStack(spacing: 8) {
            // The reader's pane names its provider in its own menu just
            // above; said again here it read as a second header.
            if !isReaderChat, !hostNamesIdentity {
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
            if !hostNamesIdentity {
                Label(connectionState.label, systemImage: connectionState.systemImage)
                    .font(.caption)
                    .foregroundStyle(connectionState.color)
            }
            // In the Spacer's place, not beside one: a Spacer takes whatever
            // it is offered, and the line would be left with nothing.
            if model.isRunning, let activity = model.activity {
                AgentActivityLine(activity: activity)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            if connectionState != .connected && connectionState != .checking {
                Button("Connect", systemImage: "person.badge.key") { connect() }
                    .buttonStyle(.lampProminent)
                    .controlSize(.small)
            }
            if model.isRunning {
                Button("Stop", systemImage: "stop.fill") { model.cancel() }
                    .controlSize(.small)
            }
            // What Always Allow kept for this writing, to see and take back:
            // Lamp keeps it, out of Claude's own permission settings.
            if !savedPermissions.isEmpty {
                Button("Saved Permissions", systemImage: "checkmark.shield") { showingSavedPermissions = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("What Always Allow saved for this writing (\(savedPermissions.count))")
                    .popover(isPresented: $showingSavedPermissions, arrowEdge: .bottom) {
                        SavedPermissionsList(rules: savedPermissions, replying: model.isRunning) { rule in
                            do {
                                try AgentToolAllowRules.remove(rule, for: workspaceFolder)
                            } catch {
                                // Said, since the rule still holds.
                                submissionError = "Lamp couldn’t remove \(rule), so Claude may still do it without asking: \(error.localizedDescription)"
                            }
                            loadSavedPermissions()
                        }
                    }
            }
            if !chatGrants.isEmpty {
                Button("Allowed for This Chat", systemImage: "checkmark.circle") { showingChatGrants = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Commands allowed for this chat (\(chatGrants.count))")
                    .popover(isPresented: $showingChatGrants, arrowEdge: .bottom) {
                        ChatCommandGrantsList(grants: chatGrants) { grant in
                            if let key = model.chatGrantKey { AgentChatCommandGrants.shared.remove(grant, for: key) }
                        }
                    }
            }
            if !hostShowsNewChat {
                Button("New Chat", systemImage: "square.and.pencil") {
                    showingClearConfirmation = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canStartNewChat)
                .help("Start a new chat")
            }
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
                    .buttonStyle(.lampProminent)
                    .controlSize(.small)
                    .disabled(connectionState == .notInstalled)
                if connectionState == .notInstalled {
                    Link("Open installation guide", destination: provider.documentationURL)
                        .font(.caption)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else if model.messages.isEmpty, model.sendingPlaceholder.isEmpty, !mode.isReadOnly {
            writingStarters
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
                AgentUsageSummary(provider: provider)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(24)
            .allowsHitTesting(false)
        }
    }

    /// An empty writing chat offers a first question, each
    /// put in the message field to be read and sent, never sent for you; and
    /// says what goes with every message: the writing, and what is selected.
    private var writingStarters: some View {
        let name = workspaceName
        let starters: [(String, String)] = [
            ("text.quote", "Suggest Scripture that supports this section"),
            ("checkmark.seal", "Check each quotation against its translation"),
            ("scissors", "Tighten the paragraph I’ve selected"),
            ("list.bullet.indent", "Outline “\(name)” as a talk"),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Ask \(provider.shortName) about “\(name)”")
                .font(.headline)
            Text("Each message is sent with the writing and whatever you have selected in it. Changes appear in the editor as they are made, and can be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(starters, id: \.1) { symbol, prompt in
                    Button {
                        draft = prompt
                    } label: {
                        Label(prompt, systemImage: symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            AgentUsageSummary(provider: provider)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        onConnectionChanged?(connectionState)
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
                        .buttonStyle(.lampProminent)
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

extension Notification.Name {
    /// A reader chat's reply has finished. The object is the chat's workspace.
    static let lampReaderChatTurnFinished = Notification.Name("lampReaderChatTurnFinished")
}

/// Where each connected provider's account stands against its plan's limits,
/// for Settings and for a chat before its first message.
///
/// Asked when a view showing it appears and the last answer is more than a
/// few minutes old, or when the person asks; never on a timer. See
/// `AgentUsageReport` for what each provider is asked, and why only that.
@MainActor
final class AgentUsageService: ObservableObject {
    static let shared = AgentUsageService()

    enum State: Equatable {
        case loading
        case shown(AgentUsageReport)
        /// The provider gives no reading, or gave one Lamp could not read.
        case unavailable
    }

    @Published private(set) var states: [AIProviderCLI: State] = [:]
    private var askedAt: [AIProviderCLI: Date] = [:]
    private static let freshFor: TimeInterval = 5 * 60

    /// Whether Lamp has any way to ask this provider.
    /// Antigravity documents no way for an app to read its usage. Its plan
    /// is all `agy acp` says, and reading the CLI's sign-in to ask Google's
    /// servers directly is what its terms forbid.
    static func reports(_ provider: AIProviderCLI) -> Bool { provider != .antigravity }

    func refreshIfStale(_ provider: AIProviderCLI) {
        guard Self.reports(provider) else { return }
        if let asked = askedAt[provider], Date().timeIntervalSince(asked) < Self.freshFor { return }
        refresh(provider)
    }

    func refresh(_ provider: AIProviderCLI) {
        guard Self.reports(provider), states[provider] != .loading else { return }
        askedAt[provider] = Date()
        if case .shown? = states[provider] {} else { states[provider] = .loading }
        Task {
            let report: AgentUsageReport?
            switch provider {
            case .claude: report = await Self.claudeUsage()
            case .codex: report = await Self.codexUsage()
            case .openCode: report = await Self.openCodeUsage()
            case .antigravity: report = nil
            }
            states[provider] = report.map(State.shown) ?? .unavailable
        }
    }

    /// `claude -p /usage`: answered by Claude Code itself, with no model turn.
    private static func claudeUsage() async -> AgentUsageReport? {
        let result = await AgentCLIProcessRunner().run(
            executableName: AIProviderCLI.claude.executable,
            arguments: ["-p", "/usage"],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0 else { return nil }
        return AgentUsageReading.claude(usageOutput: result.output)
    }

    /// OpenCode's own server, through `opencode api`, as Lamp already asks it
    /// for its models. A release without the route answers 404, which shows
    /// nothing.
    private static func openCodeUsage() async -> AgentUsageReport? {
        let result = await AgentCLIProcessRunner().run(
            executableName: AIProviderCLI.openCode.executable,
            arguments: ["api", "GET", "/api/experimental/usage/limits"],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        guard result.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        else { return nil }
        return AgentUsageReading.openCode(limitsResponse: object)
    }

    /// `account/rateLimits/read` on `codex app-server`, over its stdio
    /// JSON-RPC: initialize, initialized, the one request, then gone.
    private static func codexUsage() async -> AgentUsageReport? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readCodexRateLimits())
            }
        }
    }

    nonisolated private static func readCodexRateLimits() -> AgentUsageReport? {
        guard let url = try? AgentCLIProcessRunner().resolveExecutable(named: AIProviderCLI.codex.executable)
        else { return nil }
        let process = AgentSpawnedProcess()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = url
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.environment = AgentProcessEnvironment.cleaned(ProcessInfo.processInfo.environment)
        AgentHelperProcesses.refuseSIGPIPE(input)
        guard (try? AgentHelperProcesses.launch(process)) != nil else { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            AgentHelperProcesses.end([process])
            AgentHelperProcesses.untrack(process)
            process.release()
        }
        // An app-server that never answers is not waited on past this; the
        // whole group, so a read held open by a child ends too.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            AgentHelperProcesses.end([process])
        }
        func send(_ message: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        }
        var reader = AgentChatLineReader()
        let handle = output.fileHandleForReading
        func reply(to id: Int) -> [String: Any]? {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return nil }
                for line in reader.lines(from: chunk) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          object["id"] as? Int == id
                    else { continue }
                    return object
                }
            }
        }
        send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "lamp-bible", "title": "Lamp Bible", "version": "1"],
        ]])
        guard reply(to: 1)?["result"] != nil else { return nil }
        send(["method": "initialized"])
        send(["id": 2, "method": "account/rateLimits/read", "params": [String: Any]()])
        guard let result = reply(to: 2)?["result"] as? [String: Any] else { return nil }
        return AgentUsageReading.codex(rateLimitsResult: result)
    }
}

/// A provider's usage, in a caption's voice: shown where the account is.
struct AgentUsageSummary: View {
    let provider: AIProviderCLI
    @ObservedObject private var service = AgentUsageService.shared

    var body: some View {
        Group {
            switch service.states[provider] {
            case .shown(let report)?:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.lines, id: \.self) { line in
                        Text(line)
                    }
                }
            case .loading?:
                Text("Checking usage…")
            case .unavailable?, nil:
                // Not `EmptyView`: a group with nothing in it never appears,
                // so its `.task` never runs and nothing is ever asked.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .task(id: provider) { service.refreshIfStale(provider) }
    }
}
