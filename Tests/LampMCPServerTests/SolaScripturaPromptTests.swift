import Foundation
import LampBibleMacSupport
import LampCore
@testable import LampMCPServer
import Testing

struct SolaScripturaPromptTests {
    @Test func oneClaimDoesNotGetInventedWritingInput() throws {
        let prompt = try #require(LampMCPPromptCatalog.prompt(named: "sola-scriptura"))
        #expect(prompt.arguments?.map(\.name).sorted() == ["claim", "writing"])
        #expect(prompt.arguments?.allSatisfy { $0.required != true } == true)
        let text = try studyPromptText("sola-scriptura", arguments: ["claim": "A claim to examine."])
        #expect(text.contains("## The claim to adjudicate"))
        #expect(text.contains("A claim to examine."))
        #expect(!text.contains("## The writing to audit"))
    }

    @Test func writingArrivesIntactAndABarePromptInventsNoInput() throws {
        let writing = "# A study\n\nScripture teaches this.\n"
        let text = try studyPromptText("sola-scriptura", arguments: ["writing": writing])
        #expect(text.hasSuffix("## The writing to audit\n\n" + writing))
        let bare = try studyPromptText("sola-scriptura")
        #expect(!bare.contains("## The writing to audit"))
        #expect(!bare.contains("## The claim to adjudicate"))
        #expect(try LampMCPPromptCatalog.messages(for: "not-a-prompt", arguments: nil) == nil)
    }

    @Test func writingAlongsideAClaimIsContextNotAConflictingFullAuditRequest() throws {
        let text = try studyPromptText("sola-scriptura", arguments: [
            "claim": "Check this one claim.", "writing": "The surrounding study.",
        ])
        #expect(text.contains("## The claim to adjudicate"))
        #expect(text.hasSuffix("## Writing supplied as context for this claim\n\nThe surrounding study."))
        #expect(!text.contains("## The writing to audit"))
    }
}

/// These four policies came from observed reader-chat failures. Delivery parity
/// cannot protect them from being removed from the canonical instructions.
/// Deliberately pin short clauses (including exceptions), not whole paragraphs
/// or a second MCP copy. Model adherence is covered by the behavioural replays.
struct SolaScripturaGuardrailTests {
    private func instructions(_ file: String = "SKILL.md") throws -> String {
        try LampBundledSkills.read(name: "sola-scriptura", file: file)
            .replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func commentaryIsNotTheFrameButSourceQuestionsRemainAllowed() throws {
        let text = try instructions()
        #expect(text.contains("Do not open one first to find out what a passage means"))
        #expect(text.contains("Read commentaries only when the user asks about them"))
        #expect(text.contains("the writing uses them, or a specific unattributed framing needs tracing"))
    }

    @Test func libraryCoverageIsALimitNotEvidenceForAReading() throws {
        let text = try instructions()
        #expect(text.contains("What the library holds or fails to hold says nothing about a reading's merit"))
        #expect(text.contains("Unequal source coverage belongs among the limits, never among the points scored for one reading"))
    }

    @Test func disputedInterpretationsAreNotAgreedPremisesButIndependentEvidenceIsAllowed() throws {
        let text = try instructions()
        #expect(text.contains("Do not use a disputed interpretation as an agreed premise to settle the same dispute"))
        #expect(text.contains("Independent evidence can still be examined"))
        let weighing = try instructions("references/weighing-evidence.md")
        #expect(weighing.contains("Independent passages may still supply evidence; their disputed status alone does not make using them circular"))
        #expect(weighing.contains("If a conclusion needs the disputed premise, report it as conditional"))
    }

    @Test func balanceRequiresASurveyAndRevisionRequiresReasonsNotAgreement() throws {
        let text = try instructions()
        #expect(text.contains("identify the relevant kinds of evidence and read them for both readings"))
        #expect(text.contains("withhold a balance that exceeds that coverage"))
        // The detailed safeguards must remain routed from the entrypoint.
        #expect(text.contains("Read [references/weighing-evidence.md](references/weighing-evidence.md) for a comparative judgement or a follow-up that challenges one"))
        let weighing = try instructions("references/weighing-evidence.md")
        #expect(weighing.contains("A follow-up is a reason to examine evidence, not to agree with whoever spoke last"))
        #expect(weighing.contains("If an ordinary relevant passage was overlooked, acknowledge that the previous balance exceeded the research actually done, name the missing category"))
        #expect(weighing.contains("If genuinely new evidence or a better argument changes the answer, say so"))
    }
}

struct ScriptureAnswerDisciplineTests {
    @Test func servedInstructionsComposeTheSharedDiscipline() {
        #expect(LampMCPServerFactory.instructions.contains(LampScriptureAnswerDiscipline.text))
    }
}
