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
