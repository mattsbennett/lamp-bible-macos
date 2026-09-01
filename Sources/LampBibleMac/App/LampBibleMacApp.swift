import AVFoundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import LampModuleKit
import SwiftUI

@main
struct LampBibleMacApp: App {
    @StateObject private var libraryModel = LibraryModel()
    @StateObject private var syncController = LibrarySyncController()
    @StateObject private var scrollLink = ReaderScrollLink()
    @StateObject private var presentationRemoteHost = LampPresentationRemoteHost()

    var body: some Scene {
        WindowGroup("Lamp Bible", id: "reader") {
            LibraryRootView()
                .environmentObject(libraryModel)
                .environmentObject(syncController)
                .environmentObject(scrollLink)
        }
        .defaultSize(width: 1_240, height: 820)
        .commands {
            LampBibleCommands()
        }

        WindowGroup("Book Reader", id: "book-reader", for: BookReaderRequest.self) { $request in
            StandaloneBookReaderView(request: request ?? BookReaderRequest())
                .environmentObject(libraryModel)
        }
        .defaultSize(width: 1_180, height: 820)

        Window("Import or Create Content", id: "add-to-library") {
            AddToLibraryView()
                .environmentObject(libraryModel)
        }
        .defaultSize(width: 1_100, height: 700)

        // A window rather than a sheet so a devotional can be written with the
        // reader open beside it — the scripture being written about is usually the
        // reason for writing.
        WindowGroup("Devotional", id: "devotional-editor", for: DevotionalEditorRequest.self) { $request in
            DevotionalEditorView(request: request ?? DevotionalEditorRequest())
                .environmentObject(libraryModel)
                .environmentObject(syncController)
        }
        .defaultSize(width: 1_180, height: 780)

        WindowGroup("Slide Studio", id: "slide-studio", for: SlideStudioRequest.self) { $request in
            SlideStudioView(request: request ?? SlideStudioRequest())
                .environmentObject(libraryModel)
                .environmentObject(presentationRemoteHost)
        }
        .defaultSize(width: 1_360, height: 860)

        WindowGroup(
            "Slide Presenter",
            id: "slide-presenter",
            for: SlidePresentationRequest.self
        ) { $request in
            if let request {
                SlidePresentationView(request: request)
                    .environmentObject(libraryModel)
                    .environmentObject(presentationRemoteHost)
            }
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)

        WindowGroup(
            "Presenter",
            id: "devotional-presenter",
            for: DevotionalPresentationRequest.self
        ) { $request in
            if let request {
                DevotionalPresentationView(request: request)
                    .environmentObject(libraryModel)
            }
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)

        Settings {
            ReaderSettingsView()
                .environmentObject(libraryModel)
                .environmentObject(syncController)
        }

        MenuBarExtra("Lamp Bible", systemImage: "book.closed.fill") {
            LampMenuBarView()
                .environmentObject(libraryModel)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct StandaloneBookReaderView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: LibraryModel

    let request: BookReaderRequest

    var body: some View {
        NavigationStack {
            BookModulesView(
                initialBookID: request.bookID,
                initialSectionID: request.sectionID,
                allowsStandaloneWindow: false,
                showImporter: { openWindow(id: "add-to-library") },
                openReference: { reference in
                    model.openReference(reference)
                    openWindow(id: "reader")
                }
            )
        }
    }
}

private struct ReaderSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var syncController: LibrarySyncController
    @AppStorage("reader.fontSize") private var fontSize = LampTextScale.readerText.defaultValue
    @AppStorage("reader.lineSpacing") private var lineSpacing = LampTextScale.readerLineSpacing.defaultValue
    @AppStorage("reader.typeface") private var typeface = ProseTypeface.readerDefault
    @AppStorage("commentary.fontSize") private var commentaryFontSize = LampTextScale.commentaryText.defaultValue
    @AppStorage("commentary.lineSpacing") private var commentaryLineSpacing = LampTextScale.commentaryLineSpacing.defaultValue
    @AppStorage("commentary.typeface") private var commentaryTypeface = ProseTypeface.commentaryDefault
    @AppStorage("books.fontSize") private var bookFontSize = LampTextScale.bookText.defaultValue
    @AppStorage("books.lineSpacing") private var bookLineSpacing = LampTextScale.bookLineSpacing.defaultValue
    @AppStorage("books.typeface") private var bookTypeface = ProseTypeface.readerDefault
    @AppStorage("reader.readAloud.voice") private var readAloudVoice = ""
    @AppStorage("reader.readAloud.rate") private var readAloudRate = 0.5
    @AppStorage("reader.readAloud.followAlong") private var followReadAloud = true
    @AppStorage("plans.wordsPerMinute") private var wordsPerMinute = 225
    @AppStorage("plans.externalBibleApp") private var externalBibleApp = ""
    @AppStorage("plans.reminder.enabled") private var reminderEnabled = false
    @AppStorage("plans.reminder.hour") private var reminderHour = 8
    @AppStorage("plans.reminder.minute") private var reminderMinute = 0
    @State private var reminderError: String?
    @AppStorage("reader.showStrongsHints") private var showStrongsHints = true
    @AppStorage("reader.crossReferences.canonicalOrder") private var canonicalCrossReferenceOrder = false
    @AppStorage("reader.defaultTranslationID") private var defaultTranslationID = ""
    @AppStorage("studyInspector.greekDictionaryModuleID") private var defaultGreekDictionaryID = ""
    @AppStorage("studyInspector.hebrewDictionaryModuleID") private var defaultHebrewDictionaryID = ""
    @AppStorage("studyInspector.commentaryModuleID") private var defaultCommentaryID = ""
    @State private var selectedSettingsSection = ReaderSettingsSection.reader
    @State private var selectedModuleType = ConfigurableModuleType.translations
    @AppStorage("devotional.fontSize")
    private var devotionalFontSize = LampTextScale.writingPreviewText.defaultValue
    @AppStorage("devotional.lineSpacing")
    private var devotionalLineSpacing = LampTextScale.writingPreviewLineSpacing.defaultValue
    @AppStorage("devotional.typeface")
    private var devotionalTypeface = ProseTypeface.readerDefault
    @AppStorage("devotional.editor.fontSize")
    private var writingEditorFontSize = LampTextScale.writingEditorText.defaultValue
    @AppStorage("writing.preview.fontSize")
    private var writingPreviewFontSize = LampTextScale.writingPreviewText.defaultValue
    @AppStorage("writing.preview.lineSpacing")
    private var writingPreviewLineSpacing = LampTextScale.writingPreviewLineSpacing.defaultValue
    @AppStorage("writing.preview.typeface")
    private var writingPreviewTypeface = ProseTypeface.readerDefault
    @AppStorage("writing.preview.followsEditorScrolling")
    private var writingPreviewFollowsEditorScrolling = true
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
    @AppStorage("agent.moduleAccess.enabled") private var agentModuleAccessEnabled = true
    @AppStorage("agent.moduleAccess.scope") private var agentModuleAccessScope = AgentModuleAccessScope.enabledModules.rawValue
    @AppStorage("agent.moduleAccess.personal") private var agentPersonalContentEnabled = false
    @State private var agentModuleAccessStatus: String?
    @AppStorage("sync.automatic") private var automaticSync = true
    @State private var webDAVEndpoint = ""
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted {
                ($0.name, $0.language).0.localizedStandardCompare(($1.name, $1.language).0) == .orderedAscending
            }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSettingsSection) {
                Section("Reading") {
                    settingsLink(.reader)
                    settingsLink(.books)
                    settingsLink(.studySidebar)
                    settingsLink(.readingPlans)
                }

                Section("Content") {
                    settingsLink(.modules)
                    settingsLink(.devotionalsAndQuizzes)
                    settingsLink(.writing)
                }

                Section("Services") {
                    settingsLink(.aiAndAgents)
                    settingsLink(.sync)
                }
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 235)
        } detail: {
            Form {
                switch selectedSettingsSection {
                case .reader:
                    Section("Reader") {
                        Picker("Typeface", selection: $typeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        metricSlider("Text Size", value: $fontSize, scale: .readerText)
                        metricSlider("Line Spacing", value: $lineSpacing, scale: .readerLineSpacing)
                        Picker("Read Aloud Voice", selection: $readAloudVoice) {
                            Text("System Default").tag("")
                            ForEach(voices, id: \.identifier) { voice in
                                Text("\(voice.name) — \(voice.language)").tag(voice.identifier)
                            }
                        }
                        LabeledContent("Read Aloud Speed") {
                            HStack {
                                Slider(value: $readAloudRate, in: 0.3...0.65, step: 0.025)
                                    .frame(width: 220)
                                Text(readAloudRate.formatted(.number.precision(.fractionLength(2))))
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                        Toggle("Follow the spoken verse", isOn: $followReadAloud)
                        Toggle("Show Strong’s number hints", isOn: $showStrongsHints)
                        Toggle("Sort cross-references canonically", isOn: $canonicalCrossReferenceOrder)
                        Button("Restore Reader Defaults") {
                            fontSize = LampTextScale.readerText.defaultValue
                            lineSpacing = LampTextScale.readerLineSpacing.defaultValue
                            typeface = .readerDefault
                            readAloudVoice = ""
                            readAloudRate = 0.5
                            followReadAloud = true
                            showStrongsHints = true
                            canonicalCrossReferenceOrder = false
                        }
                    }

                case .studySidebar:
                    Section("Study Sidebar") {
                        Picker("Typeface", selection: $commentaryTypeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        metricSlider("Text Size", value: $commentaryFontSize, scale: .commentaryText)
                        metricSlider(
                            "Line Spacing", value: $commentaryLineSpacing, scale: .commentaryLineSpacing)
                        Button("Restore Sidebar Defaults") {
                            commentaryFontSize = LampTextScale.commentaryText.defaultValue
                            commentaryLineSpacing = LampTextScale.commentaryLineSpacing.defaultValue
                            commentaryTypeface = .commentaryDefault
                        }
                    }

                case .books:
                    Section("Books") {
                        Picker("Typeface", selection: $bookTypeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        metricSlider("Text Size", value: $bookFontSize, scale: .bookText)
                        metricSlider(
                            "Line Spacing",
                            value: $bookLineSpacing,
                            scale: .bookLineSpacing
                        )
                        Button("Restore Book Defaults") {
                            bookFontSize = LampTextScale.bookText.defaultValue
                            bookLineSpacing = LampTextScale.bookLineSpacing.defaultValue
                            bookTypeface = .readerDefault
                        }
                    }

                case .modules:
                    Section("Modules") {
                        Picker("Module Type", selection: $selectedModuleType) {
                            ForEach(ConfigurableModuleType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch selectedModuleType {
                        case .translations:
                            Picker(
                                "Default Translation",
                                selection: Binding(
                                    get: { validDefault(defaultTranslationID, in: enabledTranslationModules) },
                                    set: {
                                        defaultTranslationID = $0
                                        model.setDefaultTranslation($0.isEmpty ? nil : $0)
                                    }
                                )
                            ) {
                                Text("First Enabled").tag("")
                                ForEach(enabledTranslationModules) { translation in
                                    Text(translation.name).tag(translation.id)
                                }
                            }
                            ForEach(translationModules) { module in
                                moduleToggle(module) {
                                    if defaultTranslationID == module.id {
                                        defaultTranslationID = ""
                                        model.setDefaultTranslation(nil)
                                    }
                                }
                            }

                        case .dictionaries:
                            Picker(
                                "Default Greek Dictionary",
                                selection: defaultModuleBinding(
                                    $defaultGreekDictionaryID,
                                    modules: enabledGreekDictionaryModules
                                )
                            ) {
                                Text("First Enabled").tag("")
                                ForEach(enabledGreekDictionaryModules) { dictionary in
                                    Text(dictionary.name).tag(dictionary.id)
                                }
                            }
                            Picker(
                                "Default Hebrew Dictionary",
                                selection: defaultModuleBinding(
                                    $defaultHebrewDictionaryID,
                                    modules: enabledHebrewDictionaryModules
                                )
                            ) {
                                Text("First Enabled").tag("")
                                ForEach(enabledHebrewDictionaryModules) { dictionary in
                                    Text(dictionary.name).tag(dictionary.id)
                                }
                            }
                            ForEach(dictionaryModules) { module in
                                moduleToggle(module) {
                                    if defaultGreekDictionaryID == module.id { defaultGreekDictionaryID = "" }
                                    if defaultHebrewDictionaryID == module.id { defaultHebrewDictionaryID = "" }
                                }
                            }

                        case .commentaries:
                            Picker(
                                "Default Commentary",
                                selection: defaultModuleBinding(
                                    $defaultCommentaryID, modules: enabledCommentaryModules)
                            ) {
                                Text("First Enabled").tag("")
                                ForEach(enabledCommentaryModules) { commentary in
                                    Text(commentary.name).tag(commentary.id)
                                }
                            }
                            ForEach(commentaryModules) { module in
                                moduleToggle(module) {
                                    if defaultCommentaryID == module.id { defaultCommentaryID = "" }
                                }
                            }
                        }
                    }

                case .devotionalsAndQuizzes:
                    Section("Devotionals & Quizzes") {
                        metricSlider(
                            "Devotional Text Size",
                            value: $devotionalFontSize,
                            scale: .writingPreviewText
                        )
                        metricSlider(
                            "Devotional Line Spacing",
                            value: $devotionalLineSpacing,
                            scale: .writingPreviewLineSpacing
                        )
                        Picker("Devotional Typeface", selection: $devotionalTypeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        TextField("Preferred quiz age-group ID", text: $defaultQuizAgeGroup)
                    }

                case .writing:
                    Section("Writing") {
                        metricSlider(
                            "Editor Text Size",
                            value: $writingEditorFontSize,
                            scale: .writingEditorText
                        )
                        metricSlider(
                            "Preview Text Size",
                            value: $writingPreviewFontSize,
                            scale: .writingPreviewText
                        )
                        metricSlider(
                            "Preview Line Spacing",
                            value: $writingPreviewLineSpacing,
                            scale: .writingPreviewLineSpacing
                        )
                        Picker("Preview Typeface", selection: $writingPreviewTypeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Toggle(
                            "Preview follows the editor while writing",
                            isOn: $writingPreviewFollowsEditorScrolling
                        )
                        Button("Restore Writing Defaults") {
                            writingEditorFontSize = LampTextScale.writingEditorText.defaultValue
                            writingPreviewFontSize = LampTextScale.writingPreviewText.defaultValue
                            writingPreviewLineSpacing = LampTextScale.writingPreviewLineSpacing.defaultValue
                            writingPreviewTypeface = ProseTypeface.readerDefault
                            writingPreviewFollowsEditorScrolling = true
                        }
                    }

                case .aiAndAgents:
                    Section("AI Provider Accounts") {
                        AIProviderAccountsSettingsView()
                        Divider()
                        Toggle("Allow agents to query Lamp modules", isOn: $agentModuleAccessEnabled)
                        Picker("Module Access", selection: $agentModuleAccessScope) {
                            ForEach(AgentModuleAccessScope.allCases) { scope in
                                Text(scope.title).tag(scope.rawValue)
                            }
                        }
                        .disabled(!agentModuleAccessEnabled)
                        Toggle(
                            "Include personal devotionals, notes, and highlights",
                            isOn: $agentPersonalContentEnabled
                        )
                        .disabled(!agentModuleAccessEnabled)
                        HStack {
                            Text(
                                "Module results are sent to the AI provider you launch. All Lamp tools are read-only."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("Test Module Tools", systemImage: "stethoscope") {
                                testAgentModuleAccess()
                            }
                            .controlSize(.small)
                            .disabled(!agentModuleAccessEnabled)
                        }
                        if let agentModuleAccessStatus {
                            Label(agentModuleAccessStatus, systemImage: "server.rack")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                case .readingPlans:
                    Section("Reading Plans") {
                        Stepper(
                            "Reading speed: \(wordsPerMinute) words per minute", value: $wordsPerMinute,
                            in: 80...600, step: 5)
                        Picker("Default External Bible", selection: $externalBibleApp) {
                            Text("Ask Each Time").tag("")
                            ForEach(ExternalBibleApplication.allCases) { application in
                                Text(application.rawValue).tag(application.rawValue)
                            }
                        }
                        Toggle("Daily reading reminder", isOn: $reminderEnabled)
                        DatePicker(
                            "Reminder Time",
                            selection: Binding(
                                get: { reminderDate },
                                set: { updateReminderTime($0) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.field)
                        .disabled(!reminderEnabled)
                        if let reminderError {
                            Label(reminderError, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }

                case .sync:
                    Section("Sync") {
                        Picker(
                            "Provider",
                            selection: Binding(
                                get: { syncController.provider },
                                set: { syncController.provider = $0 }
                            )
                        ) {
                            ForEach(LibrarySyncController.Provider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        if syncController.provider == .folder {
                            LabeledContent("Folder", value: syncController.folderName ?? "Not Chosen")
                            Button("Choose iCloud Drive or Folder…", systemImage: "folder") {
                                syncController.chooseFolder()
                            }
                        } else if syncController.provider == .webDAV {
                            TextField("WebDAV folder URL", text: $webDAVEndpoint)
                                .onChange(of: webDAVEndpoint) { _, value in syncController.endpoint = value }
                            TextField("Username", text: $webDAVUsername)
                                .onChange(of: webDAVUsername) { _, value in syncController.username = value }
                            LabeledContent("Password") {
                                HStack {
                                    SecureField("New password", text: $webDAVPassword)
                                        .frame(minWidth: 180)
                                        .help("Leave blank to keep the password already saved in Keychain")
                                    Button("Update Password") {
                                        if syncController.updateWebDAVPassword(webDAVPassword) {
                                            webDAVPassword = ""
                                        }
                                    }
                                    .disabled(webDAVPassword.isEmpty)
                                }
                            }
                        }
                        Toggle("Sync automatically when Lamp Bible opens", isOn: $automaticSync)
                            .disabled(syncController.provider == .off)
                        Text("Includes companion writing files, agent context, custom workspace skills, and revision history. Provider credentials and generated agent configuration stay on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                                Task {
                                    if !webDAVPassword.isEmpty {
                                        guard syncController.updateWebDAVPassword(webDAVPassword) else { return }
                                        webDAVPassword = ""
                                    }
                                    await syncController.sync(library: model.library)
                                    model.refresh()
                                }
                            }
                            .disabled(syncController.provider == .off || syncController.isSyncing)
                            if syncController.isSyncing { ProgressView().controlSize(.small) }
                            if let status = syncController.statusMessage {
                                Text(status).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if let error = syncController.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selectedSettingsSection.title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 880, height: 640)
        .onChange(of: reminderEnabled) { _, _ in applyReminder() }
        .onChange(of: reminderHour) { _, _ in applyReminder() }
        .onChange(of: reminderMinute) { _, _ in applyReminder() }
        .onAppear {
            webDAVEndpoint = syncController.endpoint
            webDAVUsername = syncController.username
        }
    }

    private func settingsLink(_ section: ReaderSettingsSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    /// The same bounds the `aA` menus step through, so a size set in Settings and a
    /// size set while reading are the same setting rather than two that disagree.
    private func metricSlider(
        _ title: String,
        value: Binding<Double>,
        scale: LampTextScale
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: scale.range, step: scale.step)
                    .frame(width: 220)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }

    private var reminderDate: Date {
        Calendar.current.date(from: DateComponents(hour: reminderHour, minute: reminderMinute)) ?? Date()
    }

    private func updateReminderTime(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        reminderHour = components.hour ?? 8
        reminderMinute = components.minute ?? 0
    }

    private func applyReminder() {
        let configuration = ReadingReminderConfiguration(
            isEnabled: reminderEnabled,
            hour: reminderHour,
            minute: reminderMinute
        )
        Task {
            do {
                try await ReadingReminderScheduler.apply(configuration)
                reminderError = nil
            } catch {
                reminderError = error.localizedDescription
            }
        }
    }

    private var translationModules: [LampInstalledModule] { modules(of: .translation) }
    private var dictionaryModules: [LampInstalledModule] { modules(of: .dictionary) }
    private var commentaryModules: [LampInstalledModule] { modules(of: .commentary) }

    private var enabledTranslationModules: [LampInstalledModule] {
        translationModules.filter(isEnabled)
    }

    private var enabledDictionaryModules: [LampInstalledModule] {
        dictionaryModules.filter(isEnabled)
    }

    private var enabledGreekDictionaryModules: [LampInstalledModule] {
        enabledDictionaryModules.filter { $0.biblicalOriginalLanguage == .greek }
    }

    private var enabledHebrewDictionaryModules: [LampInstalledModule] {
        enabledDictionaryModules.filter { $0.biblicalOriginalLanguage == .hebrew }
    }

    private var enabledCommentaryModules: [LampInstalledModule] {
        commentaryModules.filter(isEnabled)
    }

    private func modules(of kind: LampModuleKind) -> [LampInstalledModule] {
        model.modules
            .filter { $0.kind == kind }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func isEnabled(_ module: LampInstalledModule) -> Bool {
        !model.hiddenModuleIDs.contains(module.id)
    }

    private func validDefault(_ moduleID: String, in modules: [LampInstalledModule]) -> String {
        modules.contains(where: { $0.id == moduleID }) ? moduleID : ""
    }

    private func defaultModuleBinding(
        _ selection: Binding<String>,
        modules: [LampInstalledModule]
    ) -> Binding<String> {
        Binding(
            get: { validDefault(selection.wrappedValue, in: modules) },
            set: { selection.wrappedValue = $0 }
        )
    }

    private func moduleToggle(
        _ module: LampInstalledModule,
        onDisable: @escaping () -> Void
    ) -> some View {
        Toggle(module.name, isOn: Binding(
            get: { isEnabled(module) },
            set: { enabled in
                model.setModuleHidden(module.id, hidden: !enabled)
                if !enabled { onDisable() }
            }
        ))
    }

    private var currentAgentAccessPolicy: LampAgentAccessPolicy {
        AgentModuleAccessPreferences.policy(
            isEnabled: agentModuleAccessEnabled,
            scope: AgentModuleAccessScope(rawValue: agentModuleAccessScope) ?? .enabledModules,
            includesPersonalContent: agentPersonalContentEnabled,
            modules: model.modules,
            hiddenModuleIDs: model.hiddenModuleIDs
        )
    }

    private func testAgentModuleAccess() {
        agentModuleAccessStatus = "Checking…"
        Task {
            agentModuleAccessStatus = await AgentModuleAccessPreferences.healthCheck(
                policy: currentAgentAccessPolicy,
                libraryRootURL: model.library.rootURL,
                bundledModulesArchiveURL: Bundle.main.url(
                    forResource: "bundled_modules.db",
                    withExtension: "zlib"
                )
            )
        }
    }
}

private enum ReaderSettingsSection: String, CaseIterable, Identifiable {
    case reader
    case books
    case studySidebar
    case modules
    case devotionalsAndQuizzes
    case writing
    case aiAndAgents
    case readingPlans
    case sync

    var id: Self { self }

    var title: String {
        switch self {
        case .reader: "Reader"
        case .books: "Books"
        case .studySidebar: "Study Sidebar"
        case .modules: "Modules"
        case .devotionalsAndQuizzes: "Devotionals & Quizzes"
        case .writing: "Writing"
        case .aiAndAgents: "AI & Agents"
        case .readingPlans: "Reading Plans"
        case .sync: "Sync"
        }
    }

    var systemImage: String {
        switch self {
        case .reader: "book"
        case .books: "books.vertical"
        case .studySidebar: "sidebar.right"
        case .modules: "shippingbox"
        case .devotionalsAndQuizzes: "heart.text.square"
        case .writing: "square.and.pencil"
        case .aiAndAgents: "sparkles"
        case .readingPlans: "calendar"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

private enum ConfigurableModuleType: String, CaseIterable, Identifiable {
    case translations
    case dictionaries
    case commentaries

    var id: Self { self }
    var title: String { rawValue.capitalized }
}
