import Foundation

public enum AgentChatWireProvider: String, Sendable {
    case codex
    case claude
    case openCode
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
        mode: AgentChatMode = .writing
    ) -> [String] {
        switch provider {
        case .codex:
            var arguments = [
                "exec", "--json", "--sandbox", mode.isReadOnly ? "read-only" : "workspace-write",
                "--skip-git-repo-check",
            ]
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
            if case .reader(let configuration) = mode {
                arguments += [
                    "--tools", "", "--allowedTools", "mcp__lamp__*",
                    "--strict-mcp-config", "--mcp-config", configuration.claudeJSON,
                    "--disable-slash-commands",
                ]
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
            if mode.isReadOnly { arguments += ["--pure", "--agent", "lamp-reader"] }
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

    /// What to tell the user, naming the provider as the UI names it.
    public static func message(provider: String) -> String {
        "\(provider) needs to be set up before it can answer here. Open the Terminal session to sign in and answer its first-run prompts, then come back to Chat."
    }
}

public enum AgentChatWireEvent: Equatable, Sendable {
    case sessionStarted(String)
    case textFragment(String)
    case finalText(String)
    case failure(String)
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
            guard let event = object.dictionary("event"),
                  let delta = event.dictionary("delta"),
                  delta.string("type") == "text_delta",
                  let text = delta.string("text"), !text.isEmpty
            else { return events }
            events.append(.textFragment(text))
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
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
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
