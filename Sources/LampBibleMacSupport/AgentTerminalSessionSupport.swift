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
//
// One more hook goes the other way. With each message, Claude Code and Codex
// run a `UserPromptSubmit` hook that prints what the writing editor has open and
// selected, and both add what such a hook prints to what the model is given.
// OpenCode has no such hook; its instructions point it at the same file.

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
        // No Terminal session for Antigravity, so nothing is captured.
        case .antigravity:
            return nil
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

    /// Where the files the Terminal runs are written for a workspace: the
    /// launch script, Claude's settings and the recap. In Lamp's own folder,
    /// outside every workspace, so what Lamp runs is never a file an agent in
    /// the writing could have written (`decisions/0032`). One folder per
    /// workspace, by a digest of its path, written afresh at each launch.
    public static func launchDirectory(for workspace: URL, in root: URL = launchRoot) -> URL {
        let path = workspace.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    /// Removes the launch files the Terminal used to have written in the
    /// workspace, which nothing runs now: each only if it is a plain file,
    /// reached through folders that are not links, so the clean-up never
    /// leaves the workspace or takes a folder.
    public static func removeRetiredLaunchFiles(in workspace: URL) {
        let base = workspace.standardizedFileURL.path
        let folder = terminalDirectory(in: workspace).standardizedFileURL.path
        guard folder.hasPrefix(base + "/") else { return }
        var directory = open(base, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { close(directory) }
        for part in folder.dropFirst(base.count + 1).split(separator: "/") {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return }
            close(directory)
            directory = next
        }
        for name in ["launch.sh", "claude-settings.json", "earlier-conversation.md"] {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            unlinkat(directory, name, 0)
        }
    }

    /// Launch folders not used for a month go, with the recaps of
    /// conversations they held: a writing moved or deleted leaves its folder
    /// under a path no launch will name again. Only folders named as
    /// `launchDirectory` names them, and none reached through a link.
    public static func pruneLaunches(in root: URL, now: Date = Date(), olderThan days: Double = 30) {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard name.count == 24, name.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { continue }
            let folder = root.appendingPathComponent(name)
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A writing's own launches from before today go; the folder each
    /// Terminal ran from is needed only while it starts.
    public static func pruneLaunchesOf(_ folder: URL, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-86_400)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard UUID(uuidString: name) != nil else { continue }
            let launch = folder.appendingPathComponent(name)
            var info = stat()
            guard lstat(launch.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: launch)
        }
    }

    public static var launchRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lamp Bible", isDirectory: true)
            .appendingPathComponent("Terminal Launches", isDirectory: true)
    }

    public static func launchRecordURL(in workspace: URL) -> URL {
        terminalDirectory(in: workspace).appendingPathComponent("launch.json")
    }

    public static func filePrefix(for provider: AgentChatWireProvider) -> String {
        switch provider {
        case .claude: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        case .antigravity: "agy"
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
        /// Where this launch's CLI says it has started, for one that can
        /// (Claude); nil for one that can't, whose hold ends by time.
        public var readyMarker: URL?
        /// This launch's own folder of what it runs.
        public var launchFolder: URL
    }

    public static func prepare(
        providerID: String,
        executable: String,
        workspace: URL,
        installID: String,
        openCodeConfigDirectory: URL,
        editorStateFile: URL? = nil,
        launchRoot: URL = AgentTerminalCaptureStore.launchRoot,
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

        // What the Terminal runs, outside the workspace; see `launchDirectory`.
        // A folder of this launch's own within it, so two launches of one
        // writing at once don't write over each other's script and start mark.
        AgentTerminalCaptureStore.pruneLaunches(in: launchRoot, now: now)
        let writingLaunches = AgentTerminalCaptureStore.launchDirectory(for: workspace, in: launchRoot)
        AgentTerminalCaptureStore.pruneLaunchesOf(writingLaunches, now: now)
        let terminalDirectory = writingLaunches.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: terminalDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: AgentTerminalCaptureStore.terminalDirectory(in: workspace), withIntermediateDirectories: true
        )
        AgentTerminalCaptureStore.removeRetiredLaunchFiles(in: workspace)

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
        // This launch's own, so an older one's start doesn't count for it.
        let readyMarker = terminalDirectory.appendingPathComponent("ready-\(UUID().uuidString)")
        try AgentTerminalLaunchPlanner.claudeSettings(readyMarker: readyMarker).write(to: claudeSettings, options: .atomic)
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
            openCodeConfigDirectory: openCodeConfigDirectory,
            editorStateFile: editorStateFile,
            readyMarker: readyMarker
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
            integrationWrittenAfresh: integrationWrittenAfresh,
            readyMarker: [.claude, .openCode].contains(provider) ? readyMarker : nil,
            launchFolder: terminalDirectory
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
        case .antigravity: nil
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
        /// Where the CLI marks that it has started, for OpenCode, whose
        /// plugin is told it in the environment (Claude's is in its settings).
        public var readyMarker: URL?
        /// The earlier conversation, written out, when there is one to carry on
        /// but no session to resume.
        public var recapFile: URL?
        public var recapText: String?
        public var captureDirectory: URL
        public var claudeSettingsFile: URL
        public var openCodeConfigDirectory: URL
        /// What the writing editor has open and selected, kept current by
        /// the editor, for the context hook to hand over with each message.
        public var editorStateFile: URL?

        public init(
            provider: AgentChatWireProvider,
            executable: String,
            resumeSessionID: String?,
            newSessionID: String?,
            recapFile: URL?,
            recapText: String?,
            captureDirectory: URL,
            claudeSettingsFile: URL,
            openCodeConfigDirectory: URL,
            editorStateFile: URL? = nil,
            readyMarker: URL? = nil
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
            self.readyMarker = readyMarker
            self.editorStateFile = editorStateFile
        }
    }

    public static let captureDirectoryVariable = "LAMP_CAPTURE_DIR"
    public static let editorStateVariable = "LAMP_EDITOR_STATE"
    public static let readyMarkerVariable = "LAMP_READY_MARKER"
    static let noticeFormatName = "lamp-terminal-notice"

    public static func plan(_ request: Request) -> AgentTerminalLaunchPlan {
        var plan = AgentTerminalLaunchPlan(
            executable: request.executable,
            arguments: [],
            environment: [captureDirectoryVariable: request.captureDirectory.path],
            guardedEnvironment: [],
            capturePrefix: AgentTerminalCaptureStore.filePrefix(for: request.provider)
        )
        if let editorState = request.editorStateFile {
            plan.environment[editorStateVariable] = editorState.path
        }
        if request.provider == .openCode, let readyMarker = request.readyMarker {
            plan.environment[readyMarkerVariable] = readyMarker.path
        }
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

        case .antigravity:
            // Lamp offers no Terminal session for Antigravity: driving its
            // interactive CLI from another app is not the integration Google
            // documents, so its chats go through `agy acp` alone. Nothing
            // asks for this plan.
            break

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

    /// The settings file for Claude's capture hooks, and the context hook
    /// that hands over the editor's state with each message.
    /// `readyMarker`: a file in Lamp's own folder the session touches as it
    /// starts, once it has read its settings, which is how Lamp knows a
    /// launch is ready (`decisions/0032`); never anything in the workspace,
    /// which an agent could write.
    public static func claudeSettings(readyMarker: URL? = nil) throws -> Data {
        let capture: [String: Any] = ["type": "command", "command": captureCommand(prefix: "claude")]
        let context: [String: Any] = ["type": "command", "command": contextCommand]
        var hooks = Dictionary(uniqueKeysWithValues: capturedEvents.map { event in
            (event, [["hooks": event == contextEvent ? [capture, context] : [capture]]])
        })
        if let readyMarker {
            let ready: [String: Any] = ["type": "command", "command": "/usr/bin/touch " + shellQuote(readyMarker.path)]
            hooks["SessionStart"] = [["hooks": (hooks["SessionStart"]?.first?["hooks"] as? [[String: Any]] ?? []) + [ready]]]
        }
        // What the assistant wrote, said by the assistant.
        //
        // The editor sees only that a file in the workspace changed, and
        // a change is the assistant's or the writer's own arriving from
        // another device — a mark is a claim about which, and it cannot
        // be read off the file. Told here, it is not guessed: the hook
        // carries the path its tool wrote.
        //
        // Claude's only, which is where it is documented. The others
        // fall back to what the editor can show for itself, which marks
        // less rather than marking wrongly.
        var all: [String: Any] = hooks
        all[wroteEvent] = [[
            "matcher": "Write|Edit|NotebookEdit",
            "hooks": [["type": "command", "command": wroteCommand]],
        ] as [String: Any]]
        return try JSONSerialization.data(
            withJSONObject: ["hooks": all], options: [.prettyPrinted, .sortedKeys]
        )
    }

    static let wroteEvent = "PostToolUse"
    /// Where the payloads naming what a tool wrote are left, beside the
    /// turns: a folder of its own, so the turn reader never sees them.
    public static let wroteDirectoryName = "wrote"

    public static func wroteDirectory(in workspace: URL) -> URL {
        AgentTerminalCaptureStore.captureDirectory(in: workspace)
            .appendingPathComponent(wroteDirectoryName, isDirectory: true)
    }

    /// The same shape as the capture hook, into a folder of its own, and
    /// silent about everything: a hook that fails must never be what
    /// stops a writer's turn.
    static var wroteCommand: String {
        "d=\"${\(captureDirectoryVariable):-}\"; [ -n \"$d\" ] || exit 0; "
            + "d=\"$d/\(wroteDirectoryName)\"; "
            + "mkdir -p \"$d\" && t=$(mktemp \"$d/.wrote.XXXXXXXX\") && "
            + "cat > \"$t\" && mv \"$t\" \"$d/wrote.${t##*.}.json\"; exit 0"
    }

    /// `-c hooks.<Event>=[…]` for each captured event.
    ///
    /// Codex runs a hook only once the user has reviewed and trusted its exact
    /// definition, which it asks for the first time it sees one. Trust for hooks
    /// passed this way is kept by definition, not by workspace, so these must be
    /// identical on every launch: any change, even to whitespace, asks the user
    /// to trust them again.
    public static func codexHookOverrides() -> [String] {
        let capture = "{type=\"command\",command=\(tomlString(captureCommand(prefix: "codex")))}"
        let context = "{type=\"command\",command=\(tomlString(contextCommand))}"
        return capturedEvents.flatMap { event in
            let handlers = event == contextEvent ? "\(capture),\(context)" : capture
            return ["-c", "hooks.\(event)=[{hooks=[\(handlers)]}]"]
        }
    }

    static let capturedEvents = ["SessionStart", "UserPromptSubmit", "Stop"]
    /// When the editor's state is handed over: with each message, where both
    /// CLIs add what a hook prints to what the model is given.
    static let contextEvent = "UserPromptSubmit"

    /// Prints what the writing editor has open and selected, from the file
    /// the launch names. Like the capture hook it names no path of its own,
    /// so it is the same for every workspace and Codex's trust in it holds,
    /// and it does nothing outside Lamp's launches.
    ///
    /// It reads its payload first, which it has no use for, so the CLI never
    /// finds the pipe closed on it; and it always succeeds, since an editor
    /// with nothing to say must not stop a message.
    static let contextCommand =
        "cat > /dev/null; f=\"${\(editorStateVariable):-}\"; "
            + "[ -n \"$f\" ] && [ -s \"$f\" ] && cat \"$f\"; exit 0"

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
      // Started, and so settings read: Lamp's mark for this launch, in its
      // own folder, which ends the writing's hold on its chats.
      if (process.env.LAMP_READY_MARKER) {
        try { await writeFile(process.env.LAMP_READY_MARKER, "") } catch {}
      }
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

/// What the assistant has said it wrote.
///
/// The editor's poll sees only that a file in the workspace changed, and
/// cannot tell the assistant writing one from the writer's own edits
/// arriving from another device. A mark is a claim about which of those
/// happened, so it must be shown rather than guessed.
///
/// The assistant says so itself, through its own tool hook
/// (`AgentTerminalLaunchPlanner.wroteCommand`), which leaves the payload its
/// CLI hands it. This reads those payloads and answers for a path.
///
/// Said only where the CLI runs the hook, which today is Claude's. The
/// others fall back to what the editor can show for itself: a turn open
/// and a body no sync pass installed. That marks less rather than
/// marking wrongly, which is the right way round — an unmarked change is
/// in the document's history, while a mark on the writer's own sentence
/// is a claim they have to clear.
public enum AgentDeclaredWrites {
    /// Every workspace path the assistant has said it wrote, read from
    /// the payloads and then taken away, so one write is answered once.
    ///
    /// Read whole each time rather than watched: these arrive a handful
    /// to a turn, and a directory of a few files costs nothing beside
    /// the poll that asks.
    /// What the assistant said it wrote, for the paths asked about.
    ///
    /// Only those are taken away. A declaration for a file this look did
    /// not see is left where it is: the poll that does see that file
    /// needs it, and a declaration thrown away is a mark never made.
    ///
    /// The body comes with it where the tool reported one, which `Write`
    /// does. That is what the assistant actually left, and it may not be
    /// what stands in the file by the time anyone looks — the writer can
    /// have typed since. Marking up to the declared body says what the
    /// assistant did and leaves what the writer did alone.
    public static func take(
        _ paths: Set<String>, in workspace: URL, fileManager: FileManager = .default
    ) -> [String: String?] {
        let directory = AgentTerminalLaunchPlanner.wroteDirectory(in: workspace)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return [:]
        }
        var written: [String: String?] = [:]
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let input = payload["tool_input"] as? [String: Any],
                  let path = input["file_path"] as? String
            else {
                // Nothing anyone can use, and keeping it would mean
                // reading it again on every poll for ever.
                try? fileManager.removeItem(at: url)
                continue
            }
            // Standardised, since a hook reports whatever path its tool
            // was given and the editor knows the file by its own.
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            guard paths.contains(standard) else { continue }
            // The last one wins, read in name order, which is the order
            // they were left: a file written twice in a turn is as the
            // assistant last left it.
            written[standard] = input["content"] as? String
            try? fileManager.removeItem(at: url)
        }
        return written
    }
}

/// What a writing's own settings hold that Lamp cannot vouch for, put to the
/// person before a Terminal opens (`decisions/0032`).
///
/// The Terminal is the person's own session and keeps reading the writing's
/// settings, so nothing they use there changes. But those files are in the
/// workspace, where any provider's agent can write, and what is written there
/// runs when the Terminal opens. So before it opens, Lamp writes its own
/// provider files again, then looks at everything under the folders and
/// files a provider reads (`roots`), and counts every entry it does not
/// recognise: anything but Lamp's own files as it writes them, its skills as
/// it installs them, and in `.claude/settings.local.json` the settings Claude
/// writes there itself; an allow rule or extra folder is shown for the person
/// to keep, never trusted for when it appeared (who wrote a rule can't be told
/// from when, and five reviews broke every way of guessing it), while a rule
/// that only restricts passes. An allow-list, failing closed: a
/// setting no one has seen yet counts. Each counted entry is fingerprinted
/// by its bytes, and the person's answer holds for exactly those bytes.
public enum AgentTerminalLaunchCheck {
    public struct Finding: Equatable, Sendable, Identifiable, Codable {
        /// Where, relative to the workspace.
        public let path: String
        /// What was approved: a digest of the bytes, or of the setting.
        public let fingerprint: String
        /// What is shown: the setting and its whole value, a small file's
        /// text, a link's target, or a file's size.
        public let detail: String
        /// A permission parsed from Claude's local settings, set by the scan
        /// alone, which the sheet words as a confirmation.
        public var isPermission = false
        public var id: String { path + "\u{0}" + fingerprint }
        /// Something the check could not look at, which no answer can cover.
        public var isIncomplete: Bool { fingerprint == AgentTerminalLaunchCheck.incomplete }
    }

    static let incomplete = "incomplete"

    /// Whether the folders Lamp's skills are installed into are real ones,
    /// or not there: never a link, which an install would write through.
    public static func skillFoldersArePlain(in workspace: URL) -> Bool {
        for path in [".claude", ".claude/skills", ".agents", ".agents/skills"] {
            var info = stat()
            if lstat(workspace.appendingPathComponent(path).path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR { return false }
        }
        return true
    }

    /// What every provider reads from a workspace, matched without regard to
    /// case: the union, since one reads another's (Codex `.agents/`,
    /// OpenCode `.claude/skills`).
    static let roots: Set<String> = [".mcp.json", ".claude", ".codex", ".opencode", ".agents", "opencode.json", "opencode.jsonc"]
    /// Beyond these, the rest is one finding saying so.
    static let largestCount = 5_000
    static let shownBytes = 4_000

    public static func findings(
        in workspace: URL, lampServer: LampAgentMCPConfiguration?, bundledSkills: URL?
    ) -> [Finding] {
        var found: [Finding] = []
        var counted = 0
        let expected: [String: String] = lampServer.map { server in
            [
                ".mcp.json": server.answering(provider: AgentChatWireProvider.claude.rawValue).claudeJSON,
                ".codex/config.toml": server.answering(provider: AgentChatWireProvider.codex.rawValue).codexTOML,
                "opencode.json": server.answering(provider: AgentChatWireProvider.openCode.rawValue).openCodeJSON,
            ]
        } ?? [:]
        // What can't be looked at is incomplete, never nothing: a provider
        // can still open a file by its known name in a folder Lamp can't list.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workspace.path) else {
            return [Finding(path: ".", fingerprint: incomplete, detail: "the writing's folder could not be listed")]
        }
        func visit(_ relative: String) {
            counted += 1
            guard counted <= largestCount else { return }
            let url = workspace.appendingPathComponent(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                found.append(Finding(path: relative, fingerprint: incomplete, detail: "\(relative) could not be looked at"))
                return
            }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "?"
                found.append(Finding(path: relative, fingerprint: digest("link:" + target), detail: "a link to \(target)"))
            case S_IFDIR:
                guard let listed = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                    found.append(Finding(path: relative, fingerprint: incomplete, detail: "\(relative) could not be listed"))
                    return
                }
                let children = listed.sorted()
                let parts = relative.split(separator: "/")
                for child in children {
                    let path = relative + "/" + child
                    // A skill Lamp put there, as Lamp puts it, is Lamp's.
                    if parts.count == 2, parts[1] == "skills", ["claude", "agents"].contains(parts[0].dropFirst().lowercased()),
                       isLampsSkill(workspace.appendingPathComponent(path), named: child, bundled: bundledSkills) {
                        continue
                    }
                    visit(path)
                }
            case S_IFREG:
                // Hashed in pieces, never read whole: a skill or plugin can
                // hold a large file, and only a small one is shown or parsed.
                guard let (fingerprint, head, size) = read(url) else {
                    found.append(Finding(path: relative, fingerprint: incomplete, detail: "\(relative) could not be read"))
                    return
                }
                if let lamps = expected[relative], size == lamps.utf8.count, head == Data(lamps.utf8) { return }
                if relative == ".claude/settings.local.json", size <= Int64(settingsBytes),
                   let settings = claudeLocalSettings(head) {
                    found += settings.map {
                        Finding(path: relative, fingerprint: digest($0.canonical), detail: $0.shown, isPermission: $0.canonical.hasPrefix("grant\u{0}"))
                    }
                    return
                }
                let text = size <= Int64(shownBytes) ? String(data: head, encoding: .utf8) : nil
                found.append(Finding(
                    path: relative, fingerprint: fingerprint,
                    detail: text ?? "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) of content"
                ))
            default:
                // A pipe or device: what a provider would read from it can't
                // be looked at, so no answer can cover it.
                found.append(Finding(path: relative, fingerprint: incomplete, detail: "\(relative) is not a plain file or folder"))
            }
        }
        for name in names.sorted() where roots.contains(name.lowercased()) { visit(name) }
        if counted > largestCount {
            found.append(Finding(path: ".", fingerprint: incomplete, detail: "more than \(largestCount) entries, too many to check one by one"))
        }
        return found
    }

    /// What a file's bytes hash to, read in pieces, with up to the first
    /// `settingsBytes` of them, and its size.
    static func read(_ url: URL) -> (fingerprint: String, head: Data, size: Int64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var head = Data()
        var size: Int64 = 0
        while true {
            // Nil at the end of the file, as well as empty; a thrown read is
            // the failure.
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            if head.count < settingsBytes { head.append(chunk.prefix(settingsBytes - head.count)) }
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), head, size)
    }

    /// Claude's local settings larger than this are a finding whole.
    static let settingsBytes = 1 << 20

    /// The findings in Claude's local settings: each setting Claude does not
    /// write there itself, with its value, and each allow rule or extra
    /// folder, which the person keeps by approving it. Nil when the file is
    /// not a settings object, which is then a finding whole.
    /// Each with what is shown and what is fingerprinted: the setting's key
    /// and its value as typed JSON, so a string that reads as an object is
    /// not the object.
    static func claudeLocalSettings(_ data: Data) -> [(shown: String, canonical: String)]? {
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var found: [(shown: String, canonical: String)] = []
        let harmless: Set<String> = ["permissions", "outputStyle", "enabledMcpjsonServers", "disabledMcpjsonServers", "enableAllProjectMcpServers"]
        for key in settings.keys.sorted() where !harmless.contains(key) {
            found.append(("the setting \(key): \(shown(settings[key] as Any))", "setting\u{0}\(key)\u{0}\(typed(settings[key] as Any))"))
        }
        if let permissions = settings["permissions"] {
            guard let permissions = permissions as? [String: Any] else {
                return found + [("the setting permissions: \(shown(permissions))", "setting\u{0}permissions\u{0}\(typed(permissions))")]
            }
            for key in permissions.keys.sorted() where !["allow", "ask", "deny", "additionalDirectories"].contains(key) {
                found.append(("the permission setting \(key): \(shown(permissions[key] as Any))",
                              "permission\u{0}\(key)\u{0}\(typed(permissions[key] as Any))"))
            }
            for rule in grants(in: settings) {
                found.append(("\(permissionPrefix)\(rule)", "grant\u{0}\(rule)"))
            }
        }
        return found
    }

    /// How a saved permission reads, which the sheet words as a
    /// confirmation rather than a warning when every finding is one.
    public static let permissionPrefix = "a permission saved for Claude: "

    /// A value as JSON with its type kept: a string stays a quoted string.
    private static func typed(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "?" + String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// The allow rules and extra folders in Claude's local settings, as
    /// `allow Bash(sw_vers)` and `folder /path`: what grants something.
    public static func grants(in settings: [String: Any]) -> [String] {
        let permissions = settings["permissions"] as? [String: Any] ?? [:]
        return ((permissions["allow"] as? [Any]) ?? []).map { "allow \(shown($0))" }
            + ((permissions["additionalDirectories"] as? [Any]) ?? []).map { "folder \(shown($0))" }
    }

    private static func shown(_ value: Any) -> String {
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value) || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A skill as Lamp installs it: a built-in equal to the bundle's copy, or
    /// a custom one as plain as Lamp writes one, its `SKILL.md` alone.
    static func isLampsSkill(_ directory: URL, named name: String, bundled: URL?) -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        if WorkspaceSkillStore.bundledSkillNames.contains(name) {
            guard let bundled,
                  let mine = try? WorkspaceSkillStore.treeDigest(of: directory),
                  let theirs = try? WorkspaceSkillStore.treeDigest(of: bundled.appendingPathComponent(name, isDirectory: true))
            else { return false }
            return mine == theirs && !containsLinkOrHidden(directory)
        }
        return WorkspaceSkillStore.isPlainSkill(directory)
    }

    /// Whether a folder holds a link, or a hidden entry the digest skips.
    private static func containsLinkOrHidden(_ directory: URL) -> Bool {
        guard let walk = FileManager.default.enumerator(atPath: directory.path) else { return true }
        while let relative = walk.nextObject() as? String {
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }
            var info = stat()
            if lstat(directory.appendingPathComponent(relative).path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ text: String) -> String { digest(Data(text.utf8)) }

    // MARK: What the person said

    public static var stateFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lamp Bible", isDirectory: true)
            .appendingPathComponent("TerminalChecks.json")
    }

    private struct Record: Codable {
        /// Findings the person said to open with.
        var approved: [String] = []
    }

    private static func key(_ workspace: URL) -> String { workspace.standardizedFileURL.path }

    /// Every read and rewrite of the file, one at a time: an approval and a
    /// session's end can land together, and each rewrites it whole.
    private static let storeLock = NSLock()

    private static func load(_ file: URL) -> [String: Record] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    private static func save(_ records: [String: Record], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    /// Whether every finding is one the person already said to open with.
    public static func isApproved(_ findings: [Finding], for workspace: URL, in file: URL = stateFile) -> Bool {
        let approved = Set(load(file)[key(workspace)]?.approved ?? [])
        return findings.allSatisfy { approved.contains($0.id) }
    }

    /// After a scan that finished, approvals for what is no longer there go,
    /// so a setting removed and later put back is asked about again.
    public static func keepApprovals(onlyFor findings: [Finding], for workspace: URL, in file: URL = stateFile) {
        storeLock.lock()
        defer { storeLock.unlock() }
        var records = load(file)
        guard var record = records[key(workspace)] else { return }
        let present = Set(findings.map(\.id))
        let kept = record.approved.filter(present.contains)
        guard kept != record.approved else { return }
        record.approved = kept
        records[key(workspace)] = record
        try? save(records, to: file)
    }

    /// The person said to open with these, as shown: added to what they
    /// said before, which `keepApprovals` trims to what is still there.
    public static func approve(_ findings: [Finding], for workspace: URL, in file: URL = stateFile) throws {
        storeLock.lock()
        defer { storeLock.unlock() }
        var records = load(file)
        let before = Set(records[key(workspace)]?.approved ?? [])
        records[key(workspace), default: Record()].approved = Array(before.union(findings.map(\.id))).sorted()
        try save(records, to: file)
    }

    /// The findings not yet approved, which are what is shown.
    public static func unapproved(_ findings: [Finding], for workspace: URL, in file: URL = stateFile) -> [Finding] {
        let approved = Set(load(file)[key(workspace)]?.approved ?? [])
        return findings.filter { !approved.contains($0.id) }
    }
}
