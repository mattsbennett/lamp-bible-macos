import LampCore
import SwiftUI

/// A writing's category: a field to type in, with a menu of the kinds already
/// to hand.
///
/// This was a pop-up over seven fixed kinds, which is quicker to use — but the
/// vocabulary is open now, because a fixed list could not hold the kinds real
/// writing comes in. The owner's own corpus is handouts, class discussions,
/// study questions and comprehensive documents, and the list offered none of
/// them; meanwhile two of its seven had never been used at all.
///
/// So the field has to accept a word it has never seen, and the menu keeps the
/// common case to one click: the kinds Lamp suggests, then every other kind
/// this library already holds, so a writer's own kind is a click away the
/// second time they reach for it.
struct WritingCategoryField: View {
    let title: String
    @Binding var storedValue: String

    /// The category of every writing in the library, so the menu can offer the
    /// ones this writer uses. Unparsed and undeduplicated — `LampCore` tells
    /// two spellings of one kind apart, and does it the same way here as in
    /// the filter and the search.
    let held: [String?]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                // A writing may have no kind, and an empty row should say so
                // rather than look like a field that failed to load.
                TextField(title, text: $storedValue, prompt: Text("None"))
                    .labelsHidden()
                Menu {
                    ForEach(offered, id: \.self) { kind in
                        Button(LampWritingCategory.displayName(kind) ?? kind) {
                            storedValue = kind
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                // The menu draws its own chevron on top of that one otherwise,
                // and a row with two of them reads as a mistake.
                .menuIndicator(.hidden)
                .fixedSize()
                .help("The kinds Lamp suggests, and the ones you have used")
                .accessibilityLabel("Choose a category")
            }
        }
    }

    /// What the writer has typed is offered too, so the menu shows the kind
    /// this writing already carries rather than looking as though it has none.
    private var offered: [String] {
        LampWritingCategory.offered(forLibraryHolding: held + [storedValue])
    }
}
