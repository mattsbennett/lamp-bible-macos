import Foundation
import Testing

/// The visual editor is a web page, and Lamp drives it by name: every
/// formatting button evaluates a string like `window.editorAPI.toggleBold()`.
/// Nothing in Swift or in the page checks that those names agree. Rebuild the
/// bundled editor with a method renamed and the toolbar keeps compiling, keeps
/// looking right, and silently stops working — the call lands on `undefined`
/// and the page throws where no one is watching.
///
/// So the names are checked here instead: every method the Mac calls has to be
/// one the shipped page actually exports.
struct TipTapEditorBridgeTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let bundleURL = repositoryRoot
        .appendingPathComponent("Sources/LampBibleMac/Resources/TipTapEditor/index.html")

    private static let bridgeSourceURL = repositoryRoot
        .appendingPathComponent("Sources/LampBibleMac/Library/TipTapEditorView.swift")

    /// The method names in the `window.editorAPI = { … }` literal of the
    /// shipped page, at the top level of that object only. The build minifies
    /// to shorthand methods — `setContent(t){…}` — alongside plain
    /// `name: value` properties, so both spellings count.
    private func exportedMethods() throws -> Set<String> {
        let page = try String(contentsOf: Self.bundleURL, encoding: .utf8)
        let assignment = try #require(
            page.range(of: "window.editorAPI=", options: .literal)
                ?? page.range(of: "window.editorAPI =", options: .literal),
            "The page no longer assigns window.editorAPI — this guard needs updating"
        )
        let open = try #require(
            page.range(of: "{", range: assignment.upperBound..<page.endIndex)
        )

        var names: Set<String> = []
        var depth = 0
        var identifier = ""
        var index = open.lowerBound
        while index < page.endIndex {
            let character = page[index]
            if character.isLetter || character.isNumber || character == "_" || character == "$" {
                identifier.append(character)
                index = page.index(after: index)
                continue
            }
            // A name immediately before `(` or `:` at the top level of the
            // object is one of its members, whichever way it was written.
            if depth == 1, !identifier.isEmpty, character == "(" || character == ":" {
                names.insert(identifier)
            }
            identifier = ""
            switch character {
            case "{", "[", "(":
                depth += 1
            case "}", "]", ")":
                depth -= 1
                if depth == 0 { return names }
            default:
                break
            }
            index = page.index(after: index)
        }
        Issue.record("Could not find the end of the window.editorAPI object")
        return names
    }

    private func calledMethods() throws -> Set<String> {
        let source = try String(contentsOf: Self.bridgeSourceURL, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"window\.editorAPI\.([A-Za-z_$][A-Za-z0-9_$]*)"#
        )
        let range = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }

    @Test func everyEditorMethodTheMacCallsIsExportedByTheBundledPage() throws {
        let exported = try exportedMethods()
        let called = try calledMethods()

        // If either side comes back empty the guard is not looking at what it
        // thinks it is, and would pass no matter how wrong the names were.
        #expect(exported.count > 20, "Only found \(exported.count) exported methods")
        #expect(called.count > 5, "Only found \(called.count) calls")

        let missing = called.subtracting(exported).sorted()
        #expect(
            missing.isEmpty,
            """
            The Mac calls editor methods the bundled page does not export: \
            \(missing.joined(separator: ", ")). Each one is a control that does \
            nothing at runtime.
            """
        )
    }

    /// The bundle is shared with iOS, which drives far more of the editor, so
    /// it exports more than the Mac uses. That is expected — but the page has
    /// to be the built artefact, not a stub, or the editor would not load.
    @Test func theBundledPageIsTheBuiltEditor() throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: Self.bundleURL.path
        )
        let size = try #require(attributes[.size] as? Int)
        #expect(size > 100_000, "The bundled editor is only \(size) bytes")
    }
}
