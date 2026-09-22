import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

struct ReaderChatSidebarView: View {
    @EnvironmentObject private var libraryModel: LibraryModel
    @AppStorage("reader.chat.provider") private var providerID = AIProviderCLI.codex.rawValue
    @AppStorage("agent.moduleAccess.enabled") private var moduleAccessEnabled = true
    @AppStorage("agent.moduleAccess.personal") private var personalContentEnabled = false
    @State private var configuration: LampAgentMCPConfiguration?
    @State private var preparationError: String?

    let windowID: UUID
    let close: () -> Void

    private var provider: AIProviderCLI { AIProviderCLI(rawValue: providerID) ?? .codex }

    private var workspace: URL {
        ReaderChatWorkspaceStore.workspaceURL(
            libraryRootURL: libraryModel.library.rootURL, windowID: windowID
        )
    }

    private var accessPolicy: LampAgentAccessPolicy {
        // Reader research spans the whole installed library, including modules
        // hidden from the reader menus. Personal content retains its opt-in.
        LampAgentAccessPolicy(
            isEnabled: moduleAccessEnabled,
            includesPersonalContent: personalContentEnabled
        )
    }

    private var context: ReaderChatContext? {
        guard let book = libraryModel.selectedBook,
              let translation = libraryModel.selectedTranslation else { return nil }
        return ReaderChatContext(
            reference: "\(book.name) \(libraryModel.selectedChapterNumber)",
            translationID: translation.id,
            translationName: translation.name
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Reader Chat", systemImage: "bubble.left.and.bubble.right")
                        .font(.headline)
                    Spacer()
                    Button("Close Chat", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Close reader chat")
                }

                HStack {
                    Picker("Provider", selection: $providerID) {
                        ForEach(AIProviderCLI.allCases) { provider in
                            Text(provider.shortName).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    Spacer()
                    Label("Read-only", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let context {
                    Label(context.reference, systemImage: "book")
                        .font(.subheadline.weight(.medium))
                    Text(context.translationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(context.translationName)
                } else {
                    Text("Choose a chapter in the reader to begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(moduleAccessEnabled
                        ? (personalContentEnabled ? "All installed modules and personal study content" : "All installed modules")
                        : "Module access is off in AI & Agents settings")
                    Spacer(minLength: 4)
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("AI provider and module access settings")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if let configuration {
                NativeAgentChatView(
                    provider: provider,
                    workspace: workspace,
                    mode: .reader(configuration),
                    canSend: context != nil,
                    preparePrompt: { question in
                        guard let context else {
                            throw CocoaError(.fileReadUnknown, userInfo: [
                                NSLocalizedDescriptionKey: "Choose a chapter in the reader first.",
                            ])
                        }
                        try writeAccessPolicy()
                        return context.prompt(for: question)
                    }
                )
                .id("\(provider.rawValue)|\(workspace.path)")
            } else if let preparationError {
                ContentUnavailableView {
                    Label("Chat Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text(preparationError)
                } actions: {
                    Button("Try Again", action: prepareWorkspace)
                }
            } else {
                ProgressView("Preparing Chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .onAppear(perform: prepareWorkspace)
        .onChange(of: accessPolicy) { _, _ in
            do {
                try writeAccessPolicy()
            } catch {
                preparationError = error.localizedDescription
                configuration = nil
            }
        }
    }

    private var policyURL: URL { workspace.appendingPathComponent(".lamp/module-policy.json") }

    private func writeAccessPolicy() throws {
        try FileManager.default.createDirectory(
            at: policyURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(accessPolicy).write(to: policyURL, options: .atomic)
    }

    private func prepareWorkspace() {
        do {
            guard let helper = AgentModuleAccessPreferences.mcpHelperExecutableURL else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "The Lamp module helper is unavailable. Rebuild or reinstall Lamp Bible to restore chat access to your library.",
                ])
            }
            let configuration = LampAgentMCPConfiguration(
                helperExecutableURL: helper,
                libraryRootURL: libraryModel.library.rootURL,
                bundledModulesArchiveURL: Bundle.main.url(
                    forResource: "bundled_modules.db", withExtension: "zlib"
                ),
                policyURL: policyURL
            )
            try writeAccessPolicy()
            try ReaderChatWorkspaceStore.prepare(workspace: workspace, configuration: configuration)
            self.configuration = configuration
            preparationError = nil
        } catch {
            preparationError = error.localizedDescription
        }
    }
}
