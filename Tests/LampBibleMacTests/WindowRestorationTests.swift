import Foundation
import Testing

/// AppKit records every window as it opens and closes and hands those records
/// back at the next launch. SwiftUI restores a window that carries a value
/// without its value, and each of Lamp's value-carrying groups reads no value as
/// "start a new one" — so a writing editor open when the app was killed came
/// back as a blank new writing. The groups opt out of restoration instead; this
/// holds the opt-out to every group that carries a value, including ones added
/// later, because the failure only shows itself after a crash or a rebuild.
struct WindowRestorationTests {
    @Test func everyWindowGroupCarryingAValueOptsOutOfRestoration() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LampBibleMac/App/LampBibleMacApp.swift"),
            encoding: .utf8
        )

        // Each scene declaration, in order, so a group's own text can be read
        // without the next group's.
        let scenes = source.components(separatedBy: "\n        WindowGroup(").dropFirst()
        #expect(!scenes.isEmpty, "no window groups found — has the app been restructured?")

        for scene in scenes {
            let declaration = scene.prefix { $0 != "{" }
            guard declaration.contains(", for: ") else { continue }
            // The group's title: the first quoted word of its declaration,
            // which may begin on the line below `WindowGroup(`.
            let name = declaration
                .split(separator: "\"")
                .first { $0.contains(where: \.isLetter) } ?? "?"
            #expect(
                scene.contains(".restorationBehavior(.disabled)"),
                "the \(name) window group carries a value, so it must opt out of restoration"
            )
        }
    }
}
