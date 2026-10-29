import Foundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import LampModuleKit
import MCP

public actor LampMCPToolHandler {
    private let library: LampAgentLibrary
    /// Where the library is, for the one tool that needs the path rather than
    /// the library's own API: drawing a deck checks its quotations against the
    /// installed translations. `LampAgentLibrary` does not publish its root,
    /// and this is not reason enough to make it.
    private let libraryRootURL: URL?
    /// Where the descriptor is, which carries the writing switch. Injected
    /// rather than looked up, so the check can be tested without reading the
    /// machine's own Application Support — an untestable permission check is
    /// one nobody can be sure of.
    private let applicationSupportURL: URL?
    private let policyURL: URL?
    /// The agent workspace this session serves, when it has one. Only the
    /// writing's own history is reachable, and only to read.
    private let workspaceURL: URL?
    private let encoder: JSONEncoder
    /// The policy as last read, kept because some tools have to ask about it
    /// rather than let the library enforce it.
    ///
    /// Starts at the default, where personal content is *not* included, so a
    /// session with no policy file to read denies it. Failing closed is the
    /// only safe direction for a permission: a missing answer must not read as
    /// yes.
    /// The policy as last read.
    ///
    /// Given at startup rather than left at the default, so it cannot
    /// disagree with the library it was handed: a session started without a
    /// policy file to re-read would otherwise deny personal content that the
    /// library itself permits. Still defaults to the policy where personal
    /// content is *not* included, because a missing answer must not read as
    /// yes.
    private var policy: LampAgentAccessPolicy

    /// Whether outside apps may change a writing, read from the descriptor at
    /// each call rather than held from startup: the setting can be turned off
    /// while an app is connected, and the next write should see that.
    private var allowsExternalWriting: Bool {
        guard let applicationSupportURL else { return false }
        return (try? LampAgentDescriptorStore.read(inApplicationSupport: applicationSupportURL))?
            .allowsExternalWriting ?? false
    }

    public init(
        library: LampAgentLibrary,
        libraryRootURL: URL? = nil,
        applicationSupportURL: URL? = LampAgentDescriptorStore.defaultApplicationSupportURL(),
        policy: LampAgentAccessPolicy = LampAgentAccessPolicy(),
        policyURL: URL? = nil,
        workspaceURL: URL? = nil
    ) {
        self.library = library
        self.libraryRootURL = libraryRootURL
        self.applicationSupportURL = applicationSupportURL
        self.policy = policy
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

        case "validate_deck":
            return try result(LampDeckTools.validate(
                deckJSON: try deckJSON(arguments)
            ))

        case "build_deck":
            let built = try LampDeckTools.build(
                deckJSON: try deckJSON(arguments),
                manuscript: arguments["manuscript"]?.stringValue
            )
            // The deck itself goes back as text beside the report, since a
            // caller with no folder cannot read it off disk afterwards.
            return CallTool.Result(
                content: [
                    .text(
                        text: String(decoding: built.reportJSON, as: UTF8.self),
                        annotations: nil,
                        _meta: nil
                    ),
                    .text(
                        text: String(decoding: built.deckJSON, as: UTF8.self),
                        annotations: nil,
                        _meta: nil
                    ),
                ],
                structuredContent: Value?.some(
                    try structuredContent(from: built.reportJSON)
                ),
                isError: !built.resolved
            )

        case "render_deck":
            return try await renderDeck(arguments)

        case "list_writings":
            try requirePersonalContent()
            return try result(LampWritingWorkspace.listed(
                libraryRootURL: try writingLibraryRoot()
            ))

        case "read_writing":
            try requirePersonalContent()
            return try result(try readWriting(arguments))

        case "write_writing_draft":
            return try await writeWritingDraft(arguments)

        default:
            throw LampMCPToolError.unknownTool(name)
        }
    }

    /// A deck's JSON from the arguments, as text rather than a path: the
    /// apps this is for have no folder to put a file in.
    private func deckJSON(_ arguments: [String: Value]) throws -> Data {
        Data(try requiredString("deck", in: arguments).utf8)
    }

    /// Draws the slides and sends the pictures back with the report.
    ///
    /// Each image is its own content item, titled, because a client shows them
    /// in order and the reader needs to know which slide they are looking at.
    private func renderDeck(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let slides = strings(arguments["slides"])?.compactMap(Int.init)
        let rendered = try await LampDeckTools.render(
            deckJSON: try deckJSON(arguments),
            manuscript: arguments["manuscript"]?.stringValue,
            libraryRoot: libraryRootURL,
            slideNumbers: slides?.isEmpty == true ? nil : slides,
            width: Double(arguments["width"]?.intValue ?? 1_600)
        )
        var content: [Tool.Content] = [
            .text(
                text: String(decoding: rendered.reportJSON, as: UTF8.self),
                annotations: nil,
                _meta: nil
            ),
        ]
        if !rendered.unreadable.isEmpty {
            content.append(.text(
                text: "These slides were drawn but their pictures could not be read back: "
                    + rendered.unreadable.map(String.init).joined(separator: ", ")
                    + ".",
                annotations: nil,
                _meta: nil
            ))
        }
        for image in rendered.images {
            content.append(.text(
                text: "Slide \(image.slideNumber): \(image.title)",
                annotations: nil,
                _meta: nil
            ))
            content.append(.image(
                data: image.pngData.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            ))
        }
        return CallTool.Result(
            content: content,
            structuredContent: Value?.some(
                try structuredContent(from: rendered.reportJSON)
            ),
            isError: false
        )
    }

    /// The writing as the library holds it, for comparing against what the
    /// caller read — or nil when there is nothing comparable to compare.
    ///
    /// This is a second, earlier guard. It catches the writer editing in
    /// Lamp's own editor, which never reaches `draft.md`, and so gives the
    /// agent a refusal at write time rather than a surprise at import. The
    /// guard that actually protects the writer's words is the one at import,
    /// which compares the note's base against Lamp's own full copy of the
    /// writing; so where this returns nil, nothing is lost but the early
    /// warning.
    ///
    /// Nil for two reasons, and only these two. A writing that exists as a
    /// workspace and not in the library has nothing to compare. And a writing
    /// past the read limit comes back truncated, with a marker appended:
    /// hashing that against a full draft would refuse *every* write to a long
    /// writing, and tell the writer their own editing was the cause.
    ///
    /// Any other failure refuses. A read that did not work is not permission
    /// to skip the check.
    private func writingAsLampHoldsIt(_ writingID: String) async throws -> String? {
        do {
            let text = try await library.readDevotional(
                moduleID: "personal-devotionals", devotionalID: writingID
            ).content
            // `limitedText` appends its notice, so a truncated result is
            // always longer than the limit it was cut to.
            return text.count > policy.maximumItemCharacters ? nil : text
        } catch LampAgentError.itemNotFound {
            return nil
        }
    }

    /// Replaces a writing's draft, if the writer has not moved it underneath.
    ///
    /// The switch is checked here rather than by hiding the tool, so an app
    /// that was told about the tool can tell its user which setting to change.
    private func writeWritingDraft(_ arguments: [String: Value]) async throws -> CallTool.Result {
        try requirePersonalContent()
        guard allowsExternalWriting else { throw LampMCPToolError.writingNotAllowed }
        let root = try writingLibraryRoot()
        let writingID = try requiredString("writing_id", in: arguments)
        let draft = try requiredString("draft", in: arguments)
        let basedOn = try requiredString("based_on", in: arguments)

        let libraryText = try await writingAsLampHoldsIt(writingID)

        let note = try LampWritingWrite.writeDraft(
            libraryRootURL: root,
            applicationSupportURL: applicationSupportURL,
            writingID: writingID,
            draft: draft,
            basedOn: basedOn,
            libraryText: libraryText
        )
        return try result(WritingWriteOutcome(
            writingID: writingID,
            saved: true,
            draftFingerprint: note.draftFingerprint,
            // Said plainly, because it has not been imported yet and a reply
            // that implied otherwise would be the one thing worth getting
            // right here.
            message: """
            Saved to the writing's draft. Lamp will bring it in when you next \
            open this writing's agent workspace.
            """
        ))
    }

    /// Reading or changing a writing is reading or changing personal content,
    /// so it answers to the same setting as the rest of it.
    private func requirePersonalContent() throws {
        guard policy.isEnabled else { throw LampMCPToolError.accessDisabled }
        guard policy.includesPersonalContent else {
            throw LampMCPToolError.personalContentNotAllowed
        }
    }

    /// Where the workspaces are. A writing tool needs the library's path, and
    /// a session started without one cannot serve them.
    private func writingLibraryRoot() throws -> URL {
        guard let libraryRootURL else { throw LampMCPToolError.noLibraryRoot }
        return libraryRootURL
    }

    private func readWriting(_ arguments: [String: Value]) throws -> WritingDraft {
        let root = try writingLibraryRoot()
        let writingID = try requiredString("writing_id", in: arguments)
        guard LampWritingWorkspace.exists(libraryRootURL: root, writingID: writingID) else {
            throw LampMCPToolError.noWritingWorkspace(writingID)
        }
        let draft = try LampWritingWorkspace.readDraft(
            libraryRootURL: root, writingID: writingID
        )
        return WritingDraft(
            writingID: writingID,
            title: LampWritingWorkspace.title(ofDraft: draft),
            draft: draft,
            context: arguments["include_context"]?.boolValue ?? true
                ? LampWritingWorkspace.readContext(libraryRootURL: root, writingID: writingID)
                : nil
        )
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
        self.policy = policy
        await library.updatePolicy(policy)
    }

    private func result<Output: Codable & Sendable>(_ output: Output) throws -> CallTool.Result {
        let data = try encoder.encode(output)
        let text = String(decoding: data, as: UTF8.self)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: Value?.some(try structuredContent(from: data)),
            isError: false
        )
    }

    /// MCP requires `structuredContent` to be a JSON *object*. Most Lamp tools
    /// answer with a list, and sending that list bare makes a client that
    /// validates the result — Claude Code does — reject every call. A list is
    /// therefore named rather than dropped, so structured consumers keep it.
    ///
    /// Built by reading back what was already encoded, rather than encoding the
    /// answer a second time through `Value`. The second encoding used the SDK's
    /// own defaults, which write a `Date` as seconds from Apple's 2001 epoch
    /// while the text beside it read ISO 8601 — two answers to one question,
    /// and `writing_changes` takes only one of them back as `since`.
    private func structuredContent(from data: Data) throws -> Value {
        let encoded = try JSONDecoder().decode(Value.self, from: data)
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

/// What a write did, as the calling app is told it.
struct WritingWriteOutcome: Codable, Sendable {
    var writingID: String
    var saved: Bool
    var draftFingerprint: String
    var message: String
}

/// A writing's draft and the context Lamp wrote beside it.
struct WritingDraft: Codable, Sendable {
    var writingID: String
    var title: String?
    var draft: String
    var context: String?
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
    case accessDisabled
    case personalContentNotAllowed
    case noLibraryRoot
    case noWritingWorkspace(String)
    case writingNotAllowed

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
        case .accessDisabled:
            """
            Lamp is not letting agents use the library. Turn on "Allow agents \
            to query Lamp modules" in Lamp's Settings, under AI & Agents.
            """
        case .personalContentNotAllowed:
            """
            Lamp is not sharing personal writing. Turn on "Include personal \
            writing, notes, and highlights" in Lamp's Settings, under AI & \
            Agents, to read it here.
            """
        case .noLibraryRoot:
            "This session was started without a library, so it has no writings."
        case .writingNotAllowed:
            """
            Lamp is not letting other apps change writings. Turn on "Allow \
            other apps to change my writings" in Lamp's Settings, under AI & \
            Agents. It is separate from reading, and off until the writer \
            turns it on.
            """
        case .noWritingWorkspace(let id):
            """
            The writing \(id) has no agent workspace. Open it in Lamp and \
            show its agent pane once; Lamp writes the workspace, because it \
            holds the context document and instructions that belong in it. \
            Use list_writings for the writings that have one.
            """
        }
    }
}
