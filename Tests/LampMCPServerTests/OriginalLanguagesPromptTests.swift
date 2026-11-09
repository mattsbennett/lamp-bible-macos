import Foundation
import LampBibleMacSupport
import LampCore
@testable import LampMCPServer
import MCP
import Testing

struct OriginalLanguagesPromptTests {
    @Test func passageQuestionAndWritingAreAvailableWithoutRequiringAllThree() throws {
        let prompt = try #require(LampMCPPromptCatalog.prompt(named: "original-languages"))
        #expect(prompt.arguments?.map(\.name).sorted() == ["passage", "question", "writing"])
        #expect(prompt.arguments?.allSatisfy { $0.required != true } == true)
        let text = try studyPromptText("original-languages", arguments: [
            "passage": "Romans 8:3", "question": "Why do renderings differ?",
            "writing": "The aorist proves this happened once for all.",
        ])
        #expect(text.contains("## The passage\n\nRomans 8:3"))
        #expect(text.contains("## What is being asked\n\nWhy do renderings differ?"))
        #expect(text.contains("## The writing to audit\n\nThe aorist proves"))
    }
}

/// Exact delivery parity, not phrase matching: changing any instruction or
/// reference must reach both MCP and workspace consumers without a second edit.
struct StudySkillDeliveryTests {
    @Test(arguments: LampBundledSkills.studySkillNames.sorted())
    func promptAndBothToolSurfacesServeCanonicalFiles(name: String) async throws {
        let catalog = try #require(LampBundledSkills.catalogURL)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-study-delivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try WorkspaceSkillStore.installBundledSkills(
            named: [name], from: catalog, intoSkillDirectoriesOf: workspace
        )
        let external = LampMCPToolHandler(library: LampAgentLibrary(libraryRootURL: workspace))
        let installed = LampMCPToolHandler(
            library: LampAgentLibrary(libraryRootURL: workspace), skillsURL: workspace
        )
        // Resolved, because the enumerator below resolves whatever it is
        // given. With the checkout under /tmp — which every install build is,
        // being made in a worktree in the scratchpad — the catalog is /tmp/…
        // and the files come back /private/tmp/…, and a relative path taken
        // by character count is then short by exactly those eight characters.
        let skill = catalog.appendingPathComponent(name).resolvingSymlinksInPath()
        let files = try #require(FileManager.default.enumerator(
            at: skill, includingPropertiesForKeys: nil
        )).compactMap { ($0 as? URL) }.filter { $0.pathExtension == "md" }
        let entrypoint = try LampBundledSkills.read(name: name)
        let prompt = try studyPromptText(name)
        #expect(prompt.hasPrefix(entrypoint))
        for file in files {
            let relative = String(
                file.resolvingSymlinksInPath().path.dropFirst(skill.path.count + 1)
            )
            let canonical = try String(contentsOf: file, encoding: .utf8)
            for handler in [external, installed] {
                let result = try await handler.call(name: "read_skill", arguments: [
                    "name": .string(name), "file": .string(relative),
                ])
                #expect(result.structuredContent?.objectValue?["text"]?.stringValue == canonical)
            }
            if relative != "SKILL.md" {
                #expect(!prompt.contains(canonical), "references must remain on demand: \(relative)")
            }
        }
    }

    @Test func unavailableCanonicalInstructionsFailRatherThanReturningAnOlderSummary() throws {
        #expect(throws: (any Error).self) {
            try LampBundledSkills.read(name: "sola-scriptura", catalogURL: nil)
        }
        #expect(throws: (any Error).self) {
            try LampBundledSkills.read(name: "not-a-skill")
        }
    }
}

func studyPromptText(_ name: String, arguments: [String: String]? = nil) throws -> String {
    let messages = try #require(try LampMCPPromptCatalog.messages(for: name, arguments: arguments))
    let first = try #require(messages.first)
    guard case let .text(text) = first.content else {
        throw NSError(domain: "StudyPromptTests", code: 1)
    }
    return text
}
