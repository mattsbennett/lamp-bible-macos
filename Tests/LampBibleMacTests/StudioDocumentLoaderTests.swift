import Foundation
import Testing
@testable import LampBibleMacSupport

struct StudioDocumentLoaderTests {
    @Test func loadsBuildablePlanForStudio() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/test-plan.json")
        let document = StudioDocumentLoader.inspect(data: Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0",
            "id": "test-plan",
            "type": "plan",
            "name": "Test Plan"
          },
          "days": []
        }
        """#.utf8), sourceURL: sourceURL)

        #expect(document.failureMessage == nil)
        #expect(document.inspection?.kind == .plan)
        #expect(document.isValid)
        #expect(document.canBuild)
        #expect(document.suggestedOutputFilename == "test-plan.lamp")
    }

    @Test func enablesBuildForSupportedModule() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/fallback-name.json")
        let document = StudioDocumentLoader.inspect(data: Data(#"""
        {
          "meta": {
            "schemaVersion": "2.1",
            "id": "test_dict",
            "type": "dictionary",
            "name": "Test Dictionary"
          },
          "entries": []
        }
        """#.utf8), sourceURL: sourceURL)

        #expect(document.isValid)
        #expect(document.canBuild)
        #expect(document.suggestedOutputFilename == "test_dict.lamp")
    }

    @Test func enablesBuildForPortableStudyModules() {
        let notes = StudioDocumentLoader.inspect(data: Data(#"""
        {
          "meta": {"schemaVersion": "1.1", "id": "notes", "type": "notes"},
          "book": "Gen", "bookNumber": 1, "chapters": []
        }
        """#.utf8), sourceURL: URL(fileURLWithPath: "/tmp/notes.json"))
        let highlights = StudioDocumentLoader.inspect(data: Data(#"""
        {
          "meta": {
            "schemaVersion": "1.0", "id": "highlights", "type": "highlights",
            "translationId": "ESV"
          },
          "verses": []
        }
        """#.utf8), sourceURL: URL(fileURLWithPath: "/tmp/highlights.json"))

        #expect(notes.canBuild)
        #expect(notes.inspection?.statistics == ["chapters": 0, "notes": 0])
        #expect(highlights.canBuild)
        #expect(highlights.inspection?.statistics == ["verses": 0, "highlights": 0])
    }
}
