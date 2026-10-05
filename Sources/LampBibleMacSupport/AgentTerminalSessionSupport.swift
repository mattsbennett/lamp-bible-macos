import CryptoKit
import Foundation

// Terminal mode runs a provider's own interactive CLI, so Lamp never sees the
// conversation directly. It is captured instead through the hook each provider
// documents for exactly this — never by reading a provider's private session
// files, whose formats change between releases:
//
// - Claude Code and Codex: their `SessionStart`, `UserPromptSubmit` and `Stop`
//   lifecycle hooks, which carry `session_id`, `prompt` and
//   `last_assistant_message`. Both run sub-agents under separate events, so these
//   see only the user's own conversation. Lamp passes them per launch — Claude's
//   with `--settings`, Codex's with `-c` — and both CLIs add hooks given this way
//   to the user's own rather than replacing them.
// - OpenCode: a plugin using the published SDK's `session.messages()`, loaded
//   from a Lamp-owned `OPENCODE_CONFIG_DIR` only for Terminal launches.
//
// Each hook drops its payload, unaltered, into its own file. Lamp reads only the
// documented fields, so a release that adds fields changes nothing, and one that
// removes them stops capture visibly rather than corrupting the transcript.

/// What one captured file says happened in a Terminal session.
public enum AgentTerminalCaptureEvent: Equatable, Sendable {
    /// The provider reported the session it is running. Proof that capture works
    /// before any turn has completed.
    case sessionStarted(sessionID: String, isFreshConversation: Bool)
    /// Lamp's OpenCode plugin loaded.
    case integrationLoaded
    case messages(sessionID: String, [AgentChatTranscript.Message])
    /// The launch script couldn't set something up, and says what that costs.
    case launchNotice(String)
}

public enum AgentTerminalCaptureParser {
    /// Reads one captured payload.
    ///
    /// - Parameters:
    ///   - eventKey: unique to the file, used to give a message without a
    ///     provider-assigned id a stable one.
    ///   - recordedAt: when the payload was written, which is when the event
    ///     happened for providers whose payloads carry no time of their own.
    public static func parse(
        _ data: Data,
        provider: AgentChatWireProvider,
        eventKey: String,
        recordedAt: Date
    ) -> [AgentTerminalCaptureEvent]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if object["lamp"] as? String == AgentTerminalLaunchPlanner.noticeFormatName {
            return nonEmpty(object["notice"]).map { [.launchNotice($0)] }
        }
        switch provider {
        case .claude, .codex:
            return parseLifecycleHook(object, provider: provider, eventKey: eventKey, recordedAt: recordedAt)
        case .openCode:
            return parseOpenCode(object)
        }
    }

    /// Claude Code and Codex document the same hook payloads for these events.
    private static func parseLifecycleHook(
        _ object: [String: Any],
        provider: AgentChatWireProvider,
        eventKey: String,
        recordedAt: Date
    ) -> [AgentTerminalCaptureEvent]? {
        guard let sessionID = nonEmpty(object["session_id"]),
              let event = object["hook_event_name"] as? String
        else { return nil }
        // Codex identifies each turn; Claude doesn't, so its messages are keyed
        // by the file they arrived in.
        let turn = nonEmpty(object["turn_id"]) ?? eventKey
        func message(_ role: AgentChatTranscript.Role, _ text: String) -> AgentTerminalCaptureEvent {
            .messages(sessionID: sessionID, [AgentChatTranscript.Message(
                id: LampStableIdentifier.uuid([provider.rawValue, sessionID, turn, role.rawValue]),
                role: role,
                text: text,
                date: recordedAt
            )])
        }
        switch event {
        case "SessionStart":
            // `clear` is the user starting over inside the CLI; the transcript
            // follows, as it does for New Chat.
            let source = object["source"] as? String
            return [.sessionStarted(sessionID: sessionID, isFreshConversation: source == "clear")]
        case "UserPromptSubmit":
            return nonEmpty(object["prompt"]).map { [message(.user, $0)] } ?? []
        case "Stop":
            return nonEmpty(object["last_assistant_message"]).map { [message(.assistant, $0)] } ?? []
        default:
            return []
        }
    }

    /// Lamp's own plugin writes Lamp's own format, so this parses nothing of
    /// OpenCode's; the plugin is where the SDK's shapes are read.
    private static func parseOpenCode(_ object: [String: Any]) -> [AgentTerminalCaptureEvent]? {
        guard object["lamp"] as? String == AgentTerminalOpenCodePlugin.formatName else { return nil }
        switch object["event"] as? String {
        case "loaded":
            return [.integrationLoaded]
        case "messages":
            guard let sessionID = nonEmpty(object["sessionID"]),
                  let entries = object["messages"] as? [[String: Any]]
            else { return nil }
            let messages = entries.compactMap { entry -> AgentChatTranscript.Message? in
                guard let id = nonEmpty(entry["id"]),
                      let text = nonEmpty(entry["text"]),
                      let role = (entry["role"] as? String).flatMap(AgentChatTranscript.Role.init),
                      let created = entry["created"] as? Double
                else { return nil }
                return AgentChatTranscript.Message(
                    id: LampStableIdentifier.uuid(["opencode", id]),
                    role: role,
                    text: text,
                    date: Date(timeIntervalSince1970: created / 1_000)
                )
            }
            return [.messages(sessionID: sessionID, messages)]
        default:
            return []
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension AgentChatTranscript {
    /// Folds turns captured from a Terminal session into the conversation, and
    /// records that session as the one to resume — in Chat or Terminal.
    ///
    /// A message already present is replaced only if its text differs, so the
    /// same capture can be read twice without effect.
    func absorbing(
        capturedMessages: [Message],
        fromSession sessionID: String,
        installID: String,
        now: Date = Date()
    ) -> AgentChatTranscript {
        guard !capturedMessages.isEmpty else { return self }
        var result = self
        if result.conversationID == nil, result.messages.isEmpty {
            result.conversationID = UUID()
            result.startedAt = now
        }
        var positions = [UUID: Int]()
        for (index, message) in result.messages.enumerated() { positions[message.id] = index }

        var additions: [Message] = []
        for message in capturedMessages {
            if let index = positions[message.id] {
                if result.messages[index].text != message.text { result.messages[index] = message }
            } else if !additions.contains(where: { $0.id == message.id }) {
                additions.append(message)
            }
        }
        result.messages += additions.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        result.sessionID = sessionID
        result.sessionInstallID = installID
        return result
    }

    /// The user cleared the conversation inside the CLI.
    func startingOver(now: Date = Date()) -> AgentChatTranscript {
        AgentChatTranscript(conversationID: UUID(), startedAt: now)
    }
}

/// The session a Terminal launch is bound to, kept on disk so capture still
/// lands in the right place if Lamp restarts while the CLI keeps running.
public struct AgentTerminalLaunchRecord: Codable, Equatable, Sendable {
    public var providerID: String
    public var launchedAt: Date
    /// Known up front when resuming, or for Claude, whose session ID Lamp
    /// chooses. Otherwise adopted from the first session the provider reports,
    /// so a sub-agent's session can never take the conversation over.
    public var sessionID: String?

    public init(providerID: String, launchedAt: Date, sessionID: String? = nil) {
        self.providerID = providerID
        self.launchedAt = launchedAt
        self.sessionID = sessionID
    }
}

public struct AgentTerminalIngestResult: Equatable, Sendable {
    public var integrationReported = false
    public var absorbedMessageCount = 0
    public var unreadableFileCount = 0
    public var linkedSessionID: String?
    public var notices: [String] = []

    public init() {}
}

public enum AgentTerminalCaptureStore {
    private static let terminalDirectoryName = "terminal"

    /// Everything Terminal capture writes lives here, beside the transcript and
    /// out of sync's way: only the transcript it produces travels.
    public static func terminalDirectory(in workspace: URL) -> URL {
        AgentChatTranscriptStore.directory(in: workspace)
            .appendingPathComponent(terminalDirectoryName, isDirectory: true)
    }

    public static func captureDirectory(in workspace: URL) -> URL {
        terminalDirectory(in: workspace).appendingPathComponent("captured", isDirectory: true)
    }

    public static func launchRecordURL(in workspace: URL) -> URL {
        terminalDirectory(in: workspace).appendingPathComponent("launch.json")
    }

    public static func filePrefix(for provider: AgentChatWireProvider) -> String {
        switch provider {
        case .claude: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        }
    }

    public static func saveLaunchRecord(_ record: AgentTerminalLaunchRecord, in workspace: URL) throws {
        let url = launchRecordURL(in: workspace)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public static func loadLaunchRecord(in workspace: URL) -> AgentTerminalLaunchRecord? {
        guard let data = try? Data(contentsOf: launchRecordURL(in: workspace)) else { return nil }
        return try? JSONDecoder().decode(AgentTerminalLaunchRecord.self, from: data)
    }

    /// Reads every captured file for the launched provider, in the order the
    /// events happened, folds them into the transcript, and removes them.
    ///
    /// Files are removed only after the transcript is saved, so an interruption
    /// means the same events are read again — harmless, since absorbing is
    /// idempotent — rather than lost.
    @discardableResult
    public static func ingest(
        workspace: URL,
        installID: String,
        now: Date = Date()
    ) throws -> AgentTerminalIngestResult {
        var result = AgentTerminalIngestResult()
        guard var launch = loadLaunchRecord(in: workspace),
              let provider = AIProviderIdentity.wireProvider(forProviderID: launch.providerID)
        else { return result }

        let prefix = filePrefix(for: provider) + "."
        let directory = captureDirectory(in: workspace)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        .map { url -> (url: URL, created: Date) in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return (url, created ?? .distantPast)
        }
        .sorted { ($0.created, $0.url.lastPathComponent) < ($1.created, $1.url.lastPathComponent) }
        guard !files.isEmpty else { return result }

        let original = AgentChatTranscriptStore.load(providerID: launch.providerID, in: workspace)
        var transcript = original
        var launchChanged = false

        for file in files {
            guard let data = try? Data(contentsOf: file.url),
                  let events = AgentTerminalCaptureParser.parse(
                    data,
                    provider: provider,
                    eventKey: file.url.deletingPathExtension().lastPathComponent,
                    recordedAt: file.created
                  )
            else {
                result.unreadableFileCount += 1
                continue
            }
            for event in events {
                switch event {
                case .integrationLoaded:
                    result.integrationReported = true
                case .launchNotice(let notice):
                    result.notices.append(notice)
                case .sessionStarted(let sessionID, let isFresh):
                    result.integrationReported = true
                    // Sub-agents report under their own events, so a new
                    // session here is the user's own `/clear` or `/resume`.
                    if launch.sessionID != sessionID {
                        launch.sessionID = sessionID
                        launchChanged = true
                    }
                    if isFresh { transcript = transcript.startingOver(now: now) }
                case .messages(let sessionID, let messages):
                    result.integrationReported = true
                    if launch.sessionID == nil {
                        launch.sessionID = sessionID
                        launchChanged = true
                    }
                    guard sessionID == launch.sessionID, !messages.isEmpty else { continue }
                    transcript = transcript.absorbing(
                        capturedMessages: messages,
                        fromSession: sessionID,
                        installID: installID,
                        now: now
                    )
                    result.absorbedMessageCount += messages.count
                    result.linkedSessionID = sessionID
                }
            }
        }

        if transcript != original {
            try AgentChatTranscriptStore.save(transcript, providerID: launch.providerID, in: workspace)
        }
        if launchChanged { try saveLaunchRecord(launch, in: workspace) }
        for file in files { try? FileManager.default.removeItem(at: file.url) }
        return result
    }
}

/// Writes everything a Terminal launch needs and returns the command that
/// starts it.
///
/// Everything here goes through options each CLI documents: resuming by ID,
/// handing over a recap as instructions, and the hooks that report turns.
public enum AgentTerminalLauncher {
    public struct Prepared: Equatable, Sendable {
        /// Typed into the login shell. `/bin/sh` inherits its environment,
        /// `PATH` included, and the script carries the exact arguments.
        public var command: String
        public var resumedSessionID: String?
        public var carriesRecap: Bool
        /// Lamp wrote its integration afresh — for OpenCode, the plugin, which
        /// OpenCode then installs again on load.
        public var integrationWrittenAfresh: Bool
    }

    public static func prepare(
        providerID: String,
        executable: String,
        workspace: URL,
        installID: String,
        openCodeConfigDirectory: URL,
        now: Date = Date()
    ) throws -> Prepared {
        guard let provider = AIProviderIdentity.wireProvider(forProviderID: providerID) else {
            throw CocoaError(.featureUnsupported)
        }
        // Anything the previous launch reported belongs to its session; collect
        // it before the launch record is replaced.
        _ = try? AgentTerminalCaptureStore.ingest(workspace: workspace, installID: installID, now: now)

        let transcript = AgentChatTranscriptStore.load(providerID: providerID, in: workspace)
        let resumeSessionID = transcript.resumableSessionID(forInstall: installID)
        // Claude lets Lamp choose a new session's ID, so it is known from the start.
        let newSessionID = provider == .claude && resumeSessionID == nil
            ? UUID().uuidString.lowercased() : nil

        let terminalDirectory = AgentTerminalCaptureStore.terminalDirectory(in: workspace)
        try FileManager.default.createDirectory(at: terminalDirectory, withIntermediateDirectories: true)

        let recapText = resumeSessionID == nil
            ? AgentChatContinuation.sessionInstructions(continuing: transcript.messages)
            : nil
        let recapFile = terminalDirectory.appendingPathComponent("earlier-conversation.md")
        if let recapText {
            try recapText.write(to: recapFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: recapFile)
        }

        let claudeSettings = terminalDirectory.appendingPathComponent("claude-settings.json")
        try AgentTerminalLaunchPlanner.claudeSettings().write(to: claudeSettings, options: .atomic)
        let integrationWrittenAfresh = provider == .openCode
            ? try installOpenCodePlugin(in: openCodeConfigDirectory)
            : false

        let plan = AgentTerminalLaunchPlanner.plan(.init(
            provider: provider,
            executable: executable,
            resumeSessionID: resumeSessionID,
            newSessionID: newSessionID,
            recapFile: recapText == nil ? nil : recapFile,
            recapText: recapText,
            captureDirectory: AgentTerminalCaptureStore.captureDirectory(in: workspace),
            claudeSettingsFile: claudeSettings,
            openCodeConfigDirectory: openCodeConfigDirectory
        ))
        let script = terminalDirectory.appendingPathComponent("launch.sh")
        try AgentTerminalLaunchPlanner.shellScript(for: plan)
            .write(to: script, atomically: true, encoding: .utf8)

        try AgentTerminalCaptureStore.saveLaunchRecord(
            AgentTerminalLaunchRecord(
                providerID: providerID,
                launchedAt: now,
                sessionID: resumeSessionID ?? newSessionID
            ),
            in: workspace
        )
        return Prepared(
            command: "exec /bin/sh " + AgentTerminalLaunchPlanner.shellQuote(script.path),
            resumedSessionID: resumeSessionID,
            carriesRecap: recapText != nil,
            integrationWrittenAfresh: integrationWrittenAfresh
        )
    }

    /// Writes the plugin unless it's already there as this Lamp has it, and
    /// says whether it had to.
    static func installOpenCodePlugin(in directory: URL) throws -> Bool {
        let plugin = directory
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(AgentTerminalOpenCodePlugin.filename)
        let source = AgentTerminalOpenCodePlugin.source
        guard (try? String(contentsOf: plugin, encoding: .utf8)) != source else { return false }
        try FileManager.default.createDirectory(
            at: plugin.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: plugin, atomically: true, encoding: .utf8)
        return true
    }
}

/// What Lamp remembers about each CLI having run its capture integration on
/// this Mac, so first-run guidance shows only while it's needed.
///
/// Each remembers the exact integration that ran, by fingerprint, not just that
/// something did: a Lamp release that changes it brings the guidance back.
/// Kept in this Mac's preferences and deliberately not synced, since what it
/// stands for — Codex's trust, OpenCode's installed plugin — lives on this Mac.
public enum AgentTerminalIntegrationMemory: CaseIterable, Sendable {
    /// Codex reports nothing until a session's first prompt, so at launch Lamp
    /// can't see whether its hooks are trusted. Once they have reported they
    /// stay trusted: Codex keeps trust for the exact definition, and asks again
    /// only if it changes.
    case codexHooks
    /// OpenCode installs a plugin's SDK the first time it loads the plugin,
    /// which can take a while. After that it loads quickly — until Lamp has to
    /// write the plugin again, when this is forgotten.
    case openCodePlugin

    public static func forProvider(_ provider: AgentChatWireProvider) -> Self? {
        switch provider {
        case .codex: .codexHooks
        case .openCode: .openCodePlugin
        // Claude's hooks need no first-run step, so there's nothing to remember.
        case .claude: nil
        }
    }

    var defaultsKey: String {
        switch self {
        case .codexHooks: "agent.terminal.codexHooksReported"
        case .openCodePlugin: "agent.terminal.openCodePluginLoaded"
        }
    }

    /// Identifies the integration as this Lamp installs it.
    public var fingerprint: String {
        let definition = switch self {
        case .codexHooks: AgentTerminalLaunchPlanner.codexHookOverrides().joined(separator: "\n")
        case .openCodePlugin: AgentTerminalOpenCodePlugin.source
        }
        return SHA256.hash(data: Data(definition.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func hasRun(in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: defaultsKey) == fingerprint
    }

    public func recordRun(in defaults: UserDefaults = .standard) {
        guard !hasRun(in: defaults) else { return }
        defaults.set(fingerprint, forKey: defaultsKey)
    }

    public func forget(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// A resumed session the CLI no longer has.
///
/// Each CLI, asked to resume a session it doesn't have, prints why and exits
/// with status 1 within a couple of seconds, before any turn. What it prints goes
/// to the terminal, out of Lamp's reach, so the exit is the signal. Without
/// handling it, every later launch would try the same dead session.
public enum AgentTerminalResumeFailure {
    public static let window: TimeInterval = 15

    public static func indicatesMissingSession(
        exitStatus: Int32?,
        runningFor: TimeInterval,
        capturedMessages: Int
    ) -> Bool {
        // 126 and 127 are the shell failing to find or run the CLI at all;
        // above that, the CLI was stopped by a signal — closed by Lamp or the
        // user, not turned away.
        guard let exitStatus, exitStatus > 0, exitStatus < 126 else { return false }
        return runningFor < window && capturedMessages == 0
    }
}

public extension AgentTerminalCaptureStore {
    /// Lets go of a session that can't be resumed, keeping the conversation, so
    /// the next launch carries it on from a recap.
    @discardableResult
    static func forgetSession(_ sessionID: String, providerID: String, in workspace: URL) throws -> Bool {
        var transcript = AgentChatTranscriptStore.load(providerID: providerID, in: workspace)
        guard transcript.sessionID == sessionID else { return false }
        transcript.sessionID = nil
        transcript.sessionInstallID = nil
        try AgentChatTranscriptStore.save(transcript, providerID: providerID, in: workspace)
        return true
    }
}

public enum TerminalWaitStatus {
    /// The exit status a shell would report for a raw `waitpid` status, which
    /// is what SwiftTerm hands over: `exit(1)` arrives as 256.
    public static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}

/// Maps the identifiers the app uses for each CLI onto the wire provider. Kept
/// here so capture can run without the app's own types.
public enum AIProviderIdentity {
    public static func wireProvider(forProviderID providerID: String) -> AgentChatWireProvider? {
        switch providerID {
        case "claude": .claude
        case "codex": .codex
        case "openCode": .openCode
        default: nil
        }
    }
}

/// How a Terminal session should be started, independent of how it is typed.
public struct AgentTerminalLaunchPlan: Equatable, Sendable {
    /// An environment variable Lamp sets only if the user hasn't: overriding
    /// theirs would break their configuration to make Lamp's work.
    public struct GuardedVariable: Equatable, Sendable {
        public var name: String
        public var value: String
        /// What is lost when it is left alone, reported back to Lamp.
        public var noticeIfAlreadySet: String
    }

    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var guardedEnvironment: [GuardedVariable]
    /// Captured files are named for their provider, so a notice from the
    /// launch script is read alongside the session's own events.
    public var capturePrefix: String
}

public enum AgentTerminalLaunchPlanner {
    public struct Request: Sendable {
        public var provider: AgentChatWireProvider
        public var executable: String
        /// A session this Mac holds, to resume.
        public var resumeSessionID: String?
        /// For Claude, the ID to give a new session so it is known from the start.
        public var newSessionID: String?
        /// The earlier conversation, written out, when there is one to carry on
        /// but no session to resume.
        public var recapFile: URL?
        public var recapText: String?
        public var captureDirectory: URL
        public var claudeSettingsFile: URL
        public var openCodeConfigDirectory: URL

        public init(
            provider: AgentChatWireProvider,
            executable: String,
            resumeSessionID: String?,
            newSessionID: String?,
            recapFile: URL?,
            recapText: String?,
            captureDirectory: URL,
            claudeSettingsFile: URL,
            openCodeConfigDirectory: URL
        ) {
            self.provider = provider
            self.executable = executable
            self.resumeSessionID = resumeSessionID
            self.newSessionID = newSessionID
            self.recapFile = recapFile
            self.recapText = recapText
            self.captureDirectory = captureDirectory
            self.claudeSettingsFile = claudeSettingsFile
            self.openCodeConfigDirectory = openCodeConfigDirectory
        }
    }

    public static let captureDirectoryVariable = "LAMP_CAPTURE_DIR"
    static let noticeFormatName = "lamp-terminal-notice"

    public static func plan(_ request: Request) -> AgentTerminalLaunchPlan {
        var plan = AgentTerminalLaunchPlan(
            executable: request.executable,
            arguments: [],
            environment: [captureDirectoryVariable: request.captureDirectory.path],
            guardedEnvironment: [],
            capturePrefix: AgentTerminalCaptureStore.filePrefix(for: request.provider)
        )
        switch request.provider {
        case .claude:
            // Settings passed this way add to the user's own, hooks included.
            plan.arguments = ["--settings", request.claudeSettingsFile.path]
            if let resume = request.resumeSessionID {
                plan.arguments += ["--resume", resume]
            } else if let new = request.newSessionID {
                plan.arguments += ["--session-id", new]
            }
            if request.resumeSessionID == nil, let recapFile = request.recapFile {
                plan.arguments += ["--append-system-prompt-file", recapFile.path]
            }

        case .codex:
            // Overrides go before the subcommand, where Codex reads them for
            // every subcommand alike.
            plan.arguments = codexHookOverrides()
            if request.resumeSessionID == nil, let recapText = request.recapText {
                // Documented as adding to Codex's own instructions, not replacing them.
                plan.arguments += ["-c", "developer_instructions=" + tomlString(recapText)]
            }
            if let resume = request.resumeSessionID {
                plan.arguments += ["resume", resume]
            }

        case .openCode:
            if let resume = request.resumeSessionID {
                plan.arguments = ["--session", resume]
            }
            plan.guardedEnvironment.append(.init(
                name: "OPENCODE_CONFIG_DIR",
                value: request.openCodeConfigDirectory.path,
                noticeIfAlreadySet: "Your shell sets OPENCODE_CONFIG_DIR, so Lamp left it alone and couldn’t load its capture plugin. Turns from this session won’t sync."
            ))
            if request.resumeSessionID == nil, let recapFile = request.recapFile {
                plan.guardedEnvironment.append(.init(
                    name: "OPENCODE_CONFIG_CONTENT",
                    value: openCodeInstructionsConfig(recapFile),
                    noticeIfAlreadySet: "Your shell sets OPENCODE_CONFIG_CONTENT, so Lamp left it alone and OpenCode wasn’t given a recap of the earlier conversation."
                ))
            }
        }
        return plan
    }

    /// A POSIX script that starts the CLI. Lamp writes it per launch and the
    /// terminal runs it with `/bin/sh`, which inherits the login shell's
    /// environment — `PATH` included — while giving Lamp exact control over
    /// quoting that typing a long command into the user's shell would not.
    public static func shellScript(for plan: AgentTerminalLaunchPlan) -> String {
        var lines = [
            "#!/bin/sh",
            "# Written by Lamp to start one Terminal session; rewritten on every launch.",
        ]
        for (name, value) in plan.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name)=\(shellQuote(value)); export \(name)")
        }
        if !plan.guardedEnvironment.isEmpty {
            lines.append(contentsOf: [
                "lamp_notice() {",
                "  d=\"$\(captureDirectoryVariable)\"; mkdir -p \"$d\" && t=$(mktemp \"$d/.notice.XXXXXXXX\") && "
                    + "printf '%s' \"$1\" > \"$t\" && mv \"$t\" \"$d/\(plan.capturePrefix).${t##*.}.json\"",
                "}",
            ])
        }
        for variable in plan.guardedEnvironment {
            lines.append(contentsOf: [
                "if [ -n \"${\(variable.name):-}\" ]; then",
                "  lamp_notice \(shellQuote(noticeJSON(variable.noticeIfAlreadySet)))",
                "else",
                "  \(variable.name)=\(shellQuote(variable.value)); export \(variable.name)",
                "fi",
            ])
        }
        let command = ([plan.executable] + plan.arguments).map(shellQuote).joined(separator: " ")
        // Clear the screen and scrollback, which still show this script's long
        // path as it was typed, so the session starts on a clean terminal.
        lines.append("printf '\\033[H\\033[2J\\033[3J'")
        lines.append("exec \(command)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The settings file for Claude's capture hooks.
    public static func claudeSettings() throws -> Data {
        let hook: [String: Any] = ["type": "command", "command": captureCommand(prefix: "claude")]
        let settings: [String: Any] = [
            "hooks": Dictionary(uniqueKeysWithValues: capturedEvents.map { ($0, [["hooks": [hook]]]) }),
        ]
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    /// `-c hooks.<Event>=[…]` for each captured event.
    ///
    /// Codex runs a hook only once the user has reviewed and trusted its exact
    /// definition, which it asks for the first time it sees one. Trust for hooks
    /// passed this way is kept by definition, not by workspace, so these must be
    /// identical on every launch: any change, even to whitespace, asks the user
    /// to trust them again.
    public static func codexHookOverrides() -> [String] {
        let handler = "{type=\"command\",command=\(tomlString(captureCommand(prefix: "codex")))}"
        return capturedEvents.flatMap { ["-c", "hooks.\($0)=[{hooks=[\(handler)]}]"] }
    }

    static let capturedEvents = ["SessionStart", "UserPromptSubmit", "Stop"]

    /// Copies the hook's payload into the capture folder. It names no path of
    /// its own — the folder comes from the launch's environment — so it is the
    /// same for every workspace, and does nothing outside Lamp's launches.
    ///
    /// The payload is written to a hidden file and renamed into view only when
    /// complete, so Lamp never reads a half-written event. It always succeeds:
    /// a failed capture must never interrupt the user's session.
    static func captureCommand(prefix: String) -> String {
        "d=\"${\(captureDirectoryVariable):-}\"; [ -n \"$d\" ] || exit 0; "
            + "mkdir -p \"$d\" && t=$(mktemp \"$d/.\(prefix).XXXXXXXX\") && "
            + "cat > \"$t\" && mv \"$t\" \"$d/\(prefix).${t##*.}.json\"; exit 0"
    }

    static func noticeJSON(_ notice: String) -> String {
        let object: [String: Any] = ["lamp": noticeFormatName, "notice": notice]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func openCodeInstructionsConfig(_ recapFile: URL) -> String {
        let object = ["instructions": [recapFile.path]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Single-quoted for a POSIX shell; the only character that needs care is
    /// the single quote itself.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A TOML basic string, as Codex's `-c` overrides parse their values.
    public static func tomlString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

/// Lamp's OpenCode plugin. It runs only where `LAMP_CAPTURE_DIR` is set — Lamp's
/// Terminal launches — and writes Lamp's own format, so OpenCode's SDK shapes are
/// read in this one small place and nowhere in Lamp.
public enum AgentTerminalOpenCodePlugin {
    public static let formatName = "lamp-opencode-capture"
    public static let filename = "lamp-capture.js"

    public static let source = """
    // Written by Lamp. Records completed OpenCode turns from Lamp's Terminal so
    // the conversation can sync. Inactive in any session Lamp didn't start.
    import { mkdir, rename, writeFile } from "node:fs/promises"
    import { join } from "node:path"
    import { randomUUID } from "node:crypto"

    export const LampCapture = async ({ client }) => {
      const directory = process.env.LAMP_CAPTURE_DIR
      if (!directory) return {}
      const startedAt = Date.now()
      const record = async (payload) => {
        try {
          await mkdir(directory, { recursive: true })
          const name = `opencode.${randomUUID()}`
          const pending = join(directory, `.${name}`)
          await writeFile(pending, JSON.stringify({ lamp: "\(formatName)", version: 1, ...payload }))
          await rename(pending, join(directory, `${name}.json`))
        } catch {}
      }
      const unwrap = (response) => (response && "data" in response ? response.data : response)
      await record({ event: "loaded" })
      return {
        event: async ({ event }) => {
          if (event?.type !== "session.idle") return
          const sessionID = event.properties?.sessionID
          if (!sessionID) return
          try {
            // Sub-agents run in child sessions; only the user's conversation is kept.
            const session = unwrap(await client.session.get({ path: { id: sessionID } }))
            if (session?.parentID) return
            const items = unwrap(await client.session.messages({ path: { id: sessionID } })) ?? []
            const messages = []
            for (const item of items) {
              const info = item?.info ?? {}
              const created = info.time?.created ?? 0
              // Messages from before this launch are already in Lamp's transcript.
              if (created < startedAt - 1000) continue
              if (info.role !== "user" && info.role !== "assistant") continue
              if (info.role === "assistant" && !info.time?.completed) continue
              const text = (item.parts ?? [])
                .filter((part) => part?.type === "text" && !part.synthetic && typeof part.text === "string")
                .map((part) => part.text)
                .join("\\n")
                .trim()
              if (text) messages.push({ id: info.id, role: info.role, text, created })
            }
            if (messages.length) await record({ event: "messages", sessionID, messages })
          } catch {}
        },
      }
    }

    """
}

/// Stable identifiers derived from provider-assigned ones, so re-reading the
/// same capture yields the same messages.
public enum LampStableIdentifier {
    public static func uuid(_ components: [String]) -> UUID {
        let digest = SHA256.hash(data: Data(components.joined(separator: "\u{1F}").utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
