import Foundation
import LampBibleMacSupport
import LampCore
import MCP
@testable import LampMCPServer
import Testing

struct LampMCPServerTests {
    /// Every tool is read-only except the one that writes, and that one says
    /// so.
    ///
    /// `readOnlyHint` is what makes an app ask before running something, so a
    /// write tool that claimed to be read-only would be rewriting someone's
    /// prose without the prompt they are entitled to. This test used to assert
    /// that *all* tools were read-only, which stopped being true the moment
    /// `write_writing_draft` existed.
    @Test func onlyTheWriteToolsSayTheyWrite() {
        let all = LampMCPToolCatalog.tools(workspace: true)
        #expect(LampMCPToolCatalog.tools.count == 17)
        #expect(LampMCPToolCatalog.deckTools.count == 3)
        #expect(LampMCPToolCatalog.writingTools.count == 2)
        #expect(LampMCPToolCatalog.writeTools.count == 2)
        #expect(all.count == 25)
        #expect(Set(all.map(\.name)).count == all.count)

        let writing = Set(LampMCPToolCatalog.writeTools.map(\.name))
        #expect(writing == ["write_writing_draft", "add_reading_plan"])
        for tool in all {
            if writing.contains(tool.name) {
                #expect(
                    tool.annotations.readOnlyHint == false,
                    "\(tool.name) must declare that it writes, or no app will ask first"
                )
            } else {
                #expect(
                    tool.annotations.readOnlyHint == true,
                    "\(tool.name) is not a write tool and should say it only reads"
                )
            }
        }
        #expect(all.allSatisfy {
            $0.inputSchema.objectValue?["type"]?.stringValue == "object"
        })
    }

    /// The write tool is offered whether or not the setting is on, because the
    /// server caches its tool list and an app cannot recommend a setting it
    /// was never told about. Being refused at call time is the design.
    @Test func thewriteToolIsAlwaysOfferedAndNamesItsSetting() throws {
        let tool = try #require(
            LampMCPToolCatalog.tools(workspace: false)
                .first { $0.name == "write_writing_draft" }
        )
        let description = try #require(tool.description)
        #expect(description.contains("Allow other apps to change my writings"))
        #expect(description.contains("Settings"))
    }

    /// The same for the plan tool, and the drafting tool beside it must stay
    /// read-only: showing someone the days before anything is added is the
    /// whole shape of this feature, and it cannot need a setting to do it.
    @Test func theplanToolsSayWhichOneChangesSomething() throws {
        let tools = LampMCPToolCatalog.tools(workspace: false)

        let adding = try #require(tools.first { $0.name == "add_reading_plan" })
        let description = try #require(adding.description)
        #expect(description.contains("Allow other apps to add reading plans"))
        #expect(description.contains("Settings"))
        #expect(adding.annotations.readOnlyHint == false)
        // A plan is a module that was not there before: nothing of the user's
        // is replaced or removed.
        #expect(adding.annotations.destructiveHint == false)

        let drafting = try #require(tools.first { $0.name == "draft_reading_plan" })
        #expect(drafting.annotations.readOnlyHint == true)
        // Both take the same arguments, or a plan previewed by one is not the
        // plan the other adds.
        #expect(
            drafting.inputSchema.objectValue?["properties"]
                == adding.inputSchema.objectValue?["properties"]
        )
    }

    /// Charts are worked out through the *agent* library, so a key is only
    /// ever counted in a translation the policy permits.
    ///
    /// With access turned off the refusal has to be said. Swallowed, it would
    /// look like a deck whose charts are simply empty, and an agent would go
    /// hunting through its own chart sources for a fault that is a setting.
    @Test func achartIsNotQuietlyEmptiedWhenAgentAccessIsOff() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-chart-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(
                libraryRootURL: fixture,
                policy: LampAgentAccessPolicy(isEnabled: false)
            )
        )
        let deck = """
        {"schemaVersion":1,"id":"60910124-99b3-48ca-9310-11c63ed118c0",
         "title":"Living Hope","aspectRatio":"widescreen",
         "theme":{"id":"lamp-dark","accentColor":"#F59E0B","backgroundColor":"#111827",
                  "foregroundColor":"#F9FAFB","typeface":"system-serif"},
         "source":{"id":"60910124-99b3-48ca-9310-11c63ed118c1","kind":"devotional"},
         "slides":[{"id":"3b184129-31c5-48c8-962e-fe79e2862cc8","layout":"title-and-body",
           "isHidden":false,"speakerNotes":"n","blocks":[
             {"id":"b1","kind":"title","text":"Living Hope"},
             {"id":"b2","kind":"chart","text":"Where","chart":{
               "source":{"strongs":"G26","translationID":"ESVs"},
               "by":"section","measure":"occurrences"}}]}]}
        """

        let response = try await handler.call(
            name: "build_deck", arguments: ["deck": .string(deck)]
        )
        let report = try #require(response.structuredContent?.objectValue)
        let problems = report["problems"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(
            problems.contains { $0.contains("did not work out this deck's charts") },
            "the report has to say the charts were not worked out: \(problems)"
        )
    }

    /// Three cautions belong in this description, each naming a way the
    /// numbers mislead whoever takes them at face value: a book marked "more"
    /// is above *chance*, not merely above average; a count is only as good as
    /// one translation's tagging; and a rendering is a translator's choice,
    /// not the word's meaning.
    ///
    /// They are tested because the description is the last place to say so.
    /// An agent reads it once, writes a talk from the figures, and nothing
    /// downstream will catch "Mark uses it more" standing in for a
    /// log-likelihood result.
    @Test func theStrongsToolWarnsAboutItsOwnNumbers() throws {
        let tool = try #require(
            LampMCPToolCatalog.tools.first { $0.name == "analyze_strongs" }
        )
        let description = try #require(tool.description)
        #expect(description.contains("chance"), "\"more\" must be pinned to chance")
        #expect(
            description.contains("name the translation"),
            "a count that does not name its translation reads as a fact about the Bible"
        )
        #expect(
            description.contains("lexicon"),
            "renderings are translators' choices; the description must point meaning elsewhere"
        )

        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["key"])
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(properties["translation_ids"] != nil)
        #expect(properties["range"] != nil)
    }

    /// Once, a session without a workspace was not offered the writing
    /// history at all, because there was nothing for it to report on. A
    /// writing can be named now, so it is offered either way — and refuses
    /// with the argument to pass when nothing names one.
    @Test func thewritingHistoryIsOfferedEitherWayAndSaysWhatItNeeds() async throws {
        for workspace in [true, false] {
            #expect(
                LampMCPToolCatalog.tools(workspace: workspace)
                    .contains { $0.name == "writing_changes" }
            )
        }
        let tool = try #require(
            LampMCPToolCatalog.workspaceTools.first { $0.name == "writing_changes" }
        )
        #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?["writing_id"] != nil)

        #expect(
            LampMCPToolError.noWorkspace.localizedDescription.contains("writing_id"),
            "the refusal has to name the argument that fixes it"
        )
    }

    @Test func refusesTheWritingHistoryWithoutAWorkspace() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(library: LampAgentLibrary(libraryRootURL: fixture))
        await #expect(throws: LampMCPToolError.noWorkspace) {
            try await handler.call(name: "writing_changes", arguments: nil)
        }
    }

    @Test func readsTheWritingHistoryOfTheWorkspaceItWasGiven() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        let workspace = fixture.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try DevotionalAgentRevisionStore.record(
            kind: .userEdit,
            before: "So on capacity there has been no meaningful change.",
            after: "But on this question of capacity, there has been no meaningful change.",
            in: workspace
        )

        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture),
            workspaceURL: workspace
        )
        let response = try await handler.call(name: "writing_changes", arguments: nil)
        #expect(response.isError == false)
        guard case .text(let text, _, _) = response.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("\"source\" : \"editor\""))
        #expect(text.contains("+But on this question of capacity"))
        #expect(text.contains("-So on capacity there has been no meaningful change."))

        // A time has to come back in the form `since` takes. It used to be
        // seconds from Apple's 2001 epoch in the structured copy and ISO 8601
        // in the text, so neither could be handed back without knowing which
        // was which.
        #expect(text.contains("\"at\" : \"20"))
        let structured = try #require(response.structuredContent)
        let changes = try #require(structured.objectValue?["results"]?.arrayValue)
        let at = try #require(changes.first?.objectValue?["at"]?.stringValue)
        guard case .time = LampWritingChanges.since(at) else {
            Issue.record("`at` should read back as a time: \(at)")
            return
        }
    }

    @Test func dispatchesAListCallWithStructuredContent() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture)
        )
        let response = try await handler.call(name: "list_modules", arguments: nil)
        #expect(response.isError == false)
        // MCP requires an object here. A bare array makes Claude Code reject
        // the call as a schema violation, which disabled every Lamp tool.
        #expect(response.structuredContent == .object(["results": .array([])]))
        guard case .text(let text, _, _) = response.content.first else {
            Issue.record("Expected a text representation")
            return
        }
        #expect(text == "[\n\n]")
    }

    @Test(arguments: [
        ("list_modules", [String: Value]()),
        ("list_reading_plans", [:]),
        ("list_books", [:]),
        ("search_library", ["query": .string("grace")]),
        ("list_quiz_modules", [:]),
        ("analyze_strongs", ["key": .string("G3056")]),
        // Answers with one object rather than a list of days, and does it
        // from no library at all: the layout is arithmetic, not a read.
        (
            "draft_reading_plan",
            [
                "name": .string("A Week in John"),
                "tracks": .array([.object(["passages": .array([.string("John")])])]),
                "reading_days": .int(7),
            ]
        ),
    ])
    func namesEveryStructuredResultAsAnObject(tool: String, arguments: [String: Value]) async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture)
        )
        let response = try await handler.call(name: tool, arguments: arguments)
        #expect(response.structuredContent?.objectValue != nil, "\(tool) must answer with an object")
    }

    @Test func rejectsUnknownToolsAndMissingArguments() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture)
        )
        await #expect(throws: LampMCPToolError.unknownTool("missing")) {
            try await handler.call(name: "missing", arguments: nil)
        }
        await #expect(throws: LampMCPToolError.missingArgument("reference")) {
            try await handler.call(name: "read_passage", arguments: [:])
        }
    }

    @Test func reloadsAccessPolicyBeforeEveryToolCall() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcp-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let policyURL = fixture.appendingPathComponent("policy.json")
        try JSONEncoder().encode(LampAgentAccessPolicy())
            .write(to: policyURL, options: .atomic)
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: fixture.appendingPathComponent("Library")),
            policyURL: policyURL
        )

        _ = try await handler.call(name: "list_modules", arguments: nil)
        try JSONEncoder().encode(LampAgentAccessPolicy.disabled)
            .write(to: policyURL, options: .atomic)

        await #expect(throws: LampAgentError.disabled) {
            try await handler.call(name: "list_modules", arguments: nil)
        }
    }
}

struct LampMCPClientCompatibilityTests {
    // Verbatim from Codex 0.156.1.
    private let codexInitialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.156.1"}}}"#

    @Test func codexsHandshakeDecodes() throws {
        let original = Data(codexInitialize.utf8)
        // The failure being worked around: the SDK can't decode it as sent.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Request<Initialize>.self, from: original)
        }

        let compatible = LampMCPServerFactory.compatibleClientMessage(original)
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: compatible)
        #expect(request.params.clientInfo.name == "codex-mcp-client")
        #expect(request.params.protocolVersion == "2025-06-18")
        #expect(request.params.capabilities.elicitation != nil)
    }

    @Test func everyOtherMessagePassesThroughUnchanged() {
        let messages = [
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#,
            "not json",
        ]
        for message in messages {
            let data = Data(message.utf8)
            #expect(LampMCPServerFactory.compatibleClientMessage(data) == data)
        }
    }

    // MARK: - Writing from outside Lamp

    private struct WritingFixture {
        let library: LampLibrary
        let agent: LampAgentLibrary
        let root: URL
        let support: URL
        let content: String
        let writingID = "living-hope"
    }

    /// A real library with a real writing, because the write tool's second
    /// check reads the writing as Lamp holds it, and no test could reach that
    /// path until the descriptor's location became injectable.
    private func writingFixture(
        allowsWriting: Bool,
        allowsReadingPlans: Bool = false
    ) async throws -> WritingFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-write-mcp-\(UUID().uuidString)", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let content = "# Living Hope\n\nIt asks that we hold to it.\n"
        let library = LampLibrary(rootURL: libraryRoot)
        _ = try await library.savePersonalDevotional(
            LampDevotional(
                id: "living-hope",
                moduleID: "personal-devotionals",
                moduleName: "My Writing",
                title: "Living Hope",
                content: content
            )
        )

        let workspace = LampWritingWorkspace.url(
            libraryRootURL: libraryRoot, writingID: "living-hope"
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(content.utf8).write(
            to: workspace.appendingPathComponent(LampWritingWorkspace.draftFilename)
        )
        try LampAgentDescriptorStore.write(
            LampAgentDescriptor(
                libraryRootPath: libraryRoot.path,
                policyPath: libraryRoot.appendingPathComponent("p.json").path,
                allowsExternalApps: true,
                allowsExternalWriting: allowsWriting,
                allowsExternalReadingPlans: allowsReadingPlans
            ),
            inApplicationSupport: support
        )
        return WritingFixture(
            library: library,
            agent: LampAgentLibrary(
                libraryRootURL: libraryRoot,
                policy: LampAgentAccessPolicy(includesPersonalContent: true)
            ),
            root: root,
            support: support,
            content: content
        )
    }

    private func handler(_ fixture: WritingFixture) -> LampMCPToolHandler {
        LampMCPToolHandler(
            library: fixture.agent,
            libraryRootURL: fixture.root.appendingPathComponent("Library", isDirectory: true),
            applicationSupportURL: fixture.support,
            policy: LampAgentAccessPolicy(includesPersonalContent: true)
        )
    }

    @Test func awriteIsRefusedWhileTheSettingIsOffAndSaysWhichSetting() async throws {
        let fixture = try await writingFixture(allowsWriting: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: LampMCPToolError.writingNotAllowed) {
            try await handler(fixture).call(name: "write_writing_draft", arguments: [
                "writing_id": .string(fixture.writingID),
                "draft": .string("rewritten"),
                "based_on": .string(fixture.content),
            ])
        }
        let message = LampMCPToolError.writingNotAllowed.localizedDescription
        #expect(message.contains("Allow other apps to change my writings"))
        #expect(message.contains("Settings"))
    }

    @Test func awriteGoesToTheDraftWhenTheSettingIsOn() async throws {
        let fixture = try await writingFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let revised = "# Living Hope\n\nIt asks that we hold to it before anything changes.\n"

        let response = try await handler(fixture).call(
            name: "write_writing_draft",
            arguments: [
                "writing_id": .string(fixture.writingID),
                "draft": .string(revised),
                "based_on": .string(fixture.content),
            ]
        )

        #expect(response.isError == false)
        #expect(
            try LampWritingWorkspace.readDraft(
                libraryRootURL: fixture.root.appendingPathComponent("Library", isDirectory: true),
                writingID: fixture.writingID
            ) == revised
        )
    }

    /// The check this test exists for: the writer edited in Lamp's own editor,
    /// which never touches `draft.md`. The draft on disk still matches what the
    /// agent read, so only the library has moved — and the write must be
    /// refused on that alone.
    @Test func awriteIsRefusedWhenOnlyTheLibraryHasMoved() async throws {
        let fixture = try await writingFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.library.savePersonalDevotional(
            LampDevotional(
                id: fixture.writingID,
                moduleID: "personal-devotionals",
                moduleName: "My Writing",
                title: "Living Hope",
                content: fixture.content + "\nA sentence the writer added in Lamp.\n"
            )
        )

        await #expect(throws: LampWritingWrite.WriteError.writingChangedInLamp) {
            try await handler(fixture).call(name: "write_writing_draft", arguments: [
                "writing_id": .string(fixture.writingID),
                "draft": .string("rewritten"),
                "based_on": .string(fixture.content),
            ])
        }
        #expect(
            try LampWritingWorkspace.readDraft(
                libraryRootURL: fixture.root.appendingPathComponent("Library", isDirectory: true),
                writingID: fixture.writingID
            ) == fixture.content,
            "the draft must be left exactly as it was"
        )
    }

    /// Core's `personalDevotionalRevision` and this app's
    /// `LampWritingWrite.fingerprint` are two implementations of one rule, and
    /// a write is refused when they disagree. Nothing else holds them
    /// together, so this does: if either side's normalisation or digest ever
    /// moves, every write to every writing starts being refused and the
    /// message blames the writer's own editing.
    ///
    /// Both sides are also checked against a value computed from neither, so
    /// the test cannot pass by both drifting the same way.
    @Test func coresRevisionAndThisAppsFingerprintAgree() async throws {
        let fixture = try await writingFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let revision = try await fixture.agent.personalDevotionalRevision(fixture.writingID)
        #expect(revision == LampWritingWrite.fingerprint(fixture.content))
        #expect(
            revision == "50ba0fa9cd13352cd4ca22ea7216cd172d487bd7d217bf44a55e2394c6629636",
            "an independently computed SHA-256 of the NFC body"
        )

        // A writing that is not there has no revision, which is not the same
        // answer as "unchanged".
        #expect(try await fixture.agent.personalDevotionalRevision("never-written") == nil)
    }

    /// The body stored decomposed still fingerprints as the composed one, so a
    /// writing whose text was pasted from somewhere that decomposes accents is
    /// still writable. Without composing on both sides this is where it would
    /// break, and it would break for that writing only.
    @Test func adecomposedBodyAgreesWithItsComposedFingerprint() async throws {
        let fixture = try await writingFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let decomposed = "# Cafe\u{301} Hope\n\nIt asks that we hold to it.\n"
        #expect(
            Array(decomposed.utf8)
                != Array(decomposed.precomposedStringWithCanonicalMapping.utf8),
            "the fixture has to really differ in its bytes"
        )
        _ = try await fixture.library.savePersonalDevotional(
            LampDevotional(
                id: fixture.writingID,
                moduleID: "personal-devotionals",
                moduleName: "My Writing",
                title: "Living Hope",
                content: decomposed
            )
        )

        let revision = try await fixture.agent.personalDevotionalRevision(fixture.writingID)
        #expect(revision == LampWritingWrite.fingerprint(decomposed))
        #expect(
            revision
                == LampWritingWrite.fingerprint(decomposed.precomposedStringWithCanonicalMapping),
            "the two spellings are one writing"
        )
    }
}

extension LampMCPServerTests {
    /// Searching the way the apps do: a book range, a Strong's key, a
    /// highlight colour.
    ///
    /// An agent that can only search words has to read whole books back to
    /// narrow them itself, which is both slower and less accurate than the
    /// query the apps already run.
    @Test func thelibrarySearchTakesTheSameNarrowingTheAppsDo() throws {
        let tool = try #require(
            LampMCPToolCatalog.tools.first { $0.name == "search_library" }
        )
        let properties = try #require(
            tool.inputSchema.objectValue?["properties"]?.objectValue
        )
        for name in ["range", "strongs_key", "highlight_colors"] {
            #expect(properties[name] != nil, "search_library should take \(name)")
        }
        #expect(
            tool.inputSchema.objectValue?["required"]?.arrayValue?
                .compactMap(\.stringValue) == ["query"],
            "the new narrowing is optional; a plain word search still works"
        )
    }
}

extension LampMCPClientCompatibilityTests {
    /// Drafting a plan changes nothing, so it answers to no switch of its own.
    /// This is what lets an app show someone the days before asking to add
    /// them.
    @Test func aplanCanBeLaidOutAndShownWithTheAddingSwitchOff() async throws {
        let fixture = try await writingFixture(allowsWriting: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = try await handler(fixture).call(
            name: "draft_reading_plan",
            arguments: [
                "name": .string("The Gospels in a Month"),
                "tracks": .array([
                    .object(["passages": .array([.string("Matthew-John")])]),
                ]),
                "reading_days": .int(30),
                "start_date": .string("2026-11-01"),
            ]
        )

        #expect(response.isError == false)
        let draft = try #require(response.structuredContent?.objectValue)
        #expect(draft["readingDays"]?.intValue == 30)
        #expect(draft["days"]?.arrayValue?.count == 30)
        #expect(draft["days"]?.arrayValue?.first?.objectValue?["date"]?.stringValue == "2026-11-01")
        #expect(
            LampReadingPlanAdditions
                .pending(inApplicationSupport: fixture.support).isEmpty,
            "drafting asks Lamp for nothing"
        )
    }

    @Test func addingAPlanIsRefusedWhileTheSettingIsOffAndSaysWhichSetting() async throws {
        let fixture = try await writingFixture(allowsWriting: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: LampMCPToolError.readingPlansNotAllowed) {
            try await handler(fixture).call(name: "add_reading_plan", arguments: [
                "name": .string("The Gospels in a Month"),
                "tracks": .array([.object(["passages": .array([.string("Matthew-John")])])]),
                "reading_days": .int(30),
            ])
        }
        #expect(
            LampReadingPlanAdditions.pending(inApplicationSupport: fixture.support).isEmpty
        )
        let message = LampMCPToolError.readingPlansNotAllowed.localizedDescription
        #expect(message.contains("Allow other apps to add reading plans"))
        #expect(message.contains("Settings"))
    }

    /// Letting apps change a writing must not also let them add a plan. Two
    /// switches, two answers.
    @Test func thewritingSwitchDoesNotGrantAddingPlans() async throws {
        let fixture = try await writingFixture(allowsWriting: true, allowsReadingPlans: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: LampMCPToolError.readingPlansNotAllowed) {
            try await handler(fixture).call(name: "add_reading_plan", arguments: [
                "name": .string("The Gospels in a Month"),
                "tracks": .array([.object(["passages": .array([.string("Matthew-John")])])]),
                "reading_days": .int(30),
            ])
        }
    }

    /// With the switch on, the plan is written down for Lamp and *not*
    /// installed here: the helper is its own process, and the library is open
    /// in Lamp.
    @Test func anaddedPlanIsLeftForLampRatherThanInstalledHere() async throws {
        let fixture = try await writingFixture(allowsWriting: false, allowsReadingPlans: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = try await handler(fixture).call(
            name: "add_reading_plan",
            arguments: [
                "name": .string("The Gospels in a Month"),
                "description": .string("Matthew to John over November."),
                "tracks": .array([.object(["passages": .array([.string("Matthew-John")])])]),
                "reading_days": .int(30),
                "start_date": .string("2026-11-01"),
                "rest_days": .array([.string("weekends")]),
            ]
        )

        #expect(response.isError == false)
        let answer = try #require(response.structuredContent?.objectValue)
        #expect(answer["queued"]?.boolValue == true)
        let id = try #require(answer["planID"]?.stringValue)
        #expect(answer["plan"]?.objectValue?["days"]?.arrayValue?.count == 30)
        let said = try #require(answer["message"]?.stringValue)
        #expect(said.contains("not in the library yet"))

        let waiting = LampReadingPlanAdditions.pending(inApplicationSupport: fixture.support)
        #expect(waiting.count == 1)
        #expect(waiting.first?.id == id)
        #expect(waiting.first?.request.restDays == ["weekends"])
        #expect(try await fixture.library.readingPlans().isEmpty, "nothing was installed")
    }

    /// A plan asked for with no start date is written down with today's, not
    /// with nothing: Lamp may install it hours later, and "today" has to mean
    /// the day it was asked for or the preview was a different plan.
    @Test func thedayItWasAskedForIsTheDayItStarts() async throws {
        let fixture = try await writingFixture(allowsWriting: false, allowsReadingPlans: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await handler(fixture).call(name: "add_reading_plan", arguments: [
            "name": .string("John a Chapter a Day"),
            "tracks": .array([.object([
                "passages": .array([.string("John")]),
                "chapters_per_day": .int(1),
            ])]),
        ])

        let waiting = try #require(
            LampReadingPlanAdditions.pending(inApplicationSupport: fixture.support).first
        )
        #expect(waiting.request.startDate == LampReadingPlanForm.dateText(Date()))
        #expect(waiting.request.readingDays == nil, "its pace is its length")
    }

    /// A request core cannot lay out is refused while the caller is still
    /// there to be told why, rather than written down to fail unseen in Lamp.
    @Test func arequestThatCannotBeLaidOutIsRefusedAtOnce() async throws {
        let fixture = try await writingFixture(allowsWriting: false, allowsReadingPlans: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: LampReadingPlanError.unknownPassage("The Gospel of Thomas")) {
            try await handler(fixture).call(name: "add_reading_plan", arguments: [
                "name": .string("Thomas in a Week"),
                "tracks": .array([
                    .object(["passages": .array([.string("The Gospel of Thomas")])]),
                ]),
                "reading_days": .int(7),
            ])
        }
        #expect(
            LampReadingPlanAdditions.pending(inApplicationSupport: fixture.support).isEmpty,
            "nothing is left for Lamp to fail at later"
        )
    }

    @Test func atrackWithNothingToReadIsSaidSoRatherThanIgnored() async throws {
        let fixture = try await writingFixture(allowsWriting: false, allowsReadingPlans: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: LampMCPToolError.missingArgument("tracks")) {
            try await handler(fixture).call(name: "add_reading_plan", arguments: [
                "name": .string("Nothing"),
                "tracks": .array([]),
            ])
        }
        await #expect(throws: LampMCPToolError.self) {
            try await handler(fixture).call(name: "draft_reading_plan", arguments: [
                "name": .string("Nothing"),
                "tracks": .array([.object(["passages": .array([])])]),
            ])
        }
    }
}
