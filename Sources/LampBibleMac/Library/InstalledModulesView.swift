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
    @Environment(\.openWindow) private var openWindow
    @State private var moduleToRemove: LampInstalledModule?
    @State private var exportRequest: ModuleExportRequest?
    @State private var filterText = ""
    /// The shelves shown, by title, one to a line; every shelf when empty.
    @AppStorage("modules.shelfFilter") private var shelfFilter = ""
    let showImporter: () -> Void

    private var exportChoices: [ModuleExportChoice] {
        LampPersonalModule.allCases.map(ModuleExportChoice.personal)
            + model.modules.filter { !$0.isBundled }.map(ModuleExportChoice.installed)
    }

    private var allShelves: [(title: String, modules: [LampInstalledModule])] {
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
        .filter { !$0.1.isEmpty }
    }

    private static let personalShelf = "Personal"

    /// The kinds the library holds, each with how many: the chips under
    /// the title, and the toolbar's menu.
    private var shelfChoices: [(title: String, count: Int)] {
        [(Self.personalShelf, LampPersonalModule.allCases.count)]
            + allShelves.map { ($0.title, $0.modules.count) }
    }

    /// The shelves chosen that the library still holds: a choice left from a
    /// kind since removed would otherwise show an empty page.
    private var chosenShelves: Set<String> {
        let stored = Set(shelfFilter.split(separator: "\n").map(String.init))
        return stored.intersection(shelfChoices.map(\.title))
    }

    private func isShown(_ title: String) -> Bool {
        chosenShelves.isEmpty || chosenShelves.contains(title)
    }

    private func toggleShelf(_ title: String) {
        var chosen = chosenShelves
        if chosen.contains(title) { chosen.remove(title) } else { chosen.insert(title) }
        shelfFilter = chosen.sorted().joined(separator: "\n")
    }

    private var shelves: [(title: String, modules: [LampInstalledModule])] {
        allShelves
            .filter { isShown($0.title) }
            .map { ($0.0, $0.1.filter(matchesFilter)) }
            .filter { !$0.1.isEmpty }
    }

    private var personalModules: [LampPersonalModule] {
        guard isShown(Self.personalShelf) else { return [] }
        return LampPersonalModule.allCases.filter { matchesFilter(name: $0.name, abbreviation: nil) }
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

    /// "14 translations": a shelf's chip, the count first, as the line of
    /// counts under the title read before it became the filter.
    private func chipLabel(_ title: String, count: Int) -> String {
        let kind: LampModuleKind? = switch title {
        case "Translations": .translation
        case "Dictionaries": .dictionary
        case "Commentaries": .commentary
        case "Books": .book
        case "Reading Plans": .plan
        case "Writing": .devotional
        case "Quizzes": .quiz
        case "Notes": .notes
        case "Highlights": .highlights
        default: nil
        }
        return "\(count) \(kind.map { noun(for: $0, count: count) } ?? title.lowercased())"
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

    /// The page's own title, set large in the reading face — the shelf
    /// announces itself as a library before it is a grid.
    private var header: some View {
        Text("Modules")
            .font(.system(size: 32, weight: .bold, design: .serif))
            .accessibilityAddTraits(.isHeader)
    }

    /// What the library holds, a chip a kind: choosing some shows only
    /// those shelves, and choosing none shows them all.
    private var shelfChips: some View {
        WrappingRow(spacing: 8) {
            ForEach(shelfChoices, id: \.title) { choice in
                let isChosen = chosenShelves.contains(choice.title)
                Button {
                    toggleShelf(choice.title)
                } label: {
                    Text(chipLabel(choice.title, count: choice.count))
                        .monospacedDigit()
                        .foregroundStyle(isChosen ? Color.accentColor : Color.primary)
                        .moduleShelfChip(isChosen: isChosen)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
                .help(isChosen ? "Stop showing only these" : "Show only these")
            }
            if !chosenShelves.isEmpty {
                Button("Show All") { shelfFilter = "" }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .frame(height: 30)
                    .padding(.leading, 4)
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    if trimmedFilter.isEmpty {
                        header
                    }
                    shelfChips
                }
                if !personalModules.isEmpty {
                    shelfHeading(Self.personalShelf, count: personalModules.count)
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
                    // Only the words typed can empty the page: a kind is
                    // offered only while the library holds some of it.
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
            ToolbarItem {
                // The chips' choices again, for when they are scrolled away.
                Menu {
                    Button("All Modules") { shelfFilter = "" }
                    Divider()
                    ForEach(shelfChoices, id: \.title) { choice in
                        Toggle(choice.title, isOn: Binding(
                            get: { chosenShelves.contains(choice.title) },
                            set: { _ in toggleShelf(choice.title) }
                        ))
                    }
                } label: {
                    Label(
                        "Show",
                        systemImage: chosenShelves.isEmpty
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .help(chosenShelves.isEmpty
                    ? "Show only some kinds of module"
                    : "Showing " + chosenShelves.sorted().joined(separator: ", "))
            }
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
            isBuiltIn: module.isBundled,
            tagsStrongs: module.tagsStrongs
        ) {
            Button("Get Info", systemImage: "info.circle") {
                openWindow(id: "module-info", value: ModuleInfoRequest(moduleID: module.id))
            }
            if !module.isBundled {
                Divider()
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
            Button("Get Info", systemImage: "info.circle") {
                openWindow(id: "module-info", value: ModuleInfoRequest(moduleID: module.id))
            }
            if !module.isBundled {
                Divider()
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
            // The ancient languages by the names a reader knows them by
            // (core's): the locale calls Greek "Ancient Greek".
            return LampTranslationLanguages.name(of: module.language) ?? "Bible"
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
    /// A translation whose words carry Strong's numbers, marked so: its name
    /// no longer says so.
    var tagsStrongs = false
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
                if tagsStrongs { StrongsBadge() }
                HStack(spacing: 4) {
                    detail
                        .font(.system(size: 12))
                        .foregroundStyle(Color.lampSecondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Quiet at rest and full strength under the pointer.
                    //
                    // Every card carries it, built-in ones included. They had
                    // no button while export and remove were all it held and
                    // neither applies to a bundled module — but Get Info does,
                    // and most of a library is bundled, so without the button
                    // its details would be reachable only by right-clicking a
                    // cover that gives no sign there is a menu there.
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
                    .help(isBuiltIn ? "Details of \(name)" : "Details, export or remove \(name)")
                    .accessibilityLabel("Actions for \(name)")
                }
            }
            .frame(width: cover.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

/// The mark of a translation whose words carry Strong's numbers, which is
/// what the word studies, the analysis and the interlinear read.
///
/// Neutral, not accented. In the accent colour it pulled the eye across a
/// shelf of covers to a fact about a translation's data (owner, Nov 2026) —
/// and on the Scripture shelf most translations carry it, so the shelf lit
/// up in a row without distinguishing anything. It wears the unchosen
/// filter chip's fill and stroke, so it reads as a label rather than a
/// state worth acting on.
struct StrongsBadge: View {
    var body: some View {
        Text("Strong’s")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.lampSecondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.lampTileFill))
            .overlay(Capsule().strokeBorder(Color.lampCardStroke))
            .help("Its words are tagged with Strong’s numbers")
            .accessibilityLabel("Tagged with Strong’s numbers")
    }
}

extension LampInstalledModule {
    /// The badge a menu item can carry for a translation tagged with
    /// Strong's numbers, where a styled view cannot go.
    var strongsMenuBadge: Text? {
        tagsStrongs ? Text("Strong’s") : nil
    }
}

/// Translations as every picker groups them: by language, and within one,
/// whole Bibles before the Septuagint, a Testament or any other part.
enum TranslationGroups {
    static func of(_ translations: [LampInstalledModule]) -> [LampTranslationLanguages.Group<LampInstalledModule>] {
        LampTranslationLanguages.grouped(
            translations, language: \.language, holdsWholeBible: \.holdsWholeBible
        )
    }

    /// A language's whole Bibles, then a separator, then its parts, all in
    /// the language's one section. Not a section of their own inside it: a
    /// picker draws the options of a nested section disabled, so the
    /// Septuagint could not be chosen at all.
    @ViewBuilder
    static func parts<Rows: View>(
        of group: LampTranslationLanguages.Group<LampInstalledModule>,
        @ViewBuilder rows: @escaping ([LampInstalledModule]) -> Rows
    ) -> some View {
        ForEach(Array(group.parts.enumerated()), id: \.element.id) { index, part in
            if index > 0 { Divider() }
            rows(part.items)
        }
    }
}

/// A menu's translations as buttons, grouped by language the way
/// `TranslationPickerOptions` groups a picker's: the same sections, in the
/// same order, with the same Strong's badge. For a menu that acts on the
/// translation chosen rather than holding a selection.
struct TranslationMenuOptions: View {
    let translations: [LampInstalledModule]
    let choose: (LampInstalledModule) -> Void

    var body: some View {
        let groups = TranslationGroups.of(translations)
        if groups.count > 1 {
            ForEach(groups) { group in
                Section(group.title) { TranslationGroups.parts(of: group, rows: rows) }
            }
        } else if let group = groups.first {
            TranslationGroups.parts(of: group, rows: rows)
        }
    }

    private func rows(_ items: [LampInstalledModule]) -> some View {
        ForEach(items) { translation in
            Button { choose(translation) } label: {
                Text(translation.name)
                    .badge(translation.strongsMenuBadge)
            }
        }
    }

    /// Whether the menu shows language sections, so a caller with a heading
    /// of its own knows whether its heading can be a section's title.
    static func isGrouped(_ translations: [LampInstalledModule]) -> Bool {
        LampTranslationLanguages.grouped(translations, language: \.language).count > 1
    }
}

/// A picker's translations under the languages they are written in —
/// English, any other modern language, then the biblical languages — or one
/// plain list when they share a language. Within each, whole Bibles first and
/// then, below a separator, translations of part of it. Each carries its
/// Strong's badge.
struct TranslationPickerOptions<Tag: Hashable>: View {
    let translations: [LampInstalledModule]
    var title: (LampInstalledModule) -> String = { $0.name }
    let tag: (LampInstalledModule) -> Tag

    var body: some View {
        let groups = TranslationGroups.of(translations)
        if groups.count > 1 {
            ForEach(groups) { group in
                Section(group.title) { TranslationGroups.parts(of: group, rows: rows) }
            }
        } else if let group = groups.first {
            TranslationGroups.parts(of: group, rows: rows)
        }
    }

    private func rows(_ items: [LampInstalledModule]) -> some View {
        ForEach(items) { translation in
            Text(title(translation))
                .badge(translation.strongsMenuBadge)
                .tag(tag(translation))
        }
    }
}

private extension View {
    /// A shelf's chip: Search's filter capsule, tinted when chosen.
    func moduleShelfChip(isChosen: Bool) -> some View {
        font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(isChosen ? Color.accentColor.opacity(0.14) : Color.lampTileFill))
            .overlay(Capsule().strokeBorder(isChosen ? Color.accentColor.opacity(0.55) : Color.lampCardStroke))
            .contentShape(Capsule())
    }
}


/// Which module an info window is about.
///
/// The ID rather than the module: a window's value is encoded for it, and the
/// module is looked up again each time the window draws, so details that
/// change under it — a size after a sync, a name after an import — are not
/// shown stale from whenever the window was opened.
struct ModuleInfoRequest: Hashable, Codable {
    var moduleID: String = ""
}

/// Everything the library knows about one module.
///
/// The owner asked for this because two modules can wear the same name: with
/// `ESV` and `ESVs` both installed, the shelf shows "ESV" twice and nothing
/// on screen tells them apart. The identifier does, and it was not shown
/// anywhere before this.
///
/// A window rather than a sheet, as Finder's Get Info is (owner, Nov 2026):
/// a modal could not be opened twice, and comparing two modules that share a
/// name is the whole reason for it. One window per module, since the window
/// group is keyed by the request.
///
/// Nothing is left out and the technical fields sit behind a disclosure, as
/// the owner asked — a reader meeting a hash and a file name in a list of
/// publishers and languages learns less, not more. The same reveal the
/// analysis's Compare tab uses for the biblical-language texts.
struct ModuleInfoWindow: View {
    let request: ModuleInfoRequest

    @EnvironmentObject private var model: LibraryModel
    @State private var showsTechnicalDetails = false

    /// Every installed module, not only the ones `modules` holds: a reading
    /// plan, a writing, a quiz, notes and highlights are each their own
    /// module and each has a shelf of its own.
    private var everyModule: [LampInstalledModule] {
        model.modules + model.planModules + model.devotionalModules
            + model.quizModuleInstallations + model.noteModules + model.highlightModules
    }

    private var module: LampInstalledModule? {
        everyModule.first { $0.id == request.moduleID }
    }

    /// "English Standard Version (ESVs) Info" rather than a second window
    /// titled exactly like the first.
    ///
    /// Two modules wearing one name is the case this window exists for, and
    /// titling both of them "English Standard Version Info" would leave the
    /// reader comparing two windows they cannot tell apart — including in the
    /// Window menu, which is where you go to find the one behind the other.
    /// The identifier appears only when it is doing work.
    private func windowTitle(_ module: LampInstalledModule) -> String {
        let sharesName = everyModule.contains {
            $0.id != module.id && $0.name == module.name
        }
        return sharesName ? "\(module.name) (\(module.id)) Info" : "\(module.name) Info"
    }

    var body: some View {
        Group {
            if let module {
                content(module)
                    .navigationTitle(windowTitle(module))
            } else {
                noLongerInstalled
                    .navigationTitle("Module Info")
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 320, idealHeight: 460)
    }

    /// A window can outlive what it was opened for — a module removed here or
    /// on another device while its details were open. Saying so is better than
    /// an empty window or the last values it happened to hold.
    private var noLongerInstalled: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(Color.lampSecondaryText)
            Text("No Longer Installed")
                .font(.system(size: 14, weight: .semibold))
            Text("This module is not in your library any more.")
                .font(.system(size: 12))
                .foregroundStyle(Color.lampSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ module: LampInstalledModule) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(module)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("About", rows: aboutRows(module))
                    if module.kind == .translation {
                        group("Scripture", rows: scriptureRows(module))
                    }
                    technicalDetails(module)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(_ module: LampInstalledModule) -> some View {
        HStack(spacing: 14) {
            LibraryCover(
                monogram: module.abbreviation,
                title: module.name,
                systemImage: nil,
                seed: module.id,
                width: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.system(size: 15, weight: .semibold))
                    .textSelection(.enabled)
                Text(kindName(module.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.lampSecondaryText)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Rows

    private func aboutRows(_ module: LampInstalledModule) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let abbreviation = module.abbreviation, !abbreviation.isEmpty {
            rows.append(("Abbreviation", abbreviation))
        }
        if let language = module.language, !language.isEmpty {
            // "en" is not a language a reader recognises. The library holds a
            // `language_name` beside the code and does not expose it yet, so
            // the system names the code until core's record read lands; the
            // code itself stays, under Technical Details.
            let named = Locale.current.localizedString(forIdentifier: language)
                ?? Locale.current.localizedString(forLanguageCode: language)
            rows.append(("Language", named ?? language))
        }
        rows.append(("Source", module.isBundled ? "Built in to Lamp Bible" : "Installed"))
        if !module.isBundled {
            rows.append(("Size", ByteCountFormatter.string(
                fromByteCount: Int64(module.compressedByteCount), countStyle: .file
            )))
        }
        return rows
    }

    private func scriptureRows(_ module: LampInstalledModule) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Strong’s numbers", module.tagsStrongs ? "Tagged" : "Not tagged")
        ]
        if !module.coveredBooks.isEmpty {
            let chapters = module.coveredBooks.values.reduce(0, +)
            let books = module.coveredBooks.count
            rows.append((
                "Coverage",
                module.holdsWholeBible
                    ? "The whole Bible · \(chapters) chapters"
                    : "\(books) \(books == 1 ? "book" : "books") · \(chapters) chapters"
            ))
        }
        return rows
    }

    /// The fields that answer "which copy is this", kept behind a reveal.
    ///
    /// Thin for now: the library holds a version, a hash, a publisher, a
    /// licence, a versification and its timestamps, and `LampInstalledModule`
    /// carries none of them. Core is adding a read that returns the whole
    /// record, for this window and the phone's; this grows then.
    private func technicalRows(_ module: LampInstalledModule) -> [(String, String)] {
        var rows: [(String, String)] = [("Identifier", module.id)]
        if let language = module.language, !language.isEmpty {
            rows.append(("Language code", language))
        }
        let earlier = LampTranslationID.equivalents(of: module.id)
            .filter { $0 != module.id }
        if !earlier.isEmpty {
            rows.append((
                earlier.count == 1 ? "Earlier identifier" : "Earlier identifiers",
                earlier.joined(separator: ", ")
            ))
        }
        return rows
    }

    // MARK: Pieces

    private func technicalDetails(_ module: LampInstalledModule) -> some View {
        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(technicalRows(module), id: \.0) { row in
                    detailRow(row.0, row.1, monospaced: true)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Technical Details")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.lampSecondaryText)
        }
    }

    private func group(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.lampSecondaryText)
            ForEach(rows, id: \.0) { row in
                detailRow(row.0, row.1, monospaced: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ name: String, _ value: String, monospaced: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(Color.lampSecondaryText)
                .frame(width: 128, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Singular, for a field rather than a heading: the shelf headings say
    /// "Scripture" and "Books" over a list, which reads wrongly beside a name.
    private func kindName(_ kind: LampModuleKind) -> String {
        switch kind {
        case .translation: "Translation"
        case .dictionary: "Dictionary"
        case .commentary: "Commentary"
        case .book: "Book"
        case .devotional: "Writing"
        case .notes: "Notes"
        case .plan: "Reading plan"
        case .highlights: "Highlights"
        case .quiz: "Quiz"
        }
    }
}
