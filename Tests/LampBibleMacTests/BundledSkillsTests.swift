import Foundation
import Testing
@testable import LampBibleMacSupport

/// What ships under `Resources/AgentSkills` and what `bundledSkillNames` says
/// ships must be the same set.
///
/// They are read by different rules, and a disagreement is silent in both
/// directions. A folder that ships unregistered becomes editable, deletable and
/// syncable, so a reader's copy quietly diverges from the one their build ships
/// and an agent reads year-old instructions. A name registered with no folder
/// behind it hides a skill from the catalog without anything taking its place.
struct BundledSkillsTests {
    private var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMac/Resources/AgentSkills", isDirectory: true)
    }

    private var shippedSkillNames: Set<String> {
        get throws {
            let contents = try FileManager.default.contentsOfDirectory(
                at: catalogURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return Set(
                contents.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }.map(\.lastPathComponent)
            )
        }
    }

    @Test func everyShippedSkillIsRegisteredAndEveryRegisteredSkillShips() throws {
        #expect(try shippedSkillNames == WorkspaceSkillStore.bundledSkillNames)
    }

    /// A bundled name has to pass the catalog's own name rule, or the paths that
    /// check validity before built-in-ness would let it through as a custom
    /// skill of the same name.
    @Test func everyBundledNameIsAValidSkillName() {
        for name in WorkspaceSkillStore.bundledSkillNames {
            #expect(WorkspaceSkillStore.isValidSkillName(name), "\(name) is not a valid skill name")
        }
    }

    /// Each shipped skill needs the frontmatter an agent picks it by: a `name`
    /// matching its folder, and a `description` saying when to use it.
    @Test func everyShippedSkillHasFrontmatterNamingItself() throws {
        for name in try shippedSkillNames {
            let document = try String(
                contentsOf: catalogURL
                    .appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("SKILL.md"),
                encoding: .utf8
            )
            #expect(document.hasPrefix("---\n"), "\(name)/SKILL.md has no frontmatter")
            let frontmatter = document.components(separatedBy: "---").dropFirst().first ?? ""
            #expect(frontmatter.contains("name: \(name)\n"), "\(name)/SKILL.md names something else")
            #expect(frontmatter.contains("description:"), "\(name)/SKILL.md has no description")
        }
    }

    /// A reference the skill links to has to be there: an agent that follows a
    /// dead link falls back on its own judgement without saying so.
    @Test func everyReferenceLinkedBySkillExists() throws {
        for name in try shippedSkillNames {
            let skill = catalogURL.appendingPathComponent(name, isDirectory: true)
            let document = try String(
                contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8
            )
            let pattern = try NSRegularExpression(pattern: #"\]\((references/[^)]+)\)"#)
            let matches = pattern.matches(
                in: document,
                range: NSRange(document.startIndex..., in: document)
            )
            for match in matches {
                guard let range = Range(match.range(at: 1), in: document) else { continue }
                let path = String(document[range])
                #expect(
                    FileManager.default.fileExists(atPath: skill.appendingPathComponent(path).path),
                    "\(name)/SKILL.md links \(path), which is not there"
                )
            }
        }
    }
}
