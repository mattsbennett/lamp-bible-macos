import Foundation

// A chat run can't show Claude Code's own permission prompt, so a tool call
// its permissions don't already allow is put to the person in Lamp instead.
// Claude Code documents the way in: a `PermissionRequest` hook "runs only when
// Claude Code is about to ask you for permission, or when it would otherwise
// auto-deny a call that can't prompt", and in non-interactive runs "if no hook
// returns a decision, it denies the tool call". Lamp passes one per launch
// with `--settings`, as Terminal mode passes its capture hooks.
//
// The hook is a shell command. It drops the request, unaltered, into a folder
// only that run uses and waits for Lamp to write its decision beside it, then
// prints the decision. Lamp reads only the documented `tool_name`,
// `tool_input` and `permission_suggestions`, and writes only the documented
// `decision` fields. If Lamp
// doesn't answer — it has quit, or the run has ended and the folder is gone —
// the hook prints nothing and Claude Code denies the call, as it would have
// without the hook.

/// A tool call put to the person.
public struct AgentToolApprovalRequest: Equatable, Sendable, Identifiable {
    public let id: String
    /// The tool, as Claude Code names it: `Bash`, `WebFetch`, `mcp__server__tool`.
    public let toolName: String
    /// The tool's input, as Claude Code passed it.
    public let toolInputJSON: String
    /// The rule Always Allow would save, if there is one narrow enough to
    /// offer; see `AgentToolAlwaysAllowRule`.
    public let alwaysAllowRule: AgentToolAlwaysAllowRule?

    public init(
        id: String,
        toolName: String,
        toolInputJSON: String,
        alwaysAllowRule: AgentToolAlwaysAllowRule? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.alwaysAllowRule = alwaysAllowRule
    }

    /// Reads a hook's payload. Nil if it names no tool.
    public init?(id: String, hookPayload: Data) {
        guard let payload = (try? JSONSerialization.jsonObject(with: hookPayload)) as? [String: Any],
              let toolName = payload["tool_name"] as? String, !toolName.isEmpty
        else { return nil }
        let input = payload["tool_input"].flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        self.init(
            id: id,
            toolName: toolName,
            toolInputJSON: input.map { String(decoding: $0, as: UTF8.self) } ?? "{}",
            alwaysAllowRule: AgentToolAlwaysAllowRule(
                toolName: toolName,
                toolInput: payload["tool_input"] as? [String: Any] ?? [:],
                suggestions: payload["permission_suggestions"] as? [[String: Any]]
            )
        )
    }

    public var toolInput: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(toolInputJSON.utf8))) as? [String: Any] ?? [:]
    }
}

/// What Always Allow saves: permission rules, kept by Lamp for that writing
/// on this Mac (`AgentToolAllowRules`), and handed to each of its runs in
/// the `--settings` Lamp passes. Never in the workspace's own
/// `.claude/settings.local.json`, which a chat's run no longer reads, and
/// which an agent in the writing could write to. Sync carries none of it.
///
/// Claude Code's own suggestion for the request is used when it makes one,
/// as its permission dialog would, but only if every rule in it is narrow
/// enough to say plainly: a rule with no content for a tool that takes one
/// grants all of that tool, and reads as a single harmless word. Otherwise
/// a rule is made only where the documented rule syntax allows a narrow one:
/// the exact command, the site's domain, the one MCP tool. Anything broader
/// isn't offered.
///
/// File rules aren't offered at all. Claude Code matches `Read` and `Edit`
/// paths as gitignore patterns, so a folder's path covers everything in it
/// with no wildcard to show for it, and a single leading `/` means the
/// settings' own folder rather than the disk's root; and it never matches a
/// `Write` or `NotebookEdit` path rule. None of that can be said plainly in
/// a card, and in a writing chat a file call only asks when it reaches
/// outside the workspace, which is where a lasting grant matters most.
public struct AgentToolAlwaysAllowRule: Equatable, Sendable {
    /// What the rules permit, in words: running “sw_vers -productVersion”.
    public let description: String
    /// The rules as Claude Code's settings write them: `Bash(sw_vers)`.
    public let rules: [String]
    /// The rules as a permission update for the rest of this run only
    /// (`destination: session`), so the same call in this turn is not asked
    /// about again; written nowhere.
    let sessionEntryJSON: String
    /// The rules on one line, as the card's help shows them.
    public var ruleText: String { rules.joined(separator: ", ") }

    init?(toolName: String, toolInput: [String: Any], suggestions: [[String: Any]]?) {
        let suggested = suggestions?.first {
            $0["type"] as? String == "addRules"
                && $0["behavior"] as? String == "allow"
                && Self.plainDescriptions(of: $0["rules"]) != nil
        }
        guard var entry = suggested ?? Self.narrowEntry(toolName: toolName, toolInput: toolInput),
              let listed = entry["rules"] as? [[String: Any]],
              let descriptions = Self.plainDescriptions(of: listed)
        else { return nil }
        entry["destination"] = "session"
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        sessionEntryJSON = String(decoding: data, as: UTF8.self)
        description = ListFormatter.localizedString(byJoining: descriptions)
        rules = listed.compactMap { rule -> String? in
            guard let tool = rule["toolName"] as? String else { return nil }
            guard let content = rule["ruleContent"] as? String, !content.isEmpty else { return tool }
            return "\(tool)(\(content))"
        }
    }

    /// The narrowest rule the documented syntax gives for this call, or none.
    private static func narrowEntry(toolName: String, toolInput: [String: Any]) -> [String: Any]? {
        let rule: [String: Any]
        switch toolName {
        case "Bash":
            guard let command = toolInput["command"] as? String,
                  !command.isEmpty, !command.contains("\n"), !command.contains("*") else { return nil }
            rule = ["toolName": "Bash", "ruleContent": command]
        case "WebFetch":
            guard let host = (toolInput["url"] as? String).flatMap(URL.init(string:))?.host,
                  !host.isEmpty else { return nil }
            rule = ["toolName": "WebFetch", "ruleContent": "domain:\(host)"]
        case "WebSearch":
            rule = ["toolName": "WebSearch"]
        default:
            guard toolName.hasPrefix("mcp__") else { return nil }
            rule = ["toolName": toolName]
        }
        return ["type": "addRules", "rules": [rule], "behavior": "allow"]
    }

    /// Each rule in words, or nil if any of them is too broad to offer.
    private static func plainDescriptions(of rules: Any?) -> [String]? {
        guard let rules = rules as? [[String: Any]], !rules.isEmpty else { return nil }
        var descriptions: [String] = []
        for rule in rules {
            guard let description = plainDescription(of: rule) else { return nil }
            descriptions.append(description)
        }
        return descriptions
    }

    /// One rule in words. Nil for a rule that grants more than one plain
    /// phrase can honestly say: all of a tool that takes content, a pattern
    /// with a wildcard anywhere but the end of a command, or any file rule.
    static func plainDescription(of rule: [String: Any]) -> String? {
        guard let tool = rule["toolName"] as? String, !tool.isEmpty else { return nil }
        let content = (rule["ruleContent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let content else {
            if tool == "WebSearch" { return "searching the web" }
            // `mcp__server__tool`, naming one tool; a server's own name may
            // contain underscores.
            let parts = tool.components(separatedBy: "__")
            guard parts.count >= 3, parts[0] == "mcp", !tool.contains("*") else { return nil }
            return "using \(parts.dropFirst(2).joined(separator: "__")) from \(parts[1])"
        }
        switch tool {
        case "Bash":
            if !content.contains("*") { return "running “\(content)”" }
            // A trailing wildcard, written either way, is a command prefix.
            for suffix in [" *", ":*"] where content.hasSuffix(suffix) {
                let prefix = String(content.dropLast(suffix.count))
                guard !prefix.isEmpty, !prefix.contains("*") else { return nil }
                return "running any command that starts with “\(prefix)”"
            }
            return nil
        case "WebFetch":
            guard content.hasPrefix("domain:"), !content.contains("*") else { return nil }
            return "fetching pages from \(content.dropFirst("domain:".count))"
        default:
            return nil
        }
    }
}

/// The person's answer.
public enum AgentToolApprovalAnswer: Equatable, Sendable {
    case allow
    /// Allow, and save the rule so the same call isn't asked about again.
    case alwaysAllow(AgentToolAlwaysAllowRule)
    case deny

    /// What Claude Code is told on a denial, so it changes course rather than
    /// trying the same call again.
    static let denialMessage = "The person using Lamp declined this tool call. Don't try it again; carry on without it, or ask them about it."

    /// The hook's output, in the form Claude Code documents for
    /// `PermissionRequest` decisions.
    public var hookOutput: Data {
        var decision: [String: Any]
        switch self {
        case .allow:
            decision = ["behavior": "allow"]
        case .alwaysAllow(let rule):
            // Allowed now, and for the rest of this run; Lamp keeps the rule
            // for the writing's next runs (`AgentToolAllowRules`), rather
            // than Claude Code writing it into the workspace.
            decision = ["behavior": "allow"]
            if let entry = try? JSONSerialization.jsonObject(with: Data(rule.sessionEntryJSON.utf8)) {
                decision["updatedPermissions"] = [entry]
            }
        case .deny:
            decision = ["behavior": "deny", "message": Self.denialMessage]
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }
}

/// The folder one chat run's requests and decisions pass through.
public struct AgentToolApprovalChannel: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A fresh folder for one run, under the system's temporary folder:
    /// nothing in it is worth syncing or keeping.
    public static func makeForRun() throws -> AgentToolApprovalChannel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-tool-approvals", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AgentToolApprovalChannel(directory: directory)
    }

    /// Requests a hook is still waiting on, oldest first.
    ///
    /// A request older than Claude Code's timeout for the hook is left out
    /// even if it's still there: its hook has been stopped, perhaps before it
    /// could take the request back, and the call was denied. Showing it would
    /// invite an answer that nothing reads. A request that can't be read is
    /// denied at once rather than left to time out.
    public func pendingRequests(now: Date = Date()) -> [AgentToolApprovalRequest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .compactMap { name -> (AgentToolApprovalRequest, Date)? in
                guard name.hasPrefix("request-"), name.hasSuffix(".json") else { return nil }
                let id = String(name.dropFirst("request-".count).dropLast(".json".count))
                let url = directory.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: answerURL(id).path),
                      let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      now.timeIntervalSince(created) < Double(ClaudePermissionHook.timeoutSeconds),
                      let data = try? Data(contentsOf: url)
                else { return nil }
                guard let request = AgentToolApprovalRequest(id: id, hookPayload: data) else {
                    try? answer(id, with: .deny)
                    return nil
                }
                return (request, created)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    public enum AnswerError: LocalizedError {
        case expired
        case alreadyAnswered

        public var errorDescription: String? {
            switch self {
            case .expired: "That request had already timed out, and the tool call was denied."
            case .alreadyAnswered: "That request was already answered."
            }
        }
    }

    /// Writes the decision the waiting hook prints. Written whole, then
    /// renamed into place, so the hook never reads half of one. A request its
    /// hook has taken back can't be answered: nothing would read it.
    ///
    /// Once: a second answer, from another pane on the same chat, is refused
    /// rather than written over the first, which the hook may already have
    /// taken. Linked into place, which fails where one is there.
    public func answer(_ id: String, with answer: AgentToolApprovalAnswer) throws {
        guard FileManager.default.fileExists(atPath: requestURL(id).path) else {
            throw AnswerError.expired
        }
        let draft = directory.appendingPathComponent(".answer-\(UUID().uuidString)")
        try answer.hookOutput.write(to: draft)
        defer { unlink(draft.path) }
        guard link(draft.path, answerURL(id).path) == 0 else {
            if errno == EEXIST { throw AnswerError.alreadyAnswered }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Whether the hook took the answer to `id`, waiting for it to settle:
    /// it looks five times a second and marks what it took, and one whose
    /// wait ended took its request back without it. Gone with the channel's
    /// folder, or after `seconds`, it was not taken.
    /// With `answer`, only if what it took is that answer.
    public func waitUntilTaken(
        _ id: String, answer: AgentToolApprovalAnswer? = nil,
        seconds: Double = Double(ClaudePermissionHook.timeoutSeconds)
    ) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        let fileManager = FileManager.default
        let taken = directory.appendingPathComponent("taken-\(id)")
        repeat {
            // Looked at once at least, a wait of nothing included.
            if fileManager.fileExists(atPath: taken.path) {
                guard let answer else { return true }
                return (try? Data(contentsOf: taken)) == answer.hookOutput
            }
            if !fileManager.fileExists(atPath: requestURL(id).path) { return false }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < end
        return false
    }

    /// Ends the channel. A hook still waiting gives Claude Code no decision,
    /// and the call is denied.
    public func close() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func requestURL(_ id: String) -> URL {
        directory.appendingPathComponent("request-\(id).json")
    }

    private func answerURL(_ id: String) -> URL {
        directory.appendingPathComponent("answer-\(id).json")
    }
}

/// What the person chose Always Allow for, by writing, on this Mac: in one
/// file of Lamp's, outside every workspace, so no agent writes it.
public enum AgentToolAllowRules {
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lamp Bible", isDirectory: true)
            .appendingPathComponent("AgentAllowRules.json")
    }

    /// A workspace by its folder's path, which names its writing.
    private static func key(_ workspace: URL) -> String {
        workspace.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func load(_ file: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return stored
    }

    public static func rules(for workspace: URL, in file: URL = defaultFile) -> [String] {
        load(file)[key(workspace)] ?? []
    }

    /// Posted as rules are kept or taken back, so a list of them follows.
    public static let changed = Notification.Name("LampAllowRulesChanged")

    /// Takes one back, as the person asked.
    public static func remove(_ rule: String, for workspace: URL, in file: URL = defaultFile) throws {
        var stored = load(file)
        stored[key(workspace)] = (stored[key(workspace)] ?? []).filter { $0 != rule }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: file, options: .atomic)
        NotificationCenter.default.post(name: changed, object: key(workspace))
    }

    public static func add(_ rules: [String], for workspace: URL, in file: URL = defaultFile) throws {
        var stored = load(file)
        var kept = stored[key(workspace)] ?? []
        for rule in rules where !kept.contains(rule) { kept.append(rule) }
        stored[key(workspace)] = kept
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: file, options: .atomic)
        NotificationCenter.default.post(name: changed, object: key(workspace))
    }
}

/// The instructions and settings a Claude writing run is given, one file
/// each per run in Lamp's own folder, outside every workspace, removed when
/// the run ends: either can outgrow a command line (a writing's sources, its
/// saved rules).
public enum AgentChatInstructionFiles {
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lamp Bible", isDirectory: true)
            .appendingPathComponent("Chat Instructions", isDirectory: true)
    }

    /// Writes `text` to a new file, named with `extension`.
    public static func write(_ text: String, in folder: URL = folder, extension kind: String = "md") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + "." + kind)
        // A new name each time, never written over; Foundation refuses this
        // together with `.atomic`.
        try Data(text.utf8).write(to: file, options: [.withoutOverwriting])
        return file
    }

    public static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}

/// The hook Lamp gives a Claude Code chat run.
public enum ClaudePermissionHook {
    /// How long Claude Code lets the hook run, in seconds: its default for a
    /// command hook, stated rather than assumed.
    public static let timeoutSeconds = 600
    /// How long the hook waits for the person, by the clock: a margin under
    /// the timeout, so the hook ends of its own accord and takes its request
    /// back before Claude Code would stop it.
    static let waitSeconds = 580

    /// The `--settings` JSON that adds the hook for every tool, and allows
    /// what the person chose Always Allow for in this writing.
    public static func settingsJSON(for channel: AgentToolApprovalChannel, allowing rules: [String] = []) -> String {
        let hook: [String: Any] = [
            "type": "command",
            "command": command(for: channel),
            "timeout": timeoutSeconds,
        ]
        var settings: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [hook]]]]]
        if !rules.isEmpty { settings["permissions"] = ["allow": rules] }
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Drops the payload into the channel, waits for the decision and prints
    /// it. Without one — the folder gone, or the wait over — it takes its
    /// request back and prints nothing. It always exits 0: a decision is given
    /// only through the output.
    static func command(for channel: AgentToolApprovalChannel, waitSeconds: Int = waitSeconds) -> String {
        let folder = AgentTerminalLaunchPlanner.shellQuote(channel.directory.path)
        // The wait is measured on the clock: counting sleeps undercounts by
        // the cost of starting each one, enough to run past the timeout.
        return [
            "d=\(folder); [ -d \"$d\" ] || exit 0",
            "end=$(( $(/bin/date +%s) + \(waitSeconds) ))",
            "id=$(/usr/bin/uuidgen | /usr/bin/tr 'A-Z' 'a-z')",
            "t=$(/usr/bin/mktemp \"$d/.request.XXXXXXXX\") && /bin/cat > \"$t\" && /bin/mv \"$t\" \"$d/request-$id.json\" || exit 0",
            "while [ \"$(/bin/date +%s)\" -lt \"$end\" ]; do",
            "  if [ -f \"$d/answer-$id.json\" ]; then /bin/cat \"$d/answer-$id.json\"; /bin/ln \"$d/answer-$id.json\" \"$d/taken-$id\"; exit 0; fi",
            "  [ -d \"$d\" ] || exit 0",
            "  /bin/sleep 0.2",
            "done",
            "/bin/rm -f \"$d/request-$id.json\"; exit 0",
        ].joined(separator: "\n")
    }
}

/// What a tool call is, put plainly for the prompt: what the agent wants to
/// do, and the detail that decides whether to let it.
public struct AgentToolApprovalSummary: Equatable, Sendable {
    public let title: String
    /// The command or address in full; for a file, its path and what would
    /// be written into it, since the path alone doesn't decide it.
    public let detail: String?
    /// What allowing it means, where that is more than the title says.
    public let note: String?

    public init(title: String, detail: String?, note: String? = nil) {
        self.title = title
        self.detail = detail
        self.note = note
    }

    public static func of(_ request: AgentToolApprovalRequest) -> AgentToolApprovalSummary {
        let input = request.toolInput
        func string(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let rawInput = request.toolInputJSON == "{}" ? nil : request.toolInputJSON
        switch request.toolName {
        case AgentCodexRun.commandToolName:
            // The command and where it runs, then Codex's reason, said to be
            // Codex's: it is the agent's account of itself, not Lamp's.
            let parts = [
                string("command"),
                string("cwd").map { "In \($0)" },
                string("reason").map { "Codex says: \($0)" },
            ].compactMap { $0 }
            return .init(
                title: "Run a command outside its sandbox",
                detail: parts.isEmpty ? rawInput : parts.joined(separator: "\n\n"),
                note: "Outside its sandbox the command can read and change anything your account can, and use the network. Allow lets it run this once."
            )
        case AgentACPRun.commandToolName:
            return .init(
                title: "Run a command",
                detail: [string("command"), string("cwd").map { "In \($0)" }].compactMap { $0 }.joined(separator: "\n\n"),
                note: "Lamp does not sandbox Antigravity. Unless your own Antigravity settings do, this command can read and change anything your account can, and use the network. Allow lets it run this once."
            )
        case "Bash":
            return .init(title: "Run a command", detail: string("command") ?? rawInput)
        case "WebFetch":
            return .init(title: "Fetch a web page", detail: string("url") ?? rawInput)
        case "WebSearch":
            return .init(title: "Search the web", detail: string("query") ?? rawInput)
        case "Write":
            guard let path = string("file_path") else { return .init(title: "Write a file", detail: rawInput) }
            return .init(
                title: "Write a file",
                detail: [path, (input["content"] as? String).map { excerpt($0, 800) }]
                    .compactMap { $0 }.joined(separator: "\n\n")
            )
        case "Edit":
            guard let path = string("file_path") else { return .init(title: "Edit a file", detail: rawInput) }
            return .init(title: "Edit a file", detail: path + "\n\n" + replacement(input))
        case "MultiEdit":
            guard let path = string("file_path") else { return .init(title: "Edit a file", detail: rawInput) }
            let edits = input["edits"] as? [[String: Any]] ?? []
            let shown = edits.prefix(3).map(replacement).joined(separator: "\n\n")
            let more = edits.count > 3 ? "\n\n…and \(edits.count - 3) more" : ""
            return .init(title: "Make \(edits.count) edits to a file", detail: path + "\n\n" + shown + more)
        case "NotebookEdit":
            return .init(title: "Edit a notebook", detail: string("notebook_path") ?? rawInput)
        case "Read":
            return .init(title: "Read a file", detail: string("file_path") ?? rawInput)
        default:
            // `mcp__server__tool`; a server's own name may contain underscores.
            let parts = request.toolName.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                return .init(
                    title: "Use \(parts.dropFirst(2).joined(separator: "__")) from \(parts[1])",
                    detail: rawInput
                )
            }
            return .init(title: "Use \(request.toolName)", detail: rawInput)
        }
    }

    private static func replacement(_ edit: [String: Any]) -> String {
        let old = excerpt(edit["old_string"] as? String ?? "", 400)
        let new = excerpt(edit["new_string"] as? String ?? "", 400)
        return "Replace:\n\(old)\n\nWith:\n\(new)"
    }

    private static func excerpt(_ text: String, _ limit: Int) -> String {
        text.count > limit ? text.prefix(limit) + "…" : text
    }
}
