import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum AgentChatWireProvider: String, Sendable {
    case codex
    case claude
    case openCode
    /// Google's Antigravity CLI, driven over its Agent Client Protocol
    /// server (`agy acp`), the way Google documents for apps; never its
    /// headless `-p` mode, which its FAQ rules out for third-party apps on a
    /// consumer plan. See `AgentACPRun`.
    case antigravity
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
        case .codex, .openCode, .antigravity: []
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

    /// A model name split from the variant written onto it, the way OpenCode
    /// spells `provider/model#variant`.
    public static func separatingVariant(_ model: String) -> (base: String, variant: String?) {
        guard let hash = model.firstIndex(of: "#") else { return (model, nil) }
        let variant = String(model[model.index(after: hash)...])
        return (String(model[..<hash]), variant.isEmpty ? nil : variant)
    }

    /// The model as this provider is to be told it, which for OpenCode is
    /// where its effort goes: `opencode run` has no effort flag, and a variant
    /// is the one thing a single run can be told about how a model reasons.
    ///
    /// A variant the reader wrote onto the name themselves stands, because
    /// they named it more exactly than a picker can. An effort with no model
    /// to carry it is dropped, because `--model #high` names nothing.
    public static func naming(
        model: String?, effort: String?, provider: AgentChatWireProvider
    ) -> String? {
        guard let model = canonical(model) else { return nil }
        guard AgentChatEffortChoice.isCarriedByTheModel(provider),
              let effort = canonical(effort),
              separatingVariant(model).variant == nil
        else { return model }
        return "\(model)#\(effort)"
    }

    /// The flag this provider takes. Each spells it differently, and openCode
    /// wants a qualified name rather than a bare one.
    public static func arguments(
        for model: String?, effort: String? = nil, provider: AgentChatWireProvider
    ) -> [String] {
        guard let model = naming(model: model, effort: effort, provider: provider) else { return [] }
        switch provider {
        case .claude, .openCode: return ["--model", model]
        case .codex: return ["-m", model]
        // Set on the session over ACP instead; see `AgentACPRun`.
        case .antigravity: return []
        }
    }

    /// What to show beneath the picker, so a reader typing a name knows the
    /// shape the provider expects.
    public static func hint(_ provider: AgentChatWireProvider) -> String {
        switch provider {
        case .claude: "An alias such as opus, or a full model name."
        case .codex: "A model name the Codex CLI accepts."
        // The Effort beside this writes the #variant, so a reader who wants
        // one picked for them need not spell it. One written here by hand
        // stands over it.
        case .openCode: "provider/model, or provider/model#variant."
        // Not as `agy models` prints them: those end in a thinking level
        // (gemini-3.8-flash-high), which ACP's model setting does not take.
        case .antigravity: "A model ID such as gemini-3.8-flash, with no thinking level on the end."
        }
    }
}

/// How hard a provider's CLI should think, when the reader does not want its
/// default.
///
/// All three can be told, by three different means, and each is the one its
/// own CLI documents: Claude Code takes a level on the command line; Codex
/// keeps one in its config, which an override sets for a single run; OpenCode
/// has no setting of its own, and carries it in the model's variant — which
/// is why a level here can reach it only once a model is named.
public enum AgentChatEffortChoice {
    public static func defaultsKey(_ provider: AgentChatWireProvider) -> String {
        "chat.effort.\(provider.rawValue)"
    }

    /// Whether the provider takes its effort inside the model it is given
    /// rather than in a setting of its own. OpenCode does: a variant of the
    /// model is what sets its reasoning.
    public static func isCarriedByTheModel(_ provider: AgentChatWireProvider) -> Bool {
        switch provider {
        case .openCode: true
        case .claude, .codex, .antigravity: false
        }
    }

    /// Whether an effort can reach the provider as things stand. OpenCode's
    /// rides on the model's name, so until a model is named there is nothing
    /// to write it onto and a level picked now would go nowhere — better said
    /// than silently dropped.
    public static func isAvailable(provider: AgentChatWireProvider, model: String?) -> Bool {
        guard isCarriedByTheModel(provider) else { return true }
        return AgentChatModelChoice.canonical(model) != nil
    }

    /// The levels the provider itself names. Claude Code lists these in its
    /// own `--help`. Codex documents the setting but no closed set of values,
    /// so none are offered and a level is typed instead. OpenCode's differ by
    /// model — one takes low through max, another only none and thinking — so
    /// they are asked of the CLI instead; see `AgentChatOpenCodeVariants`.
    public static func levels(_ provider: AgentChatWireProvider) -> [String] {
        switch provider {
        // Antigravity documents the same five for `--effort` and its
        // session's thinking level, depending on the model.
        case .claude, .antigravity: ["low", "medium", "high", "xhigh", "max"]
        case .codex, .openCode: []
        }
    }

    public static func canonical(_ stored: String?) -> String? {
        AgentChatModelChoice.canonical(stored)
    }

    public static func arguments(
        for effort: String?, provider: AgentChatWireProvider
    ) -> [String] {
        guard let effort = canonical(effort) else { return [] }
        switch provider {
        case .claude: return ["--effort", effort]
        // Codex has no flag for it; the setting lives in `~/.codex/config.toml`
        // and `-c` overrides one key for this run alone, leaving the reader's
        // own config as they wrote it. Quoted as TOML, since the level is
        // typed: a quote or a newline in it would otherwise end the string
        // and Codex would refuse to start.
        case .codex: return ["-c", "model_reasoning_effort=" + AgentTerminalLaunchPlanner.tomlString(effort)]
        // Nothing of its own: the level is written onto the model by
        // `AgentChatModelChoice.naming`, which is where OpenCode reads it.
        case .openCode: return []
        // The session's thinking level, set over ACP; see `AgentACPRun`.
        case .antigravity: return []
        }
    }

    public static func hint(_ provider: AgentChatWireProvider) -> String {
        switch provider {
        case .claude: "A level such as high. Claude Code names low to max."
        case .codex: "A value your Codex accepts for model_reasoning_effort."
        case .openCode: "A variant of this model, such as high. It is written onto the model name, which is how OpenCode is told."
        case .antigravity: "A thinking level such as high. Which ones Antigravity offers depends on the model."
        }
    }
}

/// Which variants the installed OpenCode says a model has.
///
/// Read from the CLI's own list rather than named here. Variants are not one
/// fixed set: a reasoning model may take low through max, another only none
/// and thinking, and a model with nothing to vary has none at all. OpenCode
/// resolves the name when the run reaches the model, not when the flag is
/// parsed, so a level this app invented would be taken at the command line and
/// fail at the answer.
public enum AgentChatOpenCodeVariants {
    /// What to ask the CLI. `opencode api` addresses the same server its own
    /// `run` uses, and this route is in the server's published OpenAPI.
    public static let probeArguments = ["api", "GET", "/api/model"]

    /// Reads the CLI's answer into the variants each `provider/model` has.
    ///
    /// Anything unexpected reads as nothing known rather than as a guess: an
    /// OpenCode that answers differently leaves the control offering what the
    /// reader types, which still works, instead of a list that does not.
    public static func parse(_ output: String) -> [String: [String]] {
        guard let payload = object(in: output) else { return [:] }
        let models = payload["data"] as? [[String: Any]] ?? []
        var catalogue: [String: [String]] = [:]
        for model in models {
            guard let providerID = model["providerID"] as? String,
                  let modelID = model["modelID"] as? String
            else { continue }
            let variants = (model["variants"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
                .filter { !$0.isEmpty }
            guard !variants.isEmpty else { continue }
            catalogue["\(providerID)/\(modelID)"] = variants
        }
        return catalogue
    }

    /// The variants of the model the reader chose. A variant already written
    /// onto the name is left out of the lookup: what is wanted is the other
    /// variants the model has, so that one can be swapped for another.
    public static func variants(of model: String?, in catalogue: [String: [String]]) -> [String] {
        guard let model = AgentChatModelChoice.canonical(model) else { return [] }
        return catalogue[AgentChatModelChoice.separatingVariant(model).base] ?? []
    }

    /// The variant the reader is on, where it was written onto the model.
    public static func chosen(in model: String?) -> String? {
        guard let model = AgentChatModelChoice.canonical(model) else { return nil }
        return AgentChatModelChoice.separatingVariant(model).variant
    }

    /// The model with this variant on it, which is how a picked effort is kept
    /// for OpenCode: on the model itself, so that what the control shows and
    /// what the run is given cannot come apart. An empty variant takes it back
    /// to the plain model, and with no model there is nothing to name.
    public static func applying(variant: String, to model: String) -> String {
        let base = AgentChatModelChoice.separatingVariant(model).base
        guard AgentChatModelChoice.canonical(base) != nil else { return "" }
        guard let variant = AgentChatModelChoice.canonical(variant) else { return base }
        return "\(base)#\(variant)"
    }

    private static func object(in output: String) -> [String: Any]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return payload
        }
        // A CLI is free to say something before its answer. The braces are
        // only tried when the whole of it would not parse.
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"), start < end,
              let data = String(trimmed[start...end]).data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// What one chat is set to run with, kept beside that chat.
///
/// Two windows on two models is the point of it: a choice made in a window's
/// chat belongs to that chat and not to the app. What the app remembers is the
/// default a new chat opens on, and it is pinned into the chat the first time
/// that chat is shown — so a choice made in another window afterwards leaves
/// this one where the reader left it.
public struct AgentChatChoices: Equatable, Sendable, Codable {
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    /// This chat's own choice, or nil where it has none. An empty string is a
    /// choice — the provider's own default — and not the absence of one, which
    /// is why the two are told apart rather than both read as "nothing set".
    public func value(for key: String) -> String? {
        values[key]
    }

    /// What this chat runs with: its own choice where it has one, and what the
    /// app remembers where it has not.
    public func value(for key: String, orAppDefault appDefault: String?) -> String? {
        values[key] ?? appDefault
    }

    public mutating func set(_ value: String, for key: String) {
        values[key] = value
    }

    /// Where a chat's own provider is kept. One key, not one per provider
    /// like the model and the effort: this is which provider the chat is.
    public static let providerKey = "chat.provider"

    /// Pins what this chat is running with, the first time it is shown.
    ///
    /// Until it is pinned the chat is only following what the app remembers,
    /// and the app remembers whatever was picked last in any window — so a
    /// pick made in a second window would quietly move the first one too.
    /// Pinning is what stops that; a chat that has already pinned a choice,
    /// the provider's own default included, is left as it is.
    ///
    /// - Returns: whether anything changed, so a caller need only write when
    ///   there is something new to write.
    @discardableResult
    public mutating func pin(_ appDefault: String, for key: String) -> Bool {
        guard values[key] == nil else { return false }
        values[key] = appDefault
        return true
    }

    public var isEmpty: Bool { values.isEmpty }

    public init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: String].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Pinning a chat to what it is running with.
///
/// A chat that has pinned nothing is only following what the app remembers,
/// and the app remembers whatever was picked last in any window — so a pick
/// made in a second window would move the first one with it. Pinning is what
/// keeps the two apart, and it is done when a chat is first shown and again
/// when it changes provider, since each provider has a model and an effort of
/// its own that were never pinned while another provider was current.
public enum AgentChatChoicesPin {
    public static func pinning(
        _ choices: AgentChatChoices,
        providerID: String,
        provider: AgentChatWireProvider,
        model: String,
        effort: String
    ) -> (choices: AgentChatChoices, changed: Bool) {
        var pinned = choices
        var changed = pinned.pin(providerID, for: AgentChatChoices.providerKey)
        changed = pinned.pin(model, for: AgentChatModelChoice.defaultsKey(provider)) || changed
        changed = pinned.pin(effort, for: AgentChatEffortChoice.defaultsKey(provider)) || changed
        return (pinned, changed)
    }
}

/// Where a chat's own choices are kept: beside its transcript, because they
/// belong to the same conversation and last exactly as long as it does.
///
/// Not synced. Which models a Mac can run depends on what is installed and
/// signed in there, so the model another Mac chose is not a choice this one
/// can keep — see `AgentChatTranscriptStore.isTranscriptFilename`, which is
/// what sync carries and does not admit this name.
public enum AgentChatChoicesStore {
    public static let filename = "chat-choices.json"

    public static func url(in workspace: URL) -> URL {
        AgentChatTranscriptStore.directory(in: workspace).appendingPathComponent(filename)
    }

    /// Posted on every save, with the workspace's path, on the saving thread.
    public static let saved = Notification.Name("AgentChatChoicesStore.saved")

    /// A missing or damaged file reads as a chat with no choices of its own,
    /// so it falls back to the app's defaults rather than refusing to open.
    public static func load(in workspace: URL) -> AgentChatChoices {
        guard let data = try? Data(contentsOf: url(in: workspace)),
              let choices = try? JSONDecoder().decode(AgentChatChoices.self, from: data)
        else { return AgentChatChoices() }
        return choices
    }

    public static func save(_ choices: AgentChatChoices, in workspace: URL) throws {
        let url = url(in: workspace)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(choices)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        // For a phone following this chat, which shows what it runs with.
        NotificationCenter.default.post(name: saved, object: workspace.standardizedFileURL.path)
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
        providerMajorVersion: Int? = nil,
        codexIgnoresRules: Bool = true,
        writingServer: LampAgentMCPConfiguration? = nil,
        writingInstructionsFile: URL? = nil,
        claudeSnapshots: Bool = true
    ) -> [String] {
        // The effort is given to both: one of them takes it. A provider with a
        // setting of its own gets a flag for it, and OpenCode, which has none,
        // has it written onto the model's name instead.
        let modelArguments = AgentChatModelChoice
            .arguments(for: model, effort: effort, provider: provider)
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
                // No exec-policy rules: an `allow` rule in the person's Codex
                // settings runs a matching command outside the sandbox
                // without asking, whatever the policy, which a reader chat
                // must never do. Their `forbidden` rules go too; the chat
                // stays read-only and offline in its sandbox without them.
                // Not on a Codex too old to take the flag, which would
                // refuse every reader chat.
                if codexIgnoresRules { arguments += ["--ignore-rules"] }
                arguments += configuration.answering(provider: provider.rawValue).codexCommandLineOverrides
            } else if let writingServer {
                // A writing workspace is not trusted either, so its own
                // settings file goes unread; Lamp's server is given here.
                arguments += writingServer.codexWritingOverrides
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
                    "--strict-mcp-config", "--mcp-config",
                    configuration.answering(provider: provider.rawValue).claudeJSON,
                    "--disable-slash-commands",
                ]
            } else {
                // Started from the person's own settings and Lamp's, never
                // the workspace's: under `-p`, a project's `.mcp.json`
                // servers connect unasked and its settings' hooks run, and
                // another provider's agent in the same writing can write
                // either (tried, 2026-11-26: a planted server and hook ran,
                // and with this flag neither did). The person's own servers
                // stay; Lamp's is given here, and the instructions the
                // workspace's `CLAUDE.md` holds, which this leaves unread,
                // from a file of Lamp's: a writing's list of sources can be
                // longer than a command line holds.
                arguments += ["--setting-sources", "user"]
                if let writingServer {
                    arguments += ["--mcp-config", writingServer.answering(provider: provider.rawValue).claudeJSON]
                }
                if let writingInstructionsFile {
                    // Rendered afresh each request: by default Claude Code
                    // keeps a conversation's first prompt and resends it on
                    // every resume, whatever a later launch says, and the
                    // instructions follow the workspace (its sources, its
                    // skills, review marks).
                    arguments += ["--append-system-prompt-file", writingInstructionsFile.path]
                    // A Claude Code with no snapshot renders the prompt every
                    // request already, and refuses the flag.
                    if claudeSnapshots { arguments += ["--system-prompt-snapshot", "off"] }
                }
                if let permissionHookSettings {
                    // Asks the person about a tool call the run would
                    // otherwise deny; see `ClaudePermissionHook`.
                    arguments += ["--settings", permissionHookSettings]
                }
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
        case .antigravity:
            // Everything else — the session, the model, the prompt — goes
            // over the protocol; see `AgentACPRun`.
            return ["acp"]
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
        // `agy acp`, asked for a session before anyone has signed in.
        "authentication required",
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

/// A file an agent links to in its reply.
///
/// Agents write a file as a bare path — Codex links what it made as
/// `/Users/…/.lamp-renders/test.png` — and handed on as it is, a link with no
/// scheme is one macOS will not open (error -50). So an absolute path on this
/// Mac is a file, as a `file:` link is.
///
/// A link opens what it names, and the agent can change what that is, even
/// between Lamp looking and macOS opening. So a click opens only a picture,
/// a video, sound or a PDF, and opens a clone of the file Lamp checked —
/// opened without following a link, regular, not executable — stripped of
/// the extended attributes that choose how it opens (an alias's mark, an
/// "open with" choice) and of any lock, in a folder of Lamp's that no agent
/// writes. Anything else — text, which an editor would change in the copy
/// rather than the workspace; an SVG, which can carry scripts; Lamp's own
/// modules and decks, which a click must not install or import over what is
/// there; a folder; what runs; a link or alias; a type that can't be told —
/// is shown in Finder, which runs nothing.
public enum AgentChatFileLink {
    /// What a click does.
    public enum Action: Equatable, Sendable {
        /// Open this clone with its app.
        case open(URL)
        case reveal(URL)
        case missing
    }

    /// Whether a click on a link is this route's to answer, by its shape
    /// alone, decided as the click lands with no look at the disk: every
    /// `file:` link, whatever it names, so none reaches macOS unchecked, and
    /// a bare absolute path. `file(for:)` then says which are this Mac's.
    public static func namesAFile(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        return url.scheme == nil && url.path.hasPrefix("/")
    }

    /// Whether a link's authority is this Mac: none, or `localhost`.
    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return true }
        return host.lowercased() == "localhost"
    }

    /// The file a link names, or nil for a link that is not a local file's:
    /// one naming another computer (`//host/…`, `file://host/…`) is left as
    /// the link it is. A trailing `:12` or `:12:3`, as agents cite a line, is
    /// left off where the path without it is the one that is there.
    public static func file(for url: URL) -> URL? {
        guard namesAFile(url), isLocal(url) else { return nil }
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        if !isThere(path),
           let range = path.range(of: #"(:\d+){1,2}$"#, options: .regularExpression),
           isThere(String(path[..<range.lowerBound])) {
            return URL(fileURLWithPath: String(path[..<range.lowerBound]))
        }
        return URL(fileURLWithPath: path)
    }

    /// Formats that hold their own pictures or sound, by name: never a
    /// broad kind, under which a playlist or a stream redirector (`.asx`,
    /// `.m3u`) counts as video and sends a player elsewhere.
    static let viewed: [UTType] = [
        .png, .jpeg, .heic, .heif, .gif, .tiff, .webP, .bmp,
        .mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video,
        .mpeg4Audio, .mp3, .wav, .aiff,
        .pdf,
    ]
    static let neverViewed: [UTType] = [
        .application, .applicationBundle, .executable, .script, .shellScript, .unixExecutable,
        .sourceCode, .aliasFile, .symbolicLink, .resolvable, .bundle, .package, .svg, .html, .playlist, .m3uPlaylist,
    ]

    /// Whether a file is looked at, by its name, as the system declares the
    /// type: never by asking the file, which the agent controls.
    public static func isViewed(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension.lowercased()), !type.isDynamic,
              !neverViewed.contains(where: { type.conforms(to: $0) })
        else { return false }
        return viewed.contains { type == $0 || type.conforms(to: $0) }
    }

    /// Where a click on `file` leads. `cache` is Lamp's own folder for the
    /// clones; `viewedBy` is `isViewed`, given by a test; `selfContained`
    /// says whether a clone holds all its own media, as a QuickTime movie
    /// may not, its pictures in another file a player would read.
    public static func action(
        for file: URL, cache: URL,
        viewedBy: (URL) -> Bool = isViewed,
        selfContained: (URL) -> Bool = { holdsItsOwnMedia($0) }
    ) -> Action {
        var info = stat()
        // The item itself, not where a link would lead.
        guard lstat(file.path, &info) == 0 else { return .missing }
        let reveal = Action.reveal(file)
        guard info.st_mode & S_IFMT == S_IFREG, viewedBy(file) else { return reveal }
        // Opened without following a link, then judged as what was opened.
        let source = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { return reveal }
        defer { close(source) }
        var opened = stat()
        guard fstat(source, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0,
              let copy = clone(source, named: file.lastPathComponent, into: cache)
        else { return reveal }
        guard selfContained(copy) else {
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            return reveal
        }
        return .open(copy)
    }

    /// A clone of the open file `source` in a new folder of `cache`, with no
    /// extended attributes that choose how it opens, no lock (a clone keeps a
    /// Finder lock, and a locked clone could never be pruned), and readable
    /// by its owner alone. Nil where it
    /// can't be made: another disk (a copy of a long video is not made on a
    /// click), or a cache that is a link or not this user's.
    static func clone(_ source: Int32, named name: String, into cache: URL) -> URL? {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = stat()
        guard lstat(cache.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR, root.st_uid == geteuid()
        else { return nil }
        prune(cache)
        let folder = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { return nil }
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        guard fclonefileat(source, directory, name, 0) == 0 else {
            try? fileManager.removeItem(at: folder)
            return nil
        }
        let made = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard made >= 0 else {
            try? fileManager.removeItem(at: folder)
            return nil
        }
        defer { close(made) }
        // An alias is a regular file with a mark: judged before the mark is
        // stripped, and shown, not viewed.
        let copy = folder.appendingPathComponent(name)
        let isAlias = (try? copy.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile ?? true
        // The lock first: a locked file's attributes and mode can't change.
        let unlocked = fchflags(made, 0) == 0
        guard !isAlias, unlocked, stripAttributes(made), fchmod(made, 0o400) == 0 else {
            _ = fchflags(made, 0)
            try? fileManager.removeItem(at: folder)
            return nil
        }
        return folder.appendingPathComponent(name)
    }

    /// Removes every extended attribute from the open file but the system's
    /// own marks of where it came from, which choose nothing about how it
    /// opens and which a viewer heeds: provenance, which macOS puts on every
    /// new file and keeps, and a download's quarantine. False if any other
    /// is left.
    static func stripAttributes(_ file: Int32) -> Bool {
        guard let names = attributeNames(file) else { return false }
        for name in names where !kept.contains(name) { _ = fremovexattr(file, name, 0) }
        return attributeNames(file).map { $0.allSatisfy(kept.contains) } ?? false
    }

    static let kept: Set<String> = ["com.apple.provenance", "com.apple.quarantine"]

    static func attributeNames(_ file: Int32) -> [String]? {
        let size = flistxattr(file, nil, 0, 0)
        guard size >= 0 else { return nil }
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard flistxattr(file, &buffer, size, 0) == size else { return nil }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    /// Clones from earlier days go: each was for one look. Only folders this
    /// made, named by a UUID.
    private static func prune(_ cache: URL) {
        let dayAgo = Date().addingTimeInterval(-86_400)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [] {
            guard UUID(uuidString: name) != nil else { continue }
            let folder = cache.appendingPathComponent(name)
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < dayAgo
            else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Whether anything is at `path`, a dangling link included.
    private static func isThere(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// A tool call as one line a person can read.
public enum AgentChatToolDescription {
    /// The tool's name as the pane shows it. An MCP tool arrives as
    /// `mcp__lamp__read_passage`, which names a server nobody needs to see.
    public static func label(for name: String) -> String {
        // Antigravity spells it `mcp_lamp_read_passage`.
        if name.hasPrefix("mcp_lamp_") { return String(name.dropFirst("mcp_lamp_".count)) }
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
    /// Where the run's usage is billed, as the provider reports it.
    case billing(AgentChatBilling)
    /// Where the account stands against a usage limit, as the provider
    /// reports it during the run.
    case usageLimit(AgentChatUsageLimit)
}

/// Where a run's usage is billed: the reader's subscription, or an API key
/// charged by the token.
///
/// Claude Code says on every run, as `apiKeySource` on its `system/init`
/// event (documented in the Agent SDK reference as `ApiKeySource`). "none"
/// is no key at all — the subscription the reader signed in with — and
/// "oauth" is a subscription token. Every other source is a key, and a key
/// left in someone's environment by another tool would otherwise bill them
/// per token for a chat they thought their plan covered.
public struct AgentChatBilling: Equatable, Sendable {
    public let source: String

    public init(source: String) { self.source = source }

    public var isAPIKey: Bool { !["none", "oauth"].contains(source) }

    /// What `codex login status` says, which is how Codex reports it:
    /// "Logged in using ChatGPT" for a subscription, "Logged in using an API
    /// key" for a key. Nil when it says neither.
    public static func codex(loginStatus output: String) -> AgentChatBilling? {
        let text = output.lowercased()
        if text.contains("api key") { return AgentChatBilling(source: "API key") }
        if text.contains("chatgpt") { return AgentChatBilling(source: "none") }
        return nil
    }
}

/// A usage limit's state, from Claude Code's documented `rate_limit_event`.
///
/// Only the documented fields are read. The event carries more (which
/// window, whether overage is in use) that the reference does not promise,
/// and a field that is not promised can go without notice.
public struct AgentChatUsageLimit: Equatable, Sendable {
    public enum Status: String, Sendable {
        case allowed
        case allowedWarning = "allowed_warning"
        case rejected
    }

    public let status: Status
    public let resetsAt: Date?
    /// The share of the limit used, 0 to 1, when the event says.
    public let utilization: Double?
    /// The rejection is a subscription whose included usage is spent, which
    /// only buying usage credits gets past.
    public let needsCredits: Bool

    public init(status: Status, resetsAt: Date?, utilization: Double?, needsCredits: Bool) {
        self.status = status
        self.resetsAt = resetsAt
        self.utilization = utilization
        self.needsCredits = needsCredits
    }
}

/// Takes credentials out of text before it is shown, recorded or synced.
///
/// A provider's error can quote the request that failed, header and all, and
/// a failure is written into the chat's transcript, which goes to every Mac
/// and phone the library syncs with.
public enum AgentChatSecrets {
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#)
    private static let skKey = try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]{12,}"#)
    /// A field and its value: an optionally quoted name of bounded length,
    /// `:` or `=`, and a value quoted whole (escapes included) or running
    /// to the next delimiter. Whether the name is a credential is decided
    /// in code, so no part of the pattern can backtrack far.
    private static let fieldName = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9_-])(["']?)([A-Za-z][A-Za-z0-9_-]{0,63})\1\s*[:=]\s*"#
    )
    private static let fieldValue = try! NSRegularExpression(pattern:
        #"\G(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s"',;}\]]+)"#
    )

    public static func redacted(_ text: String) -> String {
        var result = replacing(bearer, in: text, with: "$1 [redacted]")
        result = replacing(skKey, in: result, with: "sk-[redacted]")
        let ns = result as NSString
        var pieces: [String] = []
        var cursor = 0
        // Names are found first, in one pass; a value is read only after a
        // name that could be a credential, and only from just there. So
        // "failed: GEMINI_API_KEY=…" is not taken as the value of `failed`,
        // and no value is scanned twice.
        for match in fieldName.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            let nameEnd = match.range.location + match.range.length
            guard nameEnd >= cursor else { continue }
            let name = ns.substring(with: match.range(at: 2))
            guard isCredentialName(name),
                  let valueMatch = fieldValue.firstMatch(in: result, range: NSRange(location: nameEnd, length: ns.length - nameEnd))
            else { continue }
            let valueRange = valueMatch.range
            let value = ns.substring(with: valueRange)
            guard isCredential(name: name, value: value) else { continue }
            pieces.append(ns.substring(with: NSRange(location: cursor, length: valueRange.location - cursor)))
            pieces.append("[redacted]")
            cursor = valueRange.location + valueRange.length
        }
        pieces.append(ns.substring(from: cursor))
        return pieces.joined()
    }

    /// Credential names whatever the value looks like; environment-style
    /// names (`GEMINI_API_KEY`, `GITHUB_TOKEN`) only in capitals, so a
    /// `sort_key` or `primary_key` keeps its value. A bare `token`, which
    /// prose uses too ("Unexpected token: 123"), only where the value is
    /// long enough to be one.
    /// Whether a name could be a credential's, before its value is read.
    static func isCredentialName(_ name: String) -> Bool {
        isCredential(name: name, value: String(repeating: "x", count: 12))
    }

    static func isCredential(name: String, value: String) -> Bool {
        // camelCase as snake_case, so `accessToken` reads as `access_token`.
        var snake = ""
        for character in name {
            if character.isUppercase, let last = snake.last, last.isLowercase || last.isNumber { snake.append("_") }
            snake.append(character)
        }
        let lowered = snake.lowercased().replacingOccurrences(of: "-", with: "_")
        let alwaysSecret = ["api_key", "apikey", "secret", "password", "passwd", "access_token",
                            "refresh_token", "auth_token", "bearer_token", "id_token", "private_key",
                            "secret_key", "access_key", "session_token", "client_secret"]
        if alwaysSecret.contains(where: { lowered == $0 || lowered.hasSuffix("_" + $0) }) { return true }
        if name == name.uppercased(), name.contains("_"),
           ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD"].contains(where: { name.hasSuffix($0) }) {
            return true
        }
        if lowered == "token" || lowered.hasSuffix("_token") {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).count >= 12
        }
        return false
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: template
        )
    }
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
        case .antigravity:
            return parseACP(object)
        }
    }

    private static func parseCodex(_ object: [String: Any]) -> [AgentChatWireEvent] {
        // `codex app-server` speaks in messages, `codex exec --json` in typed
        // events; a line is read by which it is.
        if object["method"] != nil || object["result"] != nil || object["error"] is [String: Any] {
            return parseCodexAppServer(object)
        }
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

    /// A writing chat's turn over `codex app-server`; see `AgentCodexRun`.
    /// Commentary is kept out by the runner before a line arrives here.
    private static func parseCodexAppServer(_ object: [String: Any]) -> [AgentChatWireEvent] {
        let params = object.dictionary("params")
        guard let method = object.string("method") else {
            // The answer to one of Lamp's requests: the thread it opened, or
            // why it could not — "no rollout found for thread id …" for one
            // Codex no longer has, which the resume path reads.
            if let thread = object.dictionary("result")?.dictionary("thread"), let id = thread.string("id") {
                return [.sessionStarted(id)]
            }
            return object["error"] is [String: Any] ? failureEvents(in: object) : []
        }
        switch method {
        case "thread/started":
            return params?.dictionary("thread")?.string("id").map { [.sessionStarted($0)] } ?? []
        case "item/agentMessage/delta":
            return params?.string("delta").flatMap { $0.isEmpty ? nil : [.textFragment($0)] } ?? []
        case "item/started":
            guard let item = params?.dictionary("item") else { return [] }
            switch item.string("type") {
            case "reasoning":
                return [.activity(.thinking(estimatedTokens: nil))]
            case "agentMessage":
                return [.activity(.writing)]
            case "commandExecution":
                // Shortened, as Claude's commands are: a step is kept in the
                // transcript and sent to a phone, and is no place for the
                // whole of one. The card has it in full.
                return [.activity(.tool(
                    name: "Command",
                    summary: AgentChatToolDescription.summary(of: item.string("command").map { ["command": AgentCodexRun.shown($0)] })
                ))]
            case "mcpToolCall":
                guard let server = item.string("server"), let tool = item.string("tool") else { return [] }
                return [.activity(.tool(
                    name: "mcp__\(server)__\(tool)",
                    summary: AgentChatToolDescription.summary(of: item.dictionary("arguments"))
                ))]
            case "webSearch":
                return [.activity(.tool(name: "WebSearch", summary: item.string("query")))]
            case "fileChange":
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0.string("path") }
                return [.activity(.tool(name: "Edit", summary: AgentChatToolDescription.summary(of: paths.first.map { ["path": $0] })))]
            default:
                return []
            }
        case "item/completed":
            guard let item = params?.dictionary("item") else { return [] }
            if item.string("type") == "agentMessage" {
                guard let text = item.string("text"), !text.isEmpty else { return [] }
                return [.finalText(text)]
            }
            return ["commandExecution", "mcpToolCall", "webSearch", "fileChange"].contains(item.string("type") ?? "")
                ? [.activity(.toolFinished)] : []
        case "turn/completed":
            guard let turn = params?.dictionary("turn"), turn.string("status") == "failed" else { return [] }
            return failureEvents(in: turn)
        case "error":
            // One Codex will try again is not yet a failure.
            guard params?.bool("willRetry") != true, let params else { return [] }
            return failureEvents(in: params)
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
            } else if object.string("subtype") == "init",
                      let source = object.string("apiKeySource"), !source.isEmpty {
                events.append(.billing(AgentChatBilling(source: source)))
            }
        case "rate_limit_event":
            if let info = object.dictionary("rate_limit_info"),
               let status = info.string("status").flatMap(AgentChatUsageLimit.Status.init(rawValue:)) {
                events.append(.usageLimit(AgentChatUsageLimit(
                    status: status,
                    resetsAt: info.number("resetsAt").map { Date(timeIntervalSince1970: $0) },
                    utilization: info.number("utilization"),
                    needsCredits: info.string("errorCode") == "credits_required"
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
                // Said plainly first where the result says why, in the
                // documented `api_error_status` and `terminal_reason`; the
                // provider's own words follow.
                let why = claudeFailureExplanation(
                    apiErrorStatus: object.int("api_error_status"),
                    terminalReason: object.string("terminal_reason")
                )
                func explained(_ message: String) -> String {
                    why.map { "\($0) \(message)" } ?? message
                }
                if let message = object.string("result"), !message.isEmpty {
                    events.append(.failure(explained(message)))
                } else if let message = (object["errors"] as? [String])?
                    .first(where: { !$0.isEmpty }) {
                    // How Claude Code reports a failure that happened before any
                    // turn ran, such as resuming a session it doesn't have.
                    events.append(.failure(explained(message)))
                } else if let why, failureEvents(in: object).isEmpty {
                    events.append(.failure(why))
                } else {
                    events.append(contentsOf: failureEvents(in: object).map { event -> AgentChatWireEvent in
                        if case .failure(let message) = event { return .failure(explained(message)) }
                        return event
                    })
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

    /// One line of an `agy acp` conversation: what the agent sent Lamp, and
    /// the answers to what Lamp asked. Lamp's own requests are not in the
    /// output; see `AgentACPRun`.
    private static func parseACP(_ object: [String: Any]) -> [AgentChatWireEvent] {
        if object.string("method") == "session/update",
           let update = object.dictionary("params")?.dictionary("update") {
            switch update.string("sessionUpdate") {
            case "agent_message_chunk":
                if update.dictionary("content")?.string("type") == "text",
                   let text = update.dictionary("content")?.string("text"), !text.isEmpty {
                    return [.textFragment(text)]
                }
            case "agent_thought_chunk":
                return [.activity(.thinking(estimatedTokens: nil))]
            case "tool_call":
                let name = update.string("name") ?? update.string("title") ?? "tool"
                let summary = update.dictionary("rawInput")?.string("toolSummary")
                    ?? AgentChatToolDescription.summary(of: update.dictionary("rawInput"))
                return [.activity(.tool(name: name, summary: summary))]
            case "tool_call_update":
                if ["completed", "failed"].contains(update.string("status") ?? "") {
                    return [.activity(.toolFinished)]
                }
            default:
                break
            }
            return []
        }
        // A request from the agent — a permission, a file read — is answered
        // by the run, not read as part of the reply.
        guard object["method"] == nil else { return [] }
        if let error = object.dictionary("error") {
            let message = error.string("message") ?? "Antigravity reported an error."
            return [.failure(message)]
        }
        guard let result = object.dictionary("result") else { return [] }
        if let sessionID = result.string("sessionId"), !sessionID.isEmpty {
            return [.sessionStarted(sessionID)]
        }
        switch result.string("stopReason") {
        case "refusal":
            // Where Antigravity reports a spent quota (QUOTA_EXHAUSTED), and
            // a refusal by the model.
            return [.failure("Antigravity stopped without answering. It does this when a usage limit is reached, or when the model refuses.")]
        case "max_tokens":
            return [.failure("Antigravity stopped partway: the reply reached the model’s length limit.")]
        case "max_turn_requests":
            return [.failure("Antigravity stopped partway: the turn reached its limit of model requests.")]
        case "cancelled":
            // A Stop is read as a stop before this is; this is one Lamp did
            // not ask for.
            return [.failure("Antigravity cancelled the reply.")]
        default:
            return []
        }
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

    /// A plain sentence for the failures a reader can do something about,
    /// read from the result's documented fields.
    static func claudeFailureExplanation(apiErrorStatus: Int?, terminalReason: String?) -> String? {
        switch (apiErrorStatus, terminalReason) {
        case (529?, _):
            return "Claude is overloaded right now. Try again in a minute."
        case (429?, _):
            return "Claude's usage limit is reached for now."
        case (_, "prompt_too_long"?):
            return "This conversation has grown too long for the model. Start a new chat to carry on."
        case (_, "budget_exhausted"?):
            return "This run reached its spending limit."
        case (_, "model_error"?):
            return "The model couldn\u{2019}t answer. Choosing another model may help."
        default:
            return nil
        }
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
    /// A number written as either an integer or a fraction.
    func number(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
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
            return .failed(AgentChatSecrets.redacted(failure))
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

/// What a chat says about a usage limit, from the documented fields alone.
public enum AgentChatUsageLimitText {
    /// Why Lamp stopped a reply the provider was holding at a limit.
    public static func reached(_ limit: AgentChatUsageLimit, provider: String, now: Date = Date()) -> String {
        var text = limit.needsCredits
            ? "\(provider)\u{2019}s included usage is spent, and the session can\u{2019}t continue until usage credits are bought for the account."
            : "\(provider)\u{2019}s usage limit is reached."
        if let resetsAt = limit.resetsAt { text += " It resets \(when(resetsAt, now: now))." }
        return text + " Lamp stopped the reply rather than leave it waiting."
    }

    /// A word of warning as the account nears a limit, or nil when there is
    /// nothing to warn of.
    public static func warning(_ limit: AgentChatUsageLimit, provider: String, now: Date = Date()) -> String? {
        guard limit.status == .allowedWarning else { return nil }
        var text = limit.utilization.map {
            "You\u{2019}ve used \(Int(($0 * 100).rounded()))% of a \(provider) usage limit."
        } ?? "You\u{2019}re nearing a \(provider) usage limit."
        if let resetsAt = limit.resetsAt { text += " It resets \(when(resetsAt, now: now))." }
        return text
    }

    private static func when(_ date: Date, now: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.wide).hour().minute()
        let prefix = Calendar.current.isDate(date, inSameDayAs: now) ? "at " : ""
        return prefix + date.formatted(style)
    }
}

/// The environment a provider CLI is started with.
public enum AgentProcessEnvironment {
    /// What a Claude Code session exports to the commands it runs. A `claude`
    /// started with them acts as part of that session — its id, messaging
    /// socket and token, its effort — rather than as the reader's own run,
    /// which is what Lamp started from a Claude Code shell during development
    /// would hand down. Named one by one rather than by prefix, so a
    /// reader's own `CLAUDE_CONFIG_DIR` and Lamp's `LAMP_*` variables pass.
    public static let hostSessionVariables: Set<String> = [
        "CLAUDECODE",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_DESKTOP_APP_VERSION",
        "CLAUDE_EFFORT",
        "CLAUDE_PID",
        "CLAUDE_AGENT_SDK_VERSION",
    ]

    public static func cleaned(_ environment: [String: String]) -> [String: String] {
        environment.filter { !hostSessionVariables.contains($0.key) }
    }
}

/// A CLI process Lamp starts, in a process group of its own.
///
/// Launched with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`, so the process
/// and everything it starts share a group whose number is its own. A stop
/// signals the group, which reaches every process the run started — an MCP
/// server, a shell command, one whose parent has already exited — with no
/// walk of the process table and no guessing at which processes are whose.
/// What leaves the group on purpose (a daemon that calls `setsid`, such as
/// OpenCode's background server) is left alone, as it should be.
///
/// Shaped like the parts of Foundation's `Process` Lamp used: configure, then
/// `run()`; a pipe or nothing (`/dev/null`) for each standard stream; and the
/// file descriptors Lamp holds are not handed down, since every one but the
/// three standard streams is closed in the child.
public final class AgentSpawnedProcess: @unchecked Sendable {
    public var executableURL: URL?
    public var arguments: [String] = []
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?
    /// Nil is `/dev/null`.
    public var standardInput: Pipe?
    public var standardOutput: Pipe?
    /// Nil is `/dev/null`. Setting it to the same pipe as `standardOutput`
    /// merges the two.
    public var standardError: Pipe?

    private let lock = NSLock()
    private let exited = DispatchGroup()
    private var pid: pid_t = 0
    /// Its exit status (or ending signal), once its exit has been seen.
    private var status: Int32?
    /// Whether it has been reaped. Until then its exit is seen but not
    /// collected (`waitid` with `WNOWAIT`), so the exited process holds its
    /// number — and with it the group's — and no other process or group can
    /// be given it. Signals to the group stop when it is reaped.
    private var released = false

    public init() {}

    deinit {
        // Never leave a zombie: one whose exit was seen is reaped now.
        if status != nil, !released, pid > 0 {
            var raw: Int32 = 0
            waitpid(pid, &raw, WNOHANG)
        }
    }

    public var processIdentifier: pid_t {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    /// Whether the process Lamp started is still running (its exit not yet
    /// seen). Others in its group may outlive it; `signalGroup` reaches them.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid != 0 && status == nil
    }

    /// Its exit status, or the number of the signal that ended it, as
    /// `Process.terminationStatus` gives it.
    public var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return status ?? 0
    }

    public func run() throws {
        guard let executableURL else { throw POSIXError(.ENOENT) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        func wire(_ pipe: Pipe?, reading: Bool, to target: Int32) {
            if let pipe {
                let fd = reading ? pipe.fileHandleForReading.fileDescriptor : pipe.fileHandleForWriting.fileDescriptor
                posix_spawn_file_actions_adddup2(&actions, fd, target)
            } else {
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", reading ? O_RDONLY : O_WRONLY, 0)
            }
        }
        wire(standardInput, reading: true, to: 0)
        wire(standardOutput, reading: false, to: 1)
        wire(standardError, reading: false, to: 2)
        if let directory = currentDirectoryURL {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group, numbered as itself; only the three streams handed
        // down; and signals as a freshly started program expects them.
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        ))
        posix_spawnattr_setpgroup(&attributes, 0)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)

        let environment = self.environment ?? ProcessInfo.processInfo.environment
        let argv = ([executableURL.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var spawned: pid_t = 0
        // Entered before the process can be seen running, so a wait can never
        // find nothing outstanding while it runs.
        exited.enter()
        let result = posix_spawn(&spawned, executableURL.path, &actions, &attributes, argv, envp)
        guard result == 0 else {
            exited.leave()
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        lock.lock()
        pid = spawned
        lock.unlock()
        // The child's ends are the child's: held open here, a pipe would
        // never reach the end of its input.
        try? standardInput?.fileHandleForReading.close()
        try? standardOutput?.fileHandleForWriting.close()
        if standardError !== standardOutput { try? standardError?.fileHandleForWriting.close() }

        Thread.detachNewThread { [self] in
            // Seen, not reaped: see `released`.
            var info = siginfo_t()
            while waitid(P_PID, id_t(spawned), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            lock.lock()
            // An exit code, or the signal that ended it, as
            // `Process.terminationStatus` gives them.
            status = info.si_status
            lock.unlock()
            exited.leave()
        }
    }

    /// Reaps the process once nothing more will be signalled to its group,
    /// waiting for it to exit first if it has not. After this its number is
    /// free to be given out again, so `signalGroup` does nothing.
    public func release() {
        guard processIdentifier != 0 else { return }
        exited.wait()
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
    }

    public func waitUntilExit() {
        guard processIdentifier != 0 else { return }
        exited.wait()
    }

    /// Waits up to `seconds` for the process to exit; true if it has.
    public func waitUntilExit(within seconds: Double) -> Bool {
        guard processIdentifier != 0 else { return true }
        return exited.wait(timeout: .now() + seconds) == .success
    }

    /// Sends `signal` to every process in the run's group: whether or not
    /// the process Lamp started is still running, since what it started may
    /// be, and safely, because until `release` its number is still its own.
    public func signalGroup(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard pid > 0, !released else { return }
        killpg(pid, signal)
    }

    /// Asks the whole group to stop, as `Process.terminate` asked the one.
    public func terminate() { signalGroup(SIGTERM) }
}

/// Where an account stands against its plan's limits, as lines fit to show.
///
/// Read only through each CLI's documented ways of saying so, and never by
/// calling a vendor's endpoints or reading its credentials:
/// - Claude Code answers `/usage` sent as a headless prompt, with no model
///   turn and no cost. Its answer is prose with no promised shape, so the
///   lines that say what is used are shown as written, not taken apart.
/// - Codex's app-server answers `account/rateLimits/read`. Its README calls
///   the schema unstable, so it is read field by field and anything
///   unrecognised means nothing is shown rather than something wrong.
/// - OpenCode's own server answers `GET /api/experimental/usage/limits` for
///   an OpenCode Go plan, in releases that have the route.
public struct AgentUsageReport: Equatable, Sendable {
    public let lines: [String]

    public init(lines: [String]) { self.lines = lines }
}

public enum AgentUsageReading {
    /// The lines of Claude Code's `/usage` answer that say what is used:
    /// "Current week (all models): 76% used · resets Nov 23 at 9pm (…)".
    public static func claude(usageOutput output: String) -> AgentUsageReport? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Current ") && $0.contains("%") }
        return lines.isEmpty ? nil : AgentUsageReport(lines: lines)
    }

    /// The windows in Codex's `account/rateLimits/read` result.
    public static func codex(rateLimitsResult result: [String: Any], now: Date = Date()) -> AgentUsageReport? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var lines: [String] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue
            else { continue }
            var line = "\(windowName(minutes: (window["windowDurationMins"] as? NSNumber)?.intValue)): \(Int(used.rounded()))% used"
            if let resetsAt = (window["resetsAt"] as? NSNumber)?.doubleValue {
                line += " · resets \(resetDescription(Date(timeIntervalSince1970: resetsAt), now: now))"
            }
            lines.append(line)
        }
        if limits["spendControlReached"] as? Bool == true {
            lines.append("The account\u{2019}s spending limit is reached.")
        }
        return lines.isEmpty ? nil : AgentUsageReport(lines: lines)
    }

    /// OpenCode Go's windows from OpenCode's own server route,
    /// `GET /api/experimental/usage/limits` (`{location, data}`; `data` is
    /// null when not signed in to an OpenCode Console workspace). The route
    /// is marked experimental and is not in every release: a missing route,
    /// a null, or a changed shape all show nothing.
    public static func openCode(limitsResponse object: [String: Any], now: Date = Date()) -> AgentUsageReport? {
        guard let data = object["data"] as? [String: Any],
              let go = data["go"] as? [String: Any]
        else { return nil }
        var lines: [String] = []
        for (key, name) in [("rolling", "5-hour limit"), ("weekly", "Weekly limit"), ("monthly", "Monthly limit")] {
            guard let meter = go[key] as? [String: Any],
                  let percent = (meter["percent"] as? NSNumber)?.doubleValue
            else { continue }
            var line = "\(name): \(Int(percent.rounded()))% used"
            if meter["limited"] as? Bool == true { line += ", reached" }
            if let resetsAt = (meter["resetsAt"] as? NSNumber)?.doubleValue {
                line += " · resets \(resetDescription(Date(timeIntervalSince1970: resetsAt / 1000), now: now))"
            }
            lines.append(line)
        }
        return lines.isEmpty ? nil : AgentUsageReport(lines: lines)
    }

    static func windowName(minutes: Int?) -> String {
        switch minutes {
        case 10080?: return "Weekly limit"
        case 1440?: return "Daily limit"
        case let minutes? where minutes > 0 && minutes % 60 == 0: return "\(minutes / 60)-hour limit"
        case let minutes? where minutes > 0: return "\(minutes)-minute limit"
        default: return "Usage limit"
        }
    }

    static func resetDescription(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "at " + date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

/// The models and thinking levels the reader's own Antigravity offers, as its
/// ACP session reports them in `configOptions`: each a value to set and the
/// name Antigravity shows for it ("Gemini 4 Neon" for `gemini-4-neon`).
///
/// Asked of the CLI, never written into Lamp: which models a reader has
/// depends on their plan and changes with Antigravity's releases. The levels
/// differ by model — some go to Extra, some stop at High, some have none —
/// and a session reports only the selected model's, so each model is
/// selected in turn to read its own.
public struct AgentACPCatalogue: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public let value: String
        public let name: String

        public init(value: String, name: String) {
            self.value = value
            self.name = name
        }
    }

    public var models: [Choice]
    /// The model a new session opens on: the reader's own default.
    public var defaultModel: String?
    /// Each model's thinking levels; empty for a model that has none.
    public var levels: [String: [Choice]]

    public init(models: [Choice], defaultModel: String?, levels: [String: [Choice]]) {
        self.models = models
        self.defaultModel = defaultModel
        self.levels = levels
    }

    /// One select option from a `session/new` or `session/set_config_option`
    /// result. Nil when the result does not carry it, which for
    /// `thought_level` means the selected model has no thinking level.
    public static func option(
        _ id: String, in result: [String: Any]
    ) -> (current: String?, choices: [Choice])? {
        guard let options = result["configOptions"] as? [[String: Any]],
              let option = options.first(where: { $0["id"] as? String == id }),
              let listed = option["options"] as? [[String: Any]]
        else { return nil }
        let choices = listed.compactMap { entry -> Choice? in
            guard let value = AgentChatModelChoice.canonical(entry["value"] as? String) else { return nil }
            let name = AgentChatModelChoice.canonical(entry["name"] as? String) ?? value
            return Choice(value: value, name: name)
        }
        return (option["currentValue"] as? String, choices)
    }

    /// What to call a value in a menu: Antigravity's name for it, or the
    /// value itself for one it does not list, such as a name typed by hand.
    public func modelName(_ value: String) -> String {
        models.first { $0.value == value }?.name ?? value
    }

    /// The thinking levels a model offers, the reader's default model when
    /// none is chosen. Nil when not known: a model typed by hand that the
    /// catalogue never read.
    public func levels(for model: String?) -> [Choice]? {
        guard let model = AgentChatModelChoice.canonical(model) ?? defaultModel else { return nil }
        return levels[model]
    }

    public func levelName(_ value: String, model: String?) -> String {
        levels(for: model)?.first { $0.value == value }?.name ?? value
    }
}

/// One turn with Google's Antigravity CLI over its Agent Client Protocol
/// server, `agy acp`: the protocol Google documents for editors and "other
/// ACP clients" to drive it with the reader's own sign-in. Its headless `-p`
/// mode is never used: the Antigravity FAQ says wrapping it in a third-party
/// app is not supported on consumer plans.
///
/// A turn is one process, as with the other CLIs: initialize, open the
/// session (`session/resume` for one Lamp already has, never `session/load`,
/// which replays every tool call), set the model and thinking level if
/// chosen, send the prompt, and end at its answer. The instructions reach it
/// as `AGENTS.md` in the workspace, which Antigravity reads itself.
public enum AgentACPRun {
    public static let protocolVersion = 1

    public static func initialize() -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "clientInfo": ["name": "lamp-bible", "title": "Lamp Bible", "version": "1"],
            // Lamp serves no files and no terminal: the agent uses its own.
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
        ]
    }

    /// `session/resume` for a session Lamp has, else `session/new`. Never
    /// extra workspace folders: Antigravity runs commands from the first, so
    /// a second one could move where they run.
    public static func open(
        sessionID: String?, workspace: URL, mcpServers: [[String: Any]]
    ) -> (method: String, params: [String: Any]) {
        var params: [String: Any] = ["cwd": workspace.path, "mcpServers": mcpServers]
        if let sessionID {
            params["sessionId"] = sessionID
            return ("session/resume", params)
        }
        return ("session/new", params)
    }

    /// What a turn sets on its session before the prompt, in order. First
    /// the `default` mode — "Ask before edits and commands, per your
    /// permission settings" — whatever the reader's own `agentMode` says,
    /// because since 1.5.7 an unset one means `auto`, which approves edits
    /// and safe commands without asking Lamp. Then the model and thinking
    /// level, as Antigravity names its config options. Set on every turn: a
    /// cold resume reports the defaults.
    public static func configuration(
        sessionID: String, model: String?, effort: String?
    ) -> [(method: String, params: [String: Any])] {
        var requests: [(method: String, params: [String: Any])] = [
            ("session/set_mode", ["sessionId": sessionID, "modeId": "default"]),
        ]
        if let model = AgentChatModelChoice.canonical(model) {
            requests.append(("session/set_config_option", ["sessionId": sessionID, "configId": "model", "value": model]))
        }
        if let effort = AgentChatEffortChoice.canonical(effort) {
            requests.append(("session/set_config_option", ["sessionId": sessionID, "configId": "thought_level", "value": effort]))
        }
        return requests
    }

    /// Why a reader chat can't be held read-only with this reader's
    /// Antigravity, or nil when it can.
    ///
    /// Lamp keeps a reader chat read-only by answering the agent's
    /// permission requests. An action the reader's own settings already
    /// allow never asks, so Lamp never sees it: Google's ACP guide says
    /// "Actions the rules already allow or deny don't prompt." The settings
    /// file and its keys are the documented ones
    /// (`~/.gemini/antigravity-cli/settings.json`: `toolPermission`,
    /// `permissions.allow`). A rule that lets anything but reading go
    /// unasked means a reader chat could change files, so it is refused.
    public static func readerRefusal(settings data: Data?) -> String? {
        guard let data, let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let reason = "Your Antigravity settings (~/.gemini/antigravity-cli/settings.json) let it %@ without asking, so Lamp can’t keep a reader chat read-only with it. Choose another provider for reader chats, or remove that setting."
        if let permission = settings["toolPermission"] as? String,
           ["always-proceed", "proceed-in-sandbox"].contains(permission) {
            return String(format: reason, "act")
        }
        let permissions = settings["permissions"] as? [String: Any]
        let allowed = (permissions?["allow"] as? [String]) ?? []
        // An ask or deny rule for the same action, on everything, comes
        // before the allow: such a call still reaches Lamp, or never runs.
        let guarded = ((permissions?["ask"] as? [String]) ?? []) + ((permissions?["deny"] as? [String]) ?? [])
        let coveredActions = Set(guarded.compactMap { rule -> String? in
            let parts = ruleParts(rule)
            return parts.target.isEmpty || parts.target == "*" ? parts.action : nil
        })
        // The same rule asked or denied as well, which comes first.
        let coveredRules = Set(guarded.map { $0.trimmingCharacters(in: .whitespaces) })
        if allowed.contains(where: {
            !isReadOnlyRule($0) && !coveredActions.contains(ruleParts($0).action)
                && !coveredRules.contains($0.trimmingCharacters(in: .whitespaces))
        }) {
            return String(format: reason, "run commands or change files")
        }
        return nil
    }

    /// Whether an allow rule, `action(target)`, can only read: a reading
    /// action, or Lamp's own MCP server by its exact name (`mcp(lamp)` or
    /// `mcp(lamp/<tool>)`), never another server whose name merely starts
    /// with it.
    static func ruleParts(_ rule: String) -> (action: String, target: String) {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return (trimmed.lowercased(), "") }
        return (
            String(trimmed[..<open]).lowercased(),
            String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        )
    }

    static func isReadOnlyRule(_ rule: String) -> Bool {
        let (action, target) = ruleParts(rule)
        if ["read_file", "view_file", "list_dir", "list_directory", "grep_search", "find_by_name", "codebase_search", "read"].contains(action) {
            return true
        }
        if action == "mcp" { return target == "lamp" || target.hasPrefix("lamp/") }
        return false
    }

    public static func prompt(sessionID: String, text: String) -> [String: Any] {
        ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]]
    }

    /// Lamp's MCP server, as ACP describes a stdio server. A reader chat's
    /// comes from its mode; a writing's is the one Lamp makes for it from
    /// the workspace's path (`WritingChatTurns.mcpConfiguration`), never the
    /// workspace's `.mcp.json`, which the agent can rewrite to name any
    /// program for Antigravity to start.
    public static func mcpServers(mode: AgentChatMode, writingServer: LampAgentMCPConfiguration?) -> [[String: Any]] {
        switch mode {
        case .reader(let configuration):
            let answering = configuration.answering(provider: AgentChatWireProvider.antigravity.rawValue)
            return [server(command: answering.helperExecutableURL.path, arguments: answering.arguments)]
        case .writing:
            guard let writingServer else { return [] }
            let answering = writingServer.answering(provider: AgentChatWireProvider.antigravity.rawValue)
            return [server(command: answering.helperExecutableURL.path, arguments: answering.arguments)]
        }
    }

    private static func server(command: String, arguments: [String]) -> [String: Any] {
        ["name": "lamp", "command": command, "args": arguments, "env": [[String: String]]()]
    }

    /// Lamp's own MCP tools, by name, as `lamp-mcp` offers them; a test holds
    /// this to the helper's catalogue.
    public static let lampToolNames: Set<String> = [
        "add_reading_plan", "analyze_strongs", "build_deck", "draft_reading_plan", "find_place", "import_writings",
        "list_book_sections", "list_books", "list_chats", "list_modules", "list_quiz_modules",
        "list_reading_plans", "list_writings", "lookup_dictionary_keys", "plan_writing_import",
        "read_book_section", "read_chat", "read_commentary", "read_devotional", "read_passage",
        "prepare_video", "read_plan_day", "read_quiz_questions", "read_skill", "read_study_material", "read_writing",
        "render_animation", "render_deck", "search_dictionary", "search_library", "start_writing", "validate_deck",
        "write_writing_draft", "writing_changes", "writing_import_status",
    ]

    /// The answer to an agent's `session/request_permission`, as the option
    /// to pick. Nothing is ever allowed always: each call is judged.
    ///
    /// - Lamp's own tools (`mcp_lamp_…`) are allowed: they are read-only but
    ///   for the writes each answers to its own setting.
    /// - A read is allowed inside the workspace, or inside Antigravity's own
    ///   folder for the session, where it puts a long tool result and then
    ///   reads it back.
    /// - A writing's agent may edit files inside its workspace, as Claude
    ///   Code's does under acceptEdits.
    /// - A question with set choices (a `toolCallId` beginning
    ///   `interaction_`) is turned down: nobody is there to answer it.
    /// - Everything else — commands, the web, schedules, subagents, writes
    ///   outside — is turned down. Work that outlives a turn would go on
    ///   after Lamp had stopped listening.
    public static func decide(
        permission params: [String: Any], readOnly: Bool, workspace: URL, home: URL, sessionID: String?
    ) -> String? {
        guard let options = params["options"] as? [[String: Any]] else { return nil }
        func option(_ kind: String) -> String? {
            options.first { $0["kind"] as? String == kind }?["optionId"] as? String
        }
        let reject = option("reject_once") ?? option("reject_always")
        guard let call = params["toolCall"] as? [String: Any] else { return reject }
        if (call["toolCallId"] as? String)?.hasPrefix("interaction_") == true { return reject }
        let name = call["name"] as? String ?? ""
        let kind = call["kind"] as? String ?? ""
        let paths = (call["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        // Only this session's own folder: never another session's.
        // Where it puts a long tool result to read back, and nothing else of
        // its own: not the rest of this session's folder, nor another's.
        let agentFolder = sessionID.map {
            home.appendingPathComponent(".gemini/antigravity-cli/brain/\($0)/.system_generated", isDirectory: true)
        }
        func inside(_ root: URL?) -> Bool {
            guard let root else { return false }
            return !paths.isEmpty && paths.allSatisfy { confined($0, to: root) }
        }
        let allowed: Bool
        if name.hasPrefix("mcp_lamp_"), lampToolNames.contains(String(name.dropFirst("mcp_lamp_".count))) {
            // By the exact name of one of Lamp's tools: another server
            // called `lamp_admin` would flatten to the same prefix.
            allowed = true
        } else if kind == "read" {
            allowed = inside(workspace) || inside(agentFolder)
        } else if kind == "edit" {
            allowed = !readOnly && inside(workspace)
                && !paths.contains { startsAProvider($0, in: workspace) }
        } else {
            allowed = false
        }
        return allowed ? option("allow_once") : reject
    }

    /// The tool name an Antigravity command carries on Lamp's approval card.
    public static let commandToolName = "agy.command"

    /// A writing chat's request to run a command, to put to the person: one
    /// of kind `execute` whose command is given whole (`rawInput.CommandLine`,
    /// as `agy acp` 1.5.14 sends it; recorded), offering a once-only allow.
    /// Never its title or summary as the command, which are the agent's
    /// words about it. Nil for anything else, which `decide` answers by rule,
    /// and always in a reader chat, which never asks (`decisions/0039`).
    public static func commandRequest(permission params: [String: Any], readOnly: Bool, id: String) -> AgentToolApprovalRequest? {
        guard !readOnly,
              let call = params["toolCall"] as? [String: Any], call["kind"] as? String == "execute",
              let input = call["rawInput"] as? [String: Any],
              let command = input["CommandLine"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              option("allow_once", in: params) != nil, option("reject_once", in: params) != nil
        else { return nil }
        var shown: [String: Any] = ["command": command]
        if let folder = input["Cwd"] as? String ?? call["cwd"] as? String, !folder.isEmpty { shown["cwd"] = folder }
        let data = (try? JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return AgentToolApprovalRequest(id: id, toolName: commandToolName, toolInputJSON: String(decoding: data, as: UTF8.self))
    }

    /// The answer to a command put to the person: its once-only option, never
    /// "always", which Antigravity saves as a rule in the person's settings
    /// (and which would then refuse every Antigravity reader chat).
    public static func outcome(for answer: AgentToolApprovalAnswer, permission params: [String: Any]) -> [String: Any] {
        let kind: String
        if case .allow = answer { kind = "allow_once" } else { kind = "reject_once" }
        guard let option = option(kind, in: params) else { return ["outcome": "cancelled"] }
        return ["outcome": "selected", "optionId": option]
    }

    private static func option(_ kind: String, in params: [String: Any]) -> String? {
        (params["options"] as? [[String: Any]])?.first { $0["kind"] as? String == kind }?["optionId"] as? String
    }

    /// Whether an edit at `path` would write what a provider is started
    /// from, by name: anything under a hidden name at the top of the
    /// workspace (`.mcp.json`, `.claude/`, `.agents/`, `.codex/`,
    /// `.opencode/`, Lamp's `.lamp/`), or OpenCode's `opencode.json`,
    /// judged where the path lands, so `alias/settings.json` with `alias` a
    /// link to `.claude` counts. Only `.lamp-renders`, the agent's scratch
    /// folder, is free.
    ///
    /// The boundary: this stops Antigravity's edit tool writing launch
    /// configuration. It does not follow links out of a guarded folder to
    /// what they lead to, and need not: making such a link takes a command,
    /// which is never allowed by rule (it is put to the person), and a writer
    /// able to make one could have written the file itself (`decisions/0038`).
    static func startsAProvider(_ path: String, in workspace: URL) -> Bool {
        guard let landing = resolved(path), let root = resolved(workspace.path) else { return true }
        let inside = root == "/" ? landing : String(landing.dropFirst(root.count))
        guard let first = inside.split(separator: "/").first.map(String.init) else { return true }
        if first == ".lamp-renders" { return false }
        return first.hasPrefix(".") || ["opencode.json", "opencode.jsonc"].contains(first.lowercased())
    }

    /// Whether `path`, as the filesystem will treat it, stays within
    /// `root`. Absolute paths only, and no `.` or `..` parts, since a
    /// symlinked folder followed by `..` means something other than the
    /// text says. The deepest part of the path that exists is resolved with
    /// `realpath`, without following a final symlink first, so a link out of
    /// the folder, or a file to be created inside one, is judged by where it
    /// lands. A dangling link is refused.
    static func confined(_ path: String, to root: URL) -> Bool {
        guard let resolvedPath = resolved(path), let resolvedRoot = resolved(root.path) else { return false }
        if resolvedRoot == "/" { return true }
        return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    private static func resolved(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else { return nil }
        var existing = parts
        var missing: [String] = []
        while !existing.isEmpty {
            var info = stat()
            if lstat("/" + existing.joined(separator: "/"), &info) == 0 { break }
            // Only a part that is not there is passed over; any other
            // failure means the path can't be judged.
            guard errno == ENOENT else { return nil }
            missing.insert(existing.removeLast(), at: 0)
        }
        // A file can only be made under a folder.
        if !missing.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: "/" + existing.joined(separator: "/"), isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
        }
        guard let real = realpath("/" + existing.joined(separator: "/"), nil) else { return nil }
        defer { free(real) }
        let base = String(cString: real)
        return missing.isEmpty ? base : (base == "/" ? "" : base) + "/" + missing.joined(separator: "/")
    }
}

/// One Codex writing-chat turn over `codex app-server`, so a command Codex
/// wants to run outside its sandbox — Blender reaching the GPU, which the
/// sandbox never opens — is put to the person rather than refused unasked,
/// as `codex exec` refuses every such request (`decisions/0028`). Reader
/// chats stay on `codex exec`, which can never ask.
///
/// A turn is one process, as with the other CLIs: `initialize`, then
/// `thread/start` or `thread/resume`, then `turn/start`, ending at
/// `turn/completed`; closing its input ends the server (0.07 s, measured).
/// The messages are those Codex 0.170 sends, pinned by a recorded turn in
/// `AgentCodexRunTests`; the protocol is labelled experimental, so anything
/// else Codex asks of Lamp is answered as a refusal, never by guessing.
public enum AgentCodexRun {
    /// The tool name a Codex command request carries on Lamp's approval
    /// card, where Claude's carry `Bash` and the like.
    public static let commandToolName = "codex.command"

    /// How long a request waits for the person before it is declined: the
    /// Claude hook's wait, so both providers' cards behave alike.
    public static let answerSeconds = Double(ClaudePermissionHook.waitSeconds)

    /// The server, with Lamp's own MCP server and the chosen thinking level
    /// on its command line, where Codex reads settings for a folder it has
    /// not been told to trust.
    public static func launchArguments(writingServer: LampAgentMCPConfiguration?, effort: String?) -> [String] {
        ["app-server"]
            + (writingServer?.codexWritingOverrides ?? [])
            + AgentChatEffortChoice.arguments(for: effort, provider: .codex)
    }

    public static func initialize() -> [String: Any] {
        ["clientInfo": ["name": "lamp-bible", "title": "Lamp Bible", "version": "1"]]
    }

    /// `thread/resume` for a thread Lamp has, else `thread/start`, with the
    /// sandbox, the approval policy and who answers set every time: a
    /// person whose Codex settings name `auto_review` would otherwise have
    /// a model answer, and one whose settings say `never` would never be
    /// asked. A thread `codex exec` made resumes here (tried).
    public static func open(threadID: String?, workspace: URL, model: String?) -> (method: String, params: [String: Any]) {
        var params: [String: Any] = [
            "cwd": workspace.path,
            "sandbox": "workspace-write",
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
        ]
        if let model = AgentChatModelChoice.canonical(model) { params["model"] = model }
        guard let threadID else { return ("thread/start", params) }
        params["threadId"] = threadID
        // Its earlier turns are Codex's to keep; the chat has its own copy.
        params["excludeTurns"] = true
        return ("thread/resume", params)
    }

    public static func turn(threadID: String, text: String) -> [String: Any] {
        ["threadId": threadID, "input": [["type": "text", "text": text]]]
    }

    public static func interrupt(threadID: String, turnID: String) -> [String: Any] {
        ["threadId": threadID, "turnId": turnID]
    }

    /// What Lamp does with a request Codex makes of it.
    public enum Reply {
        /// Put to the person on the approval card; answered by `decision`.
        case ask(AgentToolApprovalRequest)
        /// Answered at once with this result.
        case answer([String: Any])
        /// Answered at once as an error: a request Lamp has no part in.
        case refuse(String)
    }

    /// Only a command, named in full and asked about for the sandbox, comes
    /// to the person. Everything else is turned down where it stands, the
    /// turn going on without it:
    ///
    /// - a network prompt (`networkApprovalContext`): an escalated command
    ///   is already unsandboxed and its card says so; this is the managed
    ///   network asking for a host, which the card cannot put plainly;
    /// - a file change outside the workspace: what it writes is not in the
    ///   request, and a card must show what it allows;
    /// - more permissions for the rest of the turn, a question for the
    ///   person, an MCP server's form, and the older approval messages.
    public static func reply(to method: String, params: [String: Any], id: String) -> Reply {
        switch method {
        case "item/commandExecution/requestApproval":
            let kind = params["kind"] as? String ?? "command"
            guard kind == "command",
                  params["networkApprovalContext"] == nil || params["networkApprovalContext"] is NSNull,
                  let command = (params["command"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            else { return .answer(["decision": "decline"]) }
            var input: [String: Any] = ["command": shown(command)]
            if let cwd = params["cwd"] as? String, !cwd.isEmpty { input["cwd"] = cwd }
            if let reason = params["reason"] as? String, !reason.isEmpty { input["reason"] = reason }
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return .ask(AgentToolApprovalRequest(
                id: id, toolName: commandToolName, toolInputJSON: String(decoding: data, as: UTF8.self)
            ))
        case "item/fileChange/requestApproval":
            return .answer(["decision": "decline"])
        case "item/permissions/requestApproval":
            return .answer(["permissions": [String: Any](), "scope": "turn"])
        case "item/tool/requestUserInput":
            return .answer(["answers": [String: Any]()])
        case "mcpServer/elicitation/request":
            return .answer(["action": "decline"])
        case "applyPatchApproval", "execCommandApproval":
            return .answer(["decision": "denied"])
        default:
            return .refuse("Lamp does not provide \(method).")
        }
    }

    /// The answer to a command request. Only Allow Once and Deny: never
    /// Codex's own remembered approvals, which write a rule into the
    /// person's Codex settings for every session on the Mac, reader chats
    /// included. `decline` lets the turn go on, telling Codex no; Codex
    /// 0.170 accepts it though its request lists only `accept`, the rule
    /// and `cancel` (recorded).
    public static func decision(_ answer: AgentToolApprovalAnswer) -> [String: Any] {
        if case .allow = answer { return ["decision": "accept"] }
        return ["decision": "decline"]
    }

    /// A request's identity, as Lamp keys its card: Codex numbers its own
    /// requests from 0, apart from Lamp's.
    public static func requestKey(_ id: Any) -> String? {
        if let number = id as? Int { return "codex-\(number)" }
        if let text = id as? String { return "codex-\(text)" }
        return nil
    }

    /// The command as it will run, without the `zsh -lc '…'` Codex puts
    /// round it, where that is all it is: a single-quoted body holds no
    /// quote of its own, so nothing is hidden by taking it out.
    static func shown(_ command: String) -> String {
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            let prefix = "\(shell) -lc '"
            guard command.hasPrefix(prefix), command.hasSuffix("'"), command.count > prefix.count + 1 else { continue }
            let body = command.dropFirst(prefix.count).dropLast()
            if !body.contains("'") { return String(body) }
        }
        return command
    }

    /// Messages Lamp reads nothing from, dropped as they arrive: a command's
    /// output streams line by line for as long as it runs, and a render's
    /// log is long. Each still counts as the turn saying something.
    public static func isUnread(_ message: [String: Any]) -> Bool {
        guard message["id"] == nil, let method = message["method"] as? String else { return false }
        return unread.contains(method)
    }

    private static let unread: Set<String> = [
        "item/commandExecution/outputDelta", "item/fileChange/outputDelta", "command/exec/outputDelta",
        "process/outputDelta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta",
        "item/reasoning/summaryPartAdded", "item/plan/delta", "thread/tokenUsage/updated",
        "account/rateLimits/updated", "hook/started", "hook/completed", "mcpServer/startupStatus/updated",
    ]

    /// Keeps a turn's commentary out of its reply. Codex streams what it says
    /// on the way ("I'll check the folder, then…") in the same deltas as its
    /// answer; only the item's start says which it is.
    public struct Commentary {
        private var ids: Set<String> = []

        public init() {}

        /// Whether `message` is commentary, to be left out of the reply.
        public mutating func isCommentary(_ message: [String: Any]) -> Bool {
            let params = message["params"] as? [String: Any]
            switch message["method"] as? String {
            case "item/started", "item/completed":
                guard let item = params?["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                      item["phase"] as? String == "commentary", let id = item["id"] as? String
                else { return false }
                ids.insert(id)
                return true
            case "item/agentMessage/delta":
                return (params?["itemId"] as? String).map(ids.contains) ?? false
            default:
                return false
            }
        }
    }
}

/// Every process a run has started, recorded as the run goes, so ending the
/// run reaches the ones that left its process group.
///
/// A process group holds what a CLI starts unless it leaves on purpose, and
/// some do: Claude Code's Bash commands and Codex's command runner each
/// start a session of their own. While the CLI runs it ends them itself;
/// if it crashes, they are orphaned — handed to launchd, no longer anyone's
/// descendants — and could go on rewriting a draft after the turn was
/// saved, or after an undo. So the run's descendants are sampled every
/// couple of seconds and once more at the end, each known by its number
/// and start time, and what is still running with that identity is ended.
/// A known process's own children are found from it, so an orphan's
/// children are found too.
///
/// Spared: OpenCode's shared background server, which `opencode run` can
/// start and which serves every OpenCode session, not this run — a process
/// leading its own group whose program is `opencode` and whose arguments
/// are `serve --service`, as OpenCode 2 starts it. Only that: a detached
/// `opencode run`, `codex` or `claude` a tool started is this run's work.
///
/// Sampling narrows rather than closes the gap: a command started and
/// orphaned between two samples is never seen. Closing it would take
/// tracing every fork, which macOS offers apps no way to do.
public final class AgentRunMembers: @unchecked Sendable {
    public struct Member: Hashable, Sendable {
        public let pid: pid_t
        public let startedSeconds: Int
        public let startedMicroseconds: Int32
    }

    private struct Row {
        let member: Member
        let parent: pid_t
        let group: pid_t
        let name: String
    }


    private let lock = NSLock()
    private let root: Member?
    private var known: [pid_t: Member] = [:]
    /// Set by `endAll`, after which nothing more is recorded: a sample
    /// still running when the run ended must not add to what was ended.
    private var ended = false
    /// Held for the whole of `endAll`, so a second caller — a stop's grace
    /// period and the run's own end — returns only once the kills are sent.
    private let ending = NSLock()

    public init(rootPID: pid_t) {
        root = Self.table().first { $0.member.pid == rootPID }?.member
    }

    /// Records every descendant of the run's process, and of every process
    /// already recorded, that is running now.
    public func sample() {
        let table = Self.table()
        var children: [pid_t: [Row]] = [:]
        for row in table { children[row.parent, default: []].append(row) }
        let alive = Dictionary(table.map { ($0.member.pid, $0.member) }, uniquingKeysWith: { first, _ in first })
        let rows = Dictionary(table.map { ($0.member.pid, $0) }, uniquingKeysWith: { first, _ in first })
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        // One recorded before it became a shared service is let go, and is
        // not searched: its children are other sessions' work.
        for (pid, member) in known {
            if let row = rows[pid], row.member == member, Self.isSpared(row) { known[pid] = nil }
        }
        var frontier: [pid_t] = []
        if let root, alive[root.pid] == root { frontier.append(root.pid) }
        frontier += known.values.filter { alive[$0.pid] == $0 }.map(\.pid)
        var seen = Set(frontier)
        while let next = frontier.popLast() {
            for child in children[next] ?? [] where !seen.contains(child.member.pid) {
                seen.insert(child.member.pid)
                if Self.isSpared(child) { continue }
                known[child.member.pid] = child.member
                frontier.append(child.member.pid)
            }
        }
    }

    /// Looks once more, then kills every recorded process still running as
    /// the process it was recorded as, and the group of any that leads one.
    public func endAll() {
        ending.lock()
        defer { ending.unlock() }
        sample()
        let table = Self.table()
        let alive = Dictionary(table.map { ($0.member.pid, $0) }, uniquingKeysWith: { first, _ in first })
        lock.lock()
        ended = true
        let members = Array(known.values)
        known = [:]
        lock.unlock()
        for member in members {
            // Judged as it is now: a process keeps its number and start
            // time when it replaces itself with another program, so one
            // recorded as a launcher may since have become an agent's server.
            guard let row = alive[member.pid], row.member == member, !Self.isSpared(row) else { continue }
            if row.group == member.pid { killpg(member.pid, SIGKILL) }
            kill(member.pid, SIGKILL)
        }
    }

    /// How many processes have been recorded; for tests.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return known.count
    }

    private static func isSpared(_ row: Row) -> Bool {
        // Arguments only for a candidate: reading them is a second call.
        guard row.group == row.member.pid, row.name == "opencode" else { return false }
        return isSpared(name: row.name, pid: row.member.pid, group: row.group,
                        arguments: arguments(of: row.member.pid) ?? [])
    }

    /// OpenCode's background service: leading its own group, its program
    /// `opencode` — the kernel's name for it, which is its program file's,
    /// so a link named like one does not count — started as
    /// `opencode serve --service`.
    static func isSpared(name: String, pid: pid_t, group: pid_t, arguments: [String]) -> Bool {
        group == pid && name == "opencode" && Array(arguments.dropFirst()) == ["serve", "--service"]
    }

    /// A process's arguments, its program's name first, from the kernel; nil
    /// if they cannot be read.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // The argument count, the executable's path, padding, then the
        // arguments, each ended by a zero byte.
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private static func table() -> [Row] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / stride).map { process in
            var command = process.kp_proc.p_comm
            let name = withUnsafeBytes(of: &command) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let started = process.kp_proc.p_un.__p_starttime
            return Row(
                member: Member(pid: process.kp_proc.p_pid, startedSeconds: started.tv_sec,
                               startedMicroseconds: started.tv_usec),
                parent: process.kp_eproc.e_ppid,
                group: process.kp_eproc.e_pgid,
                name: name
            )
        }
    }
}

extension AgentChatFileLink {
    /// Whether every track of the movie or sound at `url` holds its own
    /// media, as `prepare_video` requires of a source; true for what is not
    /// a movie (a picture, a PDF). Asked from a background thread, which it
    /// holds until AVFoundation answers.
    public static func holdsItsOwnMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              type.conforms(to: .audiovisualContent)
        else { return true }
        let answer = AgentChatFileLinkAnswer()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let tracks = try? await AVURLAsset(url: url).load(.tracks) else { return }
            for track in tracks where (try? await track.load(.isSelfContained)) != true { return }
            answer.set(true)
        }
        done.wait()
        return answer.value
    }
}

private final class AgentChatFileLinkAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}
