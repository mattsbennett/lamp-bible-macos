import Foundation
import Testing
@testable import LampBibleMacSupport

/// Installing the skills that ship with Lamp into a workspace.
///
/// Both surfaces that host an agent do this, and until now the writing
/// workspace did it with a name written into the function. Shipping a second
/// and third skill turned that into a loop with nothing covering it, which is
/// what these are for.
struct BundledSkillInstallTests {
    private func catalog(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        for name in names {
            let skill = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: skill.appendingPathComponent("references", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("---\nname: \(name)\n---\n".utf8)
                .write(to: skill.appendingPathComponent("SKILL.md"))
            try Data("a reference".utf8)
                .write(to: skill.appendingPathComponent("references/one.md"))
        }
        return root
    }

    private func workspace() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-\(UUID().uuidString)", isDirectory: true)
    }

    private func installed(in workspace: URL, provider: (URL) -> URL) -> Set<String> {
        let root = provider(workspace)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return Set(contents.map(\.lastPathComponent))
    }

    /// Every provider gets the skill, complete with its references: a skill
    /// whose SKILL.md arrives without the files it links sends an agent to a
    /// dead link, which it will work around without saying so.
    @Test func askillArrivesWholeInEveryProviderDirectory() throws {
        let catalog = try catalog(["sola-scriptura", "original-languages"])
        let workspace = workspace()
        defer {
            try? FileManager.default.removeItem(at: catalog)
            try? FileManager.default.removeItem(at: workspace)
        }

        let names = try WorkspaceSkillStore.installBundledSkills(
            named: ["sola-scriptura", "original-languages"],
            from: catalog,
            intoSkillDirectoriesOf: workspace
        )

        #expect(names == ["original-languages", "sola-scriptura"])
        for provider in [
            WorkspaceSkillStore.codexSkillsDirectory, WorkspaceSkillStore.claudeSkillsDirectory,
        ] {
            #expect(installed(in: workspace, provider: provider)
                == ["original-languages", "sola-scriptura"])
            let reference = provider(workspace)
                .appendingPathComponent("sola-scriptura/references/one.md")
            #expect(FileManager.default.fileExists(atPath: reference.path))
        }
    }

    /// Only what was asked for, so a read-only surface does not receive a skill
    /// whose last step it cannot carry out.
    @Test func onlyTheNamedSkillsAreInstalled() throws {
        let catalog = try catalog(["build-lamp-deck", "sola-scriptura"])
        let workspace = workspace()
        defer {
            try? FileManager.default.removeItem(at: catalog)
            try? FileManager.default.removeItem(at: workspace)
        }

        try WorkspaceSkillStore.installBundledSkills(
            named: ["sola-scriptura"], from: catalog, intoSkillDirectoriesOf: workspace
        )

        #expect(installed(in: workspace, provider: WorkspaceSkillStore.codexSkillsDirectory)
            == ["sola-scriptura"])
    }

    /// A skill that has not changed is left alone. Copying it again would move
    /// its modification date for nothing, and a workspace watched for changes
    /// would see work where there was none.
    @Test func anunchangedSkillIsNotRewritten() throws {
        let catalog = try catalog(["sola-scriptura"])
        let workspace = workspace()
        defer {
            try? FileManager.default.removeItem(at: catalog)
            try? FileManager.default.removeItem(at: workspace)
        }
        try WorkspaceSkillStore.installBundledSkills(
            named: ["sola-scriptura"], from: catalog, intoSkillDirectoriesOf: workspace
        )
        let file = WorkspaceSkillStore.codexSkillsDirectory(in: workspace)
            .appendingPathComponent("sola-scriptura/SKILL.md")
        let marker = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: file.path)

        let again = try WorkspaceSkillStore.installBundledSkills(
            named: ["sola-scriptura"], from: catalog, intoSkillDirectoriesOf: workspace
        )

        #expect(again.isEmpty)
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
        #expect(date as? Date == marker)
    }

    /// A changed skill replaces what is there, including when only a reference
    /// file changed: a workspace that kept the copy it was given on the day it
    /// was made is a workspace reading last year's instructions.
    @Test func achangedSkillReplacesTheCopyInTheWorkspace() throws {
        let catalog = try catalog(["sola-scriptura"])
        let workspace = workspace()
        defer {
            try? FileManager.default.removeItem(at: catalog)
            try? FileManager.default.removeItem(at: workspace)
        }
        try WorkspaceSkillStore.installBundledSkills(
            named: ["sola-scriptura"], from: catalog, intoSkillDirectoriesOf: workspace
        )
        try Data("a longer reference than before".utf8).write(
            to: catalog.appendingPathComponent("sola-scriptura/references/one.md")
        )

        let again = try WorkspaceSkillStore.installBundledSkills(
            named: ["sola-scriptura"], from: catalog, intoSkillDirectoriesOf: workspace
        )

        #expect(again == ["sola-scriptura"])
        let copied = try String(
            contentsOf: WorkspaceSkillStore.codexSkillsDirectory(in: workspace)
                .appendingPathComponent("sola-scriptura/references/one.md"),
            encoding: .utf8
        )
        #expect(copied == "a longer reference than before")
    }

    /// A build with no resources, and a name with no folder behind it, install
    /// nothing rather than failing the workspace's preparation.
    @Test func amissingCatalogOrSkillInstallsNothing() throws {
        let catalog = try catalog(["sola-scriptura"])
        let workspace = workspace()
        defer {
            try? FileManager.default.removeItem(at: catalog)
            try? FileManager.default.removeItem(at: workspace)
        }

        #expect(try WorkspaceSkillStore.installBundledSkills(
            named: ["sola-scriptura"], from: nil, intoSkillDirectoriesOf: workspace
        ).isEmpty)
        #expect(try WorkspaceSkillStore.installBundledSkills(
            named: ["not-a-skill"], from: catalog, intoSkillDirectoriesOf: workspace
        ).isEmpty)
    }

    /// The read-only set is the table's own answer, not a second list to keep
    /// in step with it.
    @Test func thereadOnlySetIsThoseThatWriteNothing() {
        #expect(WorkspaceSkillStore.readOnlyBundledSkillNames
            .isSubset(of: WorkspaceSkillStore.bundledSkillNames))
        #expect(!WorkspaceSkillStore.readOnlyBundledSkillNames.contains("build-lamp-deck"))
        #expect(WorkspaceSkillStore.readOnlyBundledSkillNames.contains("sola-scriptura"))
        #expect(WorkspaceSkillStore.readOnlyBundledSkillNames.contains("original-languages"))
        #expect(WorkspaceSkillStore.bundledSkills.filter(\.writesFiles).map(\.name)
            == ["build-lamp-deck"])
    }

    /// A built-in stays out of the custom catalog however it got there, so a
    /// reader cannot edit or delete the copy their build ships.
    @Test func aninstalledBuiltInIsStillNotAcustomSkill() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }
        let catalogRoot = WorkspaceSkillStore.catalogDirectory(in: library)
        for name in ["sola-scriptura", "series-planner"] {
            let skill = catalogRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: d\n---\n".utf8)
                .write(to: skill.appendingPathComponent("SKILL.md"))
        }

        let catalogued = try WorkspaceSkillStore.catalogSkills(in: library).map(\.name)

        #expect(catalogued == ["series-planner"])
    }
}
