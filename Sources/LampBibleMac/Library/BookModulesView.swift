import LampCore
import SwiftUI

struct BookModulesView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var books: [LampBook] = []
    @State private var sections: [LampBookSection] = []
    @State private var selectedBookID: String?
    @State private var selectedSectionID: String?
    @State private var errorMessage: String?

    var initialBookID: String? = nil
    var initialSectionID: String? = nil
    let showImporter: () -> Void
    let openReference: (Int) -> Void

    private var selectedBook: LampBook? {
        books.first { $0.id == selectedBookID }
    }

    private var selectedSection: LampBookSection? {
        sections.first { $0.id == selectedSectionID }
    }

    private var reloadID: String {
        model.modules
            .filter { $0.kind == .book }
            .map(\.id)
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    "Unable to Open Books",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if books.isEmpty {
                ContentUnavailableView {
                    Label("No Books Installed", systemImage: "book.closed")
                } description: {
                    Text("Install a long-form book module to read it here.")
                } actions: {
                    Button("Install Module…", action: showImporter)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HSplitView {
                    booksList
                    contentsList
                    if let book = selectedBook, let section = selectedSection {
                        BookSectionReaderView(
                            book: book,
                            section: section,
                            openReference: openReference
                        )
                    } else {
                        ContentUnavailableView("Choose a Section", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Books")
        .task(id: reloadID) { await loadBooks() }
        .onChange(of: selectedBookID) { _, _ in
            Task { await loadSections() }
        }
    }

    private var booksList: some View {
        List(selection: $selectedBookID) {
            ForEach(books) { book in
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.headline)
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .tag(Optional(book.id))
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 210, idealWidth: 250)
    }

    private var contentsList: some View {
        List(selection: $selectedSectionID) {
            if let book = selectedBook {
                Section {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                            if let subtitle = section.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, CGFloat(section.depth) * 14)
                        .tag(Optional(section.id))
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Contents")
                        if let subtitle = book.subtitle, !subtitle.isEmpty {
                            Text(subtitle).textCase(nil)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(minWidth: 240, idealWidth: 290)
    }

    private func loadBooks() async {
        do {
            books = try await model.library.bookModules()
            errorMessage = nil
            if !books.contains(where: { $0.id == selectedBookID }) {
                selectedBookID = books.first(where: { $0.id == initialBookID })?.id
                    ?? books.first?.id
            } else {
                await loadSections()
            }
        } catch {
            books = []
            sections = []
            errorMessage = error.localizedDescription
        }
    }

    private func loadSections() async {
        guard let selectedBookID else {
            sections = []
            selectedSectionID = nil
            return
        }
        do {
            sections = try await model.library.bookSections(moduleID: selectedBookID)
            errorMessage = nil
            if !sections.contains(where: { $0.id == selectedSectionID }) {
                selectedSectionID = sections.first(where: { $0.id == initialSectionID })?.id
                    ?? sections.first?.id
            }
        } catch {
            sections = []
            selectedSectionID = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookSectionReaderView: View {
    let book: LampBook
    let section: LampBookSection
    let openReference: (Int) -> Void

    private var blocks: [MacBookContentBlock] {
        guard let data = section.contentJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([MacBookContentBlock].self, from: data)) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let number = section.number, !number.isEmpty {
                    Text(number.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(section.title).font(.largeTitle.bold())
                if let subtitle = section.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                }

                if !section.keyScriptures.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(section.keyScriptures) { link in
                                Button(link.displayDescription) {
                                    openReference(link.startReference)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if blocks.isEmpty {
                    Text(section.content).lineSpacing(5)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MacBookBlockView(block: block)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
        }
        .environment(\.layoutDirection, book.textDirection == "rtl" ? .rightToLeft : .leftToRight)
    }
}

private struct MacBookAnnotatedText: Decodable { let text: String }

private struct MacBookListItem: Decodable {
    let content: MacBookAnnotatedText
    let children: [MacBookListItem]?
}

private struct MacBookContentBlock: Decodable {
    let type: String
    let content: MacBookAnnotatedText?
    let level: Int?
    let listType: String?
    let items: [MacBookListItem]?
    let caption: MacBookTextValue?
}

private enum MacBookTextValue: Decodable {
    case plain(String)
    case annotated(MacBookAnnotatedText)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
        } else {
            self = .annotated(try container.decode(MacBookAnnotatedText.self))
        }
    }

    var text: String {
        switch self {
        case .plain(let value): value
        case .annotated(let value): value.text
        }
    }
}

private struct MacBookBlockView: View {
    let block: MacBookContentBlock

    @ViewBuilder
    var body: some View {
        switch block.type {
        case "heading":
            Text(block.content?.text ?? "")
                .font(headingFont)
                .fontWeight(.semibold)
                .padding(.top, 6)
        case "blockquote":
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(.secondary.opacity(0.45)).frame(width: 3)
                Text(block.content?.text ?? "").italic().foregroundStyle(.secondary)
            }
        case "list":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                    MacBookListItemView(
                        item: item,
                        marker: block.listType == "numbered" ? "\(index + 1)." : "•"
                    )
                }
            }
        case "thematic-break":
            Divider().padding(.vertical, 8)
        case "image", "audio":
            Label(
                block.caption?.text ?? (block.type == "image" ? "Image" : "Audio"),
                systemImage: block.type == "image" ? "photo" : "waveform"
            )
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        default:
            Text(block.content?.text ?? "").lineSpacing(5)
        }
    }

    private var headingFont: Font {
        switch block.level ?? 2 {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

private struct MacBookListItemView: View {
    let item: MacBookListItem
    let marker: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).frame(minWidth: 20, alignment: .trailing)
                Text(item.content.text).lineSpacing(4)
            }
            ForEach(Array((item.children ?? []).enumerated()), id: \.offset) { _, child in
                MacBookListItemView(item: child, marker: "•")
                    .padding(.leading, 24)
            }
        }
    }
}
