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

/// The owner's two rules of 2026-11-22: the skill rests on scripture as God's
/// inspired word, and a reading from an echo or a pattern is graded rather
/// than rejected for lacking a verse that states it.
struct SolaScripturaStandardTests {
    private func instructions(_ file: String = "SKILL.md") throws -> String {
        try LampBundledSkills.read(name: "sola-scriptura", file: file)
            .replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func scriptureIsItsOwnAuthorityButNoReadingIsInspired() throws {
        let text = try instructions()
        #expect(text.contains("This skill receives scripture as God's inspired word, and so as its own authority"))
        #expect(text.contains("Scripture interprets scripture."))
        #expect(text.contains("The text is inspired; no reading of it is."))
    }

    @Test func echoesAreGradedNotRejectedAndNeverOverturnAStatement() throws {
        let text = try instructions()
        #expect(text.contains("is not unsupported merely because no verse states it"))
        #expect(text.contains("[references/echoes-and-patterns.md](references/echoes-and-patterns.md)"))
        #expect(text.contains("it never overturns a plain statement"))
        let echoes = try instructions("references/echoes-and-patterns.md")
        #expect(echoes.contains("Explicit statement remains the strongest evidence"))
        #expect(echoes.contains("Commentators noticing an echo is agreement among readers, not evidence"))
        #expect(echoes.contains("Grade the link and the claim built on it separately"))
        #expect(echoes.contains("The finding is never that a writer reasoned from a pattern"))
    }

    /// The grading itself, each clause from a review round that found it
    /// missing: a pattern reaches Strong without shared wording, its
    /// recurrence counts for it, Faint needs one distinctive resemblance,
    /// and only an undrawn link yields to a statement.
    @Test func theGradesAdmitPatternsAndKeepTheirBoundaries() throws {
        // A row is one line of the table, so each criterion is held to its grade.
        let rows = try LampBundledSkills.read(name: "sola-scriptura", file: "references/echoes-and-patterns.md")
            .split(separator: "\n").map(String.init)
        func row(_ grade: String) throws -> String {
            try #require(rows.first { $0.hasPrefix("| **\(grade)** |") })
        }
        let strong = try row("Strong")
        #expect(strong.contains("with no shared wording at all"))
        #expect(strong.hasSuffix("| Inferred, strong |"))
        #expect(try row("Faint").contains("One distinctive resemblance"))
        #expect(try row("Faint").hasSuffix("| Inferred, faint |"))
        #expect(try row("Not shown").contains("Only features common enough to occur anyway"))
        #expect(try row("Drawn").hasSuffix("| Stated |"))
        let echoes = try instructions("references/echoes-and-patterns.md")
        #expect(echoes.contains("recurrence across many contexts is the evidence, so many matches count for it"))
        #expect(echoes.contains("A shape so general it would fit almost any account is a commonplace, not a pattern"))
        #expect(echoes.contains("An undrawn link that would overturn a plain statement is Contrary"))
        #expect(echoes.contains("A drawn link is itself scripture speaking."))
        #expect(echoes.contains("A detail some text states is Stated, cited to that text."))
        let skill = try instructions()
        #expect(skill.contains("[references/prophecy.md](references/prophecy.md)"))
        #expect(skill.contains("It takes Imported when it needs a key from outside scripture"))
        #expect(skill.contains("It takes Contrary when it would overturn a plain statement, whatever its grade"))
    }
}

/// The owner's prophecy principles of 2026-11-22, credited to their source,
/// with the limits that keep them from becoming a second authority.
struct SolaScripturaProphecyTests {
    @Test func theyAreCreditedAndTheTextsRemainTheAuthority() throws {
        let text = try LampBundledSkills.read(name: "sola-scriptura", file: "references/prophecy.md")
            .replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("The principles below follow Jonathan Burke, More Sure Word of Prophecy (2010)."))
        #expect(text.contains("Those texts, not the book, are the authority"))
        #expect(text.contains("Either way, the condition, or its absence, must come from scripture."))
        #expect(text.contains("a second application is almost always expounded by scripture itself"))
        #expect(text.contains("never from where a passage stands in its book"))
        #expect(text.contains("a symbol's meaning in one passage does not carry over to another by itself"))
        #expect(text.contains("that two terms name the same class is itself a claim to show"))
        #expect(text.contains("Its facts are history, an external premise to name."))
    }
}

struct ScriptureAnswerDisciplineTests {
    @Test func servedInstructionsComposeTheSharedDiscipline() {
        #expect(LampMCPServerFactory.instructions.contains(LampScriptureAnswerDiscipline.text))
    }
}
