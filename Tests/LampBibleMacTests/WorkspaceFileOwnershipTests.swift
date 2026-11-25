import Foundation
import Testing

/// Every writer of a writing workspace's files belongs to one owner,
/// `WritingWorkspaceFiles`, so a preparation, a pane's own writes and a sync
/// pass taking a whole workspace in cannot interleave and tear each other's
/// work. The owner used to be the main actor, which served only as the lock and
/// made each of those writes a run of frames the window could not draw.
///
/// Nothing in the language holds that rule here. This project builds in Swift 5
/// mode, where calling an actor-isolated function from a synchronous main-actor
/// context is a **warning**, not an error — and the call then runs inline on the
/// caller's thread. A writer added without the annotation therefore compiles,
/// runs on whoever called it, races the others, and the build still says it
/// succeeded. That is how nine call sites stayed on the main thread through a
/// green build while this work was being done, and how the sync pass wrote live
/// workspaces outside the owner for as long as it has existed.
///
/// So the rule is held here instead: every function on these surfaces carries
/// the annotation unless it is named below with a reason. Adding one forces that
/// choice rather than letting it pass quietly.
///
/// This reads the source, as `SessionPaneMountingTests` does, because an actor
/// annotation leaves no seam to test through.
struct WorkspaceFileOwnershipTests {
    /// A body of code the rule covers.
    private struct Surface {
        let label: String
        let file: String
        /// The text that opens the type's block.
        let declaration: String
        /// Support's stores keep their helpers private and reachable only
        /// through the public API, so there the public surface is the rule;
        /// the editor's own store is checked whole.
        let publicOnly: Bool
        /// Name to the reason it is outside the owner.
        let outsideTheOwner: [String: String]
    }

    private static let surfaces: [Surface] = [
        Surface(
            label: "DevotionalAgentWorkspaceStore",
            file: "Sources/LampBibleMac/Library/DevotionalAgentWorkspaceView.swift",
            declaration: "enum DevotionalAgentWorkspaceStore",
            publicOnly: false,
            outsideTheOwner: [
                "workspaceURL": "builds a path, touching nothing",
                "isValidSkillName": "checks a name, touching nothing",
                "parseSkill": "parses text it is handed",
                "contextDirectory": "builds a path",
                "codexSkillsDirectory": "builds a path",
                "claudeSkillsDirectory": "builds a path",
                "presentationImportMarkerURL": "builds a path",
                "instructions": "builds the instructions' text, touching nothing",
            ]
        ),
        Surface(
            label: "WorkspaceSkillStore",
            file: "Sources/LampBibleMacSupport/WorkspaceSkillSupport.swift",
            declaration: "enum WorkspaceSkillStore",
            publicOnly: true,
            outsideTheOwner: [
                "catalogDirectory": "builds a path",
                "selectionURL": "builds a path",
                "isValidSkillName": "checks a name, touching nothing",
                "codexSkillsDirectory": "builds a path",
                "claudeSkillsDirectory": "builds a path",
                "installBundledSkills": """
                    installs into whatever skills directories it is given, and \
                    the reader's chat workspaces are its other caller. The \
                    writing-workspace paths that reach it are on the owner \
                    themselves.
                    """,
            ]
        ),
        Surface(
            label: "WorkspaceContextFileStore",
            file: "Sources/LampBibleMacSupport/WorkspaceTextFileSupport.swift",
            declaration: "enum WorkspaceContextFileStore",
            publicOnly: true,
            outsideTheOwner: [:]
        ),
        Surface(
            label: "LampWorkspaceSync",
            file: "Sources/LampBibleMacSupport/SyncSupport.swift",
            declaration: "enum LampWorkspaceSync",
            publicOnly: true,
            outsideTheOwner: [
                "namesAsource": """
                    reads a published path and opens nothing (`decisions/0016`'s
                    sibling: the gather has already described the workspace by
                    the time this is asked).
                    """,
                "mayPointSync": """
                    compares the paths and the records it is handed, and opens \
                    nothing: the settings ask it on the main actor as a change \
                    is made, and a hop to the owner there would be a frame.
                    """,
                "claimableRevisionMembers": """
                    compares two sets of paths it is handed and opens nothing. \
                    Named apart from `revisionMembersHeldWithoutAFile`, which \
                    reads a workspace's history and is on the owner: this test \
                    exempts by bare name, so an overload would have exempted \
                    the reader too (`decisions/0016`).
                    """,
            ]
        ),
    ]

    private static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The functions declared on a surface, each with whether the line above it
    /// puts it on the owner.
    private func declarations(on surface: Surface) throws -> [(name: String, isOwned: Bool)] {
        let source = try Self.source(surface.file)
        let start = try #require(source.range(of: surface.declaration))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let lines = source[start.upperBound..<end.lowerBound].components(separatedBy: "\n")
        let prefixes = surface.publicOnly
            ? ["public static func "]
            : ["static func ", "private static func ", "fileprivate static func ",
               "public static func "]
        var found: [(String, Bool)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) else { continue }
            let name = trimmed.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber }
            let previous = index > 0 ? lines[index - 1] : ""
            found.append((String(name), previous.contains("@WritingWorkspaceFiles")))
        }
        return found
    }

    @Test func everyWorkspaceFileFunctionHasOneOwner() throws {
        for surface in Self.surfaces {
            let unowned = try declarations(on: surface)
                .filter { !$0.isOwned && surface.outsideTheOwner[$0.name] == nil }
                .map(\.name)
            #expect(
                unowned.isEmpty,
                """
                On \(surface.label), these are not marked @WritingWorkspaceFiles: \
                \(unowned.joined(separator: ", ")). A writer of a workspace's files \
                belongs to that actor, so it cannot interleave with a preparation, \
                another pane, or a sync pass taking the workspace in; in Swift 5 mode \
                leaving it off is only a warning, and the work then runs on whoever \
                called it. Annotate it, or name it in `outsideTheOwner` with the reason.
                """
            )
        }
    }

    /// The exemptions are only honest while every name in them still exists: a
    /// renamed function would otherwise leave its exemption behind, quietly
    /// covering whatever took the name.
    @Test func nothingIsExemptedThatIsNotThere() throws {
        for surface in Self.surfaces {
            let declared = Set(try declarations(on: surface).map(\.name))
            let missing = Set(surface.outsideTheOwner.keys).subtracting(declared).sorted()
            #expect(
                missing.isEmpty,
                "Exempted on \(surface.label) but no longer there: \(missing.joined(separator: ", "))"
            )
        }
    }

    /// The export a sync pass gathers reads the live library, so it is on the
    /// owner too — it is reached through a type declared elsewhere, so it is
    /// named rather than swept up with a surface.
    @Test func theSyncPassGathersOnTheOwner() throws {
        let source = try Self.source("Sources/LampBibleMacSupport/LampSyncLocalFiles.swift")
        let declaration = try #require(
            source.range(of: "public static func workspaceFiles(\n        inLibraryAt")
        )
        #expect(
            source[..<declaration.lowerBound].hasSuffix("@WritingWorkspaceFiles\n    "),
            """
            `workspaceFiles(inLibraryAt:stagingIn:)` exports the live library into \
            the pass's scratch directory, so it reads workspaces a pane may be \
            part-way through writing.
            """
        )
    }

    /// Every pass the pane asks for must be awaited.
    ///
    /// Annotating a function does not put a call on the actor: in this
    /// project's Swift 5 mode, calling it without `await` from a synchronous
    /// main-actor context is a **warning**, and the call then runs inline on
    /// the thread that drew the frame. Three of the pane's five passes —
    /// the one on opening, every poll and every keystroke — shipped that way
    /// in this change's first draft, through a green build and a clean
    /// warning count, because the count was read from a log rather than the
    /// call sites. So the call sites are read here.
    @Test func thePanesPassesAreAwaited() throws {
        let source = try Self.source(
            "Sources/LampBibleMac/Library/DevotionalAgentWorkspaceView.swift"
        )
        var unawaited: [String] = []
        for line in source.components(separatedBy: "\n") {
            guard line.contains("reconciler(for:") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("private func"), !trimmed.hasPrefix("///") else { continue }
            if !trimmed.contains("await") {
                unawaited.append(trimmed)
            }
        }
        #expect(
            unawaited.isEmpty,
            """
            These calls into the reconciler are not awaited, so they run on \
            whoever called them instead of on `WritingWorkspaceFiles`: \
            \(unawaited.joined(separator: " / ")). In Swift 5 mode the compiler \
            only warns about this.
            """
        )
    }

    /// The owner has to exist, be its own actor rather than the main one wearing
    /// a new name, and live where the sync pass can see it.
    @Test func theOwnerIsItsOwnActor() throws {
        let source = try Self.source(
            "Sources/LampBibleMacSupport/WorkspaceTextFileSupport.swift"
        )
        #expect(source.contains("@globalActor"))
        #expect(source.contains("public actor WritingWorkspaceFiles"))
        let declaration = try #require(
            source.range(of: "actor WritingWorkspaceFiles").map { source[..<$0.lowerBound] }
        )
        #expect(
            !declaration.hasSuffix("@MainActor\npublic "),
            "The owner serialises file work; on the main actor it would serialise drawing with it."
        )
    }
}
