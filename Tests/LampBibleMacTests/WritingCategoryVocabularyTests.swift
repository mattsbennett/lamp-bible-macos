import Foundation
import Testing

/// A writing's categories are an open vocabulary held in one place, `LampCore`'s
/// `LampWritingCategory`, because the Mac, the phone, the module schema and the
/// search all have to agree on what a kind is and on which two spellings are
/// one kind. The Mac used to keep its own list of seven and its own reading of
/// the renamed `sermon`, and the phone kept a different list that never knew
/// `sermon` at all — so the same writing read "Exhortation" here and showed no
/// kind there.
///
/// A second copy would not fail a build or a test; it would just quietly
/// disagree with the other platform again, which is why this is checked by
/// reading the sources rather than by exercising them.
struct WritingCategoryVocabularyTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appSources() throws -> [(name: String, text: String)] {
        let root = repositoryRoot.appendingPathComponent("Sources/LampBibleMac")
        let files = FileManager.default.enumerator(atPath: root.path)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") } ?? []
        #expect(files.count > 20, "no app sources found — has the package been restructured?")
        return try files.map {
            (name: $0, text: try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// No kind is named in the app's own code. Naming one is how a second
    /// vocabulary starts, and the kinds Lamp suggests are core's to decide.
    ///
    /// These four and not all five: `devotional` is also the app's own word
    /// for the feature and for a search result's kind, and `other` is an
    /// English word, so checking those would fail on code that has nothing to
    /// do with the vocabulary — and a guard that cries wolf is one a future
    /// reader deletes. The four here are distinctive enough that a hit is a
    /// vocabulary, including `sermon`, whose reading core now owns.
    @Test func theAppNamesNoKindOfItsOwn() throws {
        for source in try appSources() {
            for kind in ["\"exhortation\"", "\"reflection\"", "\"testimony\"", "\"sermon\""] {
                #expect(
                    !source.text.contains(kind),
                    "\(source.name) names the kind \(kind); the vocabulary is LampWritingCategory's"
                )
            }
        }
    }

    /// The one kind the editor did name was the default for a new writing,
    /// which now comes from the head of core's own list.
    @Test func anewWritingStartsAsTheFirstKindOffered() throws {
        let editor = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/LampBibleMac/Library/DevotionalEditorView.swift"),
            encoding: .utf8
        )
        #expect(editor.contains("LampWritingCategory.suggestions.first"))
        #expect(!editor.contains("var category = \""))
    }

    /// The editor takes a kind it has never seen. A pop-up cannot, which is
    /// the whole change: the owner's own writing comes in kinds no fixed list
    /// held — handouts, class discussions, study questions.
    @Test func theEditorLetsAwriterTypeTheirOwnKind() throws {
        let editor = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/LampBibleMac/Library/DevotionalEditorView.swift"),
            encoding: .utf8
        )
        #expect(editor.contains("WritingCategoryField("))
        #expect(
            !editor.contains("Picker(\"Category\""),
            "the category is a pop-up again, so a kind Lamp does not suggest cannot be written"
        )
        #expect(
            editor.contains("LampWritingCategory.kindToStore(shown: category, held: originalCategory)"),
            "an autosave rewrites a kind nobody renamed; the writing saves every 1.5s"
        )
        #expect(
            editor.contains("LampWritingCategory.displayName(devotional.category)"),
            "the field shows the stored spelling, so it reads exhortation beside a menu saying Exhortation"
        )
    }

    /// The filter offers the kinds the library holds, so a kind a writer
    /// invents is filterable without a release.
    @Test func thefilterIsBuiltFromTheWritingItself() throws {
        let list = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/LampBibleMac/Library/DevotionalsAndQuizzesView.swift"),
            encoding: .utf8
        )
        #expect(list.contains("LampWritingCategory.kindsHeld("))
        #expect(list.contains("LampWritingCategory.foldedKey("))
        #expect(list.contains("LampWritingCategory.displayName("))
    }
}
