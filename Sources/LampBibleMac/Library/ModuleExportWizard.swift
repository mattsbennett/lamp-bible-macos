import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

struct ModuleExportChoice: Identifiable {
    enum Source {
        case personal(LampPersonalModule)
        case installed(LampInstalledModule)
    }

    let id: String
    let name: String
    let kind: LampModuleKind
    let exportIdentifier: String
    let source: Source

    static func personal(_ module: LampPersonalModule) -> Self {
        Self(
            id: "personal:\(module.id)",
            name: module.name,
            kind: module.kind,
            exportIdentifier: module.id,
            source: .personal(module)
        )
    }

    static func installed(_ module: LampInstalledModule) -> Self {
        Self(
            id: "installed:\(module.kind.rawValue):\(module.id)",
            name: module.name,
            kind: module.kind,
            exportIdentifier: module.id,
            source: .installed(module)
        )
    }

    var supportedFormats: [LampModuleExportFormat] {
        switch source {
        case .personal(let module):
            LampLibrary.supportedExportFormats(for: module)
        case .installed(let module):
            LampLibrary.supportsMarkdownExport(for: module.kind)
                ? [.lamp, .markdown]
                : [.lamp]
        }
    }
}

struct ModuleExportRequest: Identifiable {
    let id = UUID()
    let initialChoiceID: String?
}

struct ModuleExportWizard: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel
    let choices: [ModuleExportChoice]

    @State private var selectedChoiceID: String
    @State private var format = LampModuleExportFormat.lamp
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(choices: [ModuleExportChoice], initialChoiceID: String?) {
        self.choices = choices
        let initialID = initialChoiceID.flatMap { requestedID in
            choices.first(where: { $0.id == requestedID })?.id
        } ?? choices.first?.id ?? ""
        _selectedChoiceID = State(initialValue: initialID)
    }

    private var selectedChoice: ModuleExportChoice? {
        choices.first { $0.id == selectedChoiceID }
    }

    private var supportsMarkdown: Bool {
        selectedChoice?.supportedFormats.contains(.markdown) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Export Personal Module", systemImage: "square.and.arrow.up")
                    .font(.title2.bold())
                Text("Choose a personal or user-installed module and the portable format to create.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 24)

            Form {
                Picker("Module", selection: $selectedChoiceID) {
                    ForEach(choices) { choice in
                        Text("\(choice.name) — \(choice.kind.exportDisplayName)")
                            .tag(choice.id)
                    }
                }
                .help("Choose the personal or user-installed module to export")

                if supportsMarkdown {
                    Picker("Format", selection: $format) {
                        Text("Lamp Module (.lamp)")
                            .tag(LampModuleExportFormat.lamp)
                        Text("Markdown (.md)")
                            .tag(LampModuleExportFormat.markdown)
                    }
                    .pickerStyle(.radioGroup)
                    .help("Choose the exported file format")
                } else {
                    LabeledContent("Format") {
                        Text("Lamp Module (.lamp)")
                    }
                    .accessibilityLabel("Format: Lamp Module")
                }

                LabeledContent("About this format") {
                    Text(formatDescription)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 330, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .onChange(of: selectedChoiceID) { _, _ in
                if !supportsMarkdown { format = .lamp }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", systemImage: "square.and.arrow.up") {
                    chooseDestinationAndExport()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedChoice == nil || isExporting)
                .help("Choose where to save the exported module")
            }
            .padding(16)
        }
        .frame(width: 540, height: 390)
        .alert(
            "Module Could Not Be Exported",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The module could not be exported.")
        }
    }

    private var formatDescription: String {
        switch format {
        case .lamp:
            if let choice = selectedChoice, case .personal = choice.source {
                "A portable snapshot of the current personal collection, preserving its structured content and metadata."
            } else {
                "A lossless copy of the original module, including all metadata, annotations, and structured content."
            }
        case .markdown:
            "A readable text version of the module. Use the Lamp format when you need to preserve every module feature."
        }
    }

    private func chooseDestinationAndExport() {
        guard let choice = selectedChoice else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(choice.name)"
        panel.prompt = "Export"
        panel.nameFieldStringValue = choice.exportIdentifier + (format == .lamp ? ".lamp" : ".md")
        panel.allowedContentTypes = format == .lamp
            ? [UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data)]
            : [UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isExporting = true
        errorMessage = nil
        Task {
            do {
                switch choice.source {
                case .personal(let module):
                    try await model.library.exportPersonalModule(
                        module,
                        format: format,
                        to: destinationURL
                    )
                case .installed(let module):
                    try await model.library.exportModule(
                        moduleID: module.id,
                        format: format,
                        to: destinationURL
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}

private extension LampModuleKind {
    var exportDisplayName: String {
        switch self {
        case .translation: "Translation"
        case .dictionary: "Dictionary"
        case .commentary: "Commentary"
        case .book: "Book"
        case .devotional: "Writing"
        case .notes: "Notes"
        case .plan: "Reading Plan"
        case .highlights: "Highlights"
        case .quiz: "Quiz"
        }
    }
}
