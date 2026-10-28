import Foundation
import Testing

/// What lands in `Lamp Bible.app/Contents/Resources`.
///
/// The resource folders go in whole — `Package.swift` copies
/// `Resources/AgentSkills`, and the Xcode project carries it as a folder
/// reference — so whatever is sitting in those directories ships, including
/// files git never sees. `.gitignore` is no defence here: an ignored file is
/// invisible to review and still gets copied.
///
/// This is not hypothetical. A `__pycache__/validate_deck.cpython-313.pyc`,
/// written by whoever last imported the deck validator, shipped inside the
/// installed app: a compiled artifact tied to one machine's Python, in a
/// release build, that no commit could show.
struct BundledResourcesTests {
    private var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMac/Resources")
    }

    @Test func noPythonBuildDroppingsAreShippedWithTheResources() throws {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: resourcesDirectory,
                includingPropertiesForKeys: nil
            )
        )

        let droppings = enumerator.compactMap { item -> String? in
            guard let url = item as? URL else { return nil }
            let isDropping = url.lastPathComponent == "__pycache__"
                || url.pathExtension == "pyc"
            guard isDropping else { return nil }
            return url.path.replacingOccurrences(
                of: resourcesDirectory.path + "/", with: ""
            )
        }

        #expect(
            droppings.isEmpty,
            """
            These are copied into the app bundle as they are. Delete them, and \
            run the validator as a script rather than importing it, which is \
            what writes a __pycache__ beside the source: \
            \(droppings.sorted().joined(separator: ", "))
            """
        )
    }
}
