import Foundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import LampModuleKit
import MCP

public actor LampMCPToolHandler {
    private let library: LampAgentLibrary
    private let policyURL: URL?
    /// The agent workspace this session serves, when it has one. Only the
    /// writing's own history is reachable, and only to read.
    private let workspaceURL: URL?
    private let encoder: JSONEncoder

    public init(
        library: LampAgentLibrary,
        policyURL: URL? = nil,
        workspaceURL: URL? = nil
    ) {
        self.library = library
        self.policyURL = policyURL
        self.workspaceURL = workspaceURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
    }

    public func call(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        try await refreshPolicy()
        let arguments = arguments ?? [:]
        switch name {
        case "list_modules":
            return try result(try await library.listModules(kinds: try kinds(arguments["kinds"])))

        case "search_library":
            return try result(try await library.searchLibrary(
                query: try requiredString("query", in: arguments),
                kinds: try kinds(arguments["kinds"]),
                moduleIDs: stringSet(arguments["module_ids"]),
                limit: arguments["limit"]?.intValue ?? 20
            ))

        case "read_passage":
            return try result(try await library.readPassage(
                reference: try requiredString("reference", in: arguments),
                translationIDs: strings(arguments["translation_ids"]),
                includeHeadings: arguments["include_headings"]?.boolValue ?? true,
                includeAnnotations: arguments["include_annotations"]?.boolValue ?? false
            ))

        case "read_commentary":
            return try result(try await library.readCommentary(
                reference: try requiredString("reference", in: arguments),
                moduleIDs: stringSet(arguments["module_ids"]),
                limit: arguments["limit"]?.intValue ?? 30
            ))

        case "search_dictionary":
            return try result(try await library.searchDictionary(
                query: try requiredString("query", in: arguments),
                moduleIDs: stringSet(arguments["module_ids"]),
                limit: arguments["limit"]?.intValue ?? 20
            ))

        case "lookup_dictionary_keys":
            return try result(try await library.lookupDictionaryKeys(
                try requiredStrings("keys", in: arguments),
                moduleIDs: stringSet(arguments["module_ids"])
            ))

        case "list_reading_plans":
            return try result(try await library.listReadingPlans())

        case "read_plan_day":
            return try result(try await library.readPlanDay(
                moduleID: try requiredString("module_id", in: arguments),
                day: try requiredInt("day", in: arguments)
            ))

        case "list_books":
            return try result(try await library.listBooks())

        case "list_book_sections":
            return try result(try await library.listBookSections(
                moduleID: try requiredString("module_id", in: arguments)
            ))

        case "read_book_section":
            return try result(try await library.readBookSection(
                moduleID: try requiredString("module_id", in: arguments),
                sectionID: try requiredString("section_id", in: arguments)
            ))

        case "read_devotional":
            return try result(try await library.readDevotional(
                moduleID: try requiredString("module_id", in: arguments),
                devotionalID: try requiredString("devotional_id", in: arguments)
            ))

        case "list_quiz_modules":
            return try result(try await library.listQuizModules(
                planID: arguments["plan_id"]?.stringValue
            ))

        case "read_quiz_questions":
            return try result(try await library.readQuizQuestions(
                moduleID: try requiredString("module_id", in: arguments),
                day: try requiredInt("day", in: arguments),
                reference: arguments["reference"]?.stringValue,
                ageGroup: arguments["age_group"]?.stringValue
            ))

        case "read_study_material":
            return try result(try await library.readStudyMaterial(
                reference: try requiredString("reference", in: arguments),
                translationID: try requiredString("translation_id", in: arguments)
            ))

        case "writing_changes":
            return try result(try writingChanges(arguments))

        default:
            throw LampMCPToolError.unknownTool(name)
        }
    }

    /// What has changed in the writing, as diffs.
    ///
    /// An agent is told `draft.md` changed but not what changed, and used to
    /// keep private copies of the draft to compare. Lamp has the revisions.
    private func writingChanges(_ arguments: [String: Value]) throws -> [WritingChange] {
        guard let workspaceURL else {
            throw LampMCPToolError.noWorkspace
        }
        let changes = try LampWritingChanges.changes(
            in: workspaceURL,
            documentPath: arguments["document_path"]?.stringValue
                ?? DevotionalAgentRevisionStore.primaryDocumentPath,
            since: LampWritingChanges.since(arguments["since"]?.stringValue),
            limit: arguments["limit"]?.intValue ?? 20,
            context: arguments["context"]?.intValue ?? LampUnifiedDiff.defaultContext
        )
        return changes.map { WritingChange($0) }
    }

    private func refreshPolicy() async throws {
        guard let policyURL else { return }
        let data = try Data(contentsOf: policyURL)
        let policy = try JSONDecoder().decode(LampAgentAccessPolicy.self, from: data)
        await library.updatePolicy(policy)
    }

    private func result<Output: Codable & Sendable>(_ output: Output) throws -> CallTool.Result {
        let data = try encoder.encode(output)
        let text = String(decoding: data, as: UTF8.self)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: Value?.some(try structuredContent(for: output)),
            isError: false
        )
    }

    /// MCP requires `structuredContent` to be a JSON *object*. Most Lamp tools
    /// answer with a list, and sending that list bare makes a client that
    /// validates the result — Claude Code does — reject every call. A list is
    /// therefore named rather than dropped, so structured consumers keep it.
    private func structuredContent<Output: Codable & Sendable>(
        for output: Output
    ) throws -> Value {
        let encoded = try Value(output)
        if case .object = encoded { return encoded }
        return .object(["results": encoded])
    }

    private func requiredString(
        _ name: String,
        in arguments: [String: Value]
    ) throws -> String {
        guard let value = arguments[name]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LampMCPToolError.missingArgument(name)
        }
        return value
    }

    private func requiredInt(_ name: String, in arguments: [String: Value]) throws -> Int {
        guard let value = arguments[name]?.intValue else {
            throw LampMCPToolError.missingArgument(name)
        }
        return value
    }

    private func requiredStrings(
        _ name: String,
        in arguments: [String: Value]
    ) throws -> [String] {
        guard let values = strings(arguments[name]), !values.isEmpty else {
            throw LampMCPToolError.missingArgument(name)
        }
        return values
    }

    private func strings(_ value: Value?) -> [String]? {
        value?.arrayValue?.compactMap(\.stringValue)
    }

    private func stringSet(_ value: Value?) -> Set<String>? {
        strings(value).map(Set.init)
    }

    private func kinds(_ value: Value?) throws -> Set<LampModuleKind>? {
        guard let rawKinds = strings(value) else { return nil }
        let parsed = rawKinds.compactMap(LampModuleKind.init(rawValue:))
        guard parsed.count == rawKinds.count else {
            let invalid = rawKinds.filter { LampModuleKind(rawValue: $0) == nil }
            throw LampMCPToolError.invalidArgument(
                "kinds",
                "Unsupported module kinds: \(invalid.joined(separator: ", "))"
            )
        }
        return Set(parsed)
    }
}

/// One change to the writing, as it is sent to an agent.
///
/// Named here rather than returned from the support layer directly, so what
/// goes over the wire is a deliberate shape — `kind` reads as `editor` or
/// `agent`, which is the question being asked.
struct WritingChange: Codable, Sendable {
    var id: String
    var at: Date
    var startedAt: Date
    var source: String
    var providerName: String?
    var documentPath: String
    var addedLines: Int
    var removedLines: Int
    var diff: String

    /// Not guarded by `canImport`: under Xcode the support sources compile
    /// into this target, so the type is here even though the module is not.
    init(_ change: LampWritingChanges.Change) {
        id = change.id.uuidString
        at = change.at
        startedAt = change.startedAt
        source = change.source.rawValue
        providerName = change.providerName
        documentPath = change.documentPath
        addedLines = change.addedLines
        removedLines = change.removedLines
        diff = change.diff
    }
}

public enum LampMCPToolError: Error, LocalizedError, Equatable, Sendable {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String, String)
    case noWorkspace

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "Unknown Lamp Bible tool: \(name)."
        case .missingArgument(let name):
            "The required ‘\(name)’ argument is missing or invalid."
        case .invalidArgument(let name, let message):
            "The ‘\(name)’ argument is invalid. \(message)"
        case .noWorkspace:
            "This session serves no agent workspace, so it has no writing history to read."
        }
    }
}
