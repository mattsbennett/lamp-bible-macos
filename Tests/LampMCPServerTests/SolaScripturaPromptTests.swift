import Foundation
import LampCore
import MCP
@testable import LampMCPServer
import Testing

/// The audit reaches an app with no workspace through a prompt, and the same
/// audit reaches an agent in a workspace through the skill folder. Two copies of
/// one procedure drift, and a reader comparing a finding from one against a
/// finding from the other has no way to tell which copy was behind.
///
/// These hold the copies to the terms the report is written in. Prose may differ
/// — the prompt is condensed on purpose, since a client gets one message and no
/// reference files — but a verdict or a load named in one and missing from the
/// other means the two no longer report the same thing.
struct SolaScripturaPromptTests {
    private var skillURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LampBibleMac/Resources/AgentSkills/sola-scriptura", isDirectory: true
            )
    }

    /// The skill's own terms are spread over `SKILL.md` and the reference files
    /// it sends an agent to, so the whole folder is the thing to compare against.
    private var skillText: String {
        get throws {
            var text = try String(contentsOf: skillURL.appendingPathComponent("SKILL.md"), encoding: .utf8)
            let references = skillURL.appendingPathComponent("references", isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: references, includingPropertiesForKeys: nil)
            where file.pathExtension == "md" {
                text += try String(contentsOf: file, encoding: .utf8)
            }
            return text
        }
    }

    private static let verdicts = [
        "Stated", "Entailed", "Inferred", "Imported", "Unsupported", "Contrary",
    ]
    private static let loads = ["load-bearing", "supporting", "decorative"]

    @Test func thepromptIsOffered() throws {
        let prompt = try #require(LampMCPPromptCatalog.prompt(named: "sola-scriptura"))
        #expect(prompt.title == "Audit writing against scripture alone")
        #expect(prompt.description?.contains("scripture alone") == true)
        #expect(prompt.arguments?.map(\.name).sorted() == ["claim", "writing"])
        #expect(prompt.arguments?.allSatisfy { $0.required != true } == true)
    }

    @Test(arguments: verdicts + loads)
    func thepromptAndTheSkillNameTheSameTerm(term: String) throws {
        let skill = try skillText.lowercased()
        let prompt = LampMCPPromptCatalog.solaScripturaInstructions.lowercased()
        #expect(prompt.contains(term.lowercased()), "the prompt does not name \(term)")
        #expect(skill.contains(term.lowercased()), "the skill does not name \(term)")
    }

    /// The rules an audit cannot be run without, as against the reference files
    /// the prompt deliberately leaves behind.
    @Test(arguments: [
        "nothing else",           // the one authority
        "comfortable claims",     // and that it bites on the writer's own side
        "from memory",            // every citation looked up
        "no finding without a quotation",
        "proof-text drift",
        "what the pass did not do",
    ])
    func thepromptCarriesTheRulesItCannotLeaveBehind(rule: String) {
        #expect(
            LampMCPPromptCatalog.solaScripturaInstructions.lowercased().contains(rule),
            "the prompt dropped: \(rule)"
        )
    }

    /// Only the modules that ship may be named as present, since the prompt is
    /// read by a client whose user may have installed nothing of their own.
    @Test func thepromptNamesOnlyBundledModules() {
        let text = LampMCPPromptCatalog.solaScripturaInstructions
        for bundled in ["KJVs", "BSBs", "ASVs", "WEBs", "YLT", "tske", "crossrefs", "bdb"] {
            #expect(text.contains(bundled), "the prompt does not name \(bundled)")
        }
        for installed in ["ESVs", "NASB", "NETs", "NIV", "NKJV", "NIC"] {
            #expect(!text.contains(installed), "the prompt names \(installed), which is not bundled")
        }
    }

    @Test func thewritingAndTheClaimArriveInTheMessage() throws {
        let audit = try #require(LampMCPPromptCatalog.messages(
            for: "sola-scriptura", arguments: ["writing": "A talk about Jonah."]
        ))
        let text = try #require(auditText(audit))
        #expect(text.contains("A talk about Jonah."))
        #expect(text.contains("The writing to audit"))

        let one = try #require(LampMCPPromptCatalog.messages(
            for: "sola-scriptura", arguments: ["claim": "Judas felt no godly grief."]
        ))
        let single = try #require(auditText(one))
        #expect(single.contains("Judas felt no godly grief."))
        #expect(single.contains("The claim to adjudicate"))
        #expect(!single.contains("The writing to audit"))

        let bare = try #require(LampMCPPromptCatalog.messages(for: "sola-scriptura", arguments: nil))
        let empty = try #require(auditText(bare))
        #expect(!empty.contains("The writing to audit"))
        #expect(empty.contains("Sola scriptura audit"))
    }

    @Test func anunknownPromptIsStillRefused() {
        #expect(LampMCPPromptCatalog.messages(for: "not-a-prompt", arguments: nil) == nil)
    }

    private func auditText(_ messages: [Prompt.Message]) -> String? {
        guard case let .text(text) = messages.first?.content else { return nil }
        return text
    }
}

/// Every surface that answers a scripture question says the same thing about
/// what it is doing, because they compose one constant rather than each keeping
/// its own wording.
struct ScriptureAnswerDisciplineTests {
    @Test func theservedInstructionsCarryIt() {
        #expect(LampMCPServerFactory.instructions.contains(LampScriptureAnswerDiscipline.text))
    }

    @Test func thedisciplineSaysWhatItHasTo() {
        let text = LampScriptureAnswerDiscipline.text.lowercased()
        #expect(text.contains("what the text states"))
        #expect(text.contains("inferred"))
        #expect(text.contains("agreement with any tradition"))
        #expect(text.contains("could not check"))
    }
}
