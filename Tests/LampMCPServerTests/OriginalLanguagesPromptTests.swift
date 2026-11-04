import Foundation
import LampCore
@testable import LampMCPServer
import MCP
import Testing

/// The language skill reaches an agent in a workspace as a folder and an app
/// with no workspace as a prompt. Two copies of one method drift, so these hold
/// them to the facts the method rests on — the modules that exist, the calls
/// that do the work, and the limits it must not imply past.
struct OriginalLanguagesPromptTests {
    private var skillURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LampBibleMac/Resources/AgentSkills/original-languages", isDirectory: true
            )
    }

    private var skillText: String {
        get throws {
            var text = try String(
                contentsOf: skillURL.appendingPathComponent("SKILL.md"), encoding: .utf8
            )
            let references = skillURL.appendingPathComponent("references", isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(
                at: references, includingPropertiesForKeys: nil
            ) where file.pathExtension == "md" {
                text += try String(contentsOf: file, encoding: .utf8)
            }
            // Wrapped markdown against an unwrapped Swift string: collapsing the
            // line breaks means a pinned phrase that straddles a wrap fails for
            // a rule having been dropped rather than for a reflow.
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    @Test func thepromptIsOffered() throws {
        let prompt = try #require(LampMCPPromptCatalog.prompt(named: "original-languages"))
        #expect(prompt.title == "Read the Hebrew or Greek")
        #expect(prompt.arguments?.map(\.name).sorted() == ["passage", "question"])
        #expect(prompt.arguments?.allSatisfy { $0.required != true } == true)
    }

    /// Only the modules that ship may be named as present: the user on the other
    /// end of a prompt may have installed nothing of their own.
    @Test(arguments: [
        "TAHOT", "TAGNT", "LXX", "Brenton", "KJVs", "BSBs", "ASVs", "WEBs", "YLT",
        "bdb", "strongs_hebrew", "strongs_greek", "dodson_greek",
    ])
    func bothNameTheBundledModule(module: String) throws {
        #expect(LampMCPPromptCatalog.originalLanguagesInstructions.contains(module))
        #expect(try skillText.contains(module))
    }

    @Test(arguments: ["ESVs", "NASB", "NETs", "NIV", "NKJV"])
    func neitherNamesAmoduleThatIsNotBundled(module: String) throws {
        #expect(!LampMCPPromptCatalog.originalLanguagesInstructions.contains(module))
        #expect(try !skillText.contains(module))
    }

    /// The calls, the order, and the terms a report is written in.
    @Test(arguments: [
        "read_passage", "analyze_strongs", "lookup_dictionary_keys", "search_library",
        "leningrad", "nestlé-aland", "stem", "state", "construct",
        "renderings are translators",
        // The third job, and the verdicts that are this skill's own.
        "audit a writing", "carried", "permitted", "overreach",
        "translation-dependent", "unverifiable here",
        // The Septuagint: what it measures, and the numbering nothing converts.
        "oldest rendering of the hebrew", "english psalm 22:1 is `lxx` 21:2",
        "there is no nehemiah", "no tagging at all",
    ])
    func bothCarryTheMethodsOwnTerms(term: String) throws {
        #expect(
            LampMCPPromptCatalog.originalLanguagesInstructions.lowercased().contains(term),
            "the prompt dropped: \(term)"
        )
        #expect(try skillText.lowercased().contains(term), "the skill dropped: \(term)")
    }

    /// The limits are the half an agent will otherwise invent past.
    @Test(arguments: [
        "no textual apparatus", "no syntax beyond the word", "not a lexicon",
    ])
    func bothStateTheLimit(limit: String) throws {
        #expect(
            LampMCPPromptCatalog.originalLanguagesInstructions.lowercased().contains(limit),
            "the prompt dropped the limit: \(limit)"
        )
        #expect(try skillText.lowercased().contains(limit), "the skill dropped the limit: \(limit)")
    }

    @Test func thepassageAndTheQuestionArriveInTheMessage() throws {
        let messages = try #require(LampMCPPromptCatalog.messages(
            for: "original-languages",
            arguments: ["passage": "Romans 8:3", "question": "Why does the Berean differ?"]
        ))
        guard case let .text(text) = messages.first?.content else {
            Issue.record("no text in the message"); return
        }
        #expect(text.contains("Romans 8:3"))
        #expect(text.contains("Why does the Berean differ?"))
        #expect(text.contains("The passage"))
        #expect(text.contains("What is being asked"))

        let bare = try #require(
            LampMCPPromptCatalog.messages(for: "original-languages", arguments: nil)
        )
        guard case let .text(empty) = bare.first?.content else {
            Issue.record("no text in the bare message"); return
        }
        #expect(!empty.contains("## The passage"))
        #expect(empty.contains("Reading the original"))
    }
}
