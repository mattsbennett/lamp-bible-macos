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
}
