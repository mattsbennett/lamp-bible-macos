import AppKit
import LampCore
import LampModuleKit
import SwiftUI

/// The library: everything installed, shelved by kind.
///
/// A shelf of covers rather than a list of rows. The list stretched each row
/// the width of the window, so a module's name sat at one edge and its
/// actions at the other with nothing between them, and every translation
/// wore the same icon. Covers tell modules apart at a glance, and a narrow
/// card keeps a module's name, its details and its actions together.
struct InstalledModulesView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var moduleToRemove: LampInstalledModule?
    @State private var exportRequest: ModuleExportRequest?
    @State private var filterText = ""
    let showImporter: () -> Void

    private var exportChoices: [ModuleExportChoice] {
        LampPersonalModule.allCases.map(ModuleExportChoice.personal)
            + model.modules.filter { !$0.isBundled }.map(ModuleExportChoice.installed)
    }

    private var shelves: [(title: String, modules: [LampInstalledModule])] {
        [
            ("Translations", model.modules.filter { $0.kind == .translation }),
            ("Dictionaries", model.modules.filter { $0.kind == .dictionary }),
            ("Commentaries", model.modules.filter { $0.kind == .commentary }),
            ("Books", model.modules.filter { $0.kind == .book }),
            ("Reading Plans", model.planModules),
            ("Writing", model.devotionalModules),
            ("Quizzes", model.quizModuleInstallations),
            ("Notes", model.noteModules),
            ("Highlights", model.highlightModules),
        ]
        .map { ($0.0, $0.1.filter(matchesFilter)) }
        .filter { !$0.1.isEmpty }
    }

    private var personalModules: [LampPersonalModule] {
        LampPersonalModule.allCases.filter { matchesFilter(name: $0.name, abbreviation: nil) }
    }

    private var trimmedFilter: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesFilter(_ module: LampInstalledModule) -> Bool {
        matchesFilter(name: module.name, abbreviation: module.abbreviation)
    }

    private func matchesFilter(name: String, abbreviation: String?) -> Bool {
        guard !trimmedFilter.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(trimmedFilter)
            || (abbreviation?.localizedCaseInsensitiveContains(trimmedFilter) ?? false)
    }

    private static let coverWidth: CGFloat = 148

    private let columns = [
        GridItem(.adaptive(minimum: coverWidth, maximum: 172), spacing: 28, alignment: .top)
    ]

    /// Three across, one per kind of thing the reader makes.
    private let personalColumns = [
        GridItem(.flexible(), spacing: 16, alignment: .top),
        GridItem(.flexible(), spacing: 16, alignment: .top),
        GridItem(.flexible(), spacing: 16, alignment: .top),
    ]

    /// "14 translations · 2 dictionaries · 30 books": what the library holds,
    /// said once under the title.
    private var summary: String {
        let all: [(LampModuleKind, Int)] = [
            (.translation, model.modules.filter { $0.kind == .translation }.count),
            (.dictionary, model.modules.filter { $0.kind == .dictionary }.count),
            (.commentary, model.modules.filter { $0.kind == .commentary }.count),
            (.book, model.modules.filter { $0.kind == .book }.count),
            (.plan, model.planModules.count),
            (.devotional, model.devotionalModules.count),
            (.quiz, model.quizModuleInstallations.count),
        ]
        return all.filter { $0.1 > 0 }
            .map { "\($0.1) \(noun(for: $0.0, count: $0.1))" }
            .joined(separator: "  ·  ")
    }

    private func noun(for kind: LampModuleKind, count: Int) -> String {
        let one = count == 1
        return switch kind {
        case .translation: one ? "translation" : "translations"
        case .dictionary: one ? "dictionary" : "dictionaries"
        case .commentary: one ? "commentary" : "commentaries"
        case .book: one ? "book" : "books"
        case .plan: one ? "reading plan" : "reading plans"
        case .devotional: one ? "writing collection" : "writing collections"
        case .quiz: one ? "quiz set" : "quiz sets"
        case .notes: one ? "note set" : "note sets"
        case .highlights: one ? "highlight set" : "highlight sets"
        }
    }

    /// The page's own title, set large in the reading face, with what the
    /// library holds beneath it — the shelf announces itself as a library
    /// before it is a grid.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modules")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(summary)
                .font(.title3)
                .foregroundStyle(Color.lampSecondaryText)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                if trimmedFilter.isEmpty {
                    header
                }
                if !personalModules.isEmpty {
                    shelfHeading("Personal", count: personalModules.count)
                        .padding(.bottom, -20)
                    LazyVGrid(columns: personalColumns, alignment: .leading, spacing: 16) {
                        ForEach(personalModules) { personalModule in
                            personalCard(personalModule)
                        }
                    }
                }
                ForEach(Array(shelves.enumerated()), id: \.element.title) { shelfIndex, shelf in
                    self.shelf(shelf.title, count: shelf.modules.count) {
                        ForEach(Array(shelf.modules.enumerated()), id: \.element.id) { index, module in
                            // Each shelf starts at a different place in the
                            // order, so the first cover of every shelf is
                            // not the same navy.
                            moduleCard(module, shelfPosition: index + shelfIndex * 5)
                        }
                    }
                }
                if personalModules.isEmpty && shelves.isEmpty {
                    ContentUnavailableView.search(text: trimmedFilter)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Modules")
        .searchable(text: $filterText, placement: .toolbar, prompt: "Filter Modules")
        .toolbar {
            ToolbarItemGroup {
                Button("Install Module…", systemImage: "plus", action: showImporter)
                    .help("Install a Lamp module")
                Button("Export Module…", systemImage: "square.and.arrow.up") {
                    exportRequest = ModuleExportRequest(initialChoiceID: nil)
                }
                .help("Export a personal or user-installed module")
                Button("Show Library in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(model.library.rootURL)
                }
                .help("Show the Lamp Bible library in Finder")
            }
        }
        .sheet(item: $exportRequest) { request in
            ModuleExportWizard(
                choices: exportChoices,
                initialChoiceID: request.initialChoiceID
            )
            .environmentObject(model)
        }
        .confirmationDialog(
            "Remove Module?",
            isPresented: Binding(
                get: { moduleToRemove != nil },
                set: { if !$0 { moduleToRemove = nil } }
            ),
            presenting: moduleToRemove
        ) { module in
            Button("Remove \(module.name)", role: .destructive) {
                model.remove(module)
                moduleToRemove = nil
            }
        } message: { module in
            // Not "the installed copy": `LibraryModel.remove(_:)` records the
            // removal through LampSyncRemovedModules first, which is what stops
            // the next sync fetching the module back — and so is what carries
            // the removal to the other devices.
            Text("This removes \(module.name) from your library — from this Mac, and from your other devices the next time they sync. Your original .lamp file is not affected.")
        }
    }

    /// A heading that outranks the names under it, with a count, then the
    /// covers.
    private func shelf<Content: View>(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            shelfHeading(title, count: count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                content()
            }
        }
    }

    private func shelfHeading(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text("\(count)")
                .font(.title3)
                .foregroundStyle(Color.lampSecondaryText)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The reader's own writing, notes and highlights, as a row of cards
    /// across the page rather than three covers at its left edge: they are
    /// collections that grow, not volumes on a shelf, and the covers left the
    /// rest of the row empty.
    private func personalCard(_ personalModule: LampPersonalModule) -> some View {
        let choice = ModuleExportChoice.personal(personalModule)
        return HStack(spacing: 14) {
            LibraryCover(
                monogram: nil,
                title: personalModule.name,
                systemImage: icon(for: personalModule.kind),
                seed: personalModule.id,
                width: 40
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(personalModule.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(personalDescription(personalModule))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.lampSecondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Export \(personalModule.name)…", systemImage: "square.and.arrow.up") {
                exportRequest = ModuleExportRequest(initialChoiceID: choice.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Color.lampSecondaryText)
            .help("Export \(personalModule.name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lampCard(padding: 14)
        .contextMenu {
            Button("Export Module…", systemImage: "square.and.arrow.up") {
                exportRequest = ModuleExportRequest(initialChoiceID: choice.id)
            }
        }
    }

    private func moduleCard(_ module: LampInstalledModule, shelfPosition: Int) -> some View {
        ModuleShelfCard(
            name: module.name,
            detail: detail(for: module),
            cover: LibraryCover(
                monogram: module.abbreviation,
                title: module.name,
                caption: coverCaption(for: module),
                systemImage: module.kind == .translation || module.kind == .book
                    ? nil : coverSymbol(for: module),
                seed: module.id,
                width: Self.coverWidth,
                shelfPosition: shelfPosition
            ),
            isBuiltIn: module.isBundled
        ) {
            if !module.isBundled {
                Button("Export Module…", systemImage: "square.and.arrow.up") {
                    exportRequest = ModuleExportRequest(
                        initialChoiceID: ModuleExportChoice.installed(module).id
                    )
                }
                Divider()
                Button("Remove Module…", systemImage: "trash", role: .destructive) {
                    moduleToRemove = module
                }
            }
        }
        .help(module.name)
        .contextMenu {
            if !module.isBundled {
                Button("Export Module…", systemImage: "square.and.arrow.up") {
                    exportRequest = ModuleExportRequest(
                        initialChoiceID: ModuleExportChoice.installed(module).id
                    )
                }
                Divider()
                Button("Remove Module", role: .destructive) {
                    moduleToRemove = module
                }
            }
        }
    }

    /// Abbreviation, then whether it came with Lamp or how much room it takes.
    private func detail(for module: LampInstalledModule) -> Text {
        let trailing: Text = module.isBundled
            ? Text("Built In")
            : Text(ByteCountFormatter.string(
                fromByteCount: Int64(module.compressedByteCount),
                countStyle: .file
            ))
        guard let abbreviation = module.abbreviation, !abbreviation.isEmpty else {
            return trailing
        }
        return Text(abbreviation) + Text("  ·  ") + trailing
    }

    /// Under a cover's monogram: the text's language for a translation, the
    /// module's kind otherwise. The full name is printed under the cover, so
    /// lettering it on the cover too only said it twice.
    private func coverCaption(for module: LampInstalledModule) -> String? {
        switch module.kind {
        case .translation:
            guard let code = module.language?.lowercased(), !code.isEmpty else { return "Bible" }
            // The ancient languages by the names a reader knows them by:
            // the locale calls Greek "Ancient Greek" and has no name at all
            // for biblical Hebrew's code.
            switch code {
            case "grc": return "Greek"
            case "hbo": return "Hebrew"
            default: return Locale.current.localizedString(forLanguageCode: code) ?? code
            }
        case .dictionary: return "Dictionary"
        case .commentary: return "Commentary"
        case .book: return nil
        case .plan: return "Reading Plan"
        case .devotional: return "Writing"
        case .quiz: return "Quizzes"
        case .notes: return "Notes"
        case .highlights: return "Highlights"
        }
    }

    private func personalDescription(_ module: LampPersonalModule) -> String {
        switch module {
        case .writing: "Everything you have written in Lamp."
        case .notes: "Your notes on verses and passages."
        case .highlights: "The verses you have marked."
        }
    }

    /// A text with a short mark is lettered with it; anything else is a
    /// reference work, and wears its kind.
    private func coverSymbol(for module: LampInstalledModule) -> String? {
        if let abbreviation = module.abbreviation, abbreviation.count <= 6 { return nil }
        return icon(for: module.kind)
    }

    private func icon(for kind: LampModuleKind) -> String {
        switch kind {
        case .translation: "books.vertical"
        case .dictionary: "character.book.closed"
        case .commentary: "text.book.closed"
        case .book: "book.closed"
        case .plan: "checklist"
        case .devotional: "sun.max"
        case .quiz: "questionmark.bubble"
        case .notes: "note.text"
        case .highlights: "highlighter"
        }
    }
}

/// One module on the shelf: its cover, its name, and a line of detail with
/// the module's actions beside it, as a bookshop app puts them.
///
/// A module's actions — export, remove — are on a menu button that is always
/// drawn, and on the context menu. Shown only under the pointer, they left the
/// shelf looking like a wall of tiles that did nothing.
private struct ModuleShelfCard<Actions: View>: View {
    let name: String
    let detail: Text
    let cover: LibraryCover
    var isBuiltIn = false
    @ViewBuilder let actions: () -> Actions

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                // Three lines: two cut "Translators Amalgamated Hebrew Old
                // Testament" before the words that tell it from its Greek twin.
                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    detail
                        .font(.system(size: 12))
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Quiet at rest and full strength under the pointer. A
                    // built-in module has nothing to export or remove, so it
                    // has no button; its detail line says "Built In".
                    if !isBuiltIn {
                        Menu {
                            actions()
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 14))
                                .frame(width: 22, height: 16)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(isHovering ? Color.primary : Color.lampSecondaryText)
                        .help("Export or remove \(name)")
                        .accessibilityLabel("Actions for \(name)")
                    }
                }
            }
            .frame(width: cover.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }
}
