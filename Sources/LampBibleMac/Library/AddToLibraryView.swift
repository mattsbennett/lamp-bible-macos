import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let lampModuleFile = UTType(
        exportedAs: "com.neus.lamp-bible.lamp",
        conformingTo: .data
    )
    static let markdownFile = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}

private enum LibraryAdditionPath: String, CaseIterable, Identifiable {
    case installModule
    case importBible
    case importStudyData
    case buildModule

    var id: Self { self }

    var title: String {
        switch self {
        case .installModule: "Install Module"
        case .importBible: "Import a Bible"
        case .importStudyData: "Import Personal Content"
        case .buildModule: "Create Module"
        }
    }

    var sidebarDescription: String {
        switch self {
        case .installModule: "Install a finished .lamp content package"
        case .importBible: "Bring in a USFM, OSIS or XML Bible you own"
        case .importStudyData: "Import .md writing or restore Lamp exports"
        case .buildModule: "Validate source .json and build a .lamp file"
        }
    }

    var systemImage: String {
        switch self {
        case .installModule: "shippingbox.and.arrow.backward"
        case .importBible: "text.book.closed"
        case .importStudyData: "arrow.up.arrow.down.square"
        case .buildModule: "hammer"
        }
    }
}

/// One front door for installing modules, restoring personal data, and authoring
/// module packages. The authoring workspace is embedded so the entire workflow
/// stays in this window.
struct AddToLibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    @StateObject private var moduleStudioModel = ModuleStudioModel()
    @State private var selection = LibraryAdditionPath.installModule
    @State private var showingModuleImporter = false
    @State private var showingBibleImporter = false
    @State private var showingStudyDataImporter = false
    @State private var showingNotesMarkdownImporter = false
    @State private var showingDevotionalsMarkdownImporter = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Modules") {
                    pathRow(.installModule)
                    pathRow(.importBible)
                    pathRow(.buildModule)
                }

                Section("Personal Data") {
                    pathRow(.importStudyData)
                }
            }
            .navigationTitle("Import or Create Content")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
        } detail: {
            switch selection {
            case .installModule:
                ScrollView {
                    installModulePane
                        .frame(maxWidth: 610, alignment: .leading)
                        .padding(40)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            case .importBible:
                ScrollView {
                    importBiblePane
                        .frame(maxWidth: 610, alignment: .leading)
                        .padding(40)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            case .importStudyData:
                ScrollView {
                    importStudyDataPane
                        .frame(maxWidth: 610, alignment: .leading)
                        .padding(40)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            case .buildModule:
                ModuleStudioView(model: moduleStudioModel)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 600)
        .fileImporter(
            isPresented: $showingModuleImporter,
            allowedContentTypes: [.lampModuleFile],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.install(urls)
            }
        }
        .fileImporter(
            isPresented: $showingBibleImporter,
            // USFM has no system type of its own, and a Bible may be a folder
            // of books; the importer says what it can't read.
            allowedContentTypes: [.folder, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.readTranslation(at: url)
            }
        }
        .sheet(item: $model.pendingTranslationImport) { pending in
            TranslationImportSheet(pending: pending, installed: model.modules) { name, abbreviation, language in
                model.importTranslation(pending, name: name, abbreviation: abbreviation, language: language)
            }
        }
        .fileImporter(
            isPresented: $showingStudyDataImporter,
            allowedContentTypes: [.json, .lampModuleFile],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importPersonalStudyData(urls)
            }
        }
        .fileImporter(
            isPresented: $showingNotesMarkdownImporter,
            allowedContentTypes: [.markdownFile],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importPersonalMarkdown(urls, as: .notes)
            }
        }
        .fileImporter(
            isPresented: $showingDevotionalsMarkdownImporter,
            allowedContentTypes: [.markdownFile],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importPersonalMarkdown(urls, as: .devotionals)
            }
        }
        .alert(
            "Lamp Bible",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "The operation could not be completed.")
        }
        .alert(
            "Translation Imported",
            isPresented: Binding(
                get: { model.translationImportMessage != nil },
                set: { if !$0 { model.translationImportMessage = nil } }
            )
        ) {
            Button("OK") { model.translationImportMessage = nil }
        } message: {
            Text(model.translationImportMessage ?? "The translation is in your library.")
        }
        .alert(
            "Personal Content Imported",
            isPresented: Binding(
                get: { model.studyImportMessage != nil },
                set: { if !$0 { model.studyImportMessage = nil } }
            )
        ) {
            Button("OK") { model.studyImportMessage = nil }
        } message: {
            Text(model.studyImportMessage ?? "Your personal study data was imported.")
        }
    }

    private var installModulePane: some View {
        pathPane(
            title: "Install a .lamp Module",
            systemImage: "shippingbox.and.arrow.backward",
            description: "Open a finished .lamp package to install ready-to-use library content. A module can contain a Bible translation, reading plan, devotional, quiz, dictionary, commentary, or book.",
            distinction: "Input: a finished .lamp content module. This adds reference content to your library; it does not restore or alter personal notes and highlights.",
            steps: [
                ("Choose one or more finished .lamp modules.", "Lamp validates each package before adding it to your library."),
                ("Use the new content immediately.", "Installed modules appear in their matching library section and can be enabled or disabled in Settings."),
            ]
        ) {
            Button("Choose .lamp Modules…", systemImage: "folder") {
                showingModuleImporter = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isImporting)

            if model.isImporting {
                ProgressView("Installing modules…")
            }
        }
    }

    private var importBiblePane: some View {
        pathPane(
            title: "Import a Bible You Own",
            systemImage: "text.book.closed",
            description: "Turn a Bible you already have into a translation in your library: USFM, OSIS, Zefania or another XML Bible, as a single file, a folder of books, or a zip.",
            distinction: "Input: a Bible in another app’s format. Lamp converts it once and keeps the translation in your library, where it syncs like your other modules. Import only Bibles you have the right to use.",
            steps: [
                ("Choose the file, folder or zip.", "Lamp reads it and shows what it found, including anything it had to leave out, such as books outside the 66."),
                ("Name it and import.", "Give the translation a name and abbreviation. Importing the same abbreviation again replaces the earlier import."),
            ]
        ) {
            Button("Choose a Bible…", systemImage: "folder") {
                showingBibleImporter = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isReadingTranslation || model.isImporting)

            if model.isReadingTranslation {
                ProgressView("Reading the Bible…")
            } else if model.isImporting {
                ProgressView("Importing…")
            }
        }
    }

    private var importStudyDataPane: some View {
        pathPane(
            title: "Import Personal Content",
            systemImage: "arrow.up.arrow.down.square",
            description: "Bring editable Markdown into My Notes or My Writing, or restore notes and highlights from a structured Lamp Bible export.",
            distinction: "Markdown (.md) imports editable notes or writing. Lamp exports (.json or .lamp) restore structured notes or highlights. None of these install reference-library content.",
            steps: [
                ("Import editable Markdown.", "Choose whether each .md file contains verse-linked notes or writing entries."),
                ("Or restore a Lamp export.", "A personal-study .json or .lamp file preserves structured notes or highlights."),
            ]
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("Import Notes from .md…", systemImage: "note.text") {
                        showingNotesMarkdownImporter = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Import Writing from .md…", systemImage: "book.closed") {
                        showingDevotionalsMarkdownImporter = true
                    }
                }

                Button("Restore Notes or Highlights from .json/.lamp…", systemImage: "archivebox") {
                    showingStudyDataImporter = true
                }
            }
            .controlSize(.large)
            .disabled(model.isImportingStudyData)

            if model.isImportingStudyData {
                ProgressView("Importing study data…")
            }
        }
    }

    private func pathRow(_ path: LibraryAdditionPath) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(path.title)
                Text(path.sidebarDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: path.systemImage)
        }
        .tag(path)
        .padding(.vertical, 4)
    }

    private func pathPane<Actions: View>(
        title: String,
        systemImage: String,
        description: String,
        distinction: String,
        steps: [(title: String, detail: String)],
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.largeTitle.bold())
                Text(description)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                Label {
                    Text(distinction)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("How it works")
                    .font(.headline)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.tint, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(.headline)
                            Text(step.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                actions()
            }
        }
    }
}
