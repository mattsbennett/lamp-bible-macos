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
            // Wrapped markdown against an unwrapped Swift string: collapsing the
            // line breaks means a pinned phrase that straddles a wrap fails for
            // a rule having been dropped rather than for a reflow.
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
        "neither is the default",  // the two modes, and that the input picks
        "with no tables",          // what an adjudication must not turn into
        "permits another",         // that an undecided answer is a real one
    ])
    func thepromptCarriesTheRulesItCannotLeaveBehind(rule: String) {
        #expect(
            LampMCPPromptCatalog.solaScripturaInstructions.lowercased().contains(rule),
            "the prompt dropped: \(rule)"
        )
    }

    /// The two weightings the audit gained on 2026-11-04: how widely a claim is
    /// witnessed, and what a reading is worth when it cannot be stated without a
    /// word scripture does not use. Both say what evidence weighs rather than
    /// what a verdict is called, so a surface carrying one and not the other
    /// answers the same question differently. The clauses that stop each from
    /// hardening into a prohibition are pinned alongside them, because those are
    /// the lines a condensing pass drops first.
    @Test(arguments: [
        "breadth of witness",
        "several writers, books or testaments",
        "scripture is not a vote",
        "override a writer's own usage",
        "consensus by another name",
        "supporting a word rather than a claim",
        "separate them and ask for a text for each",
        "rather than matching it against a list",
        "a word scripture does not use is not an error",
    ])
    func thetwoCopiesWeighEvidenceAlike(rule: String) throws {
        #expect(
            LampMCPPromptCatalog.solaScripturaInstructions.lowercased().contains(rule),
            "the prompt dropped: \(rule)"
        )
        #expect(try skillText.lowercased().contains(rule), "the skill dropped: \(rule)")
    }

    /// What the Septuagint is evidence of, and the numbering that makes a
    /// citation from it wrong without saying so. `read_passage` labels what it
    /// returns with the reference it was asked for, so a surface that names
    /// `LXX` without these lines invites a comparison of two different psalms.
    @Test(arguments: [
        "how the hebrew was read",
        "one text in two languages",
        "rests on a translator",
        "english psalm 22:1 is `lxx` 21:2",
        "there is no nehemiah",
        "check the opening words against an english translation",
    ])
    func bothSayWhatTheSeptuagintIsEvidenceOf(rule: String) throws {
        #expect(
            LampMCPPromptCatalog.solaScripturaInstructions.lowercased().contains(rule),
            "the prompt dropped: \(rule)"
        )
        #expect(try skillText.lowercased().contains(rule), "the skill dropped: \(rule)")
    }

    /// Only the modules that ship may be named as present, since the prompt is
    /// read by a client whose user may have installed nothing of their own.
    @Test func thepromptNamesOnlyBundledModules() {
        let text = LampMCPPromptCatalog.solaScripturaInstructions
        for bundled in [
            "KJVs", "BSBs", "ASVs", "WEBs", "YLT", "LXX", "Brenton",
            "tske", "crossrefs", "bdb",
        ] {
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
        #expect(empty.contains("Sola scriptura"))
    }

    @Test func anunknownPromptIsStillRefused() {
        #expect(LampMCPPromptCatalog.messages(for: "not-a-prompt", arguments: nil) == nil)
    }

    private func auditText(_ messages: [Prompt.Message]) -> String? {
        guard case let .text(text) = messages.first?.content else { return nil }
        return text
    }

    /// Four rules written after reading a real reader chat, where the answer
    /// opened on a commentary, counted the library's coverage as a point,
    /// settled one disputed text with another, and gave a balance that moved as
    /// soon as the reader named an ordinary verse. Each is the kind of rule that
    /// a later tidy-up drops without anything failing, so each is pinned.
    @Test func theSkillSaysACommentaryIsNotHowAPassageIsRead() throws {
        let text = try skillText
        #expect(text.contains("A reader asking what a passage means is not one of the three."))
        // The prompt has carried this since before the skill did; they have to
        // agree, or the same question gets two different answers by surface.
        let prompt = try #require(auditText(
            LampMCPPromptCatalog.messages(for: "sola-scriptura", arguments: nil) ?? []
        )).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(prompt.contains("do not open one to find out what a passage means"))
    }

    @Test func theSkillRefusesToCountTheLibraryAsEvidence() throws {
        let text = try skillText
        #expect(text.contains("What the library holds is never evidence."))
        #expect(text.contains("says nothing whatever about the reading"))
    }

    @Test func theSkillForbidsSettlingADisputeWithADisputedText() throws {
        let text = try skillText
        #expect(text.contains("is the text I am resting on itself in dispute here?"))
        #expect(text.contains("it is a circle"))
    }

    @Test func theSkillRequiresTheSurveyBeforeTheBalance() throws {
        let text = try skillText
        #expect(text.contains("Survey before you weigh."))
        #expect(text.contains("A category you did not read is a category you cannot weigh"))
        // The moving balance is the symptom the reader actually reports, so the
        // skill has to name it rather than leaving it implied by the survey rule.
        #expect(text.contains("A balance that moves is a balance that was never taken."))
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
