import Foundation
import Testing
@testable import LampBibleMac

/// What a writing editor is asked to open, as a window's value and as the
/// main window's editing.
struct DevotionalEditorRequestTests {
    /// Two new writings asked for in turn were the same request, so the
    /// second kept the first's editor and typed into the draft it had saved.
    @Test func eachNewWritingIsItsOwnDraft() {
        let first = DevotionalEditorRequest()
        let second = DevotionalEditorRequest()
        #expect(first != second)
        #expect(first.editorIdentity != second.editorIdentity)
        let writing = DevotionalEditorRequest(devotionalID: "gideon")
        #expect(writing.draftID == nil)
        #expect(writing.editorIdentity == "gideon")
        #expect(writing == DevotionalEditorRequest(devotionalID: "gideon"), "a writing asked for again is the same request")
    }

    @Test func aWindowKeptBeforeDraftsComesBack() throws {
        let old = #"{"devotionalID":"gideon","opensAgentPane":true}"#
        let request = try JSONDecoder().decode(DevotionalEditorRequest.self, from: Data(old.utf8))
        #expect(request.devotionalID == "gideon" && request.opensAgentPane && request.draftID == nil)
        let draft = DevotionalEditorRequest()
        #expect(try JSONDecoder().decode(DevotionalEditorRequest.self, from: JSONEncoder().encode(draft)) == draft)
    }
}
