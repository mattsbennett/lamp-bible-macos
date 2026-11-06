import Foundation
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

struct ScriptureAnswerDisciplineTests {
    @Test func servedInstructionsComposeTheSharedDiscipline() {
        #expect(LampMCPServerFactory.instructions.contains(LampScriptureAnswerDiscipline.text))
    }
}
