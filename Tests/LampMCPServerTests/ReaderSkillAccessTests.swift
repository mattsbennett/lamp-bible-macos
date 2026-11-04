import Foundation
@testable import LampBibleMacSupport
import LampCore
@testable import LampMCPServer
import MCP
import Testing

/// A reader chat is told to read its skills and, until `read_skill`, had no way
/// to do it: Claude is launched with `--tools ""`, which takes Read and Skill
/// away, and OpenCode's reader agent denies everything but `lamp_*`. The skills
/// were installed in the workspace all the same, so the instructions and the
/// launch arguments disagreed and only the reader found out — one chat ended by
/// saying it had no way to open the study skills installed with it.
///
/// Nothing failed. The build was green, the skills were installed, the
/// instructions were sincere. That is why this is checked here.
struct ReaderSkillAccessTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-skill-tests-\(UUID().uuidString)", isDirectory: true)
        let skill = root.appendingPathComponent(".claude/skills/sola-scriptura", isDirectory: true)
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("references", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# Sola scriptura\nThe procedure.".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "One real finding.".write(
            to: skill.appendingPathComponent("references/worked-example.md"),
            atomically: true, encoding: .utf8
        )
        // Real, readable files the reader must not reach by asking for a skill.
        // They have to exist, or a test that walks out of the folder passes for
        // the wrong reason — the read failing because nothing is there.
        try "secret".write(
            to: root.appendingPathComponent("private.md"), atomically: true, encoding: .utf8
        )
        try "secret".write(
            to: root.appendingPathComponent(".claude/private.md"),
            atomically: true, encoding: .utf8
        )
        // Inside the skill, readable, and not Markdown.
        try "secret".write(
            to: skill.appendingPathComponent("SKILL.txt"), atomically: true, encoding: .utf8
        )
        // A link out of the skill, pointing at a file that really is there:
        // without resolving links the confinement check follows it.
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("escape.md"),
            withDestinationURL: root.appendingPathComponent("private.md")
        )
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: root
        )
        return root
    }

    private func handler(_ workspace: URL) -> LampMCPToolHandler {
        LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: workspace),
            workspaceURL: workspace
        )
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap {
            if case .text(let value) = $0 { value.text } else { nil }
        }.joined()
    }

    @Test func aChatCanListAndReadTheSkillsInstalledForIt() async throws {
        let root = try workspace()
        let listing = try await handler(root).call(name: "read_skill", arguments: nil)
        #expect(text(listing).contains("sola-scriptura"))

        let skill = try await handler(root).call(
            name: "read_skill", arguments: ["name": .string("sola-scriptura")]
        )
        #expect(text(skill).contains("The procedure."))

        let reference = try await handler(root).call(
            name: "read_skill",
            arguments: [
                "name": .string("sola-scriptura"),
                "file": .string("references/worked-example.md"),
            ]
        )
        #expect(text(reference).contains("One real finding."))
    }

    /// The tool takes a path from the agent, so it is a way out of the skill
    /// folder unless it is held to one.
    ///
    /// Every path here reaches a file that exists and can be read, so removing
    /// a guard makes the call succeed rather than fail for want of a file.
    /// Written the other way round first, and the guards could all be deleted
    /// with the tests still green.
    @Test func afileOutsideTheSkillIsRefused() async throws {
        let root = try workspace()
        let secret = root.appendingPathComponent("private.md").path
        let paths = [
            // These two reach `private.md` when the guards are taken out, so
            // they are what holds the guards in place.
            "../../../private.md",                  // climbs out to the workspace
            "references/../../../../private.md",    // climbs out after going in
            // These two are refused by a rule of their own rather than by the
            // walk-out check, and are here to pin those rules.
            secret,                                 // absolute, and Markdown
            "SKILL.txt",                            // inside, readable, not Markdown
            // A link, and a link to a folder: no `..`, inside the skill by
            // name, outside it in fact.
            "escape.md",
            "linked/private.md",
        ]
        for file in paths {
            await #expect(throws: (any Error).self, "\(file) was served") {
                try await handler(root).call(
                    name: "read_skill",
                    arguments: ["name": .string("sola-scriptura"), "file": .string(file)]
                )
            }
        }
    }

    /// A name is matched against what is installed, so it never becomes a path.
    @Test func askingForAskillTheSessionHasNotGotIsRefusedWithWhatItHas() async throws {
        let root = try workspace()
        await #expect(throws: (any Error).self) {
            try await handler(root).call(
                name: "read_skill", arguments: ["name": .string("../../../etc")]
            )
        }
    }

    /// The deck skill writes files, so a read-only chat is not given it and
    /// cannot read it either — the tool serves what was installed, nothing more.
    @Test func areaderChatIsOfferedOnlyTheSkillsItCanCarryOut() {
        #expect(WorkspaceSkillStore.readOnlyBundledSkillNames == ["original-languages", "sola-scriptura"])
        #expect(!WorkspaceSkillStore.readOnlyBundledSkillNames.contains("build-lamp-deck"))
    }

    /// The three have to agree: the chat is told to call a tool, that tool
    /// exists, and the launch arguments let it through.
    @Test func whatTheReaderIsToldToDoIsWhatItsLaunchArgumentsAllow() {
        let instructions = ReaderChatContext.instructions
        #expect(
            instructions.contains("read_skill"),
            "the reader is told about skills without being told how to reach them"
        )
        // Named, not described, which saves the agent a call to list them.
        for skill in WorkspaceSkillStore.readOnlyBundledSkillNames {
            #expect(
                instructions.contains(skill),
                "\(skill) is installed for the reader and never named to it"
            )
        }
        #expect(
            !ReaderChatContext.instructionsNaming(skills: []).contains("read_skill"),
            "a chat with no skills is told to call a tool that would tell it nothing"
        )
        #expect(
            !instructions.contains("beside this file"),
            "the reader is told to open a file, and reader mode has no file tools"
        )
        #expect(
            LampMCPToolCatalog.tools.contains { $0.name == "read_skill" },
            "the reader is told to call a tool the server does not offer"
        )
        // `--allowedTools mcp__lamp__*` is what reader mode permits, so the
        // tool has to be served by the lamp server to be reachable at all.
        #expect(LampMCPToolCatalog.tools(workspace: true).contains { $0.name == "read_skill" })
    }

    /// The chat as Lamp starts it: its configuration from the same call the
    /// reader sidebar makes, its folder prepared with the skills this build
    /// ships, and a server set up from nothing but that configuration's
    /// arguments.
    ///
    /// The tests above hand the handler a workspace directly, and so did a
    /// check against the installed helper. A real reader chat was never given
    /// one, so every call it made was refused while all of them passed. This
    /// is the step they skipped.
    @Test func areaderChatStartedAsLampStartsItCanReadItsSkills() async throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-reader-skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }
        let workspace = ReaderChatWorkspaceStore.workspaceURL(
            libraryRootURL: library, windowID: UUID()
        )
        let configuration = ReaderChatWorkspaceStore.configuration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/lamp-mcp"),
            libraryRootURL: library,
            bundledModulesArchiveURL: nil,
            policyURL: workspace.appendingPathComponent(".lamp/module-policy.json"),
            workspace: workspace
        )
        let shipped = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMac/Resources/AgentSkills", isDirectory: true)
        try ReaderChatWorkspaceStore.prepare(
            workspace: workspace, configuration: configuration, bundledSkillsCatalog: shipped
        )

        // Read back as `lamp-mcp` reads its options.
        let arguments = configuration.arguments
        func value(of option: String) -> URL? {
            guard let index = arguments.firstIndex(of: option),
                  arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #expect(value(of: "--workspace") == nil, "a reader chat has no writing to serve")
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: library),
            workspaceURL: value(of: "--workspace"),
            skillsURL: value(of: "--skills")
        )

        for skill in WorkspaceSkillStore.readOnlyBundledSkillNames {
            let reading = try await handler.call(
                name: "read_skill", arguments: ["name": .string(skill)]
            )
            #expect(reading.isError != true, "\(skill) was refused: \(text(reading))")
            #expect(text(reading).contains("name: \(skill)"), "\(skill)'s SKILL.md was not served")
        }
    }

    /// Started with nowhere to find skills, the answer says that, rather than
    /// sending the agent to look for a writing it was never given.
    @Test func asessionWithNoSkillsFolderSaysItHasNoSkills() async throws {
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: FileManager.default.temporaryDirectory)
        )
        await #expect(throws: LampMCPToolError.noSkills) {
            try await handler.call(name: "read_skill", arguments: ["name": .string("sola-scriptura")])
        }
        #expect(LampMCPToolError.noSkills.localizedDescription.contains("No skills are installed"))
    }
}
