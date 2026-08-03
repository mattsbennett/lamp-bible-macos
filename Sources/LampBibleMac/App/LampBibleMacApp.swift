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

    var body: some Scene {
        WindowGroup("Lamp Bible", id: "reader") {
            LibraryRootView()
                .environmentObject(libraryModel)
                .environmentObject(syncController)
        }
        .defaultSize(width: 1_240, height: 820)
        .commands {
            LampBibleCommands()
        }

        WindowGroup("Module Studio", id: "module-studio") {
            ModuleStudioView()
                .environmentObject(libraryModel)
                .environmentObject(syncController)
        }
        .defaultSize(width: 1_080, height: 720)

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

private struct ReaderSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var syncController: LibrarySyncController
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 7.0
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
    @AppStorage("devotional.fontSize") private var devotionalFontSize = 17.0
    @AppStorage("quiz.defaultAgeGroup") private var defaultQuizAgeGroup = ""
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
        Form {
            Section("Reader") {
                LabeledContent("Text Size") {
                    HStack {
                        Slider(value: $fontSize, in: 15...32, step: 1)
                            .frame(width: 220)
                        Text(fontSize.formatted(.number.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                LabeledContent("Line Spacing") {
                    HStack {
                        Slider(value: $lineSpacing, in: 2...16, step: 1)
                            .frame(width: 220)
                        Text(lineSpacing.formatted(.number.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
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
                    fontSize = 20
                    lineSpacing = 7
                    readAloudVoice = ""
                    readAloudRate = 0.5
                    followReadAloud = true
                    showStrongsHints = true
                    canonicalCrossReferenceOrder = false
                }
            }

            Section("Modules") {
                Picker("Default Translation", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "reader.defaultTranslationID") ?? "" },
                    set: { model.setDefaultTranslation($0.isEmpty ? nil : $0) }
                )) {
                    Text("First Available").tag("")
                    ForEach(model.allTranslations) { translation in
                        Text(translation.name).tag(translation.id)
                    }
                }
                ForEach(configurableModules) { module in
                    HStack {
                        Toggle(module.name, isOn: Binding(
                            get: { !model.hiddenModuleIDs.contains(module.id) },
                            set: { model.setModuleHidden(module.id, hidden: !$0) }
                        ))
                        Spacer()
                        Button("Move Up", systemImage: "chevron.up") {
                            model.moveModule(module.id, direction: -1)
                        }
                        .labelStyle(.iconOnly)
                        Button("Move Down", systemImage: "chevron.down") {
                            model.moveModule(module.id, direction: 1)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }

            Section("Devotionals & Quizzes") {
                LabeledContent("Devotional Text Size") {
                    Slider(value: $devotionalFontSize, in: 13...30, step: 1)
                        .frame(width: 220)
                }
                TextField("Preferred quiz age-group ID", text: $defaultQuizAgeGroup)
            }

            Section("Reading Plans") {
                Stepper("Reading speed: \(wordsPerMinute) words per minute", value: $wordsPerMinute, in: 80...600, step: 5)
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
                .disabled(!reminderEnabled)
                if let reminderError {
                    Label(reminderError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Sync") {
                Picker("Provider", selection: Binding(
                    get: { syncController.provider },
                    set: { syncController.provider = $0 }
                )) {
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
                    SecureField("Password", text: $webDAVPassword)
                        .onChange(of: webDAVPassword) { _, value in syncController.password = value }
                }
                Toggle("Sync automatically when Lamp Bible opens", isOn: $automaticSync)
                    .disabled(syncController.provider == .off)
                HStack {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await syncController.sync(library: model.library) }
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
        .formStyle(.grouped)
        .frame(width: 680, height: 760)
        .padding()
        .onChange(of: reminderEnabled) { _, _ in applyReminder() }
        .onChange(of: reminderHour) { _, _ in applyReminder() }
        .onChange(of: reminderMinute) { _, _ in applyReminder() }
        .onAppear {
            webDAVEndpoint = syncController.endpoint
            webDAVUsername = syncController.username
            webDAVPassword = syncController.password
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

    private var configurableModules: [LampInstalledModule] {
        let kinds: Set<LampModuleKind> = [.translation, .dictionary, .commentary]
        let positions = Dictionary(uniqueKeysWithValues: model.moduleOrder.enumerated().map { ($1, $0) })
        return model.modules.filter { kinds.contains($0.kind) }.sorted {
            let left = positions[$0.id] ?? Int.max
            let right = positions[$1.id] ?? Int.max
            if left != right { return left < right }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
