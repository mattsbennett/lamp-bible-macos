import Foundation

public enum AgentChatWireProvider: String, Sendable {
    case codex
    case claude
    case openCode
}

/// Which model a provider's CLI should run, when the reader does not want its
/// default.
///
/// Lamp names no model of its own. A model list in an app goes stale the week
/// after it ships, and a reader whose provider has a newer one would be stuck
/// with whatever was current when the build was made. So the only names
/// offered are the provider's own standing aliases, which the CLI resolves to
/// whatever it currently means by them, and anything else is typed in and
/// passed through untouched.
public enum AgentChatModelChoice {
    /// Where one provider's choice is kept. Per provider, because a name means
    /// nothing to another one.
    public static func defaultsKey(_ provider: AgentChatWireProvider) -> String {
        "chat.model.\(provider.rawValue)"
    }

    /// Names the provider itself keeps pointed at its current models. Empty
    /// where a provider publishes no such aliases: then the choice is its
    /// default or a name the reader types, and guessing a list would be
    /// inventing one.
    public static func aliases(_ provider: AgentChatWireProvider) -> [String] {
        switch provider {
        case .claude: ["opus", "sonnet", "haiku"]
        case .codex, .openCode: []
        }
    }

    /// What a stored choice is worth passing on: nothing, for an empty or
    /// blank one, which means the provider's default.
    public static func canonical(_ stored: String?) -> String? {
        guard let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The flag this provider takes. Each spells it differently, and openCode
    /// wants a qualified name rather than a bare one.
    public static func arguments(
        for model: String?, provider: AgentChatWireProvider
    ) -> [String] {
        guard let model = canonical(model) else { return [] }
        switch provider {
        case .claude, .openCode: return ["--model", model]
        case .codex: return ["-m", model]
        }
    }

    /// What to show beneath the picker, so a reader typing a name knows the
    /// shape the provider expects.
    public static func hint(_ provider: AgentChatWireProvider) -> String {
        switch provider {
        case .claude: "An alias such as opus, or a full model name."
        case .codex: "A model name the Codex CLI accepts."
        // Where OpenCode's effort is chosen from here: `opencode run` takes no
        // effort of its own, and a variant is the one thing a single run can
        // be told. Which variants exist is the reader's own configuration.
        case .openCode: "provider/model, and #variant to choose how it reasons."
        }
    }
}

/// How hard a provider's CLI should think, when the reader does not want its
/// default.
///
/// Only where the provider has such a setting and documents it. Claude Code
/// takes a level on the command line; Codex keeps one in its own config, which
/// an override can set for a single run; OpenCode has no separate notion of it
/// — effort rides in the model's variant, which `AgentChatModelChoice` already
/// carries. Offering a control that did nothing would be worse than offering
/// none.
public enum AgentChatEffortChoice {
    public static func defaultsKey(_ provider: AgentChatWireProvider) -> String {
        "chat.effort.\(provider.rawValue)"
    }

    /// Whether this provider has an effort of its own to set.
    public static func isSupported(_ provider: AgentChatWireProvider) -> Bool {
        switch provider {
        case .claude, .codex: true
        case .openCode: false
        }
    }

    /// The levels the provider itself names. Claude Code lists these in its
    /// own `--help`; Codex documents the setting but not a closed set of
    /// values, so none are offered and a level is typed instead.
    public static func levels(_ provider: AgentChatWireProvider) -> [String] {
        switch provider {
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .codex, .openCode: []
        }
    }

    public static func canonical(_ stored: String?) -> String? {
        AgentChatModelChoice.canonical(stored)
    }

    public static func arguments(
        for effort: String?, provider: AgentChatWireProvider
    ) -> [String] {
        guard let effort = canonical(effort), isSupported(provider) else { return [] }
        switch provider {
        case .claude: return ["--effort", effort]
        // Codex has no flag for it; the setting lives in `~/.codex/config.toml`
        // and `-c` overrides one key for this run alone, leaving the reader's
        // own config as they wrote it.
        case .codex: return ["-c", "model_reasoning_effort=\"\(effort)\""]
        case .openCode: return []
        }
    }

    public static func hint(_ provider: AgentChatWireProvider) -> String {
        switch provider {
        case .claude: "A level such as high. Claude Code names low to max."
        case .codex: "A value your Codex accepts for model_reasoning_effort."
        case .openCode: "OpenCode sets this through the model's variant."
        }
    }
}

/// Which release of a provider's CLI is installed, where its command line has
/// changed between them.
///
/// Only OpenCode needs this so far. Its version 2 dropped `--pure`, and an
/// unknown flag makes it print its usage and stop rather than refuse the flag,
/// so a reader chat answered with the CLI's help text instead of scripture and
/// nothing in the output said why.
public enum AgentChatCLIVersion {
    /// The major version in what a CLI prints for `--version`, e.g. 2 from
    /// "opencode v2.0.32". Nil when the output is not of that shape, which is
    /// treated as "assume the current release" rather than guessed at.
    public static func major(fromVersionOutput output: String) -> Int? {
        for token in output.split(whereSeparator: \.isWhitespace) {
            let digits = token.drop { !$0.isNumber }.prefix { $0.isNumber }
            if !digits.isEmpty, let value = Int(digits) { return value }
        }
        return nil
    }

    /// Whether this OpenCode takes `--pure`. Version 1 did; 2 does not, and an
    /// unknown version is read as the current one, because passing the flag to
    /// a CLI that has dropped it breaks every chat, while omitting it on one
    /// that still has it costs nothing: the read-only restriction is carried
    /// by the `lamp-reader` agent's own permissions, not by this flag.
    public static func openCodeTakesPure(major: Int?) -> Bool {
        guard let major else { return false }
        return major < 2
    }
}

public enum AgentChatMode: Equatable, Sendable {
    case writing
    case reader(LampAgentMCPConfiguration)

    public var isReadOnly: Bool {
        if case .reader = self { return true }
        return false
    }
}

public enum AgentChatLaunchArguments {
    public static func make(
        provider: AgentChatWireProvider,
        prompt: String,
        sessionID: String?,
        proposedSessionID: String?,
        mode: AgentChatMode = .writing,
        permissionHookSettings: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        providerMajorVersion: Int? = nil
    ) -> [String] {
        let modelArguments = AgentChatModelChoice.arguments(for: model, provider: provider)
            + AgentChatEffortChoice.arguments(for: effort, provider: provider)
        switch provider {
        case .codex:
            var arguments = [
                "exec", "--json", "--sandbox", mode.isReadOnly ? "read-only" : "workspace-write",
                "--skip-git-repo-check",
            ]
            // Before `resume`, which is a subcommand and takes the flags that
            // follow it as its own.
            arguments += modelArguments
            if case .reader(let configuration) = mode {
                // Explicit overrides also work before a generated workspace is trusted.
                arguments += ["-c", "approval_policy=\"never\""]
                arguments += configuration.codexCommandLineOverrides
            }
            if let sessionID { arguments += ["resume", sessionID] }
            arguments += ["--", prompt]
            return arguments
        case .claude:
            var arguments = [
                "-p", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--permission-mode", mode.isReadOnly ? "dontAsk" : "acceptEdits",
            ]
            arguments += modelArguments
            if case .reader(let configuration) = mode {
                arguments += [
                    "--tools", "", "--allowedTools", "mcp__lamp__*",
                    "--strict-mcp-config", "--mcp-config", configuration.claudeJSON,
                    "--disable-slash-commands",
                ]
            } else if let permissionHookSettings {
                // Asks the person about a tool call the run would otherwise
                // deny; see `ClaudePermissionHook`.
                arguments += ["--settings", permissionHookSettings]
            }
            if let sessionID {
                arguments += ["--resume", sessionID]
            } else if let proposedSessionID {
                arguments += ["--session-id", proposedSessionID]
            }
            arguments += ["--", prompt]
            return arguments
        case .openCode:
            var arguments = ["run", "--format", "json"]
            arguments += modelArguments
            if mode.isReadOnly {
                // `--pure` went in version 2, and an unknown flag makes
                // OpenCode print its usage instead of answering. What keeps
                // the chat read-only is the lamp-reader agent's own
                // permissions, which deny everything but the Lamp tools.
                if AgentChatCLIVersion.openCodeTakesPure(major: providerMajorVersion) {
                    arguments += ["--pure"]
                }
                arguments += ["--agent", "lamp-reader"]
            }
            if let sessionID { arguments += ["--session", sessionID] }
            arguments += ["--", prompt]
            return arguments
        }
    }
}

/// A headless provider run can only fail at something the CLI would have asked
/// about interactively: signing in, or a first-run prompt. Chat can't answer
/// those, so it recognises them and sends the user to the Terminal session
/// instead of reporting a bare exit status.
public enum AgentChatSetupRequirement {
    /// Phrases the CLIs use when the thing in the way is a prompt, not the request.
    private static let markers = [
        "please run /login",
        "run /login",
        "not logged in",
        "not authenticated",
        "please log in",
        "please sign in",
        "authentication_failed",
        "401 unauthorized",
        "missing bearer or basic authentication",
        "no credentials",
        "credentials not found",
        "do you trust the files",
        "not a trusted directory",
        "trust this folder",
        "onboarding",
        "run `codex login`",
        "run codex login",
        "run `opencode auth login`",
    ]

    /// Whether `output` says the provider needs something answered first.
    public static func isIndicated(in output: String) -> Bool {
        let normalized = output.lowercased()
        return markers.contains { normalized.contains($0) }
    }

    /// How much a finished run looks like a setup problem.
    public enum Verdict: Equatable, Sendable {
        /// Nothing about it suggests one.
        case none
        /// It failed in the shape a setup problem makes, without saying so.
        case possible
        /// Its output names a prompt only the provider's own interface can answer.
        case indicated
    }

    /// Read a failed run for a setup problem.
    ///
    /// The phrases above are the CLIs' own wording, which is theirs to change;
    /// when it does, the run still fails the same way. A provider that got as
    /// far as starting a session was past its prompts, and one that exited
    /// cleanly was not stopped by anything — so what is left, a non-zero exit
    /// with no session to show for it, is the shape of a prompt nobody
    /// answered. That is worth offering the way out for, but not worth
    /// claiming out loud: only `indicated` says it is a setup problem.
    public static func verdict(
        output: String,
        failure: String,
        sessionID: String?,
        exitCode: Int32
    ) -> Verdict {
        if isIndicated(in: output) || isIndicated(in: failure) { return .indicated }
        return sessionID == nil && exitCode != 0 ? .possible : .none
    }

    /// What to tell the user, naming the provider as the UI names it.
    public static func message(provider: String) -> String {
        "\(provider) needs to be set up before it can answer here. Open the Terminal session to sign in and answer its first-run prompts, then come back to Chat."
    }
}

/// What a run is doing while it runs, for a pane that would otherwise show
/// nothing but a spinner.
///
/// Live only: none of it is kept, because what a reply did on the way is not
/// part of what it said. The thinking *text* is deliberately absent — a
/// `claude -p` stream carries each thinking block with its text empty and only
/// a signature, so a pane can say that a run is thinking, and roughly how
/// much, but never what it thought.
public enum AgentChatActivity: Equatable, Sendable {
    /// A thinking block, with the provider's own estimate of its size where it
    /// gives one.
    case thinking(estimatedTokens: Int?)
    /// A tool call has begun. Its input has not arrived yet, and for a call
    /// with a large input it is a moment before it does.
    case toolStarted(name: String)
    /// A tool call with its input, summarised to one line.
    case tool(name: String, summary: String?)
    /// A tool call came back and the next step has not begun.
    case toolFinished
    /// The reply itself is being written.
    case writing

    /// The step to show when `next` arrives while this one is showing.
    ///
    /// A thinking delta carries an estimate only sometimes, and one without
    /// says no more than that the run is still thinking — so taking it at face
    /// value would drop a count the run has already given and read as the
    /// thinking having started again. Everything else replaces what was there.
    public func succeeded(by next: AgentChatActivity) -> AgentChatActivity {
        if case .thinking(let known) = self, known != nil, case .thinking(nil) = next {
            return self
        }
        return next
    }
}

/// A tool call as one line a person can read.
public enum AgentChatToolDescription {
    /// The tool's name as the pane shows it. An MCP tool arrives as
    /// `mcp__lamp__read_passage`, which names a server nobody needs to see.
    public static func label(for name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let last = name.components(separatedBy: "__").last ?? ""
        return last.isEmpty ? name : last
    }

    /// Which argument to show, in the order a reader would want it.
    ///
    /// Nothing outside this list is shown. A tool's input can carry a whole
    /// file or a draft, and a progress line is not the place for it — so the
    /// line is built from the arguments that say *where* a call is looking,
    /// never from the ones that carry content.
    private static let placeKeys = [
        "reference", "query", "strongs_key", "key", "keys", "file_path", "path",
        "pattern", "command", "section_id", "devotional_id", "day", "module_id",
    ]
    /// Shown after the argument above, since which modules were asked is half
    /// of what a lookup means.
    private static let moduleKeys = ["translation_ids", "module_ids"]
    /// Cut from the front rather than the back; see `shortenedPath`.
    private static let pathKeys: Set<String> = ["file_path", "path"]

    public static func summary(of input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let place = placeKeys.lazy.compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            guard pathKeys.contains(key), let path = value as? String else {
                return describe(value)
            }
            return shortenedPath(path)
        }.first
        let modules = moduleKeys.lazy.compactMap { describe(input[$0]) }.first
        let parts = [place, modules].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func describe(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return shortened(text)
        case let list as [Any]:
            let items = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return items.count > 4
                ? items.prefix(4).joined(separator: ", ") + ", …"
                : items.joined(separator: ", ")
        case let number as Int:
            return String(number)
        default:
            return nil
        }
    }

    /// A path is cut from the front, because the file's own name is the part
    /// worth reading and a scratch directory's first sixty characters are not.
    /// A workspace path is long enough for this to matter: cutting the end off
    /// one leaves a line that says a reply is reading `/private/tmp/claude…`
    /// and never which file.
    private static func shortenedPath(_ path: String) -> String? {
        let line = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard line.count > 72 else { return line }
        let shown = "…/" + line.split(separator: "/").suffix(2).joined(separator: "/")
        return shown.count > 72 ? "…" + String(shown.suffix(71)) : shown
    }

    /// One line's worth, with the line breaks taken out: a `query` may be a
    /// paragraph, and a progress line has one line to say it in.
    private static func shortened(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > 72 else { return line }
        return String(line.prefix(71)) + "…"
    }
}

/// Splits the bytes of a provider's output into the whole lines it carries.
///
/// A JSON line arrives in however many pieces the pipe gives it, and a
/// multi-byte character can be split across two reads — so decoding a chunk on
/// its own would cut a line in half and mangle a Greek word. What is left over
/// stays here until the rest of it comes.
public struct AgentChatLineReader: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func lines(from chunk: Data) -> [String] {
        pending += chunk
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        return lines
    }

    /// Whatever is left when the stream ends: a provider that does not end its
    /// last line still said something on it.
    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let text = String(decoding: pending, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pending = Data()
        return text.isEmpty ? nil : text
    }
}

public enum AgentChatWireEvent: Equatable, Sendable {
    case sessionStarted(String)
    case textFragment(String)
    case finalText(String)
    case failure(String)
    /// Progress, while the run is still running. Not part of the reply.
    case activity(AgentChatActivity)
}

public enum AgentChatWireParser {
    public static func parse(
        _ line: String,
        provider: AgentChatWireProvider
    ) -> [AgentChatWireEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        switch provider {
        case .codex:
            return parseCodex(object)
        case .claude:
            return parseClaude(object)
        case .openCode:
            return parseOpenCode(object)
        }
    }

    private static func parseCodex(_ object: [String: Any]) -> [AgentChatWireEvent] {
        switch object.string("type") {
        case "thread.started":
            return object.string("thread_id").map { [.sessionStarted($0)] } ?? []
        case "item.completed":
            guard let item = object.dictionary("item"),
                  item.string("type") == "agent_message",
                  let text = item.string("text"), !text.isEmpty
            else { return [] }
            return [.finalText(text)]
        case "turn.failed", "error":
            return failureEvents(in: object)
        default:
            return []
        }
    }

    private static func parseClaude(_ object: [String: Any]) -> [AgentChatWireEvent] {
        var events: [AgentChatWireEvent] = []
        if let sessionID = object.string("session_id"), !sessionID.isEmpty {
            events.append(.sessionStarted(sessionID))
        }

        switch object.string("type") {
        case "stream_event":
            // Read by what the event carries rather than by its own `type`:
            // a block starting and a block growing are told apart by which of
            // the two is there, and that holds for a trimmed event as well as
            // a whole one.
            guard let event = object.dictionary("event") else { return events }
            if let block = event.dictionary("content_block") {
                switch block.string("type") {
                case "thinking":
                    events.append(.activity(.thinking(estimatedTokens: nil)))
                case "tool_use":
                    if let name = block.string("name"), !name.isEmpty {
                        events.append(.activity(.toolStarted(name: name)))
                    }
                case "text":
                    events.append(.activity(.writing))
                default:
                    break
                }
            }
            if let delta = event.dictionary("delta") {
                switch delta.string("type") {
                case "text_delta":
                    if let text = delta.string("text"), !text.isEmpty {
                        events.append(.textFragment(text))
                    }
                case "thinking_delta":
                    // The `thinking` field is empty by design; the estimate is
                    // all a run says about what it is thinking.
                    events.append(.activity(.thinking(
                        estimatedTokens: delta.int("estimated_tokens")
                    )))
                default:
                    break
                }
            }
        case "system":
            if object.string("subtype") == "thinking_tokens" {
                events.append(.activity(.thinking(
                    estimatedTokens: object.int("estimated_tokens")
                )))
            }
        case "assistant":
            // A finished assistant message, which is where a tool call's input
            // arrives whole rather than as fragments of JSON, and in time: the
            // call runs after it.
            for block in object.contentBlocks() where block.string("type") == "tool_use" {
                guard let name = block.string("name"), !name.isEmpty else { continue }
                events.append(.activity(.tool(
                    name: name,
                    summary: AgentChatToolDescription.summary(of: block.dictionary("input"))
                )))
            }
        case "user":
            // A tool's result comes back as a user message, which is the only
            // sign that a call has finished.
            if object.contentBlocks().contains(where: { $0.string("type") == "tool_result" }) {
                events.append(.activity(.toolFinished))
            }
        case "result":
            if object.bool("is_error") == true {
                if let message = object.string("result"), !message.isEmpty {
                    events.append(.failure(message))
                } else if let message = (object["errors"] as? [String])?
                    .first(where: { !$0.isEmpty }) {
                    // How Claude Code reports a failure that happened before any
                    // turn ran, such as resuming a session it doesn't have.
                    events.append(.failure(message))
                } else {
                    events.append(contentsOf: failureEvents(in: object))
                }
            } else if let text = object.string("result"), !text.isEmpty {
                events.append(.finalText(text))
            }
        case "error":
            events.append(contentsOf: failureEvents(in: object))
        default:
            break
        }
        return events
    }

    private static func parseOpenCode(_ object: [String: Any]) -> [AgentChatWireEvent] {
        var events: [AgentChatWireEvent] = []
        if let sessionID = object.string("sessionID"), !sessionID.isEmpty {
            events.append(.sessionStarted(sessionID))
        }

        switch object.string("type") {
        case "text":
            if let text = object.dictionary("part")?.string("text"), !text.isEmpty {
                events.append(.textFragment(text))
            }
        case "error":
            events.append(contentsOf: failureEvents(in: object))
        default:
            break
        }
        return events
    }

    private static func failureEvents(in object: [String: Any]) -> [AgentChatWireEvent] {
        let message = object.string("message")
            ?? object.dictionary("error")?.string("message")
            ?? object.dictionary("error")?.dictionary("data")?.string("message")
            ?? object.dictionary("error")?.string("name")
        guard let message, !message.isEmpty else { return [] }
        return [.failure(message)]
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func int(_ key: String) -> Int? { self[key] as? Int }
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    /// The content blocks of a whole message event.
    func contentBlocks() -> [[String: Any]] {
        dictionary("message")?["content"] as? [[String: Any]] ?? []
    }
}

/// What a finished provider run amounts to, and so what the chat pane should
/// show for it.
///
/// A stopped run is kept apart from a failed one on purpose. Stopping a CLI
/// means terminating it, and the providers exit 143 when terminated — so a run
/// the user stopped, or that Lamp stopped by taking the pane off screen,
/// arrives here looking exactly like a crash. Describing it as one ("Claude
/// exited with status 143") blames the provider for something it didn't do.
public enum AgentChatRunDisposition: Equatable, Sendable {
    /// The run answered.
    case replied(String)
    /// The run was stopped. Carries whatever had arrived before it was.
    case stopped(partialReply: String)
    /// The run failed, with a description fit to show.
    case failed(String)
    /// The run ended successfully but said nothing.
    case silent(String)

    public static func of(
        output: String,
        exitCode: Int32,
        launchError: String?,
        wasStopped: Bool,
        provider: AgentChatWireProvider,
        providerName: String
    ) -> AgentChatRunDisposition {
        let summary = AgentChatRunSummary.summarize(output: output, provider: provider)
        // Checked before anything else: a stopped run's exit status and its
        // truncated output describe the stop, not the request.
        if wasStopped { return .stopped(partialReply: summary.response) }
        if !summary.response.isEmpty { return .replied(summary.response) }
        if exitCode != 0 || launchError != nil || summary.failure != nil {
            let failure = launchError
                ?? summary.failure
                ?? readableCLIError(in: output)
                ?? "\(providerName) exited with status \(exitCode)."
            return .failed(failure)
        }
        return .silent("\(providerName) finished without returning a message.")
    }

    /// The last few human-readable lines of a CLI's output — what it printed
    /// that wasn't part of its JSON event stream.
    public static func readableCLIError(in output: String) -> String? {
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
}

/// What `opencode auth list` says about whether anything is signed in.
///
/// OpenCode reports its credentials as a count — "no credentials",
/// "1 credentials", "12 credentials" — and the count is what decides this.
/// Looking for "0 credential" in the text instead disconnects someone for
/// having ten, because "10 credentials" contains it.
public enum AgentProviderCredentialListing {
    private static let countPattern = try! NSRegularExpression(
        pattern: #"(\d+)\s+credentials?\b"#, options: [.caseInsensitive]
    )

    /// The number of credentials the listing reports, when it reports one.
    public static func reportedCount(in output: String) -> Int? {
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        // The count is the listing's closing line, so the last one wins.
        if let match = countPattern.matches(in: output, range: range).last,
           let digits = Range(match.range(at: 1), in: output) {
            return Int(output[digits])
        }
        return output.lowercased().contains("no credential") ? 0 : nil
    }

    /// Whether the listing describes a provider that is signed in.
    public static func describesCredentials(output: String, exitCode: Int32) -> Bool {
        // A listing that never says leaves it to the exit status, which is
        // what every other provider is judged by.
        if let count = reportedCount(in: output) { return count > 0 }
        return exitCode == 0
    }
}
