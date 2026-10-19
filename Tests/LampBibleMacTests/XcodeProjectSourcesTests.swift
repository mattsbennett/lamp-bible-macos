import Foundation
import Testing

/// The package builds by globbing `Sources`, and the Xcode project — which is
/// what actually ships the app — lists every file by hand. A new file compiles
/// under `swift build` and fails in Xcode with "cannot find X in scope", which
/// is a confusing way to learn that the two disagree.
struct XcodeProjectSourcesTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func theXcodeProjectListsEverySourceFile() throws {
        let project = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Lamp Bible.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let pattern = try NSRegularExpression(pattern: #"path = (Sources/[^;]+\.swift);"#)
        let listed = Set(
            pattern.matches(
                in: project,
                range: NSRange(project.startIndex..., in: project)
            ).compactMap { match -> String? in
                Range(match.range(at: 1), in: project).map { String(project[$0]) }
            }
        )

        let sources = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        var onDisk: Set<String> = []
        let walker = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let root = repositoryRoot.standardizedFileURL.path + "/"
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = url.standardizedFileURL.path
            onDisk.insert(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
        }

        #expect(
            onDisk.subtracting(listed).isEmpty,
            "add these to the Xcode project: \(onDisk.subtracting(listed).sorted())"
        )
        #expect(
            listed.subtracting(onDisk).isEmpty,
            "these are in the Xcode project but not on disk: \(listed.subtracting(onDisk).sorted())"
        )
    }

    /// Xcode compiles the support sources straight into the target that needs
    /// them, so inside the app — and inside the MCP helper — `LampBibleMacSupport`
    /// is not a module and importing it unconditionally fails dependency
    /// scanning, while `swift build`, which does build it as a module, passes.
    /// Hence the `#if canImport` guard on every such import, and hence this.
    ///
    /// Only the import needs guarding. The *types* are present either way, so
    /// guarding a declaration that uses one removes it under Xcode alone — which
    /// is a far more confusing failure than a missing import.
    @Test(arguments: ["Sources/LampBibleMac", "Sources/LampMCPServer"])
    func everySourceGuardsItsSupportImport(directory: String) throws {
        let walker = FileManager.default.enumerator(
            at: repositoryRoot.appendingPathComponent(directory, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var unguarded: [String] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
            for (index, line) in lines.enumerated()
            where line.trimmingCharacters(in: .whitespaces) == "import LampBibleMacSupport" {
                let guarded = lines[..<index].reversed().prefix(3).contains {
                    $0.contains("#if canImport(LampBibleMacSupport)")
                }
                if !guarded { unguarded.append(url.lastPathComponent) }
            }
        }
        #expect(
            unguarded.isEmpty,
            "wrap the import in #if canImport(LampBibleMacSupport): \(unguarded.sorted())"
        )
    }

    /// Every file the helper references has to be in its own Sources phase as
    /// well as the app's: Xcode builds no `LampBibleMacSupport` module, so a
    /// file listed only for the app is missing from the tool.
    @Test func theHelperTargetCompilesTheSupportSourcesItUses() throws {
        let project = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Lamp Bible.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        // The lamp-mcp target's Sources phase, from its declaration to its end.
        let marker = "C10000000000000000000004 /* Sources */ = {"
        let start = try #require(project.range(of: marker))
        let phase = project[start.upperBound...]
            .prefix(while: { $0 != ")" })
        for name in [
            "AgentRevisionSupport.swift",
            "UnifiedDiffSupport.swift",
            "WritingChangesSupport.swift",
        ] {
            #expect(
                phase.contains(name),
                "add \(name) to the lamp-mcp target's Sources phase"
            )
        }
    }
}
