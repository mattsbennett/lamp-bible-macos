import Foundation
import LampCore
import LampModuleKit
import MCP

public actor LampMCPToolHandler {
    private let library: LampAgentLibrary
    private let policyURL: URL?
    private let encoder: JSONEncoder

    public init(library: LampAgentLibrary, policyURL: URL? = nil) {
        self.library = library
        self.policyURL = policyURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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

        default:
            throw LampMCPToolError.unknownTool(name)
        }
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
        return try CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: output,
            isError: false
        )
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

public enum LampMCPToolError: Error, LocalizedError, Equatable, Sendable {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String, String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "Unknown Lamp Bible tool: \(name)."
        case .missingArgument(let name):
            "The required ‘\(name)’ argument is missing or invalid."
        case .invalidArgument(let name, let message):
            "The ‘\(name)’ argument is invalid. \(message)"
        }
    }
}
