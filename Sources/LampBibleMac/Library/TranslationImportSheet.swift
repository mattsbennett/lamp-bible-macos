import LampCore
import LampModuleKit
import SwiftUI

/// A Bible file that has been read and is waiting for a name before it
/// becomes a translation.
struct PendingTranslationImport: Identifiable {
    let id = UUID()
    let sourceName: String
    let translation: LampImportedTranslation
}

/// A locked SWORD module waiting for the key its owner bought.
struct TranslationUnlockRequest: Identifiable {
    let id = UUID()
    let url: URL
    let prompt: String
}

/// Shows what was found in a Bible file and asks what to call the translation.
struct TranslationImportSheet: View {
    let pending: PendingTranslationImport
    let installed: [LampInstalledModule]
    let onImport: (_ name: String, _ abbreviation: String, _ language: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var abbreviation: String
    @State private var language: String

    init(
        pending: PendingTranslationImport,
        installed: [LampInstalledModule],
        onImport: @escaping (_ name: String, _ abbreviation: String, _ language: String) -> Void
    ) {
        self.pending = pending
        self.installed = installed
        self.onImport = onImport
        _name = State(initialValue: pending.translation.suggestedName ?? "")
        _abbreviation = State(initialValue: pending.translation.suggestedAbbreviation ?? "")
        _language = State(initialValue: pending.translation.language ?? "en")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAbbreviation: String { abbreviation.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var destination: LampTranslationImportDestination {
        LampTranslationImporter.destination(abbreviation: trimmedAbbreviation, installed: installed)
    }

    private var replacing: LampInstalledModule? {
        installed.first { $0.id == destination.replacedModuleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import \(pending.sourceName)")
                    .font(.title2.bold())
                    .lineLimit(2)
                Text("\(pending.translation.format.displayName) · \(pending.translation.report.contentsDescription)")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("New American Standard Bible"))
                TextField("Abbreviation", text: $abbreviation, prompt: Text("NASB"))
                Picker("Language", selection: $language) {
                    ForEach(LampTranslationImporter.languageOptions(including: language), id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
            }
            .formStyle(.columns)

            if let replacing {
                Label(
                    "Replaces “\(replacing.name)”, imported earlier as \(replacing.abbreviation ?? trimmedAbbreviation).",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .foregroundStyle(.secondary)
            } else if let sharing = LampTranslationImporter.translation(
                sharingAbbreviation: trimmedAbbreviation,
                installed: installed,
                except: destination
            ) {
                Label(
                    "“\(sharing.name)” is also called \(trimmedAbbreviation) in your library.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
            }

            let notices = pending.translation.report.notices
            if !notices.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notices, id: \.self) { notice in
                            Text(notice)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                } label: {
                    Text("Not imported as written")
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let copyright = pending.translation.copyright {
                    Text(copyright)
                        .lineLimit(3)
                }
                Text("The translation is kept in your library and syncs like your other modules. Import only Bibles you have the right to use.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(destination.replacedModuleID == nil ? "Import" : "Replace") {
                    onImport(trimmedName, trimmedAbbreviation, language)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedAbbreviation.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
