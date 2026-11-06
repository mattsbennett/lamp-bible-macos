import Foundation
@testable import LampBibleMacSupport
import Testing

struct BundledSkillSupportTests {
    @Test func catalogCanBeLocatedForAppEmbeddedHelperAndStandaloneHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-skill-locations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Lamp Bible.app/Contents/Resources")
        let catalog = resources.appendingPathComponent("AgentSkills")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        #expect(LampBundledSkills.catalogURL(resourceURL: resources, executableURL: nil)?.path == catalog.path)
        #expect(LampBundledSkills.catalogURL(
            resourceURL: nil,
            executableURL: root.appendingPathComponent("Lamp Bible.app/Contents/Helpers/lamp-mcp")
        )?.standardizedFileURL.path == catalog.standardizedFileURL.path)
        let standalone = root.appendingPathComponent("Standalone")
        let standaloneCatalog = standalone.appendingPathComponent("AgentSkills")
        try FileManager.default.createDirectory(at: standaloneCatalog, withIntermediateDirectories: true)
        #expect(LampBundledSkills.catalogURL(
            resourceURL: nil, executableURL: standalone.appendingPathComponent("lamp-mcp")
        )?.path == standaloneCatalog.path)
        #expect(LampBundledSkills.catalogURL(resourceURL: nil, executableURL: nil) == nil)
    }

    @Test func packagedSkillsMatchTheCanonicalSourceIncludingEveryReference() throws {
        let packaged = try #require(LampBundledSkills.catalogURL)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMacSupport/Resources/AgentSkills")
        let files = try #require(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        var compared = 0
        for case let file as URL in files where file.pathExtension == "md" {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            #expect(try Data(contentsOf: file) == Data(contentsOf: packaged.appendingPathComponent(relative)))
            compared += 1
        }
        #expect(compared > 3, "compare references as well as entrypoints")
    }
}
