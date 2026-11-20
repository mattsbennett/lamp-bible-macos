import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

/// A new tab's page, until a passage is chosen in it: the passage chooser
/// laid out in the page, its field ready for a reference, and the chapters
/// read lately one click away.
struct NewReaderTabPage: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var workspace: ReaderWorkspace
    let recent: [ReaderLocation]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("New Tab")
                    .font(.title2.weight(.semibold))
                PassagePickerPopover(isPresented: .constant(true), open: open, isInline: true)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recently Read")
                            .lampSectionHeading()
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(recent.prefix(8), id: \.self) { place in
                                Button { open(place) } label: {
                                    Text(label(place))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.lampSecondary)
                                .controlSize(.large)
                            }
                        }
                    }
                }
            }
            .frame(width: PassagePickerPopover.inlineWidth)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private func label(_ place: ReaderLocation) -> String {
        let book = model.bookName(place.bookNumber, in: place.translationID)
        let translation = model.translations.first { $0.id == place.translationID }
        let name = translation?.abbreviation ?? translation?.name ?? place.translationID
        return "\(book) \(place.chapterNumber) · \(name)"
    }

    private func open(_ place: ReaderLocation) {
        if let verse = place.verseReference {
            workspace.openReference(verse, translationID: place.translationID)
        } else {
            workspace.selectPassage(
                translationID: place.translationID,
                bookNumber: place.bookNumber,
                chapterNumber: place.chapterNumber
            )
        }
    }
}

/// The reader's tabs: the shared bar (`LibraryTabBar`).
struct ReaderTabBar: View {
    let tabs: [ReaderTab]
    let selectedID: UUID
    let select: (UUID) -> Void
    let close: (UUID) -> Void
    let duplicate: (UUID) -> Void
    let rename: (UUID, String?) -> Void
    let move: (UUID, Int) -> Void
    /// Opens a tab on the chapter being read, with the passage picker open.
    let newTab: () -> Void
    /// A book as the tab's translation names it.
    let bookName: (Int, String) -> String

    var body: some View {
        LibraryTabBar(
            items: tabs.map { LibraryTabStripItem(id: $0.id, title: tabTitle($0), isNamed: $0.name != nil) },
            selectedID: selectedID,
            select: select,
            close: close,
            duplicate: duplicate,
            rename: rename,
            move: move,
            clearNameTitle: "Use the Chapter's Name",
            newTabHelp: "New reader tab (⌘T)",
            newTab: newTab
        )
    }

    private func tabTitle(_ tab: ReaderTab) -> String {
        if let name = tab.name { return name }
        guard let location = tab.location else { return tab.isBlank ? "New Tab" : "Reader" }
        return "\(bookName(location.bookNumber, location.translationID)) \(location.chapterNumber)"
    }
}
