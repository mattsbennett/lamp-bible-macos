import Testing
@testable import LampBibleMacSupport

/// A writing edited in the main window: what folds, and what the list's
/// one button does.
struct WritingInPlaceLayoutTests {
    @Test func editingFoldsTheSectionsAndKeepsTheList() {
        var layout = WritingInPlaceLayout()
        #expect(!layout.foldsSections)
        #expect(!layout.showsList(readingShowsList: false), "reading keeps its own choice")
        layout.beginEditing()
        #expect(layout.foldsSections)
        #expect(layout.showsList(readingShowsList: false), "editing starts with the list")
        layout.endEditing()
        #expect(!layout.foldsSections)
    }

    @Test func theAssistantFoldsTheListAndTheButtonAsksItBack() {
        var layout = WritingInPlaceLayout()
        var reading = true
        layout.beginEditing()
        layout.setAssistantOpen(true)
        #expect(!layout.showsList(readingShowsList: reading))
        layout.toggleList(readingShowsList: &reading)
        #expect(layout.showsList(readingShowsList: reading), "the button is never dead")
        #expect(reading, "editing's choice is not reading's")
        layout.setAssistantOpen(false)
        layout.setAssistantOpen(true)
        #expect(!layout.showsList(readingShowsList: reading), "each opening folds it again")
        layout.setAssistantOpen(false)
        #expect(layout.showsList(readingShowsList: reading))
    }

    @Test func hidingTheListWhileEditingLastsForThatEditing() {
        var layout = WritingInPlaceLayout()
        var reading = true
        layout.beginEditing()
        layout.toggleList(readingShowsList: &reading)
        #expect(!layout.showsList(readingShowsList: reading))
        #expect(reading)
        layout.endEditing()
        #expect(layout.showsList(readingShowsList: reading))
        layout.beginEditing()
        #expect(layout.showsList(readingShowsList: reading), "the next editing starts with it")
        layout.endEditing()
        layout.toggleList(readingShowsList: &reading)
        #expect(!reading, "while reading, the button is reading's saved choice")
    }
}
