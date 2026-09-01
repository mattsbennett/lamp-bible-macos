import Foundation
import Testing
@testable import LampBibleMacSupport

struct WorkspaceSkillStoreTests {
    @Test func reusesAndUpdatesOneLibrarySkillAcrossWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareWorkspaces()

        try WorkspaceSkillStore.migrateWorkspaceSkills(
            in: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        try WorkspaceSkillStore.migrateWorkspaceSkills(
            in: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        try WorkspaceSkillStore.saveSkill(
            name: "series-planner",
            description: "Plans a connected teaching series",
            instructions: "Create the series outline.",
            in: fixture.libraryRoot
        )

        try WorkspaceSkillStore.enableSkill(
            named: "series-planner",
            in: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        let firstCodex = fixture.firstWorkspace.appendingPathComponent(
            ".agents/skills/series-planner/SKILL.md"
        )
        let firstClaude = fixture.firstWorkspace.appendingPathComponent(
            ".claude/skills/series-planner/SKILL.md"
        )
        #expect(FileManager.default.fileExists(atPath: firstCodex.path))
        #expect(FileManager.default.fileExists(atPath: firstClaude.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.secondWorkspace.appendingPathComponent(
                ".agents/skills/series-planner/SKILL.md"
            ).path
        ))

        try WorkspaceSkillStore.enableSkill(
            named: "series-planner",
            in: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        try WorkspaceSkillStore.saveSkill(
            name: "series-planner",
            description: "Updated description",
            instructions: "Create a revised series outline.",
            in: fixture.libraryRoot
        )

        for workspace in [fixture.firstWorkspace, fixture.secondWorkspace] {
            let document = try String(
                contentsOf: workspace.appendingPathComponent(
                    ".agents/skills/series-planner/SKILL.md"
                ),
                encoding: .utf8
            )
            #expect(document.contains("Updated description"))
            #expect(document.contains("Create a revised series outline."))
        }

        try WorkspaceSkillStore.disableSkill(
            named: "series-planner",
            in: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        #expect(!FileManager.default.fileExists(
            atPath: firstCodex.deletingLastPathComponent().path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.libraryRoot.appendingPathComponent(
                "AgentSkills/series-planner/SKILL.md"
            ).path
        ))
        #expect(try WorkspaceSkillStore.enabledSkillNames(
            in: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        ) == Set(["series-planner"]))
    }

    @Test func migratesLegacyWorkspaceSkillsWithoutLosingNameConflicts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareWorkspaces()

        try writeLegacySkill(
            name: "talk-helper",
            instructions: "First definition",
            to: fixture.firstWorkspace
        )
        try writeLegacySkill(
            name: "talk-helper",
            instructions: "Different definition",
            to: fixture.secondWorkspace
        )

        try WorkspaceSkillStore.migrateWorkspaceSkills(
            in: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        )
        try WorkspaceSkillStore.migrateWorkspaceSkills(
            in: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        )

        #expect(try WorkspaceSkillStore.catalogSkills(in: fixture.libraryRoot).map(\.name) == [
            "talk-helper", "talk-helper-2",
        ])
        #expect(try WorkspaceSkillStore.enabledSkillNames(
            in: fixture.firstWorkspace,
            libraryRootURL: fixture.libraryRoot
        ) == Set(["talk-helper"]))
        #expect(try WorkspaceSkillStore.enabledSkillNames(
            in: fixture.secondWorkspace,
            libraryRootURL: fixture.libraryRoot
        ) == Set(["talk-helper-2"]))

        let renamedDocument = try String(
            contentsOf: fixture.secondWorkspace.appendingPathComponent(
                ".agents/skills/talk-helper-2/SKILL.md"
            ),
            encoding: .utf8
        )
        #expect(renamedDocument.contains("name: talk-helper-2"))
        #expect(renamedDocument.contains("Different definition"))
    }

    private func writeLegacySkill(name: String, instructions: String, to workspace: URL) throws {
        let directory = workspace.appendingPathComponent(
            ".agents/skills/\(name)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: "Legacy skill"
        ---

        \(instructions)
        """.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private struct Fixture {
        let root: URL
        let libraryRoot: URL
        let firstWorkspace: URL
        let secondWorkspace: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-skills-\(UUID().uuidString)", isDirectory: true)
            libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
            firstWorkspace = libraryRoot.appendingPathComponent(
                "AgentWorkspaces/Devotionals/first",
                isDirectory: true
            )
            secondWorkspace = libraryRoot.appendingPathComponent(
                "AgentWorkspaces/Devotionals/second",
                isDirectory: true
            )
        }

        func prepareWorkspaces() throws {
            try FileManager.default.createDirectory(
                at: firstWorkspace,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: secondWorkspace,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
