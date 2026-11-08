import AVFoundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import LampModuleKit
import SwiftUI

/// Lets the editors finish writing before the app goes away.
///
/// Lamp writes on a short delay so that typing never waits on a disk, and that
/// delay is spent in a task the process does not wait for. Without this, Quit
/// during that window threw the last edit away — the one case a view cannot
/// cover for itself.
final class LampAppDelegate: NSObject, NSApplicationDelegate {
    private var hasReplied = false

    /// Puts the daily reminder back if the switch is on and the system is not
    /// holding one.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let configuration = ReadingReminderConfiguration(
            isEnabled: defaults.bool(forKey: "plans.reminder.enabled"),
            hour: defaults.integer(forKey: "plans.reminder.hour"),
            minute: defaults.integer(forKey: "plans.reminder.minute")
        )
        Task { await ReadingReminderScheduler.reapplyIfMissing(configuration) }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        hasReplied = false
        let quiet = LampPendingWrites.shared.flushAll { [weak self] in
            self?.reply(to: sender)
        }
        guard !quiet else { return .terminateNow }

        // Never trap someone in an app that will not quit. A write still
        // outstanding after five seconds is not going to land, and a person
        // holding a laptop lid open is a worse outcome than a lost edit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            LampPendingWrites.shared.cancelQuietHandler()
            self?.reply(to: sender)
        }
        return .terminateLater
    }

    /// Answers once. Both the last write landing and the deadline can arrive,
    /// and replying twice is a programming error AppKit complains about.
    private func reply(to sender: NSApplication) {
        guard !hasReplied else { return }
        hasReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}

@main
struct LampBibleMacApp: App {
    @NSApplicationDelegateAdaptor(LampAppDelegate.self) private var appDelegate
    @StateObject private var libraryModel = LibraryModel()
    @StateObject private var syncController = LibrarySyncController()
    @StateObject private var scrollLink = ReaderScrollLink()
    @StateObject private var presentationRemoteHost = LampPresentationRemoteHost()
    @StateObject private var softwareUpdater = SoftwareUpdater()

    init() {
        // `@AppStorage`'s default is that property wrapper's own fallback and is
        // never written to UserDefaults, so code reading the raw value gets
        // `false` until the switch is touched. Sync at launch reads it that way,
        // so on a new install it never ran while Settings showed it on.
        UserDefaults.standard.register(defaults: [
            "sync.automatic": true,
            // Registered for the same reason: the launch reminder check reads
            // these raw, and an unregistered integer is 0, which would move
            // the reminder to midnight.
            "plans.reminder.hour": LampPreferenceDefaults.plansReminderHour,
            "plans.reminder.minute": LampPreferenceDefaults.plansReminderMinute,
        ])
    }

    var body: some Scene {
        WindowGroup("Lamp Bible", id: "reader") {
            LibraryRootView()
                .environmentObject(libraryModel)
                .environmentObject(syncController)
                .environmentObject(scrollLink)
        }
        .defaultSize(width: 1_240, height: 820)
        .commands {
            LampBibleCommands(softwareUpdater: softwareUpdater)
        }

        // A window that carries a value cannot be restored: AppKit keeps a
        // record of every window as it opens and closes and hands those records
        // back at the next launch, but SwiftUI restores such a window with no
        // value at all. Each group below reads no value as "start a new one", so
        // a writing editor killed with the app — which is what a rebuild does —
        // came back at the next launch as a blank new writing, beside whatever
        // was being written. Better not to come back than to come back as the
        // wrong thing.
        WindowGroup("Book Reader", id: "book-reader", for: BookReaderRequest.self) { $request in
            StandaloneBookReaderView(request: request ?? BookReaderRequest())
                .environmentObject(libraryModel)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1_180, height: 820)

        Window("Import or Create Content", id: "add-to-library") {
            AddToLibraryView()
                .environmentObject(libraryModel)
        }
        .defaultSize(width: 1_100, height: 700)

        // A window rather than a sheet so a devotional can be written with the
        // reader open beside it — the scripture being written about is usually the
        // reason for writing.
        WindowGroup("Writing", id: "devotional-editor", for: DevotionalEditorRequest.self) { $request in
            DevotionalEditorView(request: request ?? DevotionalEditorRequest())
                .environmentObject(libraryModel)
                .environmentObject(syncController)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1_180, height: 780)

        WindowGroup("Slide Studio", id: "slide-studio", for: SlideStudioRequest.self) { $request in
            SlideStudioView(request: request ?? SlideStudioRequest())
                .environmentObject(libraryModel)
                .environmentObject(presentationRemoteHost)
        }
        .restorationBehavior(.disabled)
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
        .restorationBehavior(.disabled)
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
        .restorationBehavior(.disabled)
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)

        Settings {
            ReaderSettingsView()
                .environmentObject(libraryModel)
                .environmentObject(syncController)
                .environmentObject(softwareUpdater)
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
                    openInReader(reference)
                }
            )
        }
        // A book's scripture popover reaches for these, and in this window
        // nothing supplied them — so its buttons looked like the way to the
        // passage and did nothing at all. There are no reader tabs here, so it
        // offers the one thing this window can do.
        .environment(\.readerReferenceActions, ReaderReferenceActions(
            owner: ObjectIdentifier(model),
            openInCurrent: { openInReader($0) },
            openInNewTab: { openInReader($0) },
            opensTabs: false
        ))
    }

    private func openInReader(_ reference: Int) {
        model.openReference(reference, translationID: nil)
        openWindow(id: "reader")
    }
}

private struct ReaderSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var syncController: LibrarySyncController
    @EnvironmentObject private var softwareUpdater: SoftwareUpdater
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
    @AppStorage("plans.wordsPerMinute")
    private var wordsPerMinute = LampPreferenceDefaults.plansWordsPerMinute
    @AppStorage(LampReadingMode.silent.wordsPerMinuteKey)
    private var silentWordsPerMinute = LampReadingMode.silent.defaultWordsPerMinute
    @AppStorage(LampReadingMode.aloud.wordsPerMinuteKey)
    private var aloudWordsPerMinute = LampReadingMode.aloud.defaultWordsPerMinute
    @AppStorage("plans.externalBibleApp") private var externalBibleApp = ""
    @AppStorage("plans.reminder.enabled") private var reminderEnabled = false
    @AppStorage("plans.reminder.hour")
    private var reminderHour = LampPreferenceDefaults.plansReminderHour
    @AppStorage("plans.reminder.minute")
    private var reminderMinute = LampPreferenceDefaults.plansReminderMinute
    @State private var reminderError: String?
    @AppStorage("reader.showStrongsHints") private var showStrongsHints = true
    @AppStorage("reader.crossReferences.canonicalOrder") private var canonicalCrossReferenceOrder = false
    @AppStorage("reader.defaultTranslationID") private var defaultTranslationID = ""
    @AppStorage("studyInspector.greekDictionaryModuleID") private var defaultGreekDictionaryID = ""
    @AppStorage("studyInspector.hebrewDictionaryModuleID") private var defaultHebrewDictionaryID = ""
    @AppStorage("studyInspector.commentaryModuleID") private var defaultCommentaryID = ""
    @State private var selectedSettingsSection = ReaderSettingsSection.reader
    private var settingsDestination: SettingsDestination { .shared }
    @State private var selectedModuleType = ConfigurableModuleType.translations
    @AppStorage("devotional.fontSize")
    private var devotionalFontSize = LampTextScale.writingReadingText.defaultValue
    @AppStorage("devotional.lineSpacing")
    private var devotionalLineSpacing = LampTextScale.writingReadingLineSpacing.defaultValue
    @AppStorage("devotional.typeface")
    private var devotionalTypeface = ProseTypeface.readerDefault
    @AppStorage("devotional.editor.fontSize")
    private var writingEditorFontSize = LampTextScale.writingEditorText.defaultValue
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
    @AppStorage("agent.moduleAccess.enabled") private var agentModuleAccessEnabled = true
    @AppStorage("agent.moduleAccess.scope") private var agentModuleAccessScope = AgentModuleAccessScope.enabledModules.rawValue
    @State private var externalAppsStatus: String?
    @AppStorage(AgentModuleAccessPreferences.allowsExternalAppsKey)
    private var agentAllowsExternalApps = false
    @AppStorage(AgentModuleAccessPreferences.allowsExternalWritingKey)
    private var agentAllowsExternalWriting = false
    @AppStorage(AgentModuleAccessPreferences.allowsExternalReadingPlansKey)
    private var agentAllowsExternalReadingPlans = false
    @AppStorage("agent.moduleAccess.personal") private var agentPersonalContentEnabled = false
    @AppStorage(ReaderChatWorkspaceStore.retentionKey)
    private var readerChatRetention = ReaderChatWorkspaceStore.Retention.standard.rawValue
    @State private var agentModuleAccessStatus: String?
    @AppStorage("sync.automatic") private var automaticSync = true
    @State private var webDAVEndpoint = ""
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var isForgettingSyncDetails = false

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
                Section {
                    settingsLink(.reader)
                    settingsLink(.books)
                    settingsLink(.studySidebar)
                    settingsLink(.readingPlans)
                } header: {
                    sidebarHeading("Reading")
                }

                Section {
                    settingsLink(.modules)
                    settingsLink(.writing)
                    settingsLink(.devotionalsAndQuizzes)
                } header: {
                    sidebarHeading("Content")
                }

                Section {
                    settingsLink(.aiAndAgents)
                    settingsLink(.sync)
                    settingsLink(.updates)
                } header: {
                    sidebarHeading("Services")
                }
            }
            .navigationTitle("Settings")
            // A fixed width, and the sidebar toggle gone: this list is the
            // whole of the Settings window's navigation, and a Settings
            // window whose sections are hidden is one nobody can find their
            // way back out of.
            //
            // The frame is not belt and braces. Removing the toggle costs
            // the column its stated width — measured at 144pt against the
            // 205 it took before, which truncated "Study Sidebar" and the
            // longest section name of the time — and neither
            // `navigationSplitViewColumnWidth`, in either form, nor a
            // constant `columnVisibility` wins it back. A frame does.
            .frame(width: 205)
            .navigationSplitViewColumnWidth(205)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch selectedSettingsSection {
                case .reader:
                    // In groups that say what they hold, rather than one
                    // card headed "Reader" under a window already titled
                    // "Reader".
                    Section {
                        ReaderTypePreview(
                            fontSize: fontSize,
                            lineSpacing: lineSpacing,
                            typeface: typeface
                        )
                    }
                    Section("Text") {
                        Picker("Typeface", selection: $typeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        metricSlider("Text Size", value: $fontSize, scale: .readerText, sizeGlyphs: true)
                        metricSlider("Line Spacing", value: $lineSpacing, scale: .readerLineSpacing)
                    }
                    Section("Read Aloud") {
                        Picker("Voice", selection: $readAloudVoice) {
                            Text("System Default").tag("")
                            ForEach(voices, id: \.identifier) { voice in
                                Text("\(voice.name) — \(voice.language)").tag(voice.identifier)
                            }
                        }
                        LabeledContent("Speed") {
                            // As a multiple of the normal pace, which the
                            // voice's raw rate (0.50) never said.
                            sliderRow(
                                value: $readAloudRate,
                                range: 0.3...0.65,
                                step: 0.025,
                                low: "tortoise",
                                high: "hare",
                                readout: readAloudSpeedDescription
                            )
                        }
                        Toggle("Follow the spoken verse", isOn: $followReadAloud)
                    }
                    Section {
                        Toggle("Show Strong’s number hints", isOn: $showStrongsHints)
                        Toggle("Sort cross-references canonically", isOn: $canonicalCrossReferenceOrder)
                    } header: {
                        Text("Study Aids")
                    } footer: {
                        HStack {
                            Spacer()
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
                        .padding(.top, 4)
                    }

                case .studySidebar:
                    Section("Study Sidebar") {
                        Picker("Typeface", selection: $commentaryTypeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        metricSlider("Text Size", value: $commentaryFontSize, scale: .commentaryText, sizeGlyphs: true)
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
                        metricSlider("Text Size", value: $bookFontSize, scale: .bookText, sizeGlyphs: true)
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
                    Section("Quizzes") {
                        TextField("Preferred age-group ID", text: $defaultQuizAgeGroup)
                    }

                case .writing:
                    Section("Editor") {
                        metricSlider(
                            "Text Size",
                            value: $writingEditorFontSize,
                            scale: .writingEditorText,
                            sizeGlyphs: true
                        )
                    }
                    // How a finished writing is set when it is read rather
                    // than edited. These were under "Devotionals & Quizzes",
                    // apart from the rest of Writing.
                    Section("Reading") {
                        Picker("Typeface", selection: $devotionalTypeface) {
                            ForEach(ProseTypeface.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        metricSlider(
                            "Text Size",
                            value: $devotionalFontSize,
                            scale: .writingReadingText,
                            sizeGlyphs: true
                        )
                        metricSlider(
                            "Line Spacing",
                            value: $devotionalLineSpacing,
                            scale: .writingReadingLineSpacing
                        )
                    }
                    Section {
                        // A talk is written to be spoken and a devotional to be
                        // read, and the same words take half as long again out
                        // loud — so each pace keeps its own rate. Which of the
                        // two an estimate uses is chosen by clicking it.
                        Stepper(
                            "Silent reading: \(silentWordsPerMinute) words per minute",
                            value: $silentWordsPerMinute,
                            in: 80...600,
                            step: 5
                        )
                        Stepper(
                            "Reading aloud: \(aloudWordsPerMinute) words per minute",
                            value: $aloudWordsPerMinute,
                            in: 60...300,
                            step: 5
                        )
                    } header: {
                        Text("Reading Time")
                    } footer: {
                        HStack {
                            Spacer()
                            Button("Restore Writing Defaults") {
                                writingEditorFontSize = LampTextScale.writingEditorText.defaultValue
                                silentWordsPerMinute = LampReadingMode.silent.defaultWordsPerMinute
                                aloudWordsPerMinute = LampReadingMode.aloud.defaultWordsPerMinute
                            }
                        }
                        .padding(.top, 4)
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
                            "Include personal writing, notes, and highlights",
                            isOn: $agentPersonalContentEnabled
                        )
                        .disabled(!agentModuleAccessEnabled)
                        HStack {
                            Text(
                                """
                                Module results are sent to the AI provider you \
                                launch. Lamp's tools only read your library, \
                                apart from the two switches under Use Lamp in \
                                Other Apps.
                                """
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

                    Section("Reader Chats") {
                        Picker("Keep chats for", selection: $readerChatRetention) {
                            ForEach(ReaderChatWorkspaceStore.Retention.allCases, id: \.rawValue) {
                                Text($0.title).tag($0.rawValue)
                            }
                        }
                        Text(
                            """
                            Each reader tab keeps its own chat, and the pane \
                            lists the ones you can go back to. A chat nothing \
                            was said in is not kept, and the rest are let go \
                            of when Lamp next opens, once they are older than \
                            this.
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section("Use Lamp in Other Apps") {
                        Toggle(
                            "Allow other apps to read my library",
                            isOn: $agentAllowsExternalApps
                        )
                        .disabled(!agentModuleAccessEnabled)
                        Text(
                            """
                            Separate from writing: these apps can read, and \
                            nothing more. What they read goes to whichever AI \
                            provider that app uses, not to Lamp's.
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Toggle(
                            "Allow other apps to change my writings",
                            isOn: $agentAllowsExternalWriting
                        )
                        .disabled(!agentModuleAccessEnabled || !agentAllowsExternalApps)
                        Text(
                            """
                            An agent in another app can rewrite a writing's \
                            draft, which Lamp takes in when you next open that \
                            writing's agent workspace. It cannot write over an \
                            edit of yours it had not seen. Your draft is sent \
                            to that app's AI provider.
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Toggle(
                            "Allow other apps to add reading plans",
                            isOn: $agentAllowsExternalReadingPlans
                        )
                        .disabled(!agentModuleAccessEnabled || !agentAllowsExternalApps)
                        Text(
                            """
                            An agent in another app can ask for a reading plan \
                            over the passages you name, which Lamp lays out \
                            and adds when it next reads its library. It adds \
                            plans and nothing else: it cannot change or remove \
                            anything already in your library.
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if agentModuleAccessEnabled, agentAllowsExternalApps {
                            externalAppsSetup
                        }
                    }
                    // The helper reads the policy and the descriptor from
                    // disk, so a setting changed here has to reach them
                    // without waiting for someone to press Test.
                    .onChange(of: agentModuleAccessEnabled) { _, _ in publishAgentAccess() }
                    .onChange(of: agentModuleAccessScope) { _, _ in publishAgentAccess() }
                    .onChange(of: agentPersonalContentEnabled) { _, _ in publishAgentAccess() }
                    .onChange(of: agentAllowsExternalApps) { _, _ in publishAgentAccess() }
                    .onChange(of: agentAllowsExternalWriting) { _, _ in publishAgentAccess() }
                    .onChange(of: agentAllowsExternalReadingPlans) { _, _ in publishAgentAccess() }
                    .task { publishAgentAccess() }

                case .readingPlans:
                    Section("Reading Plans") {
                        Stepper(
                            "Reading speed: \(wordsPerMinute) words per minute", value: $wordsPerMinute,
                            in: 80...600, step: 5)
                        Picker("Default External Bible", selection: $externalBibleApp) {
                            Text("Ask Each Time").tag("")
                            // An app that isn't installed is shown greyed
                            // rather than left out, so this says which Bible
                            // apps Lamp can hand a reading to. One that could
                            // never work here is not listed at all.
                            ForEach(ExternalBibleApplication.offeredOnThisMac) { application in
                                Text(application.rawValue)
                                    .tag(application.rawValue)
                                    .disabled(!application.canOpenOnThisMac)
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

                case .updates:
                    Section("Software Updates") {
                        LabeledContent("Version", value: appVersion)
                        if softwareUpdater.isConfigured {
                            Toggle("Check for updates automatically", isOn: Binding(
                                get: { softwareUpdater.automaticallyChecksForUpdates },
                                set: { softwareUpdater.automaticallyChecksForUpdates = $0 }
                            ))
                            Toggle("Download and install updates automatically", isOn: Binding(
                                get: { softwareUpdater.automaticallyDownloadsUpdates },
                                set: { softwareUpdater.automaticallyDownloadsUpdates = $0 }
                            ))
                            .disabled(
                                !softwareUpdater.automaticallyChecksForUpdates
                                    || !softwareUpdater.allowsAutomaticUpdates
                            )
                            LabeledContent(
                                "Last Checked",
                                value: softwareUpdater.lastUpdateCheckDate?
                                    .formatted(date: .abbreviated, time: .shortened) ?? "Never"
                            )
                            Text("Checking downloads a small update feed from lampbible.com. Like any web request it reveals your IP address and identifies the app and its version; nothing about you or your library is sent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Check Now", systemImage: "arrow.down.circle") {
                                softwareUpdater.checkForUpdates()
                            }
                            .disabled(!softwareUpdater.canCheckForUpdates)
                        } else {
                            Text("Automatic updates aren’t configured in this build.")
                                .foregroundStyle(.secondary)
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
                        if syncController.provider == .off, syncController.hasRememberedDetails {
                            // Off keeps the server details so sync can be
                            // turned back on without typing them again. Said
                            // out loud, because "Off" reads as disconnected.
                            Text("Sync is off. Your server details are still saved on this Mac, so you can turn it back on without entering them again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Forget Sync Details…", systemImage: "trash", role: .destructive) {
                            isForgettingSyncDetails = true
                        }
                        .disabled(!syncController.hasRememberedDetails)
                        .confirmationDialog(
                            "Forget sync details?",
                            isPresented: $isForgettingSyncDetails,
                            titleVisibility: .visible
                        ) {
                            Button("Forget Details", role: .destructive) {
                                syncController.forgetSyncDetails()
                                webDAVEndpoint = ""
                                webDAVUsername = ""
                                webDAVPassword = ""
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This removes the folder, WebDAV address and username, and the password in your keychain, and turns sync off. Nothing already synced is deleted, here or on the server.")
                        }
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

                    if let offer = syncController.moveOffer {
                        Section(offer.title) {
                            Text(offer.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(offer.buttonTitle) {
                                Task {
                                    await syncController.move(library: model.library)
                                    model.refresh()
                                }
                            }
                            .disabled(syncController.isSyncing)
                        }
                    }

                    if !syncController.conflicts.isEmpty {
                        Section("Needs Your Decision") {
                            Text(SyncConflictSummary.text(for: syncController.conflicts))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(syncController.conflicts) { conflict in
                                SyncConflictRow(conflict: conflict) { side in
                                    Task {
                                        await syncController.resolve(
                                            conflict, keeping: side, library: model.library
                                        )
                                        model.refresh()
                                    }
                                } dismiss: {
                                    Task {
                                        await syncController.dismiss(conflict, library: model.library)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selectedSettingsSection.title)
            .onAppear { goToRequestedSection() }
            .onChange(of: settingsDestination.section) { _, _ in goToRequestedSection() }
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
        // A conflict outlives the run that found it, so the pane has to ask
        // rather than wait to be told.
        .task { await syncController.refreshConflicts(library: model.library) }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    /// A sidebar group's name in the readable secondary grey. The sidebar's
    /// own heading grey faded almost to nothing on the dark window.
    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(Color.lampSecondaryText)
    }

    /// Moves to the section a button elsewhere asked for, once.
    private func goToRequestedSection() {
        guard let asked = settingsDestination.section else { return }
        selectedSettingsSection = asked
        settingsDestination.section = nil
    }

    private func settingsLink(_ section: ReaderSettingsSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    /// The same bounds the `aA` menus step through, so a size set in Settings and a
    /// size set while reading are the same setting rather than two that disagree.
    ///
    /// The value carries its unit, points, which the bare "20" and "7" left
    /// to be guessed; a size slider has a small and a large letter at its
    /// ends, as the system's own do.
    private func metricSlider(
        _ title: String,
        value: Binding<Double>,
        scale: LampTextScale,
        sizeGlyphs: Bool = false
    ) -> some View {
        LabeledContent(title) {
            sliderRow(
                value: value,
                range: scale.range,
                step: scale.step,
                low: sizeGlyphs ? "textformat.size.smaller" : "arrow.down.and.line.horizontal.and.arrow.up",
                high: sizeGlyphs ? "textformat.size.larger" : "arrow.up.and.line.horizontal.and.arrow.down",
                readout: "\(value.wrappedValue.formatted(.number.precision(.fractionLength(0)))) pt"
            )
        }
    }

    /// One slider's controls: an end glyph, the track, the other end glyph
    /// and its value — each in a slot of fixed width, so every slider on a
    /// page starts and ends at the same place. The glyphs differed in width
    /// from slider to slider, and the tracks wandered with them.
    private func sliderRow(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        low: String,
        high: String,
        readout: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: low)
                .foregroundStyle(Color.lampSecondaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Slider(value: value, in: range, step: step)
                .frame(width: 230)
            Image(systemName: high)
                .foregroundStyle(Color.lampSecondaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(readout)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
    }

    /// The read-aloud rate as a multiple of the voice's normal pace, 0.5.
    private var readAloudSpeedDescription: String {
        "\((readAloudRate / 0.5).formatted(.number.precision(.fractionLength(1))))×"
    }

    private var reminderDate: Date {
        Calendar.current.date(from: DateComponents(hour: reminderHour, minute: reminderMinute)) ?? Date()
    }

    private func updateReminderTime(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        reminderHour = components.hour ?? LampPreferenceDefaults.plansReminderHour
        reminderMinute = components.minute ?? LampPreferenceDefaults.plansReminderMinute
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

    /// What every outside app's configuration will name, once the launcher is
    /// installed beside the descriptor.
    private var externalAppSetup: LampExternalAppSetup? {
        guard let applicationSupport =
            LampAgentDescriptorStore.defaultApplicationSupportURL() else { return nil }
        return LampExternalAppSetup(
            launcherURL: LampExternalAppSetup.launcherURL(
                inApplicationSupport: applicationSupport
            ),
            appVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        )
    }

    @ViewBuilder private var externalAppsSetup: some View {
        if let setup = externalAppSetup {
            HStack {
                Text("Claude Desktop")
                Spacer()
                Button("Add to Claude Desktop…", systemImage: "square.and.arrow.down") {
                    addToClaudeDesktop(setup)
                }
                .controlSize(.small)
            }
            Text(
                """
                Opens a bundle for Claude Desktop to install. Claude asks \
                before adding it; Lamp does not change another app's settings.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            ForEach(setup.pasteableApps) { app in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text(app.destination)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        copyExternalAppSnippet(app)
                    }
                    .controlSize(.small)
                }
            }
            Text("Paste each one into that app's own configuration file yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let externalAppsStatus {
                Label(externalAppsStatus, systemImage: "app.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label(
                "No Application Support folder, so other apps cannot be set up.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func copyExternalAppSnippet(_ app: LampExternalApp) {
        // The launcher has to exist before anyone pastes a config naming it.
        installExternalLauncher()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.snippet, forType: .string)
        externalAppsStatus = "Copied the \(app.name) snippet. Paste it into \(app.destination)."
    }

    /// Builds the `.mcpb` and hands it to Claude Desktop, whose own dialog
    /// does the installing. Lamp writes nothing into Claude's configuration.
    private func addToClaudeDesktop(_ setup: LampExternalAppSetup) {
        externalAppsStatus = "Building the bundle…"
        Task {
            do {
                installExternalLauncher()
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lamp-mcpb-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: staging) }
                let contents = staging.appendingPathComponent("bundle", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: contents, withIntermediateDirectories: true
                )
                try LampExternalAppInstaller.writeBundleContents(setup, to: contents)

                // Somewhere it will still exist after this function returns,
                // since Claude Desktop opens it asynchronously.
                let bundleURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lamp-bible.mcpb")
                try? FileManager.default.removeItem(at: bundleURL)
                try await compressDirectory(contents, to: bundleURL)

                NSWorkspace.shared.open(bundleURL)
                externalAppsStatus = "Opened lamp-bible.mcpb — Claude Desktop will ask to install it."
            } catch {
                externalAppsStatus = error.localizedDescription
            }
        }
    }

    private func installExternalLauncher() {
        guard let applicationSupport =
            LampAgentDescriptorStore.defaultApplicationSupportURL() else { return }
        try? LampExternalAppInstaller.installLauncher(inApplicationSupport: applicationSupport)
    }

    /// `ditto -c -k` with no `--keepParent`, so the manifest lands at the root
    /// of the archive where the format expects it.
    ///
    /// `--norsrc --noextattr` because without them ditto writes an AppleDouble
    /// `._` sidecar beside every entry, and `._manifest.json` next to the
    /// manifest is not something to hand another app as a bundle. The
    /// executable bit on the launcher survives either way; it is stored in the
    /// zip entry's own mode, not in an extended attribute.
    private func compressDirectory(_ directory: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c", "-k", "--norsrc", "--noextattr", directory.path, destination.path,
            ]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ExternalAppSetupFailure(
                    detail: String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }.value
    }

    /// The archive the bundled modules live in, which both the descriptor and
    /// the health check have to name identically — they are the same library.
    private var bundledModulesArchiveURL: URL? {
        Bundle.main.url(forResource: "bundled_modules.db", withExtension: "zlib")
    }

    /// Puts the current settings where the helper reads them.
    ///
    /// Silent on failure by design: this runs on every toggle, and a library
    /// that is momentarily unwritable is not something to interrupt someone
    /// changing a setting about. "Test Module Tools" is the button that
    /// reports, and it writes the same two files first.
    private func publishAgentAccess() {
        try? AgentModuleAccessPreferences.publish(
            currentAgentAccessPolicy,
            libraryRootURL: model.library.rootURL,
            bundledModulesArchiveURL: bundledModulesArchiveURL,
            allowsExternalApps: agentAllowsExternalApps,
            allowsExternalWriting: agentAllowsExternalWriting,
            allowsExternalReadingPlans: agentAllowsExternalReadingPlans
        )
    }

    private func testAgentModuleAccess() {
        agentModuleAccessStatus = "Checking…"
        Task {
            agentModuleAccessStatus = await AgentModuleAccessPreferences.healthCheck(
                policy: currentAgentAccessPolicy,
                libraryRootURL: model.library.rootURL,
                bundledModulesArchiveURL: bundledModulesArchiveURL
            )
        }
    }
}

/// The section Settings should open on, for a button elsewhere that means a
/// particular one.
///
/// Observed rather than read once: the window may already be open, in which
/// case opening it again only brings it forward and nothing appears, so the
/// view has to be told to move while it stands.
@MainActor @Observable
final class SettingsDestination {
    static let shared = SettingsDestination()

    /// Set by whoever opens Settings, cleared by Settings on arriving.
    var section: ReaderSettingsSection?

    private init() {}
}

enum ReaderSettingsSection: String, CaseIterable, Identifiable {
    case reader
    case books
    case studySidebar
    case modules
    case devotionalsAndQuizzes
    case writing
    case aiAndAgents
    case readingPlans
    case sync
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .reader: "Reader"
        case .books: "Books"
        case .studySidebar: "Study Sidebar"
        case .modules: "Modules"
        // The case keeps its stored name; on screen the app says
        // "writing", and the writing settings live under Writing.
        case .devotionalsAndQuizzes: "Quizzes"
        case .writing: "Writing"
        case .aiAndAgents: "AI & Agents"
        case .readingPlans: "Reading Plans"
        case .sync: "Sync"
        case .updates: "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .reader: "book"
        case .books: "books.vertical"
        case .studySidebar: "sidebar.right"
        case .modules: "shippingbox"
        case .devotionalsAndQuizzes: "questionmark.bubble"
        case .writing: "square.and.pencil"
        case .aiAndAgents: "sparkles"
        case .readingPlans: "calendar"
        case .sync: "arrow.triangle.2.circlepath"
        case .updates: "arrow.down.circle"
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

/// Why setting another app up did not work, with whatever the tool said.
private struct ExternalAppSetupFailure: Error, LocalizedError {
    let detail: String

    var errorDescription: String? {
        detail.isEmpty
            ? "The Claude Desktop bundle could not be built."
            : "The Claude Desktop bundle could not be built: \(detail)"
    }
}

/// A few verses set the way the reader will set them, so a change to the
/// typeface, size or spacing is seen as it is made rather than taken on trust
/// until the next chapter is opened.
private struct ReaderTypePreview: View {
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface

    /// John 1:1–2 in the Berean Standard Bible, which is in the public domain.
    private let verses: [(number: Int, text: String)] = [
        (1, "In the beginning was the Word, and the Word was with God, and the Word was God."),
        (2, "He was with God in the beginning."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            verses.reduce(Text("")) { text, verse in
                text
                    + Text("\(verse.number)")
                        .font(.system(size: max(9, fontSize * 0.6), weight: .semibold, design: typeface.design))
                        .foregroundStyle(Color.lampVerseNumber)
                        .baselineOffset(fontSize * 0.3)
                    + Text("\u{2009}\(verse.text) ")
            }
            .font(.system(size: fontSize, design: typeface.design))
            .lineSpacing(lineSpacing)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of the reader text")
        .animation(.easeOut(duration: 0.15), value: fontSize)
        .animation(.easeOut(duration: 0.15), value: lineSpacing)
    }
}
