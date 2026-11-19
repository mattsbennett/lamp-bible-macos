import Foundation
import Testing

/// Every writer of a writing workspace's files belongs to one owner,
/// `WritingWorkspaceFiles`, so preparing a workspace cannot interleave with a
/// skill edit, a context write, or a second pane preparing the same writing.
/// The owner used to be the main actor, which served only as the lock and made
/// each of those writes a run of frames the window could not draw.
///
/// Nothing in the language holds that rule here. This project builds in Swift 5
/// mode, where calling an actor-isolated function from a synchronous context is
/// a **warning**, not an error — and the call then runs inline on the caller's
/// thread. A writer added without the annotation therefore compiles, runs on
/// whichever thread called it, and races the others, while the build still says
/// it succeeded. That is how the first version of this work shipped nine call
/// sites still on the main thread through a green build.
///
/// So the rule is held here instead: every `static func` on the store carries
/// the annotation unless it is named below, and each name says why. Adding a
/// function forces that choice rather than letting it pass quietly.
///
/// This reads the source, as `SessionPaneMountingTests` does, because an actor
/// annotation leaves no seam to test through.
struct WorkspaceFileOwnershipTests {
    /// Functions deliberately outside the owner.
    ///
    /// `workspaceURL`, `isValidSkillName`, `parseSkill` and the directory
    /// helpers only compute paths or parse text, touching nothing.
    /// `librarySkills` reads the library's own skills, which are not a
    /// workspace's files.
    ///
    /// `writeDraftContent` and `readDraft` are the draft pair, left for their
    /// own change: the reconciler writes the draft from four places around turn
    /// ordering and undo. Their one point of contact with preparation is its
    /// create-if-missing on `draft.md`, which can only race while the draft does
    /// not yet exist, and the reconciler reads the draft before writing it.
    /// Moving them is where that gets re-examined.
    static let outsideTheOwner: Set<String> = [
        "workspaceURL",
        "isValidSkillName",
        "parseSkill",
        "contextDirectory",
        "codexSkillsDirectory",
        "claudeSkillsDirectory",
        "presentationImportMarkerURL",
        "librarySkills",
        "writeDraftContent",
        "readDraft",
    ]

    private var storeSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LampBibleMac/Library/DevotionalAgentWorkspaceView.swift"
                )
            let source = try String(contentsOf: url, encoding: .utf8)
            let start = try #require(source.range(of: "enum DevotionalAgentWorkspaceStore"))
            let end = try #require(
                source.range(of: "\n}\n", range: start.upperBound..<source.endIndex)
            )
            return String(source[start.upperBound..<end.lowerBound])
        }
    }

    /// Each `static func` in the store, with the line above it.
    private func declarations(in store: String) -> [(name: String, isOwned: Bool)] {
        let lines = store.components(separatedBy: "\n")
        var found: [(String, Bool)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["static func ", "private static func ", "fileprivate static func "]
            where trimmed.hasPrefix(prefix) {
                let name = trimmed.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber }
                let previous = index > 0 ? lines[index - 1] : ""
                found.append((String(name), previous.contains("@WritingWorkspaceFiles")))
                break
            }
        }
        return found
    }

    @Test func everyWorkspaceFileFunctionHasOneOwner() throws {
        let unowned = declarations(in: try storeSource)
            .filter { !$0.isOwned && !Self.outsideTheOwner.contains($0.name) }
            .map(\.name)
        #expect(
            unowned.isEmpty,
            """
            These functions on DevotionalAgentWorkspaceStore are not marked \
            @WritingWorkspaceFiles: \(unowned.joined(separator: ", ")). A writer \
            of a workspace's files belongs to that actor, so it cannot interleave \
            with preparation or another pane; in Swift 5 mode leaving it off is \
            only a warning, and the work then runs on whoever called it — which \
            for a view is the thread that draws. Annotate it, or, if it genuinely \
            touches none of the workspace's files, name it in `outsideTheOwner` \
            with the reason.
            """
        )
    }

    /// The allowlist is only honest while every name in it still exists: a
    /// renamed function would otherwise leave its exemption behind, quietly
    /// covering whatever took the name.
    @Test func nothingIsExemptedThatIsNotThere() throws {
        let declared = Set(declarations(in: try storeSource).map(\.name))
        let missing = Self.outsideTheOwner.subtracting(declared).sorted()
        #expect(
            missing.isEmpty,
            "Named in `outsideTheOwner` but no longer on the store: \(missing.joined(separator: ", "))"
        )
    }

    /// The owner itself has to exist, and be an actor rather than the main one
    /// wearing a new name.
    @Test func theOwnerIsItsOwnActor() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMac/Library/WritingChatTurns.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("@globalActor"))
        #expect(source.contains("actor WritingWorkspaceFiles"))
        let declaration = try #require(
            source.range(of: "actor WritingWorkspaceFiles")
                .map { source[..<$0.lowerBound] }
        )
        #expect(
            !declaration.hasSuffix("@MainActor\n"),
            "The owner serialises file work; on the main actor it would serialise drawing with it."
        )
    }
}
